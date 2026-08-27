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
                -- Retry a few times if the ghost materials fail to resolve on the first try —
                -- a genuinely cold load (nothing this session has touched these specific
                -- assets yet) can fail an immediate StaticFindObject/LoadAsset retry even
                -- though the exact same call succeeds once something else has already loaded
                -- them. Same bounded-retry shape LivingBase's own senkaCrewFix/tryFix uses for
                -- composite-settling races.
                local function tryGhost(triesLeft)
                    if not (actor and actor:IsValid()) then return end
                    local ok = false
                    pcall(function() ok = Spawner.ApplyGhostMaterial(actor) end)
                    if not ok and triesLeft > 0 then
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
