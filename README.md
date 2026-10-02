# LBE: Summonable Ghost Fighters

Source for **Summon Ghost Sailors**, a UE4SS Lua mod for [Windrose](https://store.steampowered.com/)
(Kraken Express, UE 5.6, single-player). Summon a translucent ghost sailor or a corrupted Senkamati
ally (or, optionally, a Grenadier) that follows and fights alongside you, then dissipates into mist a couple of minutes later —
nothing it spawns is ever saved, so nothing lingers across a reload.

This is a spin-off, standalone companion to
**[Living Base Enhanced](https://github.com/dgomiller/Living-Base-Enhanced-Windrose)**, built by the
same author — several techniques (the friendly-faction copy, the follow-at-heel AI, the on-screen
toast notifications) were ported directly from that project's own codebase, but this mod has no
runtime dependency on it: Living Base Enhanced does not need to be installed.

For what the mod actually **does** and how to **use** it, see the shipped, end-user-facing README at
[`R5/Binaries/Win64/ue4ss/Mods/SummonGhostSailors/README.md`](R5/Binaries/Win64/ue4ss/Mods/SummonGhostSailors/README.md)
— that's the one that travels with the mod itself. This top-level README is about the *codebase*,
for anyone browsing the repo.

## Repo layout

```
R5/Binaries/Win64/ue4ss/Mods/SummonGhostSailors/
├── Scripts/
│   ├── main.lua          entry point: key registration, the summon flows (sailor, Senkamati, Grenadier), the shared cap
│   ├── config.lua        every tunable constant (keys, lifetimes, roster, material/FX paths)
│   ├── spawner.lua        spawn plumbing, ghost material swap, friendly-faction copy, follow FX,
│   │                     one-shot dissipate FX, a ported Toast (on-screen messages)
│   ├── follow.lua         the shared follow/despawn tick both ghost kinds run on
│   └── modsettings.lua    optional Windrose Mod Settings integration
├── enabled.txt            required, empty — presence means the mod is enabled
├── mod.txt                UE4SS mod name:version
├── README.md              the shipped, end-user-facing doc (see above)
├── CHANGELOG.txt          version history
└── NEXUS_DESCRIPTION.txt  BBCode mirror of the README for the Nexus Mods page
```

## Dev workflow

- **Working is source of truth.** Edit files directly under `R5/...` here; there's no build step.
- This mod has no hot-reload command of its own (unlike Living Base Enhanced's `lbreload`) — a code
  change needs a full game relaunch to take effect, since `RegisterKeyBind` is only safe to call
  during a mod's initial load pass in this UE4SS build.
- **Deploying to a live install:** copy this `R5/...` tree over the corresponding path in the actual
  game install directory. Confirm the game isn't running first.
- Durable, mod-agnostic UE4SS/Windrose engine findings (several of which this mod's own development
  surfaced — the `ExecuteWithDelay`/`ExecuteInGameThread` nesting rule, component-identity
  comparison, a third-party mod's actual settings-widget types) are maintained separately, for any
  Windrose mod, in
  **[Windrose-UE4SS-Modding-Notes](https://github.com/dgomiller/Windrose-UE4SS-Modding-Notes)**.

## License

**All rights reserved by default**, except for the specific permissions in [`LICENSE`](LICENSE) —
nothing beyond what's listed there is implied.

**Permitted, without needing to ask:** modify for personal use; reuse this project's code in your
own separate project, with credit; convert/port to other games, with credit.

**Not permitted:** reuploading/rehosting this project (modified or unmodified) anywhere other than
the original author's own page(s)/repo(s); selling it or using it in anything sold or monetized, in
whole or in part (Nexus Mods' own Donation Points system is exempt).

**Windrose** and its game assets, class names, and intellectual property belong to Kraken Express —
this is an unofficial, unaffiliated mod.
