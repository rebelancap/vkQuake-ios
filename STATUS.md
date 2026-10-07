# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`) with a 26-patch overlay,
branch `upstream-1.36.0`. OTA dev build **1.1.1.1** (built on SDK 26.5) is live
at https://goomba.tailc8f64e.ts.net/ota/vkquake/ ; last public release 1.1.1.
Commit 0488357 (version **1.1.1.2**, unpublished) adds the classic-data weapon
wheel (GitHub issue #4). **BLOCKER for any OTA:** this is the first build on the
Xcode 27 / iOS 27 SDK, and on the iOS 27.0 sim the Metal view is laid out wrong
(see Last round).

## Last round (2026-10-06)
Clean-machine rebuild from a purged `build/`: oracle (meson/ninja),
`build-ios-deps.sh`, `build-sim.sh ios`, `ios-syntax-check.sh gl_screen` — all
green, no script changes. New `scripts/sim-verify-classicwheel.sh` (lane 2,
iPhone Air iOS 27.0) **PASSED**: original id1 boots (id1/pak1.pak on the search
path, no rerelease/), e1m1 loads, `weaponwheel` logs the classic-path line and
`weapon wheel: 8 slots`, the wheel switch moves the player edict from weapon 32
(v_rock2.mdl, after impulse 9) to weapon 8 (v_nail2.mdl), no missing `inv*`
lumps, and the rerelease regression still loads its own 8-slot wheel with no
classic line. Artifacts: `artifacts/sim/2026-10-06-classicwheel-*.png` and
`*-console.log`.

**But the screenshots expose a layout regression:** they come out LANDSCAPE
(2736x1260; the 2026-08-30 SDK-26.5 build on the same iOS 27.0 runtime gave
portrait 1320x2868 with full-screen content), and the game image fills only the
left 1260 px column, magnified (the top-left part of the frame), the rest black.
The UIKit touch overlay is laid out correctly across the full landscape width,
and the MoltenVK swapchain is 2736x1260 (correct). The rerelease run shows the
same thing, so the wheel change did not cause it. The wheel ring is therefore
only partly visible (classic: the shotgun `inv_` icon + the procedural axe;
rerelease: the ww_ shotgun + axe), and the HUD and viewmodel are out of frame,
so assertion (c) rests on the edict readback.

## Next steps
1. Diagnose the iOS 27 SDK layout regression: SDL 3.4.10's UIKit metal view /
   window frame vs the scene's landscape bounds (`vendor/SDL/src/video/uikit/
   SDL_uikitmetalview.m`, `SDL_uikitwindow.m`). Have the shell log the SDL
   window, view and CAMetalLayer frames at scene activation. Fix it, re-run
   `scripts/sim-verify-classicwheel.sh`, and confirm a full-screen ring + HUD.
2. Only then publish 1.1.1.2 OTA, after launching it on a device first (program
   toolchain-change rule).
3. Then the earlier queue: Austin tests on iPhone/headset; merge to main;
   Austin picks the release number.

## Open questions
- Release number/timing — Austin's call. Default: stay on OTA 1.1.1.x dev builds.

## Live claims
None. iPhone Air (lane 2) shut down by the verify script's trap; no agents
running; tree clean apart from the untracked `.claude/` and
`docs/IOS-AUDIO-SESSION-GUIDE.md` (not this round's).
