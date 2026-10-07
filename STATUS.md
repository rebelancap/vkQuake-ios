# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`) with a 26-patch overlay
plus 3 SDL patches. **Public release 1.1.2** (tag `v1.1.2`, 2026-10-07) is live
on GitHub and on the OTA hub at the same number
(https://goomba.tailc8f64e.ts.net/ota/vkquake/); `origin/main` = `f291a42`
(branch `upstream-1.36.0` = `release-1.1.2`). 1.1.2 = upstream 1.36.0 fold-in +
classic-data weapon wheel (issue #4) + SDL patch 0003 (iOS 27 SDK layout). It is
the first release built on the Xcode 27 / iOS 27 SDK; sim-verified full-screen,
Austin accepted on the strength of the sim round (rerelease-only on his device).
Next OTA dev builds are 1.1.2.1, 1.1.2.2, …

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
Then Austin chose 1.1.2: one release build via publish-ota.sh (hub staged at
1.1.2, dev console excluded), IPAs verified 1.1.2/38, GitHub release v1.1.2 with
both IPAs, main fast-forwarded, quake-ports source workflow fired.
Earlier: published 1.1.1.2 OTA (both platforms) via `scripts/publish-ota.sh`, which now
carries the Shipwright 8c1f276 guard (exactly one IPA per export dir, its own
CFBundleShortVersionString must equal the plist version; export dirs wiped
first). The publish was denied three times by the auto-mode classifier
("Production Deploy") until Austin approved it via /permissions — the session
transcript's own "don't publish before a device launch" language is the likely
trigger; a fresh session with only STATUS.md context would not carry it.

## Next steps
1. Austin posts the issue #4 reply (text drafted in the session) and closes it
   once the reporter confirms, or after a reasonable wait.
2. Confirm the SideStore source shows 1.1.2 (apps-ios.json / apps-visionos.json
   in rebelancap/quake-ports) — the workflow was fired, not yet confirmed.
3. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
4. Consider adopting upstream's per-game archived cvars in the iOS settings page.
5. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- None. (Release 1.1.2 decided 2026-10-07; a device check of the first iOS 27 SDK
  build was waived by Austin on the sim evidence — if the phone shows anything odd,
  the SDL patch 0003 path is the first suspect.)

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; tree clean apart from
the untracked `.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md` (not this round's).
