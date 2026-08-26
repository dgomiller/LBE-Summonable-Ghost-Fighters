--[[
 SummonGhostSailors / config.lua — every tunable constant, in one place.

 Standalone by design: no require() into LivingBase. The crew class + look roster below
 are copied from LivingBase's own Config.FACTION_VISITOR_LOOKS (config.lua, 2026-08 era)
 since that's the roster RedFalcon wants randomized through, but nothing here reads
 LivingBase's actual installed files at runtime — if LivingBase changes, this mod is
 unaffected until someone manually re-copies an updated roster.
]]

local Config = {}

-- Hotkey. TEMPORARY: switched to "HOME" for testing (2026-08-26) — confirmed working in this
-- UE4SS build via LivingBase's own history (Config.KEYS.dumpWidgets = "HOME"), to isolate
-- whether the summon logic itself works independent of the backslash key-name confusion.
-- "OEM_FIVE" (the real backslash binding, also confirmed working via LivingBase's own
-- pre-2026-08-24 "\" statue-facing bind) is the intended long-term key — switch back once
-- HOME confirms the rest of the mod works.
Config.SUMMON_KEY = "HOME"

-- Lifecycle.
Config.GHOST_LIFETIME_MS       = 120000   -- each sailor despawns 120s after ITS OWN spawn
Config.GHOST_TICK_MS           = 200      -- shared follow/despawn tick cadence

-- Ghost look. Same translucent preview material LivingBase's own Spawner.ApplyGhostMaterial
-- swaps onto every mesh slot — confirmed rendering on a character-adjacent mesh already.
Config.GHOST_MAT_PATH          =
  "/Game/Environment/Gameplay/GDKit/Meshes/Building/MI_Building_SimplifiedPreview.MI_Building_SimplifiedPreview"
Config.GHOST_MATERIAL_DELAY_MS = 800      -- settle delay after spawn before the material swap

-- Opacity tuning — EXPERIMENTAL, untested (2026-08-26). Set to 1.0 to disable and fall back
-- to the plain fixed-look material swap (zero risk, the original proven-safe path).
-- 0.8 = RedFalcon's requested starting point ("down to 80%").
Config.GHOST_OPACITY = 0.8
Config.GHOST_OPACITY_SCALAR_NAMES = { "Opacity", "Opacity Amount", "OpacityAmount", "Alpha", "GhostOpacity" }
Config.GHOST_COLOR_PARAM_NAMES    = { "AltColor", "MaxStabilityColor", "MinStabilityColor", "InstabilityColor" }

-- Crew base pawn — BP_Mob_Crew_Regular_Player, the same "Player" faction crew brain
-- LivingBase's own whistle.lua escort and FACTION_VISITOR_LOOKS both build on. Already
-- player-aligned by class default, so no faction copy (makeFriendly) is needed.
Config.CREW_CLASS =
  "/Game/Gameplay/Character/AI/Crew/Regular/Faction/Player/BP_Mob_Crew_Regular_Player.BP_Mob_Crew_Regular_Player_C"
Config.COMBATANT  = true   -- killable escort, not invincible set-dressing

-- Roster to randomize through — copied from LivingBase's Config.FACTION_VISITOR_LOOKS
-- (config.lua:1333-1348). colorParams intentionally dropped: confirmed to crash the game
-- if set pre-build, and LivingBase's own spawnCrewEntry never wires it in either.
local FV = "/Game/Gameplay/Character/AI/NPC/FactionActors/"
local function objPath(dir, name) return dir .. name .. "." .. name end

Config.ROSTER = {
  { name = "Player Crew" },
  { name = "Buccaneers Musketeer",
    params = objPath(FV .. "Buccaneers/CompositeMesh/Common/", "DA_NPC_AnimatedActor_Bucaneers_Common_Musketeer_CompositeMeshComponentParams") },
  { name = "Buccaneers Sailor",
    params = objPath(FV .. "Buccaneers/CompositeMesh/Common/", "DA_NPC_AnimatedActor_Bucaneers_Common_Sailor_CompositeMeshComponentParams") },
  { name = "Buccaneers Sergeant",
    params = objPath(FV .. "Buccaneers/CompositeMesh/Common/", "DA_NPC_AnimatedActor_Bucaneers_Common_Sergeant_CompositeMeshComponentParams") },
  { name = "Brethren Woman",
    params = objPath(FV .. "BrethrenOfTheCoast/CompositeMesh/Common/", "DA_NPC_AnimatedActor_BotC_Common_Female_01_CompositeMeshComponentParams") },
}

-- Cosmetic cleanup (optional).
Config.HIDE_NAMEPLATES = false

-- Follow tuning — same shape/defaults as LivingBase's whistle.lua followTick.
Config.FOLLOW_START_UU       = 700
Config.FOLLOW_WARP_UU        = 8000
Config.FOLLOW_WARP_RING_UU   = 500
Config.FOLLOW_SPEED_MULT     = 3.0
Config.FOLLOW_SPEED_MIN      = 250.0
Config.FOLLOW_SPEED_MAX      = 900.0
Config.FOLLOW_PACE_MARGIN    = 150.0
Config.FOLLOW_MATCH_PACE     = true
Config.FOLLOW_END_UU         = 300.0
Config.FOLLOW_SPEED          = 0.0
Config.FOLLOW_PARTIAL        = true
Config.FOLLOW_ASSERTIVE      = false
Config.FOLLOW_AUTOSTOP_LOGIC = true
Config.FOLLOW_STALL_TICKS    = 3

Config.VERBOSE = false

return Config
