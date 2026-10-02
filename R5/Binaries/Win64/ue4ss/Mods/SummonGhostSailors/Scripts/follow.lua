--[[
 SummonGhostSailors / follow.lua — the proven follow stack, ported from LivingBase's
 whistle.lua (Follow/WarpNear/SetSpeedMultiplier/IsFighting/SetAILogic + followTick's own
 decision tree), plus the per-sailor despawn timer whistle.lua didn't need (it borrowed the
 game's own pet-kill-timer instead; we have no anchor to borrow, so each sailor tracks its
 own spawnedAt and the shared tick checks it directly).

 One shared self-rescheduling tick drives every active sailor — not N independent timers.
]]

local UEHelpers = require("UEHelpers")
local Config = require("config")
local Spawner = require("spawner")

local Follow = {}
Follow.active = {}   -- { {actor=, label=, spawnedAt=, follow={}, fx=}, ... }
Follow._ticking = false

local function log(msg) if Config.VERBOSE then print("[GhostSailors:Follow] " .. tostring(msg) .. "\n") end end

--------------------------------------------------------------------
-- Follow primitives — same shape as LivingBase's own, defaults from Config.
--------------------------------------------------------------------
local function mercunaNav(pawn)
    local nav = nil
    pcall(function() nav = pawn.MercunaGroundNavigationComponent end)
    if nav and nav:IsValid() then return nav end
    return nil
end

local function setMaxWalkSpeed(pawn, speed)
    if not (pawn and pawn:IsValid()) then return end
    pcall(function()
        local mv = pawn.CharacterMovement
        if mv and mv:IsValid() then mv.MaxWalkSpeed = speed end
    end)
end

local function setSpeedMultiplier(pawn, mult)
    if not (pawn and pawn:IsValid()) then return end
    pcall(function()
        local mv = pawn.CharacterMovement
        if mv and mv:IsValid() then mv.CheatMovementSpeedModifer = mult end
    end)
    local nav = mercunaNav(pawn)
    if nav then pcall(function() nav:OverrideSpeedMultiplier(mult) end) end
end

local function setAILogic(pawn, on)
    if not (pawn and pawn:IsValid()) then return false end
    local ctrl = nil
    pcall(function() ctrl = pawn.Controller end)
    if not (ctrl and ctrl:IsValid()) then return false end
    return pcall(function()
        if on then ctrl:StartLogic() else ctrl:StopLogic() end
    end)
end

local function isFighting(pawn, player)
    if not (pawn and pawn:IsValid()) then return false end
    local function realEnemy(t)
        if not (t and t:IsValid()) then return false end
        if player and player:IsValid() and t == player then return false end
        return true
    end
    local tgt = nil
    pcall(function()
        local mesh = pawn.Mesh
        local anim = mesh and mesh:IsValid() and mesh:GetAnimInstance() or nil
        if anim and anim:IsValid() then tgt = anim.CurrentTarget end
    end)
    if realEnemy(tgt) then return true end
    local focus = nil
    pcall(function()
        local ctrl = pawn.Controller
        if ctrl and ctrl:IsValid() then focus = ctrl:GetFocusActor() end
    end)
    return realEnemy(focus)
end

-- Fallback for a pawn with no Mercuna nav component: plain SimpleMoveToActor.
local function moveTowards(pawn, goal)
    local ok = pcall(function()
        local AIHelperClass = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
        if AIHelperClass and AIHelperClass:IsValid() then
            AIHelperClass:SimpleMoveToActor(pawn.Controller, goal)
        end
    end)
    return ok, ok and "SimpleMoveToActor issued" or "SimpleMoveToActor failed"
end

local function follow(pawn, goal, state)
    if not (pawn and pawn:IsValid()) then return false, "pawn invalid" end
    if not (goal and goal:IsValid()) then return false, "goal invalid" end
    state = state or {}

    local nav = mercunaNav(pawn)
    if not nav then return moveTowards(pawn, goal) end

    local remaining = -1.0
    pcall(function() remaining = nav:GetRemainingPathLength() end)
    state.dead = (remaining or -1.0) <= 0.0 and (state.dead or 0) + 1 or 0

    if (not state.tracking) or (state.dead or 0) >= 3 then
        local ok = pcall(function()
            nav:TrackActor(goal, Config.FOLLOW_END_UU, Config.FOLLOW_SPEED,
                { X = 0.0, Y = 0.0, Z = 0.0 }, Config.FOLLOW_PARTIAL ~= false)
        end)
        if not ok then state.tracking = false; return false, "TrackActor threw" end
        state.tracking, state.dead = true, 0
        return true, "TrackActor issued"
    end

    if Config.FOLLOW_AUTOSTOP_LOGIC then
        local spd = 0.0
        pcall(function()
            local v = pawn:GetVelocity()
            spd = math.sqrt((v.X or 0.0) ^ 2 + (v.Y or 0.0) ^ 2)
        end)
        if spd < 10.0 then
            state.stall = (state.stall or 0) + 1
            if state.stall == (Config.FOLLOW_STALL_TICKS or 3) and not state.logicStopped then
                state.logicStopped = true
                setAILogic(pawn, false)
                state.tracking = false
                return true, "stalled — stopped StateTree so Mercuna can drive"
            end
        else
            state.stall = 0
        end
    end
    return true, "tracking"
end

local function warpNear(pawn, target, radius, index, total)
    if not (pawn and pawn:IsValid() and target and target:IsValid()) then return false end
    return pcall(function()
        local p = target:K2_GetActorLocation()
        local ang = (2 * math.pi) * ((index or 1) - 1) / math.max(total or 1, 1)
        if Config.FOLLOW_WARP_BEHIND ~= false then
            -- Land BEHIND the player (never in front, where they block the view / path): centre on the
            -- opposite of the player's facing, fanned out +/-30 deg per extra summon (capped at +/-75).
            local yaw = 0.0
            pcall(function() yaw = target:K2_GetActorRotation().Yaw end)
            local fan = math.max(-75.0, math.min(75.0, ((index or 1) - ((total or 1) + 1) / 2) * 30.0))
            ang = math.rad(yaw + 180.0 + fan)
        end
        pawn:K2_SetActorLocation({
            X = p.X + math.cos(ang) * (radius or 500.0),
            Y = p.Y + math.sin(ang) * (radius or 500.0),
            Z = p.Z,
        }, false, {}, false)
    end)
end

--------------------------------------------------------------------
-- Public: register a freshly spawned sailor (or ally) for follow (+ despawn, unless permanent).
-- opts = { kind = "ghost"|"ally" (default "ghost"), permanent = bool (default false) }.
-- Both kinds are "ghosts" now (RedFalcon: "the senkamati didnt get the ghost stuff" — it's
-- meant to, same ground-light follow FX as the sailors; the material swap itself is applied
-- separately in main.lua's summonSenkamati, same as the sailors' own tryGhost). The Senkamati
-- ally (kind="ally", permanent=true) never expires; everything else (follow/yield-to-combat/
-- warp-back/FX) is identical, reusing the same tick.
--------------------------------------------------------------------
function Follow.Add(actor, label, opts)
    opts = opts or {}
    local kind = opts.kind or "ghost"
    local fx = nil
    if Config.GHOST_FX_ENABLED then
        fx = Spawner.SpawnFollowFx(actor)
    end
    Follow.active[#Follow.active + 1] = {
        actor = actor, label = label, spawnedAt = os.clock(), follow = {}, fx = fx,
        kind = kind, permanent = opts.permanent or false,
    }
    Follow.StartTick()
end

-- Count of currently-active records of a given kind (e.g. the ghost-sailor max-cap check).
function Follow.CountByKind(kind)
    local n = 0
    for _, rec in ipairs(Follow.active) do
        if rec.kind == kind then n = n + 1 end
    end
    return n
end

function Follow.Reset()
    Follow.active = {}
end

--------------------------------------------------------------------
-- Telemetry (Config.FOLLOW_DEBUG): a compact snapshot of the state that might distinguish the
-- walk gait (speed capped at 220) from the post-combat run gait (400-500). Every read is pcall'd.
--------------------------------------------------------------------
function Follow.StateSnapshot(actor)
    local parts = {}
    local function add(name, fn)
        local v = nil
        pcall(function() v = fn() end)
        parts[#parts + 1] = name .. "=" .. tostring(v)
    end
    local anim = nil
    pcall(function()
        local mesh = actor.Mesh
        anim = mesh and mesh:IsValid() and mesh:GetAnimInstance() or nil
        if anim and not anim:IsValid() then anim = nil end
    end)
    if anim then
        add("CombatState", function() return anim.CombatState end)
        add("CombatMovement", function() return anim.CombatMovement end)
        add("ShouldMove", function() return anim.ShouldMove end)
        add("FWD", function() return anim.FWD end)
        add("AimMove", function() return anim.AimMove end)
        add("WantFwd", function() return anim["Want Forward Speed"] end)
        add("GroundSpeed", function() return string.format("%.0f", anim.GroundSpeed) end)
    else
        parts[#parts + 1] = "anim=nil"
    end
    add("MoveMode", function() return actor.CharacterMovement.MovementMode end)
    add("MaxAccel", function() return actor.CharacterMovement.MaxAcceleration end)
    add("ReqMaxSpd", function() return actor.CharacterMovement.bRequestedMoveWithMaxSpeed end)
    add("PathLeft", function()
        local nav = mercunaNav(actor)
        return nav and string.format("%.0f", nav:GetRemainingPathLength()) or "nonav"
    end)
    add("Focus", function()
        local f = actor.Controller:GetFocusActor()
        return (f and f:IsValid()) and f:GetFName():ToString() or "none"
    end)
    return table.concat(parts, " ")
end

--------------------------------------------------------------------
-- One shared per-tick decision loop: follow, yield to combat, warp back, or despawn.
--------------------------------------------------------------------
local function tickOnce()
    local player = nil
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        player = pc and pc:IsValid() and pc.Pawn or nil
    end)

    local ploc = nil
    if player then pcall(function() ploc = player:K2_GetActorLocation() end) end

    local n = #Follow.active
    if n == 0 then return end

    local paceSpeed = nil
    if player and ploc and Config.FOLLOW_MATCH_PACE then
        local ps = 0.0
        pcall(function()
            local v = player:GetVelocity()
            ps = math.sqrt((v.X or 0.0) ^ 2 + (v.Y or 0.0) ^ 2)
        end)
        paceSpeed = math.max(Config.FOLLOW_SPEED_MIN, math.min(Config.FOLLOW_SPEED_MAX, ps + Config.FOLLOW_PACE_MARGIN))
    end

    local now = os.clock()
    for i = n, 1, -1 do
        local rec = Follow.active[i]
        local actor = rec.actor
        if not (actor and actor:IsValid()) then
            if rec.fx and rec.fx:IsValid() then pcall(function() rec.fx:K2_DestroyActor() end) end
            table.remove(Follow.active, i)
            -- The actor vanished without us despawning it (killed and cleaned up, or removed by the game).
            if Config.DESPAWN_NOTIFY ~= false then
                local left = #Follow.active
                local msg = tostring(rec.label) .. " fell — " .. (left > 0 and (tostring(left) .. " left") or "none left")
                pcall(function() Spawner.Toast(msg, 3.0) end)
            end
        elseif (not rec.permanent) and (now - rec.spawnedAt) * 1000 >= Config.GHOST_LIFETIME_MS then
            local dieLoc = nil
            pcall(function() dieLoc = actor:K2_GetActorLocation() end)
            if dieLoc then
                Spawner.PlayOneShotFx(Config.GHOST_DESPAWN_FX_PATH, dieLoc, Config.GHOST_DESPAWN_FX_LIFETIME_MS)
            end
            pcall(function() actor:K2_DestroyActor() end)
            if rec.fx and rec.fx:IsValid() then pcall(function() rec.fx:K2_DestroyActor() end) end
            table.remove(Follow.active, i)
            log(rec.label .. " expired (120s) — despawned")
            if Config.DESPAWN_NOTIFY ~= false then
                local left = #Follow.active
                local msg = tostring(rec.label) .. " dissipated — " .. (left > 0 and (tostring(left) .. " left") or "none left")
                pcall(function() Spawner.Toast(msg, 3.0) end)
            end
        elseif (now - rec.spawnedAt) < (Config.FOLLOW_GRACE_S or 3.0) then
            -- Brand-new summon: its composite mesh/clothing is still being (re)built for a couple of
            -- seconds. Touch nothing (no anim/nav/movement reads or writes) until it settles.
        elseif player and ploc then
            local cloc = nil
            pcall(function() cloc = actor:K2_GetActorLocation() end)
            if cloc then
                if rec.fx then Spawner.MoveFollowFx(rec.fx, actor) end
                local dx, dy, dz = cloc.X - ploc.X, cloc.Y - ploc.Y, cloc.Z - ploc.Z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d > Config.FOLLOW_WARP_UU then
                    warpNear(actor, player, Config.FOLLOW_WARP_RING_UU, i, n)
                    rec.follow.tracking = false
                elseif isFighting(actor, player) then
                    rec.follow.tracking = false
                    setSpeedMultiplier(actor, 1.0)
                    if rec.follow.logicStopped then setAILogic(actor, true); rec.follow.logicStopped = false end
                elseif d > Config.FOLLOW_START_UU then
                    if paceSpeed then setMaxWalkSpeed(actor, paceSpeed) end
                    rec.boostSpeed = paceSpeed
                    setSpeedMultiplier(actor, Config.FOLLOW_SPEED_MULT)
                    follow(actor, player, rec.follow)
                    if Config.FOLLOW_DEBUG then
                        local mws, spd = -1, -1
                        pcall(function() mws = actor.CharacterMovement.MaxWalkSpeed end)
                        pcall(function() local v = actor:GetVelocity(); spd = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) end)
                        print(string.format("[GhostSailors:FollowDbg] %s dist=%.0f want=%.0f MaxWalkSpeed(readback)=%.0f speed=%.0f fastChecks=%d reverted=%d lastSeenWhenReverted=%s\n",
                            tostring(rec.label), d, paceSpeed or -1, mws, spd, rec.fastN or 0, rec.reverts or 0, tostring(rec.lastSeen)))
                        rec.fastN, rec.reverts = 0, 0
                        local snap = Follow.StateSnapshot(actor)
                        print("[GhostSailors:FollowState] " .. tostring(rec.label) .. " " .. snap .. "\n")
                        local running = spd >= 300
                        if rec.wasRunning ~= nil and rec.wasRunning ~= running then
                            print("[GhostSailors:FollowDbg] *** " .. tostring(rec.label) .. (running and " RUN STATE ON" or " RUN STATE OFF")
                                .. " (speed " .. string.format("%.0f", spd) .. ") " .. snap .. "\n")
                        end
                        rec.wasRunning = running
                    end
                else
                    rec.boostSpeed = nil
                    if rec.follow.tracking then
                        local nav = mercunaNav(actor)
                        if nav then pcall(function() nav:Stop() end) end
                        rec.follow.tracking = false
                    end
                    if rec.follow.logicStopped then setAILogic(actor, true); rec.follow.logicStopped = false end
                    setSpeedMultiplier(actor, 1.0)
                end
            end
        end
    end
end

-- Fast pass (2026-10-02): the game rewrites CharacterMovement.MaxWalkSpeed to its walk value (110) for
-- non-combat movement (the combat run sets 500 -- confirmed from probe dumps), so a once-per-200ms write is
-- overridden most of the time. While a summon is far behind, re-assert the boosted value every
-- Config.FOLLOW_FAST_MS between full ticks. Also counts how often the game had reverted it (telemetry).
function Follow.FastAssert()
    for _, rec in ipairs(Follow.active) do
        local a = rec.actor
        if rec.boostSpeed and a and a:IsValid() then
            local cur = nil
            pcall(function() cur = a.CharacterMovement.MaxWalkSpeed end)
            rec.fastN = (rec.fastN or 0) + 1
            if cur and math.abs(cur - rec.boostSpeed) > 1.0 then
                rec.reverts = (rec.reverts or 0) + 1
                rec.lastSeen = cur
            end
            setMaxWalkSpeed(a, rec.boostSpeed)
        end
    end
end

function Follow.StartTick()
    if Follow._ticking then return end
    Follow._ticking = true
    local function step()
        local now = os.clock()
        -- All the engine work (follow, teleport, destroy on expiry, FX) runs on the GAME thread
        -- (2026-10-02, after a crash at the first despawn); this timer thread only schedules.
        -- The next ExecuteWithDelay below is a sibling of this call, never nested inside it.
        local full = (now - (Follow._lastFull or 0)) * 1000 >= (Config.GHOST_TICK_MS - 5)
        if full then Follow._lastFull = now end
        local work = full and tickOnce or Follow.FastAssert
        if ExecuteInGameThread then
            ExecuteInGameThread(function() pcall(work) end)
        else
            pcall(work)
        end
        if #Follow.active > 0 and ExecuteWithDelay then
            local boosting = false
            for _, rec in ipairs(Follow.active) do if rec.boostSpeed then boosting = true; break end end
            ExecuteWithDelay(boosting and (Config.FOLLOW_FAST_MS or 50) or Config.GHOST_TICK_MS, step)
        else
            Follow._ticking = false
        end
    end
    if ExecuteWithDelay then ExecuteWithDelay(Config.GHOST_TICK_MS, step) end
end

return Follow
