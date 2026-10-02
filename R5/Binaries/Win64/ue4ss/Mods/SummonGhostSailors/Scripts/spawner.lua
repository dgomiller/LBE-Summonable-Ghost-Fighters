--[[
 SummonGhostSailors / spawner.lua — spawn + composite-look + ghost-material plumbing.

 Ported (trimmed) from LivingBase's own spawner.lua, verbatim where it matters:
   resolveClass/resolveAsset, getGameplayStatics, spotInFrontOfPlayer, makeSetDressing,
   ensureController, _DoEngineSpawn (the UE5.6 deferred-spawn signature auto-detection),
   Spawn itself, SetCompositeParams, ApplyGhostMaterial, HideNameplate.

 Deliberately dropped vs. the original: persistence/ledger writes (this mod never saves
 a spawn to disk — that IS how "non-persistent" is guaranteed, not a flag to check),
 toast overlay, target-lock reticle, raytrace-channel/interaction/quest-scenario strips
 (statue/decor-specific, not relevant to a crew pawn), GetFriendlyFactionParams/
 MakeFriendly (BP_Mob_Crew_Regular_Player is already player-aligned by class default —
 LivingBase's own testbed.lua spawns this exact roster the same way, makeFriendly=false).
]]

local UEHelpers = require("UEHelpers")
local Config = require("config")

local Spawner = {}
Spawner.spawned = {}   -- { {actor=, label=}, ... } — plain tracking, no ledger file

local function log(msg) if Config.VERBOSE then print("[GhostSailors] " .. tostring(msg) .. "\n") end end
local function always(msg) print("[GhostSailors] " .. tostring(msg) .. "\n") end

--------------------------------------------------------------------
-- Class/asset resolution.
--------------------------------------------------------------------
-- AssetRegistry lookup (ported from LivingBase's resolveViaAssetRegistry): a plain LoadAsset does not
-- always bring in a Blueprint class (the Blackbeard Grenadier never loaded that way), but
-- AssetRegistryHelpers:GetAsset with the exact "<package>.<Name>_C" path returns it directly.
local _assetRegistryHelpers = nil
local function resolveViaAssetRegistry(path)
    local packageName, assetName = path:match("^(.+)%.([^%.]+)$")
    if not (packageName and assetName) then return nil end
    if not _assetRegistryHelpers then
        _assetRegistryHelpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end
    if not _assetRegistryHelpers then return nil end
    local ok, result = pcall(function()
        return _assetRegistryHelpers:GetAsset({
            PackageName = UEHelpers.FindOrAddFName(packageName),
            AssetName = UEHelpers.FindOrAddFName(assetName),
        })
    end)
    if ok and result and result:IsValid() then return result end
    return nil
end

local function resolveClass(path)
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    log("Class not in memory, attempting LoadAsset: " .. path)
    local okLoad = pcall(function() LoadAsset(path) end)
    if okLoad then
        cls = StaticFindObject(path)
        if cls and cls:IsValid() then return cls end
    end
    local direct = resolveViaAssetRegistry(path)
    if direct and direct:IsValid() then return direct end
    return nil
end

function Spawner.ResolveClass(path) return resolveClass(path) end

local function resolveAsset(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    local okLoad, loadErr = pcall(function() LoadAsset(path) end)
    if not okLoad then
        always("[resolveAsset] LoadAsset threw for " .. tostring(path) .. ": " .. tostring(loadErr))
    end
    o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    always("[resolveAsset] StaticFindObject still nil after LoadAsset for " .. tostring(path)
        .. " (loadOk=" .. tostring(okLoad) .. ")")
    return nil
end

-- Spawner.Prewarm() — 2026-08-26, RedFalcon: "if i manually assign the texture first, then it
-- works". Confirms LoadAsset kicks off a real, non-instant streaming load for these specific
-- ghost-character assets (a Material + a MaterialInstance neither this mod nor LivingBase had
-- ever touched yet this session) — an immediate StaticFindObject retry right after, and even a
-- handful of 500ms-spaced retries, isn't reliably enough wall-clock time for it to finish. A
-- prior MANUAL resolve earlier in the session (e.g. via LivingBase's lbtestmaterial2) gives it
-- that time in the background before anything actually needs it, which is why "warming it up
-- first" works. Call this once at mod load, well before the player can possibly press the
-- summon key — by the time they do, the assets have had real time to finish streaming in.
function Spawner.Prewarm()
    local paths = {
        Config.GHOST_SKIN_MAT_PATH, Config.GHOST_CLOTH_MAT_PATH, Config.GHOST_HAIR_MAT_PATH,
        Config.GHOST_ARMOR_MAT_PATH, Config.GRENADIER_CLASS, Config.GHOST_FX_PATH,
        Config.GHOST_DESPAWN_FX_PATH, Config.FRIENDLY_FACTION_ASSET,
    }
    for _, entry in ipairs(Config.SENKAMATI_ROSTER or {}) do
        paths[#paths + 1] = entry.class
    end
    for _, path in ipairs(paths) do
        pcall(function() LoadAsset(path) end)
    end
    log("Prewarm: kicked off LoadAsset for ghost materials, FX, faction asset, and Senkamati classes")
end

local function getGameplayStatics()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if gs and gs:IsValid() then return gs end
    return nil
end

--------------------------------------------------------------------
-- Spawn location: ~3m in front of the player, at player height, facing the camera yaw.
--------------------------------------------------------------------
local function spotInFrontOfPlayer(distanceUU)
    distanceUU = distanceUU or 300.0
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then return nil end
    local pawn = pc.Pawn
    if not pawn or not pawn:IsValid() then return nil end
    local loc = pawn:K2_GetActorLocation()
    local yawDeg = pawn:K2_GetActorRotation().Yaw
    pcall(function()
        local camRot = pc:GetControlRotation()
        if camRot then yawDeg = camRot.Yaw end
    end)
    local yawRad = math.rad(yawDeg)
    return {
        X = loc.X + math.cos(yawRad) * distanceUU,
        Y = loc.Y + math.sin(yawRad) * distanceUU,
        Z = loc.Z,
    }, yawDeg
end

local function makeSetDressing(actor)
    pcall(function() actor:SetCanBeDamaged(false) end)
    pcall(function() actor.bCanBeDamaged = false end)
end

-- Raw-spawned pawns have no AI controller until this runs (frozen otherwise).
local function ensureController(actor)
    pcall(function() actor:SpawnDefaultController() end)
    pcall(function() actor:ActivateCharacter() end)
end

--------------------------------------------------------------------
-- Engine spawn with UE5.6 signature auto-detection (ported verbatim — load-bearing).
--------------------------------------------------------------------
local beginVariants = {
    { name = "UE5.6 (6 args: +ScaleMethod)",
      call = function(gs, w, c, t) return gs:BeginDeferredActorSpawnFromClass(w, c, t, 1, nil, 1) end },
    { name = "UE5.6 (7 args: +ScaleMethod +ret slot)",
      call = function(gs, w, c, t) return gs:BeginDeferredActorSpawnFromClass(w, c, t, 1, nil, 1, nil) end },
    { name = "UE4 classic (5 args)",
      call = function(gs, w, c, t) return gs:BeginDeferredActorSpawnFromClass(w, c, t, 1, nil) end },
}
local finishVariants = {
    { name = "UE5 (3 args: +ScaleMethod)",
      call = function(gs, a, t) return gs:FinishSpawningActor(a, t, 1) end },
    { name = "UE4 classic (2 args)",
      call = function(gs, a, t) return gs:FinishSpawningActor(a, t) end },
    { name = "UE5 (4 args: +ScaleMethod +ret slot)",
      call = function(gs, a, t) return gs:FinishSpawningActor(a, t, 1, nil) end },
}
local lockedBegin, lockedFinish = nil, nil

local function doEngineSpawn(gs, world, cls, transform, label, preFinish)
    local deferred = nil
    if lockedBegin then
        local ok, res = pcall(lockedBegin.call, gs, world, cls, transform)
        if ok then deferred = res else lockedBegin = nil end
    end
    if not deferred then
        for _, v in ipairs(beginVariants) do
            local ok, res = pcall(v.call, gs, world, cls, transform)
            if ok and res and res:IsValid() then
                deferred = res
                lockedBegin = v
                log("Begin-spawn signature locked: " .. v.name)
                break
            end
        end
    end
    if not deferred or not deferred:IsValid() then
        always("SPAWN FAILED (all begin-spawn signatures rejected): " .. tostring(label))
        return nil
    end

    if preFinish then
        local ok, err = pcall(preFinish, deferred)
        if not ok then log("preFinish hook error (non-fatal): " .. tostring(err)) end
    end

    local finished = false
    if lockedFinish then
        local ok = pcall(lockedFinish.call, gs, deferred, transform)
        if ok then finished = true else lockedFinish = nil end
    end
    if not finished then
        for _, v in ipairs(finishVariants) do
            local ok = pcall(v.call, gs, deferred, transform)
            if ok then
                finished = true
                lockedFinish = v
                log("Finish-spawn signature locked: " .. v.name)
                break
            end
        end
    end
    if not finished then
        always("SPAWN FAILED (all finish-spawn signatures rejected): " .. tostring(label))
        pcall(function() deferred:K2_DestroyActor() end)
        return nil
    end
    return deferred
end

--------------------------------------------------------------------
-- Composite-look application (pre-build only — the mechanism confirmed to actually stick).
--------------------------------------------------------------------
function Spawner.SetCompositeParams(actor, paramsPath, sex, bodyTypesPath)
    if not (actor and actor:IsValid()) then return false end
    local comp = nil
    pcall(function() comp = actor.CompositeMeshComponent end)
    if not (comp and comp:IsValid()) then return false end
    local params = resolveAsset(paramsPath)
    local bodies = resolveAsset(bodyTypesPath)
    if bodies then pcall(function() comp.BodyTypeParams = bodies end) end
    if params then pcall(function() comp.DefaultParams = params end) end
    if sex and sex ~= 0 then pcall(function() comp:SetCharacterSex(sex) end) end
    return true
end

--------------------------------------------------------------------
-- Spawner.Spawn(classPath, label, compositeLook, makeFriendly) -> actor|nil
-- compositeLook = { params, sex, bodyTypes } or nil.
-- makeFriendly (2026-08-26, added for the Senkamati ally): copies the friendly-faction params
-- BOTH pre-build (inside the deferred-spawn window, before BeginPlay runs) AND again
-- post-build — matching LivingBase's own Spawner.Spawn exactly (spawner.lua:829-850). This
-- matters for a genuinely hostile native mob: applying the faction copy only AFTER BeginPlay
-- (this mod's first attempt, via a post-spawn retry loop alone) was too late — its AIController
-- had already read/cached its initial hostile-faction perception state by then, so it kept
-- attacking the player despite FactionsParams eventually being set correctly. Pre-build
-- application is the fix; the post-build call + main.lua's own retry loop stay as backup.
--------------------------------------------------------------------
local instanceLabelCounts = {}
local function nextInstanceLabel(baseLabel)
    baseLabel = tostring(baseLabel or "GhostSailor")
    local n = (instanceLabelCounts[baseLabel] or 0) + 1
    instanceLabelCounts[baseLabel] = n
    return baseLabel .. " " .. n
end

function Spawner.Spawn(classPath, label, compositeLook, makeFriendly)
    local cls = resolveClass(classPath)
    if not cls then
        always("SPAWN FAILED (class unresolved): " .. tostring(classPath))
        return nil
    end

    local loc = spotInFrontOfPlayer()
    if not loc then
        always("SPAWN FAILED (no player location): " .. tostring(label))
        return nil
    end

    local gs = getGameplayStatics()
    local world = UEHelpers.GetWorld()
    if not gs or not world or not world:IsValid() then
        always("SPAWN FAILED: engine handles unavailable")
        return nil
    end

    local yawUsed = 0.0
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        local camRot = pc and pc:IsValid() and pc:GetControlRotation()
        if camRot then yawUsed = camRot.Yaw + 180.0 end
    end)
    local halfRad = math.rad(yawUsed) * 0.5
    local transform = {
        Rotation = { W = math.cos(halfRad), X = 0.0, Y = 0.0, Z = math.sin(halfRad) },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local hasLook = compositeLook and (compositeLook.params or compositeLook.bodyTypes)
    local preFinish = nil
    if hasLook or makeFriendly then
        preFinish = function(a)
            if hasLook then
                pcall(function()
                    Spawner.SetCompositeParams(a, compositeLook.params, compositeLook.sex, compositeLook.bodyTypes)
                end)
            end
            if makeFriendly then pcall(function() Spawner.MakeFriendly(a) end) end
        end
    end

    local finalLabel = nextInstanceLabel(label)
    local actor = doEngineSpawn(gs, world, cls, transform, finalLabel, preFinish)
    if not actor or not actor:IsValid() then return nil end

    if makeFriendly then pcall(function() Spawner.MakeFriendly(actor) end) end
    if not Config.COMBATANT then makeSetDressing(actor) end
    ensureController(actor)
    if Config.HIDE_NAMEPLATES then Spawner.HideNameplate(actor) end

    Spawner.spawned[#Spawner.spawned + 1] = { actor = actor, label = finalLabel }
    log(string.format("SPAWNED [%s] -> %s", finalLabel, classPath))
    return actor, finalLabel
end

--------------------------------------------------------------------
-- Opacity tuning — CONFIRMED DANGEROUS (2026-08-26). LivingBase's own history already
-- confirmed comp:CreateDynamicMaterialInstance (the component-level UFUNCTION) crashes this
-- game natively, twice. This tried a DIFFERENT function instead —
-- UKismetMaterialLibrary:CreateDynamicMaterialInstance, a library call rather than a
-- component method — on the theory that the crashing call itself would never run. First
-- live attempt (a wrong arg count) errored cleanly, caught by pcall, no crash, fell back to
-- the fixed-look material correctly. Second live attempt (this function's current
-- signature-auto-detection code) CRASHED THE GAME — zero [ghost-opacity] log output at all
-- beforehand, the same "pcall cannot catch this" native-crash signature already documented
-- for SetBody/AttachActorToShip elsewhere in this project's history. Disabled immediately
-- (Config.GHOST_OPACITY = 1.0, see config.lua) per the "if it doesn't work we abandon that
-- option" call — do NOT re-enable by just flipping that constant back without a genuinely
-- new theory. The crash may not even be specific to the argument count tried; it could be
-- that ANY CreateDynamicMaterialInstance-family call is unsafe in this engine build
-- regardless of which UFunction variant or signature is used. Kept below as a documented
-- reference for whoever revisits this, not as code anyone should assume is safe to call.
--------------------------------------------------------------------
local function getKismetMaterialLibrary()
    local o = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if o and o:IsValid() then return o end
    return nil
end

-- CreateDynamicMaterialInstance's real signature is (WorldContextObject, Parent, OptionalName,
-- CreationFlags) — 4 declared params. First live attempt with 3 args (no CreationFlags) failed
-- with "expected 5 parameters, received 3": same "this UE4SS build counts the return slot"
-- quirk LivingBase's own spawner.lua already solved for BeginDeferredActorSpawnFromClass — try
-- known-plausible variants once, lock onto whichever the engine accepts.
local createVariants = {
    { name = "4 args (+CreationFlags=0)",
      call = function(lib, w, m, n) return lib:CreateDynamicMaterialInstance(w, m, n, 0) end },
    { name = "5 args (+CreationFlags=0 +ret slot)",
      call = function(lib, w, m, n) return lib:CreateDynamicMaterialInstance(w, m, n, 0, nil) end },
    { name = "3 args classic",
      call = function(lib, w, m, n) return lib:CreateDynamicMaterialInstance(w, m, n) end },
}
local lockedCreateVariant = nil

local function tryOpacityInstance(mat, opacity)
    local lib = getKismetMaterialLibrary()
    if not lib then
        always("[ghost-opacity] KismetMaterialLibrary unavailable — keeping fixed-look material.")
        return nil
    end
    local world = UEHelpers.GetWorld()
    local dyn
    if lockedCreateVariant then
        local ok, res = pcall(lockedCreateVariant.call, lib, world, mat, "GhostSailorMat")
        if ok then dyn = res else lockedCreateVariant = nil end
    end
    if not (dyn and dyn:IsValid()) then
        for _, v in ipairs(createVariants) do
            local ok, res = pcall(v.call, lib, world, mat, "GhostSailorMat")
            if ok and res and res:IsValid() then
                dyn = res
                lockedCreateVariant = v
                log("[ghost-opacity] CreateDynamicMaterialInstance signature locked: " .. v.name)
                break
            elseif not ok then
                log("[ghost-opacity] variant '" .. v.name .. "' rejected: " .. tostring(res))
            end
        end
    end
    if not (dyn and dyn:IsValid()) then
        always("[ghost-opacity] CreateDynamicMaterialInstance failed on every known signature — keeping fixed-look material.")
        return nil
    end
    always("[ghost-opacity] dynamic instance created — trying to set opacity=" .. tostring(opacity))

    local anyScalarOk = false
    for _, pname in ipairs(Config.GHOST_OPACITY_SCALAR_NAMES) do
        if pcall(function() dyn:SetScalarParameterValue(pname, opacity) end) then
            anyScalarOk = true
            log("[ghost-opacity] scalar '" .. pname .. "' set ok")
        end
    end

    local anyVectorOk = false
    for _, pname in ipairs(Config.GHOST_COLOR_PARAM_NAMES) do
        local cur
        local okGet = pcall(function() cur = dyn:K2_GetVectorParameterValue(pname) end)
        if okGet and cur then
            local newColor = { R = cur.R, G = cur.G, B = cur.B, A = opacity }
            if pcall(function() dyn:SetVectorParameterValue(pname, newColor) end) then
                anyVectorOk = true
                log("[ghost-opacity] vector '" .. pname .. "' alpha set ok (RGB preserved)")
            end
        end
    end

    if not anyScalarOk and not anyVectorOk then
        always("[ghost-opacity] no known opacity parameter matched — material may not expose one (or isn't Translucent at all). Using fixed-look material.")
        return nil
    end
    return dyn
end

--------------------------------------------------------------------
-- Ghost material — CONFIRMED, RedFalcon: "it looks awesome" (2026-08-26). Skin material on
-- actor.Mesh (the base body), a different material on every other composite clothing/armor
-- piece — ported from LivingBase's own Spawner.ApplyTwoMaterialsToActor, including its
-- confirmed fix: identify the body-mesh component by GetFName():ToString(), never by raw `==`
-- (two independently-obtained component references to the same component aren't reliably
-- `==` in this UE4SS build — confirmed live the hard way, see LivingBase's CLAUDE.md item 79's
-- follow-up).
--------------------------------------------------------------------
local function unwrapComp(comp)
    pcall(function() if comp ~= nil and type(comp) == "userdata" and comp.get then comp = comp:get() end end)
    return comp
end

local function compFName(comp)
    local n = nil
    pcall(function() n = comp:GetFName():ToString() end)
    return n
end

-- Ghost look = LivingBase's "Make Ghost" preset (2026-10-02, RedFalcon's revisit TODO 1), ported:
--   body mesh: skin-family slot (_Small/_Medium/_Large) AND eye/mouth slots -> skin material (blank
--   eyes, no floating teeth); any other body slot -> plain M_CharacterGhost_V2 (no glowing eyes).
--   Head hair + Beard/Mustache/Whiskers/Eyebrows -> MI_Hair_Ghost. All other skeletal pieces
--   (clothing/armor) and every static mesh (weapons/belt) -> MI_Boneman_Ghost_Spanish.
-- Materials only, never mesh swaps -- the sailor keeps its own clothes.
local FACIAL_TOKENS = { "Eyebrow", "Mustache", "Whiskers", "Beard" }

function Spawner.ApplyGhostMaterial(actor)
    if not (actor and actor:IsValid()) then return false end
    if Config.DISABLE_GHOST_EFFECT then return true end   -- setting: leave the summon's own look alone
    local skinMat  = resolveAsset(Config.GHOST_SKIN_MAT_PATH)
    local baseMat  = resolveAsset(Config.GHOST_CLOTH_MAT_PATH)
    local hairMat  = resolveAsset(Config.GHOST_HAIR_MAT_PATH)
    local armorMat = resolveAsset(Config.GHOST_ARMOR_MAT_PATH)
    for _, r in ipairs({ { skinMat, "SKIN", Config.GHOST_SKIN_MAT_PATH }, { baseMat, "BASE", Config.GHOST_CLOTH_MAT_PATH },
                         { hairMat, "HAIR", Config.GHOST_HAIR_MAT_PATH }, { armorMat, "ARMOR", Config.GHOST_ARMOR_MAT_PATH } }) do
        if not (r[1] and r[1]:IsValid()) then
            always("[ghost] could not resolve " .. r[2] .. " material: " .. tostring(r[3]))
            return false
        end
    end

    local function setAll(comp, mat)
        local n, ok_n = 0, 0
        pcall(function() n = comp:GetNumMaterials() end)
        for slot = 0, (n - 1) do
            if pcall(function() comp:SetMaterial(slot, mat) end) then ok_n = ok_n + 1 end
        end
        return ok_n
    end

    local bodyMesh = unwrapComp(actor.Mesh)
    local bodyName = bodyMesh and compFName(bodyMesh) or nil
    local skinSlots, baseSlots, hairSlots, armorSlots = 0, 0, 0, 0
    if bodyMesh and bodyMesh:IsValid() then
        local n = 0
        pcall(function() n = bodyMesh:GetNumMaterials() end)
        for slot = 0, n - 1 do
            local mat, matName = nil, ""
            pcall(function() mat = bodyMesh:GetMaterial(slot) end)
            if mat and mat:IsValid() then pcall(function() matName = mat:GetFName():ToString() end) end
            local low = matName:lower()
            local isSkin = matName:match("_Small$") or matName:match("_Medium$") or matName:match("_Large$")
                or low:find("eye") ~= nil or low:find("mouth") ~= nil
            local use = isSkin and skinMat or baseMat
            if pcall(function() bodyMesh:SetMaterial(slot, use) end) then
                if isSkin then skinSlots = skinSlots + 1 else baseSlots = baseSlots + 1 end
            end
        end
    end

    local function eachComp(className, fn)
        local cls = StaticFindObject("/Script/Engine." .. className)
        if not (cls and cls:IsValid()) then return end
        local ok, comps = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
        if not (ok and comps) then return end
        local n = 0
        pcall(function() n = comps:GetArrayNum() end)
        if n == 0 then pcall(function() n = #comps end) end
        for i = 1, n do
            local comp
            pcall(function() comp = comps[i] end)
            if not comp then pcall(function() comp = comps:Get(i) end) end
            comp = unwrapComp(comp)
            if comp and comp:IsValid() then fn(comp) end
        end
    end

    eachComp("SkeletalMeshComponent", function(comp)
        local cn = compFName(comp)
        if bodyName and cn == bodyName then return end
        local meshName, fullPath = "", ""
        pcall(function()
            local sk = comp.SkeletalMesh
            if not (sk and sk:IsValid()) and comp.GetSkeletalMeshAsset then sk = comp:GetSkeletalMeshAsset() end
            if sk and sk:IsValid() then
                meshName = sk:GetFName():ToString()
                pcall(function() fullPath = sk:GetFullName() end)
            end
        end)
        local isHair = fullPath:find("/Hair/") ~= nil
        if not isHair then
            for _, tok in ipairs(FACIAL_TOKENS) do
                if meshName:find(tok, 1, true) then isHair = true; break end
            end
        end
        if isHair then hairSlots = hairSlots + setAll(comp, hairMat)
        else armorSlots = armorSlots + setAll(comp, armorMat) end
    end)
    eachComp("StaticMeshComponent", function(comp)
        armorSlots = armorSlots + setAll(comp, armorMat)
    end)

    log(string.format("[ghost] skin=%d base=%d hair=%d armor=%d", skinSlots, baseSlots, hairSlots, armorSlots))
    return (skinSlots + baseSlots + hairSlots + armorSlots) > 0
end

--------------------------------------------------------------------
-- Follow effect — a separate NiagaraActor, spawned once and repositioned to the sailor's
-- exact location every follow-tick (see follow.lua). Ported from LivingBase's proven-safe
-- Spawner.TestSpawnNiagaraActor technique: a bare native NiagaraActor + a plain `niag.Asset =
-- sys` property write, no UFunction call involved at all. Deliberately NOT SpawnSystemAttached
-- (confirmed to crash this game in LivingBase's own history) and NOT actor-to-actor
-- K2_AttachToActor (also confirmed to crash there, different case).
--------------------------------------------------------------------
-- Computes the FX's target world position for a given sailor: ground-level Z (pulled down
-- from the sailor's own root, which sits at capsule-center height) and a small slide toward
-- the sailor's CURRENT back (from its own yaw, not a fixed world-axis offset — stays correct
-- as it turns while following) so the sailor ends up standing centered over the ground effect.
local function fxTargetFor(actor)
    local loc, yawDeg = nil, 0.0
    pcall(function() loc = actor:K2_GetActorLocation() end)
    if not loc then return nil end
    pcall(function() yawDeg = actor:K2_GetActorRotation().Yaw end)
    local yawRad = math.rad(yawDeg)
    local back = Config.GHOST_FX_BACK_UU or 0.0
    return {
        X = loc.X - math.cos(yawRad) * back,
        Y = loc.Y - math.sin(yawRad) * back,
        Z = loc.Z + (Config.GHOST_FX_Z_OFFSET or 0.0),
    }
end

function Spawner.SpawnFollowFx(actor)
    if not (actor and actor:IsValid()) then return nil end
    local pos = fxTargetFor(actor)
    if not pos then return nil end
    local sys = resolveAsset(Config.GHOST_FX_PATH)
    if not (sys and sys:IsValid()) then
        always("[ghost-fx] could not resolve " .. tostring(Config.GHOST_FX_PATH))
        return nil
    end
    local cls
    pcall(function() cls = StaticFindObject("/Script/Niagara.NiagaraActor") end)
    if not (cls and cls:IsValid()) then
        always("[ghost-fx] could not resolve NiagaraActor class")
        return nil
    end
    local gs = getGameplayStatics()
    local world = UEHelpers.GetWorld()
    if not (gs and world and world:IsValid()) then return nil end

    local scale = Config.GHOST_FX_SCALE or 1.0
    local transform = {
        Rotation = { W = 1.0, X = 0.0, Y = 0.0, Z = 0.0 },
        Translation = { X = pos.X, Y = pos.Y, Z = pos.Z },
        Scale3D = { X = scale, Y = scale, Z = scale },
    }
    local preFinish = function(a)
        pcall(function()
            local niag = a.NiagaraComponent
            if niag and niag:IsValid() then niag.Asset = sys end
        end)
    end
    return doEngineSpawn(gs, world, cls, transform, "GhostSailorFx", preFinish)
end

-- Reposition an already-spawned follow FX to a sailor's current location/facing.
function Spawner.MoveFollowFx(fxActor, actor)
    if not (fxActor and fxActor:IsValid()) then return false end
    local pos = fxTargetFor(actor)
    if not pos then return false end
    return pcall(function()
        fxActor:K2_SetActorLocation(
            { X = pos.X, Y = pos.Y, Z = pos.Z }, false, {}, false)
    end)
end

--------------------------------------------------------------------
-- One-shot FX (e.g. the dissipate puff on despawn) — spawns a NiagaraActor at a fixed location
-- and destroys it again after lifetimeMs, for a non-looping system that would otherwise sit
-- frozen on its last frame forever. Callable from an async context (e.g. follow.lua's tick,
-- which does NOT run on the game thread) — CONFIRMED LIVE (2026-08-26): LoadAsset (inside
-- resolveAsset) throws if not hopped onto the game thread first, and ExecuteWithDelay must
-- never be called from INSIDE an ExecuteInGameThread callback (confirmed by LivingBase's own
-- testbed.lua, "No overload found for function 'ExecuteWithDelay'") — so the spawn happens
-- inside ExecuteInGameThread, and the delayed cleanup is scheduled as a SIBLING call from
-- there, never nested inside that same callback.
--------------------------------------------------------------------
function Spawner.PlayOneShotFx(path, atLoc, lifetimeMs)
    if not (path and atLoc and atLoc.X) then return end
    if not ExecuteInGameThread then return end
    ExecuteInGameThread(function()
        pcall(function()
            local sys = resolveAsset(path)
            if not (sys and sys:IsValid()) then
                always("[ghost-fx] one-shot: could not resolve " .. tostring(path))
                return
            end
            local cls
            pcall(function() cls = StaticFindObject("/Script/Niagara.NiagaraActor") end)
            if not (cls and cls:IsValid()) then return end
            local gs = getGameplayStatics()
            local world = UEHelpers.GetWorld()
            if not (gs and world and world:IsValid()) then return end
            local transform = {
                Rotation = { W = 1.0, X = 0.0, Y = 0.0, Z = 0.0 },
                Translation = { X = atLoc.X, Y = atLoc.Y, Z = atLoc.Z },
                Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
            }
            local preFinish = function(a)
                pcall(function()
                    local niag = a.NiagaraComponent
                    if niag and niag:IsValid() then niag.Asset = sys end
                end)
            end
            local fx = doEngineSpawn(gs, world, cls, transform, "GhostDissipateFx", preFinish)
            if fx and fx:IsValid() then
                fx.__ghostOneShot = true
            end
        end)
    end)
    -- Sibling to the ExecuteInGameThread call above, not nested inside it. Can't hold a
    -- reference to the just-spawned actor synchronously (ExecuteInGameThread is fire-and-forget),
    -- so this sweeps every one-shot FX actor still tagged old enough to clear instead.
    if ExecuteWithDelay then
        ExecuteWithDelay(lifetimeMs or 3000, function()
            -- Game thread (2026-10-02): FindAllOf + K2_DestroyActor must not run on the timer thread.
            ExecuteInGameThread(function()
                pcall(function()
                    local list = FindAllOf and FindAllOf("NiagaraActor")
                    if not list then return end
                    local n = 0
                    pcall(function() n = list:GetArrayNum() end)
                    if n == 0 then pcall(function() n = #list end) end
                    for i = 1, n do
                        local a = list[i]
                        if not a then pcall(function() a = list:Get(i) end) end
                        local isOurs = false
                        pcall(function() isOurs = a.__ghostOneShot == true end)
                        if isOurs and a and a:IsValid() then
                            pcall(function() a:K2_DestroyActor() end)
                        end
                    end
                end)
            end)
        end)
    end
end

--------------------------------------------------------------------
-- Friendly-faction copy — ported from LivingBase's own spawner.lua (GetFriendlyFactionParams/
-- MakeFriendly). Copies the FactionsParams a player crewman points at onto a hostile-by-default
-- native mob, so it stops attacking the player/allies WITHOUT touching its AI/combat components
-- at all — the opposite of LivingBase's own "corrupted" Senkamati rows, which pacify (strip
-- combat) for safe display. This mod wants the Senkamati ally to keep real native combat AI and
-- actually fight, just not treat the player as an enemy.
--------------------------------------------------------------------
function Spawner.GetFriendlyFactionParams()
    if Spawner._friendlyFactionParams and Spawner._friendlyFactionParams:IsValid() then
        return Spawner._friendlyFactionParams
    end
    local found = nil
    pcall(function()
        local path = Config.FRIENDLY_FACTION_ASSET
        if path then
            local fp = resolveAsset(path)
            if fp and fp:IsValid() then found = fp end
        end
    end)
    Spawner._friendlyFactionParams = found
    return found
end

function Spawner.MakeFriendly(actor)
    local fp = Spawner.GetFriendlyFactionParams()
    if not (actor and actor:IsValid() and fp) then return false end
    local ok = false
    pcall(function()
        local fc = actor.FactionComponent
        if fc and fc:IsValid() then fc.FactionsParams = fp; ok = true end
    end)
    return ok
end

-- Spawner.SyncOwner(actor) -- the Caster fix (2026-10-02). A native Senkamati's R5AS_* targeting only
-- tags a candidate as an enemy by deferring to its OWNER's relationships (R5AS_Categorizer_Relationship
-- is hardcoded native), so a faction copy alone leaves it with no valid targets and the Caster never
-- casts. Same recipe as LivingBase's whistle.lua totem fix, confirmed live there: copy the player's
-- PlayerState.AccountData.AccountId onto OwnershipComponent.OwnerId, keep bShouldUseOwnerFaction,
-- call OnRep_OwnerId(). A Caster's summoned totems then inherit the player as their owner too.
function Spawner.SyncOwner(actor)
    if not (actor and actor:IsValid()) then return false end
    local oc = nil
    pcall(function() oc = actor.OwnershipComponent end)
    if not (oc and oc:IsValid()) then
        log("[owner] no OwnershipComponent on " .. tostring(actor:GetFName():ToString()))
        return false
    end
    local ownerId = nil
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        local ps = pc and pc:IsValid() and pc.PlayerState
        if ps and ps:IsValid() then ownerId = ps.AccountData.AccountId end
    end)
    if not ownerId then
        log("[owner] sync skipped -- could not read PlayerState.AccountData.AccountId")
        return false
    end
    local wOk = pcall(function() oc.OwnerId = ownerId end)
    pcall(function() oc.bShouldUseOwnerFaction = true end)
    local rOk = pcall(function() oc:OnRep_OwnerId() end)
    log(string.format("[owner] OwnerId synced (write=%s, OnRep_OwnerId=%s)", tostring(wOk), tostring(rOk)))
    return wOk
end

--------------------------------------------------------------------
-- On-screen messages — ported near-verbatim from LivingBase's own Spawner.Toast. Splices a
-- plain TextBlock into the game's native WBP_SideNotificationsContainer_C via AddChild, rather
-- than PrintString/ClientMessage (both confirmed dead ends there: screen-messages flag off with
-- no working exec command to flip it; ClientMessage routes to UE4SS's own console window, not
-- the game's HUD). One shared self-rescheduling ticker handles removal, not a timer per toast.
--------------------------------------------------------------------
Spawner._activeToasts = Spawner._activeToasts or {}
local toastTickerStarted = false
local function toastBody()
    local now = os.time()
    local lastContainer
    for i = #Spawner._activeToasts, 1, -1 do
        local t = Spawner._activeToasts[i]
        if now >= t.expiresAt then
            pcall(function() t.box:RemoveChild(t.widget) end)
            lastContainer = t.container
            table.remove(Spawner._activeToasts, i)
        end
    end
    if #Spawner._activeToasts == 0 and lastContainer then
        pcall(function()
            lastContainer.bHidden = true
            lastContainer:CheckVisibility()
            lastContainer:SetVisibility(ESlateVisibility and ESlateVisibility.Collapsed or 1)
        end)
    end
end
-- The widget work runs on the game thread; the reschedule is a sibling call, not nested inside it.
local function toastTick()
    if ExecuteInGameThread then ExecuteInGameThread(function() pcall(toastBody) end) else pcall(toastBody) end
    if ExecuteWithDelay then ExecuteWithDelay(500, toastTick) end
end
local function ensureToastTicker()
    if toastTickerStarted then return end
    toastTickerStarted = true
    if ExecuteWithDelay then ExecuteWithDelay(500, toastTick) end
end

local function trySpliceToast(text, seconds)
    local shown = false
    pcall(function()
        local container, box
        local list
        pcall(function() list = FindAllOf("WBP_SideNotificationsContainer_C") end)
        if list then
            local n = 0
            pcall(function() n = list:GetArrayNum() end)
            if n == 0 then pcall(function() n = #list end) end
            for i = 1, n do
                local w = list[i]
                if not w then pcall(function() w = list:Get(i) end) end
                if w and w:IsValid() then
                    local b
                    pcall(function() b = w.vbox_Notifications end)
                    if b and b:IsValid() then
                        container, box = w, b
                        break
                    end
                end
            end
        end
        if not (container and box) then return end

        local okClass, TextBlockClass = pcall(function() return StaticFindObject("/Script/UMG.TextBlock") end)
        local okOuter, GameInstance = pcall(function() return UEHelpers.GetGameInstance() end)
        if not (okClass and TextBlockClass and TextBlockClass:IsValid()
            and okOuter and GameInstance and GameInstance:IsValid()) then return end
        local okNew, newWidget = pcall(function() return StaticConstructObject(TextBlockClass, GameInstance) end)
        if not (okNew and newWidget and newWidget:IsValid()) then return end
        pcall(function()
            local ktl = UEHelpers.GetKismetTextLibrary()
            newWidget:SetText(ktl:Conv_StringToText(text))
        end)
        pcall(function() newWidget:SetAutoWrapText(true) end)
        pcall(function() newWidget:SetWrapTextWidth(360) end)
        pcall(function()
            local font = newWidget.Font
            if font then
                font.Size = 14
                newWidget.Font = font
            end
        end)

        local okAdd = pcall(function() box:AddChild(newWidget) end)
        if not okAdd then return end
        pcall(function() container.bHidden = false end)
        pcall(function() container:CheckVisibility() end)
        pcall(function() container:SetVisibility(ESlateVisibility and ESlateVisibility.Visible or 0) end)
        shown = true

        ensureToastTicker()
        Spawner._activeToasts[#Spawner._activeToasts + 1] =
            { box = box, widget = newWidget, container = container, expiresAt = os.time() + math.ceil(seconds or 4.0) }
    end)
    return shown
end

function Spawner.Toast(msg, seconds)
    local text = tostring(msg)
    local function attempt(triesLeft)
        if trySpliceToast(text, seconds) then return end
        if triesLeft > 0 and ExecuteWithDelay then
            ExecuteWithDelay(1000, function() attempt(triesLeft - 1) end)
        else
            print("[GhostSailors] " .. text .. "\n")
        end
    end
    attempt(20)
    return true
end

--------------------------------------------------------------------
-- Cosmetic cleanup (optional).
--------------------------------------------------------------------
function Spawner.HideNameplate(actor)
    if not actor or not actor:IsValid() then return end
    pcall(function()
        local marker = actor.R5Marker
        if marker and marker:IsValid() then marker:DestroyMarkerComponent() end
    end)
end

return Spawner
