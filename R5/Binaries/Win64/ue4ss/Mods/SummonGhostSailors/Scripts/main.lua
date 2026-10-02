--[[
 SummonGhostSailors / main.lua — entry point.

 Home (Config.SUMMON_KEY) summons one random-look sailor from Config.ROSTER as a
 translucent "ghost": non-persistent (nothing here ever writes a save file, so nothing can be
 resurrected on reload), follows the player at pace (ported from LivingBase's whistle.lua
 followTick), and despawns itself Config.GHOST_LIFETIME_MS after ITS OWN spawn — independent
 per sailor, not a shared escort lifetime.

 End (Config.SENKAMATI_KEY) summons one corrupted Senkamati ally — its genuine native look, but
 ALSO ghosted (same material swap as the sailors — RedFalcon: "the senkamati didnt get the
 ghost stuff"), real combat AI intact, just friendly to the player (faction copy only, no
 pacification). Behaves identically to a sailor otherwise (RedFalcon: "i want them to behave
 the same as the soldiers") — same Config.GHOST_LIFETIME_MS expiry, same dissipate FX, no
 permanence, no toggle.

 Both kinds share ONE pool of Config.GHOST_MAX_ACTIVE (RedFalcon: "max 5 between both sailors
 and senkamati").

 RegisterKeyBind must run synchronously during this initial script load (confirmed
 unsafe to call later, per LivingBase's own main.lua finding) — no deferred registration.
]]

local Config = require("config")
local Spawner = require("spawner")
local Follow = require("follow")

local function log(msg) print("[GhostSailors] " .. tostring(msg) .. "\n") end

math.randomseed(os.time())

-- Kick off the ghost materials'/FX's/faction-asset's real streaming load as early as possible
-- — see Spawner.Prewarm's own comment. By the time anyone can actually press a summon key
-- (requires being in-game, past menus/loading), these have had real wall-clock time to finish.
-- Explicitly hopped onto the game thread — LoadAsset (which Prewarm calls) is confirmed to
-- throw if called from anywhere else, and top-level mod script execution isn't guaranteed to
-- already be there.
if ExecuteInGameThread then
    ExecuteInGameThread(function() pcall(function() Spawner.Prewarm() end) end)
else
    pcall(function() Spawner.Prewarm() end)
end

-- CONFIRMED LIVE (2026-08-26): LoadAsset throws "can only be called from within the game
-- thread" when called from an ExecuteWithDelay callback directly -- every retry attempt must
-- hop back via ExecuteInGameThread first. LivingBase's own testbed.lua (2026-08-16, its
-- senkaCrewFix/tryFix history) already found and documented the OTHER half of this: calling
-- ExecuteWithDelay NESTED inside an ExecuteInGameThread callback throws "No overload found for
-- function 'ExecuteWithDelay'" in this UE4SS build. Fix (matching their established pattern
-- exactly): ExecuteInGameThread (the actual work) and the next ExecuteWithDelay (the next
-- retry) must be SIBLINGS, both direct top-level calls -- never one nested in the other's
-- callback. Since ExecuteInGameThread is itself fire-and-forget async, success/failure can't
-- be checked synchronously right after it -- this just unconditionally retries a fixed number
-- of times; re-applying an already-successful effect is harmless. Shared by both summon paths
-- below instead of duplicating the retry shape twice.
local function retryInGameThread(fn, delayMs, triesLeft)
    local function step(remaining)
        ExecuteInGameThread(function() pcall(fn) end)
        if remaining > 0 and ExecuteWithDelay then
            ExecuteWithDelay(delayMs, function() step(remaining - 1) end)
        end
    end
    if ExecuteWithDelay then
        ExecuteWithDelay(delayMs, function() step(triesLeft) end)
    end
end

-- Ghost reskin, applied ONCE after the summon's composite mesh has finished (re)building (2026-10-02).
-- A crash was seen ~1.6 s after a summon, while its clothing was still being recreated and the old
-- 500 ms x6 pass was walking/replacing components under it. Now: first try after
-- Config.GHOST_MATERIAL_DELAY_MS, and only retry (up to 2 more times) if that pass applied nothing.
local function applyGhostLater(actor)
    local done = false
    retryInGameThread(function()
        if done or not (actor and actor:IsValid()) then return end
        if Spawner.ApplyGhostMaterial(actor) then done = true end
    end, Config.GHOST_MATERIAL_DELAY_MS, 2)
end

--------------------------------------------------------------------
-- Shared cap across both ghost sailors and the Senkamati ally.
--------------------------------------------------------------------
local function overCap()
    if #Follow.active >= (Config.GHOST_MAX_ACTIVE or 5) then
        local msg = Config.GHOST_MAX_MESSAGE or "Max Ghosts Summoned"
        pcall(function() Spawner.Toast(msg, 2.5) end)
        log(msg)
        return true
    end
    return false
end

--------------------------------------------------------------------
-- Ghost sailors (summon key).
--------------------------------------------------------------------
local summonBusy = false

-- One normal ghost sailor (the default summon, and the fallback if a Grenadier roll cannot spawn).
local function spawnSailor()
    local entry = Config.ROSTER[math.random(#Config.ROSTER)]
    local actor, label = Spawner.Spawn(Config.CREW_CLASS, "Ghost Sailor",
        { params = entry.params, sex = entry.sex, bodyTypes = entry.bodyTypes })
    if not (actor and actor:IsValid()) then
        log("Summon failed — see previous SPAWN FAILED line.")
        return false
    end
    log(string.format("%s summoned (%s) — ghosting in %dms, despawns in %ds.",
        label, entry.name, Config.GHOST_MATERIAL_DELAY_MS, Config.GHOST_LIFETIME_MS // 1000))
    Follow.Add(actor, label, { kind = "ghost" })
    applyGhostLater(actor)
    return true
end

-- Optional Grenadier (off by default): a native Blackbeard mob, so it takes the Senkamati path
-- (friendly pre-build + owner sync + ghost look) instead of the crew path.
local function grenadierClassReady()
    local c = nil
    pcall(function() c = Spawner.ResolveClass(Config.GRENADIER_CLASS) end)
    return c ~= nil and c:IsValid()
end

local function spawnGrenadier()
    local gActor, gLabel = Spawner.Spawn(Config.GRENADIER_CLASS, Config.GRENADIER_NAME or "Ghost Grenadier", nil, true)
    if not (gActor and gActor:IsValid()) then return false end
    log(string.format("%s summoned (grenadier roll) — ghosting, despawns in %ds.",
        gLabel, Config.GHOST_LIFETIME_MS // 1000))
    Follow.Add(gActor, gLabel, { kind = "ally" })
    retryInGameThread(function()
        if gActor and gActor:IsValid() then Spawner.MakeFriendly(gActor) end
    end, 500, 5)
    applyGhostLater(gActor)
    local gOwnerDone = false
    retryInGameThread(function()
        if gOwnerDone or not (gActor and gActor:IsValid()) then return end
        if Spawner.SyncOwner(gActor) then gOwnerDone = true end
    end, 1000, 3)
    return true
end

local function summon()
    if summonBusy then return end
    if overCap() then return end
    summonBusy = true
    ExecuteInGameThread(function()
        pcall(function()
            if Config.GRENADIER_ENABLED and math.random() < (Config.GRENADIER_CHANCE or 0.10) then
                if grenadierClassReady() then
                    if not spawnGrenadier() then
                        log("Grenadier summon failed — falling back to a normal ghost sailor.")
                        spawnSailor()
                    end
                    return
                end
                -- The Grenadier class is not in memory yet (the menu-time prewarm is dropped when the
                -- world loads). Ask for it now and keep trying for ~5 s before falling back to a sailor,
                -- so the roll works the first time instead of silently costing a summon.
                pcall(function() LoadAsset(Config.GRENADIER_CLASS) end)
                local settled = false
                retryInGameThread(function()
                    if settled or not grenadierClassReady() then return end
                    settled = true
                    if not spawnGrenadier() then
                        log("Grenadier summon failed — falling back to a normal ghost sailor.")
                        spawnSailor()
                    end
                end, 500, 9)
                if ExecuteWithDelay then
                    ExecuteWithDelay(5500, function()
                        ExecuteInGameThread(function()
                            if settled then return end
                            settled = true
                            log("Grenadier class did not load in time — falling back to a normal ghost sailor.")
                            pcall(spawnSailor)
                        end)
                    end)
                end
                return
            end
            spawnSailor()
        end)
        summonBusy = false
    end)
end

--------------------------------------------------------------------
-- Corrupted Senkamati ally (separate key, no toggle — one press summons one ally, permanent).
-- Real native combat AI left fully intact; faction copied so it stops treating the player as
-- an enemy (Spawner.MakeFriendly), AND ghosted the same as the sailors (same material swap).
--------------------------------------------------------------------
local senkamatiBusy = false

local function summonSenkamati()
    if senkamatiBusy then return end
    if overCap() then return end
    senkamatiBusy = true
    ExecuteInGameThread(function()
        pcall(function()
            local entry = Config.SENKAMATI_ROSTER[math.random(#Config.SENKAMATI_ROSTER)]
            -- makeFriendly=true: applied PRE-build (before BeginPlay) inside Spawner.Spawn
            -- itself, not just after -- CONFIRMED LIVE (2026-08-26) that a post-spawn-only
            -- faction copy was too late for this native hostile class; it kept attacking the
            -- player despite FactionsParams eventually being set correctly.
            local actor, label = Spawner.Spawn(entry.class, entry.name, nil, true)
            if not (actor and actor:IsValid()) then
                log("Senkamati summon failed — see previous SPAWN FAILED line.")
                return
            end
            log(string.format("%s summoned — ghosting, fighting alongside you, despawns in %ds.",
                label, Config.GHOST_LIFETIME_MS // 1000))
            -- Behaves identically to the sailors now (RedFalcon: "i want them to behave the
            -- same as the soldiers") -- no permanent flag, so it expires after
            -- Config.GHOST_LIFETIME_MS and plays the same dissipate FX, same as a sailor.
            Follow.Add(actor, label, { kind = "ally" })
            retryInGameThread(function()
                if actor and actor:IsValid() then Spawner.MakeFriendly(actor) end
            end, 500, 5)
            applyGhostLater(actor)
            -- Owner sync (Caster fix): once, after the actor has settled (needs a live PlayerState).
            local ownerDone = false
            retryInGameThread(function()
                if ownerDone or not (actor and actor:IsValid()) then return end
                if Spawner.SyncOwner(actor) then ownerDone = true end
            end, 1000, 3)
        end)
        senkamatiBusy = false
    end)
end

--------------------------------------------------------------------
-- Key registration. Must happen synchronously during this initial script load.
-- VK_OEM_5 (0xDC) is the raw Windows virtual-key code for backslash, kept as a fallback in
-- case a future UE4SS build's Key[] table doesn't carry "OEM_FIVE" either — RegisterKeyBind
-- accepts a raw numeric code directly, same fallback pattern LivingBase's own main.lua uses.
--------------------------------------------------------------------
local VK_FALLBACK = { OEM_FIVE = 0xDC }

local function registerAction(keyName, fn, description)
    local keyValue = (Key and Key[keyName]) or VK_FALLBACK[keyName]
    if keyValue == nil then
        log(string.format("Key '%s' not recognized by this UE4SS build — %s inactive.", keyName, description))
        return
    end
    local ok = pcall(function() RegisterKeyBind(keyValue, fn) end)
    if ok then
        log(string.format("Ready — press %s to %s.", keyName, description))
    else
        log(string.format("RegisterKeyBind failed for '%s' — %s inactive.", keyName, description))
    end
end

registerAction(Config.SUMMON_KEY, summon, "summon a ghost sailor")
registerAction(Config.SENKAMATI_KEY, summonSenkamati, "summon a corrupted Senkamati ally")

-- World load: drop tracking of any prior sailors/allies. Nothing was ever persisted, so the
-- actors themselves are already gone with the old level — this just prevents stale Lua-side
-- references (and a stray reschedule of the follow tick) surviving the transition.
if RegisterInitGameStatePostHook then
    pcall(function()
        RegisterInitGameStatePostHook(function() Follow.Reset() end)
    end)
end
