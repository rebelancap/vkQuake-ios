# Installing vkQuake on Apple Vision Pro

This is an iOS and visionOS build of [vkQuake](https://github.com/Novum/vkQuake), the Vulkan-powered Quake engine, running natively through Metal. On Apple Vision Pro it plays in a freely resizable 2D window, in a stereoscopic 3D mode on a world-locked panel in your room, and in a VR mode that puts you inside the game at life scale.

## What you need

- Apple Vision Pro on visionOS 2 or later. **VR mode requires visionOS 26 or later.**
- Your own Quake game files
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode, plus `xcodegen` and `cmake` (`brew install xcodegen cmake`)
- For VR: PS VR2 Sense controllers are optional but strongly recommended. Without them, VR is playable with a gamepad, aimed with your head.

## Your game files

Neither this repository nor the app contains any game content. You must own Quake and provide your own files. Add them at first launch, or later in the Files app under *On My Vision Pro → vkQuake*. Use one of these:

- **Quake (2021 re-release)** from Steam or GOG: pick your `rerelease` folder (`id1` + `QuakeEX.kpf`). Recommended, especially for the 3D mode; the enhanced models, music and the bonus episodes all work.
- **Original Quake**: `pak0.pak` + `pak1.pak`.

The mission packs and QuakeC mods go in the same way, each in its own folder (for example `hipnotic`, `rogue`, or `ad` for Arcane Dimensions), and appear in the in-game Mods menu.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there. No Xcode or Dev Strap is required.
2. In SideStore, go to *Sources → +* and paste this source, then install vkQuake (listed as **Quake**):

   ```
   https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-visionos.json
   ```

   The app updates from this source when new versions ship. The source also carries Quake II and Quake III.

To install by hand instead, download `vkQuake-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/vkQuake-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

From a checkout of this repo:

```sh
scripts/build-ios-deps.sh        # SDL3 + MoltenVK + codecs (once); the visionOS build also uses its Vulkan headers
scripts/build-visionos-deps.sh   # visionOS dependencies (once)
scripts/build-visionos.sh        # engine + signed visionOS app
```

`scripts/build-visionos.sh` writes the app to `build/visionos/xcode/Release-xros/vkQuake.app`. Signing uses the `DEVELOPMENT_TEAM` set in `ios/project.yml`; change it to your own Apple Developer team.

Upstream vkQuake is vendored unmodified and pinned by commit in `upstream.pin`. Every local change is a patch in `patches/`, applied by `scripts/sync-overlay.sh`. The build scripts stop with a message naming any prerequisite that is missing. A frame-level architecture map is in `docs/upstream-map.md`.

## Notes

- Switch to VR from the ornament under the window. Comfort settings (smooth or snap turning, movement relative to your head or hand, standing height, HUD position) are in *Settings → Vision Pro VR*. The default Sense controller layout is in the README's [VR mode](README.md#vr-mode-apple-vision-pro) section.
- Mods, the mission packs and online multiplayer also work in VR.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- QUAKE is © id Software. Licensed under the GNU GPL v2 (see `COPYING`), matching upstream vkQuake.
