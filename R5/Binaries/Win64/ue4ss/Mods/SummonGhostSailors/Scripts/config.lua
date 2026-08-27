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

-- Ghost look — CONFIRMED, RedFalcon: "it looks awesome" (2026-08-26). A genuine ghost-character
-- material pair found via a pakcontents.xlsx keyword sweep, applied via the same proven-safe
-- SetMaterial split LivingBase's own Spawner.ApplyTwoMaterialsToActor uses: one material on the
-- base body/skin mesh, a different one on every composite clothing/armor piece. Superseded the
-- original repurposed MI_Building_SimplifiedPreview build-preview material entirely — no opacity
-- hack needed, this pair already looks right on its own.
Config.GHOST_SKIN_MAT_PATH  =
  "/Game/Character/Skeletal_Meshes/Human/Regular/Ghost/Materials/MI_Fable_Male_Ghost_Small.MI_Fable_Male_Ghost_Small"
Config.GHOST_CLOTH_MAT_PATH =
  "/Game/Character/Shaders/MasterMaterials/M_CharacterGhost_V2.M_CharacterGhost_V2"
Config.GHOST_MATERIAL_DELAY_MS = 800      -- settle delay after spawn before the material swap

-- Opacity tuning — CONFIRMED DANGEROUS (2026-08-26): the very first live attempt crashed the
-- game with zero [ghost-opacity] log output beforehand (the exact "pcall cannot catch this"
-- native-crash signature already documented elsewhere for CreateDynamicMaterialInstance-family
-- calls — LivingBase's own component-level version crashed the same way, twice). Reverted
-- immediately per the "if it doesn't work we abandon that option" call. Left at 1.0 (disabled,
-- falls back to the plain fixed-look material swap — the original zero-risk path) and the
-- tryOpacityInstance code below is kept only as a documented reference, not called from
-- anywhere live. Do not re-enable without a genuinely new theory, not another blind arg-count
-- guess — the crash may not even be argument-count-specific; it could be this whole call
-- family being unsafe in this engine build regardless of signature.
Config.GHOST_OPACITY = 1.0
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

-- Follow effect (2026-08-26, RedFalcon: "have an effect follow them"). A separate NiagaraActor,
-- repositioned to the sailor's own location every follow-tick — the same technique LivingBase's
-- proven-safe Spawner.TestSpawnNiagaraActor uses (a bare native NiagaraActor + a plain
-- `niag.Asset = sys` property write, no UFunction call at all). Deliberately NOT
-- SpawnSystemAttached (confirmed to crash this game in LivingBase's own history) and NOT
-- actor-to-actor K2_AttachToActor (also confirmed to crash there, different case) — repositioning
-- a separate actor every tick sidesteps both entirely, using only techniques already proven safe.
-- CONFIRMED, RedFalcon (2026-08-26): FX_Necro_Legs_Light (a Boneman-mob ground light effect —
-- thematically fitting, from the same "Boneman Ghost Pirate" asset family the material look
-- was found alongside). It's a GROUND effect, not a body-height one — GHOST_FX_Z_OFFSET pulls
-- it down from the sailor's root (typically capsule-center height) to roughly ground level, and
-- GHOST_FX_BACK_UU slides it slightly toward the sailor's own back (computed from the sailor's
-- current facing each tick, not a fixed world-axis offset, so it stays correct as they turn)
-- so the sailor ends up standing centered over it rather than the effect reading as "in front."
-- RedFalcon: doesn't need to be perfectly centered — both values are rough starting guesses,
-- tune live if it still looks off.
Config.GHOST_FX_ENABLED  = true
Config.GHOST_FX_PATH     = "/Game/FX/Particles/Mobs/Boneman/FX_Necro_Legs_Light.FX_Necro_Legs_Light"
Config.GHOST_FX_Z_OFFSET = -90.0
Config.GHOST_FX_BACK_UU  = 50.0
Config.GHOST_FX_SCALE    = 1.0

Config.VERBOSE = false

return Config
