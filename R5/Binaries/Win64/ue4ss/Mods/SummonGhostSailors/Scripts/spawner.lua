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
local function resolveClass(path)
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    log("Class not in memory, attempting LoadAsset: " .. path)
    local okLoad = pcall(function() LoadAsset(path) end)
    if okLoad then
        cls = StaticFindObject(path)
        if cls and cls:IsValid() then return cls end
    end
    return nil
end

local function resolveAsset(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(function() LoadAsset(path) end)
    o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    return nil
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
-- Spawner.Spawn(classPath, label, compositeLook) -> actor|nil
-- compositeLook = { params, sex, bodyTypes } or nil.
--------------------------------------------------------------------
local instanceLabelCounts = {}
local function nextInstanceLabel(baseLabel)
    baseLabel = tostring(baseLabel or "GhostSailor")
    local n = (instanceLabelCounts[baseLabel] or 0) + 1
    instanceLabelCounts[baseLabel] = n
    return baseLabel .. " " .. n
end

function Spawner.Spawn(classPath, label, compositeLook)
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
    if hasLook then
        preFinish = function(a)
            pcall(function()
                Spawner.SetCompositeParams(a, compositeLook.params, compositeLook.sex, compositeLook.bodyTypes)
            end)
        end
    end

    local finalLabel = nextInstanceLabel(label)
    local actor = doEngineSpawn(gs, world, cls, transform, finalLabel, preFinish)
    if not actor or not actor:IsValid() then return nil end

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

function Spawner.ApplyGhostMaterial(actor)
    if not (actor and actor:IsValid()) then return false end
    local skinMat = resolveAsset(Config.GHOST_SKIN_MAT_PATH)
    local clothMat = resolveAsset(Config.GHOST_CLOTH_MAT_PATH)
    if not (skinMat and skinMat:IsValid()) then
        always("[ghost] could not resolve SKIN material: " .. tostring(Config.GHOST_SKIN_MAT_PATH))
    end
    if not (clothMat and clothMat:IsValid()) then
        always("[ghost] could not resolve CLOTH material: " .. tostring(Config.GHOST_CLOTH_MAT_PATH))
    end
    if not (skinMat and skinMat:IsValid() and clothMat and clothMat:IsValid()) then
        return false
    end

    local function applySlots(comp, mat)
        if not (comp and comp:IsValid() and mat and mat:IsValid()) then return 0 end
        local n, ok_n = 0, 0
        pcall(function() n = comp:GetNumMaterials() end)
        for slot = 0, (n - 1) do
            if pcall(function() comp:SetMaterial(slot, mat) end) then ok_n = ok_n + 1 end
        end
        return ok_n
    end

    local bodyMesh = unwrapComp(actor.Mesh)
    local bodyName = bodyMesh and compFName(bodyMesh) or nil
    local skinSlots, clothSlots = 0, 0
    if bodyMesh and bodyMesh:IsValid() then skinSlots = applySlots(bodyMesh, skinMat) end

    for _, className in ipairs({ "StaticMeshComponent", "SkeletalMeshComponent" }) do
        local cls = StaticFindObject("/Script/Engine." .. className)
        if cls and cls:IsValid() then
            local ok, comps = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
            if ok and comps then
                local n = 0
                pcall(function() n = comps:GetArrayNum() end)
                if n == 0 then pcall(function() n = #comps end) end
                for i = 1, n do
                    local comp
                    pcall(function() comp = comps[i] end)
                    if not comp then pcall(function() comp = comps:Get(i) end) end
                    comp = unwrapComp(comp)
                    if comp and comp:IsValid() then
                        local cn = compFName(comp)
                        if not (bodyName and cn == bodyName) then
                            clothSlots = clothSlots + applySlots(comp, clothMat)
                        end
                    end
                end
            end
        end
    end
    log(string.format("[ghost] skin slots=%d, cloth slots=%d", skinSlots, clothSlots))
    return (skinSlots + clothSlots) > 0
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
