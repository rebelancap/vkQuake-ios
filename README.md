# vkQuake for iPhone & Apple Vision Pro

Play **Quake** on your iPhone and Apple Vision Pro — the full campaign, the mission
packs, custom mods, a stereoscopic **3D mode** that puts the game on a floating screen
in your room with real depth, and a full **VR mode** that puts you inside it at life
scale with a gun in each hand. 100% vibe coded with lots of passion and attention to
detail.

Built on [vkQuake](https://github.com/Novum/vkQuake), the Vulkan-powered engine, running
natively through Metal.

<p align="center">
  <img src="screenshots/vision-pro.png" width="100%" alt="Quake running on a floating panel in a living room on Apple Vision Pro, with the in-app 3D toggle below the window">
</p>

---

## Install

**Add the SideStore source** — the easiest path, and vkQuake auto-updates when new versions ship:

| Device | Source URL |
| --- | --- |
| iPhone / iPad | `https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-ios.json` |
| Apple Vision Pro | `https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-visionos.json` |

In [SideStore](https://sidestore.io) / [AltStore](https://altstore.io): *Sources → **+** → paste the URL*, then
install vkQuake. These are shared sources — they also carry Quake II and Quake III.

On **Apple Vision Pro**, first install SideStore onto the headset with
[iloader](https://github.com/rebelancap/iloader/releases#release-visionos) (SideStore/AltStore can't be
installed on visionOS the usual way — iloader is what gets SideStore there). Then add the source in SideStore
exactly as above. No Xcode or Dev Strap required.

**Prefer a manual install?** Download `vkQuake-*-iOS.ipa` / `vkQuake-*-visionOS.ipa` from the
[latest release](../../releases/latest) and install it through SideStore/AltStore yourself (iPhone / iPad can
also use [Sideloadly](https://sideloadly.io)).

Then **add your Quake files** (see below) at first launch, or via **Files** → *On My iPhone / Vision Pro →
vkQuake* → pick your `rerelease` folder (`id1` + `QuakeEX.kpf`).

## You bring the game

vkQuake ships with **no game content** — you must own Quake and provide your own files.
Copy one of these into the app's folder:

- **Quake (2021 re-release)** — Steam/GOG. Highly recommended, especially for Vision Pro 3D mode. 
  The enhanced models, music, and the bonus  episodes *Dimension of the Past* and *Dimension of the Machine* all work.
- **Original Quake** — `pak0.pak` + `pak1.pak`.

The classic mission packs (*Scourge of Armagon*, *Dissolution of Eternity*) and QuakeC
mods drop in the same way — put each in its own folder (e.g. `hipnotic`, `rogue`, or a
mod like `ad` for Arcane Dimensions) and it appears in the in-game Mods menu.

## Features

- Full single-player campaign with saves, both mission packs, and the re-release episodes
- **QuakeC mods** — drop a mod folder in and launch it from a generated menu (Arcane
  Dimensions, Copper, Alkaline, …)
- Music, all sound, demos, and the full menu/console by touch or controller
- **Game controllers** with a sane default layout; on-screen touch sticks + gyro aim
- 60 / 120 Hz (ProMotion), in-app settings that persist
- **Apple Vision Pro — three ways to play:** a free-resizing 2D window; a **3D mode**
  that puts the game on a world-locked stereoscopic panel with live-tunable screen
  size, distance, depth and room dimming; and a full **VR mode** (below)
- **Multiplayer server browser** with live ping, sorted fastest-first

## VR mode (Apple Vision Pro)

Quake at life scale, in a real immersive space — head tracked, rendered per eye at the
headset's native resolution. Switch to it from the ornament under the window.

<p align="center">
  <img src="screenshots/vr.png" width="100%" alt="Quake in VR on Apple Vision Pro — a weapon held in each hand, in front of the start map's QUAKE arch">
</p>

**With PSVR2 Sense controllers** you aim with your hand, not a stick — the gun is where
your hand is and fires from its own barrel. Two interaction styles:

- **Immersive** — a weapon in each hand, both triggers live, and **holsters** on your
  hips you draw from and stow to. The belt follows you as you walk and turn.
- **Convenience** — one weapon, always in your hand, cycled with a flick of the stick.

Everything else the flat game does, VR does: the HUD, the game's messages, the menus,
the console and save/load all appear on world-locked panels inside the space. **Mods
work in VR** — nothing here forks `progs.dat` — and so does **online multiplayer**.

**Default Sense layout**

| Control | Action |
| --- | --- |
| Trigger | Fire the gun in that hand |
| Grip | Grab / holster (Immersive) |
| Stick | Move (off hand) / turn (aim hand) |
| Stick flick up | Cycle weapon (Convenience) |
| A | Jump |
| B | Swim / move down |
| Left stick click | Clear both holsters |
| Right stick click | Recentre |
| MENU | Game menu |

No controllers? **VR works with a gamepad**, aimed with your head. Comfort settings —
smooth or snap turning, movement relative to your head or your hand, standing height,
HUD position — all live in *Settings -> Vision Pro VR*, which also has its own Reset.

Sense controllers also drive the game in **2D and 3D mode**, mapped to the standard
gamepad layout.

## Requirements

- iPhone/iPad on **iOS 16+**, or **Apple Vision Pro** (visionOS 2+)
- **VR mode requires visionOS 26+.** PSVR2 Sense controllers are optional but strongly
  recommended — without them VR is playable with a gamepad and head aim
- A sideloading tool (SideStore / AltStore) ([iloader](https://github.com/rebelancap/iloader/releases#release-visionos) for visionOS)
- Your own Quake game files

## FAQ

**Which Quake data should I use?** The 2021 re-release if you have it — you get the extra
episodes and enhanced content. Original `pak0`/`pak1` also works.

**Is any game content included?** No. You supply your own files; nothing copyrighted ships
with the app.

**Multiplayer?** Direct connect over NetQuake is supported (LAN and internet servers),
with a server browser that shows live ping.

**Do I need PSVR2 controllers for VR?** No — VR works with a gamepad and head aim. With
Sense controllers you get hand aim, two guns at once and holsters, which is most of what
makes it feel like VR.

**Does VR work with mods?** Yes. Nothing in VR mode forks `progs.dat`, so Arcane
Dimensions, Copper, the mission packs and the re-release episodes all play in VR
unmodified.

**Can it download maps from servers?** No. vkQuake has no content-download support, so
joining a server running a custom map you don't have will tell you which file is missing
and return you to the server list.

**The app stopped launching after about a week?** Apps sideloaded with a free Apple
account expire after 7 days (paid developer accounts last a year). SideStore/iloader
refresh them automatically in the background — open the sideloading app and let it
re-sign.

---

## Building from source

Requires macOS with Xcode, plus `xcodegen` and `cmake` (`brew install xcodegen cmake`).

```sh
scripts/build-ios-deps.sh        # SDL3 + MoltenVK + codecs (once)
scripts/build-ios.sh             # engine + signed iOS app
scripts/build-visionos-deps.sh   # visionOS dependencies (once)
scripts/build-visionos.sh        # engine + signed visionOS app
```

Upstream vkQuake is vendored unmodified and pinned by commit; every local change is a
reviewable patch in `patches/`, applied by `scripts/sync-overlay.sh`. A frame-level
architecture map is in `docs/upstream-map.md`.

## Credits & license

- [vkQuake](https://github.com/Novum/vkQuake) by Axel Gneiting and contributors
- QUAKE © id Software
- Licensed under the **GNU GPL v2** (see `COPYING`), matching upstream vkQuake.
