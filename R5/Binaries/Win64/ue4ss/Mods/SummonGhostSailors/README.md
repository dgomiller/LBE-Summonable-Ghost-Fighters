# LBE: Summonable Ghost Fighters

A spin-off, standalone companion to **Living Base Enhanced** — summon a translucent ghost
crewman or a corrupted Senkamati ally on demand, have it follow and fight alongside you, and
watch it dissipate into mist a couple of minutes later. Nothing it spawns is ever saved, so
nothing lingers across a reload. Fully standalone: Living Base Enhanced is **not** required.

## Controls

| Key | Action |
| --- | --- |
| Home | Summon one random-look ghost sailor (Player Crew, Buccaneers Musketeer/Sailor/Sergeant, or a Brethren of the Coast woman) |
| End | Summon one corrupted Senkamati ally (Warrior, Hunter, or Caster) — real native combat AI, friendly to you |

Home and End sit right next to each other on a real keyboard, by design.

Both keys are remappable in `Scripts/config.lua` (`Config.SUMMON_KEY` / `Config.SENKAMATI_KEY`),
or via Windrose Mod Settings if installed (see below).

## What happens when you summon one

- Appears near you with a translucent "ghost" material (skin + clothing swapped to a dedicated
  ghost-character material pair) and a trailing ground-light effect.
- Follows you at pace — matches your walk/sprint speed, yields to its own combat AI the moment
  it's actually fighting something, and warps back to your side if it falls too far behind.
- After `Config.GHOST_LIFETIME_MS` (120 seconds by default) it plays a short dissipating-mist
  effect at its own feet, then disappears.
- Up to `Config.GHOST_MAX_ACTIVE` (5 by default) can be active at once, shared between sailors
  and Senkamati — summoning past the cap shows an on-screen "Max Ghosts Summoned" message.
- **Never persisted.** Nothing this mod spawns is ever written to a save file — reload the game
  and every ghost is gone, whether or not its timer had run out yet.

## Configuration (`Scripts/config.lua`)

Everything is a plain, commented Lua constant — no build step needed, just edit and relaunch
(keybind changes need a relaunch either way; RegisterKeyBind only works during initial mod load
in this UE4SS build). The main ones:

- `Config.SUMMON_KEY` / `Config.SENKAMATI_KEY` — either hotkey.
- `Config.GHOST_LIFETIME_MS` — how long a ghost lasts before despawning.
- `Config.GHOST_MAX_ACTIVE` — the shared cap across both kinds.
- `Config.ROSTER` / `Config.SENKAMATI_ROSTER` — which looks/classes get randomized through.
- `Config.GHOST_SKIN_MAT_PATH` / `Config.GHOST_CLOTH_MAT_PATH` — the ghost material pair.
- `Config.GHOST_FX_PATH` / `Config.GHOST_DESPAWN_FX_PATH` — the following ground light and the
  dissipate puff.
- `Config.GHOST_FX_ENABLED` — turn the following ground light off entirely.

## Optional: Windrose Mod Settings support

If [Windrose Mod Settings](https://www.nexusmods.com/windrose/mods/442) by IceBoxStudio is
installed, this mod registers itself automatically — both hotkeys, the ghost lifetime (in
seconds), the max-active cap, and the ground-light toggle become editable from the game's
native Settings > Mods screen. The lifetime/max-active sliders are continuous floats in this
game's build (no integer-step widget available), so whatever value you land on is rounded to
the nearest whole number when it's actually applied — the panel's own description says so.
Entirely optional: the mod works exactly the same without Windrose Mod Settings installed.

## Requirements

- Windrose (Kraken Express), single-player, current Early Access build.
- UE4SS, latest experimental / RE-UE4SS build.
- No other mods required — this is fully standalone, including from Living Base Enhanced.

## Known limitations

- A game patch can change internal class/material paths and temporarily break the ghost look
  or a summon — everything version-dependent lives in `config.lua`.
- The Windrose Mod Settings lifetime/max-active sliders don't visually snap to whole numbers
  while dragging (see above) — the applied value is still always a whole number.
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
follow-at-heel AI, and the on-screen toast notifications were all ported directly from that
project's own codebase. Thanks to IceBoxStudio for Windrose Mod Settings. Built iteratively
with Claude.
