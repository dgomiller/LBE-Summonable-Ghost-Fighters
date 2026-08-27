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
                    setSpeedMultiplier(actor, Config.FOLLOW_SPEED_MULT)
                    follow(actor, player, rec.follow)
                else
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

function Follow.StartTick()
    if Follow._ticking then return end
    Follow._ticking = true
    local function step()
        pcall(tickOnce)
        if #Follow.active > 0 and ExecuteWithDelay then
            ExecuteWithDelay(Config.GHOST_TICK_MS, step)
        else
            Follow._ticking = false
        end
    end
    if ExecuteWithDelay then ExecuteWithDelay(Config.GHOST_TICK_MS, step) end
end

return Follow
