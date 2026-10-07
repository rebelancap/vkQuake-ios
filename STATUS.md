# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`) with a 26-patch overlay
plus 3 SDL patches, branch `upstream-1.36.0`. OTA dev build **1.1.1.2** (iOS + visionOS,
published 2026-10-07) is live at https://goomba.tailc8f64e.ts.net/ota/vkquake/ ;
last public release 1.1.1. 1.1.1.2 = classic-data weapon wheel (issue #4) + the
iOS 27 SDK layout fix; it is the FIRST build on the Xcode 27 / iOS 27 SDK,
sim-verified full-screen on iOS 27.0, served IPA checked (Info.plist 1.1.1.2,
build 37, exports present) — but NOT yet launched on a device. Austin's phone
check is the gate before any public release or issue reply.

## Last round (2026-10-06)
Fixed the iOS 27 SDK layout regression (game image in the left 1260 px column,
magnified). Root cause, measured with a temporary setFrame: swizzle: under the
iOS 27 SDK `-[UIApplication statusBarOrientation]` returns Unknown (0) for our
scene app (scene said LandscapeRight). SDL 3.4.10's `UIKit_ComputeViewFrame`,
called from `-[SDL_uikitviewcontroller updateKeyboard]` when the keyboard
machinery fires (`resignFirstResponder` at startup), then decided "portrait" (our
window is RESIZABLE so SDL allows portrait) and swapped the metal view to
420x912 pt in a 912x420 window; the swapchain was rebuilt at 1260x2736. Fix:
`patches/sdl/0003-ios27-scene-interface-orientation.patch` — orientation now
comes from the window scene (`interfaceOrientation`), status bar only as a
fallback; used in ComputeViewFrame, IsDisplayLandscape and the orientation-change
handler. After the fix the metal view is only ever 912x420 and the swapchain
stays 2736x1260. `sim-verify-classicwheel.sh` PASSED (lane 2, iPhone Air iOS
27.0) with full-screen shots: e1m1, full 8-icon classic ring (axe + 7 inv_
guns, slot 5 highlighted), super-nailgun viewmodel + HUD, rerelease ww_ ring.
`sim-verify.sh ios` boot/e1m1 shots full-screen. Device `build-ios.sh` builds,
links and signs (1.1.1.2); visionOS SDL deps build clean with the patch.
Details: DECISIONS.md "2026-10-06 — iOS 27 SDK layout regression".
Note: `scripts/sim-verify.sh` has no shutdown trap — it leaves the sim booted
(shut down by hand this round).
Published 1.1.1.2 OTA (both platforms) via `scripts/publish-ota.sh`, which now
carries the Shipwright 8c1f276 guard (exactly one IPA per export dir, its own
CFBundleShortVersionString must equal the plist version; export dirs wiped
first). The publish was denied three times by the auto-mode classifier
("Production Deploy") until Austin approved it via /permissions — the session
transcript's own "don't publish before a device launch" language is the likely
trigger; a fresh session with only STATUS.md context would not carry it.

## Next steps
1. Austin installs 1.1.1.2 from the hub and checks on the iPhone
   (toolchain-change rule): boot, e1m1 full-screen, open/close the console
   keyboard (that path triggered the bug), rotate LandscapeLeft<->Right, touch
   weapon wheel; ideally once with original id1 data too.
2. If good: reply on GitHub issue #4 (fix lands in the next release; the
   fallback uses the status-bar icons + a drawn axe). Release number is
   Austin's call (1.1.2 by the patch-bump rule, folding in the 1.36.0 bump).
3. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
4. Then the earlier queue: Austin tests on iPhone/headset; merge to main;
   Austin picks the release number.
5. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- Release number/timing — Austin's call. Default: stay on OTA 1.1.1.x dev builds.
- Device check of 1.1.1.2 (needs the phone). Default: no OTA until Austin reports it launched full-screen.

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; tree clean apart from
the untracked `.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md` (not this round's).
