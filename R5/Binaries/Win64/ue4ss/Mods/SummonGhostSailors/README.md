# LBE: Summonable Ghost Fighters

A spin-off, standalone companion to **Living Base Enhanced** — summon a translucent ghost
crewman or a corrupted Senkamati ally on demand, have it follow and fight alongside you, and
watch it dissipate into mist a couple of minutes later. Nothing it spawns is ever saved, so
nothing lingers across a reload. Fully standalone: Living Base Enhanced is **not** required.

## Controls

| Key | Action |
| --- | --- |
| Home | Summon one random-look ghost sailor (Player Crew, Buccaneers Musketeer/Sailor/Sergeant, or a Brethren of the Coast woman). Optionally a Grenadier instead — see below |
| End | Summon one corrupted Senkamati ally (Warrior, Hunter, Caster or Thrall) — real native combat AI, friendly to you |

Home and End sit right next to each other on a real keyboard, by design.

Both keys are remappable in `Scripts/config.lua` (`Config.SUMMON_KEY` / `Config.SENKAMATI_KEY`),
or via Windrose Mod Settings if installed (see below).

## What happens when you summon one

- Appears near you with a translucent ghost look (the same reskin as Living Base Enhanced's
  "Make Ghost") and a trailing ground-light effect. Both can be turned off.
- Follows you, yields to its own combat AI the moment it is actually fighting something, and
  teleports back beside you — always **behind** you, never in front — if it falls too far behind.
  Out of combat the game only lets these characters walk, so the teleport does the catching up.
- A brand-new summon is left alone for its first few seconds while it finishes building.
- After the ghost lifetime (120 seconds by default) it plays a short dissipating-mist effect at
  its own feet, then disappears. **Every** summon does this — sailors, Senkamati and Grenadiers.
- An on-screen message tells you when one dissipates or falls in a fight, and how many are left.
- Up to 5 can be active at once, shared across every kind — summoning past the cap shows an
  on-screen "Max Ghosts Summoned" message.
- **Never persisted.** Nothing this mod spawns is ever written to a save file — reload the game
  and every ghost is gone, whether or not its timer had run out yet.
- Senkamati allies are set up so they work for you: friendly faction, plus ownership synced to
  you, which lets a Caster pick targets and cast.

## Optional: the Grenadier

Turn on **Grenadier Summons** (Settings > Mods, or `Config.GRENADIER_ENABLED`) and each Home press
has a chance — 10% by default, adjustable — to summon a Blackbeard Grenadier instead of a sailor.
**It is off by default because its grenades do a lot of damage**, including to your own base, so
stand somewhere open when you try it.

## Settings

If [Windrose Mod Settings](https://www.nexusmods.com/windrose/mods/442) by IceBoxStudio is
installed, this mod registers itself automatically and everything below becomes editable from the
game's native Settings > Mods screen. **Changes take effect after restarting the game.**

| Setting | What it does |
| --- | --- |
| Ghost Lifetime (seconds) | How long every summon lasts (10–500, default 120) |
| Teleport Distance (m) | How far behind you a summon can fall before it teleports back (10–500 m, default 30) |
| Max Simultaneous Ghosts | The shared cap (1–15, default 5) |
| Grenadier Chance (%) | Chance a Home press summons a Grenadier (1–50, default 10) |
| Ground Light Effect | The light that follows each summon (on by default) |
| Disable Ghost Effect | Summons keep their normal look instead of the ghost reskin (off by default) |
| Grenadier Summons | Allow the Grenadier roll (off by default) |
| Summon Ghost Sailor / Summon Senkamati Ally | The two hotkeys |

Entirely optional: the mod works exactly the same without Windrose Mod Settings installed, using
the values in `Scripts/config.lua`.

## Configuration (`Scripts/config.lua`)

Everything is a plain, commented Lua constant — no build step needed, just edit and relaunch
(keybind changes need a relaunch either way; RegisterKeyBind only works during initial mod load
in this UE4SS build). The main ones:

- `Config.SUMMON_KEY` / `Config.SENKAMATI_KEY` — either hotkey.
- `Config.GHOST_LIFETIME_MS` / `Config.GHOST_MAX_ACTIVE` — lifetime and the shared cap.
- `Config.FOLLOW_WARP_UU` — teleport distance in game units (100 units = 1 m).
- `Config.FOLLOW_WARP_BEHIND` — teleport only to the area behind you.
- `Config.DISABLE_GHOST_EFFECT` — skip the ghost reskin.
- `Config.GRENADIER_ENABLED` / `Config.GRENADIER_CHANCE` — the optional Grenadier.
- `Config.DESPAWN_NOTIFY` — the dissipate / fell messages.
- `Config.ROSTER` / `Config.SENKAMATI_ROSTER` — which looks/classes get randomized through.
- `Config.GHOST_*_MAT_PATH` / `Config.GHOST_FX_PATH` / `Config.GHOST_DESPAWN_FX_PATH` — the ghost
  materials, the following ground light and the dissipate puff.
- `Config.GHOST_FX_ENABLED` — turn the following ground light off entirely.

## Requirements

- Windrose (Kraken Express), single-player, current Early Access build.
- UE4SS, latest experimental / RE-UE4SS build.
- No other mods required — this is fully standalone, including from Living Base Enhanced.

## Known limitations

- Out of combat, summons walk at a fixed pace and cannot run to catch up — they teleport behind
  you instead (see Teleport Distance).
- A game patch can change internal class/material paths and temporarily break the ghost look
  or a summon — everything version-dependent lives in `config.lua`.
- The Senkamati ally's friendly-faction technique is shared with Living Base Enhanced's own —
  if a future game patch changes how NPC factions work, both mods would need the same fix.

## License

All rights reserved by default, except: modifying for personal use, reusing the code in your
own mod with credit, and porting to other games with credit are all permitted without asking.
Reuploading/rehosting this mod elsewhere, or selling it/using it in anything monetized, is not
permitted. Windrose and its assets belong to Kraken Express — this is an unofficial,
unaffiliated mod.

## Credits

A spin-off of Living Base Enhanced, built by the same author — the friendly-faction copy, the
ghost look, the follow AI, and the on-screen notifications were all ported directly from that
project's own codebase. Thanks to IceBoxStudio for Windrose Mod Settings. Built iteratively
with Claude.
