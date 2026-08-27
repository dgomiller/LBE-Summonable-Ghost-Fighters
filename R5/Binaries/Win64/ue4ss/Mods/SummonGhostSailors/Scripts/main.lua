--[[
 SummonGhostSailors / main.lua — entry point.

 Backslash summons one random-look sailor from Config.ROSTER as a translucent "ghost":
 non-persistent (nothing here ever writes a save file, so nothing can be resurrected on
 reload), follows the player at pace (ported from LivingBase's whistle.lua followTick),
 and despawns itself 120s after ITS OWN spawn — independent per sailor, not a shared
 escort lifetime.

 RegisterKeyBind must run synchronously during this initial script load (confirmed
 unsafe to call later, per LivingBase's own main.lua finding) — no deferred registration.
]]

local Config = require("config")
local Spawner = require("spawner")
local Follow = require("follow")

local function log(msg) print("[GhostSailors] " .. tostring(msg) .. "\n") end

math.randomseed(os.time())

-- Kick off the ghost materials'/FX's real streaming load as early as possible — see
-- Spawner.Prewarm's own comment. By the time anyone can actually press the summon key
-- (requires being in-game, past menus/loading), these have had real wall-clock time to finish.
-- Explicitly hopped onto the game thread — LoadAsset (which Prewarm calls) is confirmed to
-- throw if called from anywhere else, and top-level mod script execution isn't guaranteed to
-- already be there.
if ExecuteInGameThread then
    ExecuteInGameThread(function() pcall(function() Spawner.Prewarm() end) end)
else
    pcall(function() Spawner.Prewarm() end)
end

local summonBusy = false

local function summon()
    if summonBusy then return end
    summonBusy = true
    ExecuteInGameThread(function()
        pcall(function()
            local entry = Config.ROSTER[math.random(#Config.ROSTER)]
            local actor, label = Spawner.Spawn(Config.CREW_CLASS, "Ghost Sailor",
                { params = entry.params, sex = entry.sex, bodyTypes = entry.bodyTypes })
            if not (actor and actor:IsValid()) then
                log("Summon failed — see previous SPAWN FAILED line.")
                return
            end
            log(string.format("%s summoned (%s) — ghosting in %dms, despawns in %ds.",
                label, entry.name, Config.GHOST_MATERIAL_DELAY_MS, Config.GHOST_LIFETIME_MS // 1000))
            Follow.Add(actor, label)
            if ExecuteWithDelay then
                -- Retry a few times if the ghost materials fail to resolve on the first try
                -- (see Spawner.Prewarm's own comment). CONFIRMED LIVE (2026-08-26): LoadAsset
                -- throws "can only be called from within the game thread" when called from an
                -- ExecuteWithDelay callback directly -- every attempt must hop back via
                -- ExecuteInGameThread first. LivingBase's own testbed.lua (2026-08-16, its
                -- senkaCrewFix/tryFix history) already found and documented the OTHER half of
                -- this: calling ExecuteWithDelay NESTED inside an ExecuteInGameThread callback
                -- throws "No overload found for function 'ExecuteWithDelay'" in this UE4SS
                -- build. Fix (matching their established pattern exactly): ExecuteInGameThread
                -- (the actual work) and the next ExecuteWithDelay (the next retry) are SIBLINGS,
                -- both direct top-level calls inside tryGhost -- never one nested in the
                -- other's callback. Since ExecuteInGameThread is itself fire-and-forget async,
                -- success/failure can't be checked synchronously right after it -- this just
                -- unconditionally retries GHOST_MATERIAL_RETRIES times; re-applying an
                -- already-successful material swap is harmless.
                local function tryGhost(triesLeft)
                    ExecuteInGameThread(function()
                        pcall(function()
                            if actor and actor:IsValid() then Spawner.ApplyGhostMaterial(actor) end
                        end)
                    end)
                    if triesLeft > 0 then
                        ExecuteWithDelay(500, function() tryGhost(triesLeft - 1) end)
                    end
                end
                ExecuteWithDelay(Config.GHOST_MATERIAL_DELAY_MS, function() tryGhost(5) end)
            end
        end)
        summonBusy = false
    end)
end

-- VK_OEM_5 (0xDC) is the raw Windows virtual-key code for backslash, kept as a fallback in
-- case a future UE4SS build's Key[] table doesn't carry "OEM_FIVE" either — RegisterKeyBind
-- accepts a raw numeric code directly, same fallback pattern LivingBase's own main.lua uses.
local VK_FALLBACK = { OEM_FIVE = 0xDC }
local keyValue = (Key and Key[Config.SUMMON_KEY]) or VK_FALLBACK[Config.SUMMON_KEY]
if keyValue == nil then
    log(string.format("Key '%s' not recognized by this UE4SS build — mod inactive.", Config.SUMMON_KEY))
else
    local ok = pcall(function() RegisterKeyBind(keyValue, summon) end)
    if ok then
        log(string.format("Ready — press %s to summon a ghost sailor.", Config.SUMMON_KEY))
    else
        log(string.format("RegisterKeyBind failed for '%s' — mod inactive.", Config.SUMMON_KEY))
    end
end

-- World load: drop tracking of any prior sailors. Nothing was ever persisted, so the actors
-- themselves are already gone with the old level — this just prevents stale Lua-side
-- references (and a stray reschedule of the follow tick) surviving the transition.
if RegisterInitGameStatePostHook then
    pcall(function()
        RegisterInitGameStatePostHook(function() Follow.Reset() end)
    end)
end
