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

## Last round (2026-10-07) — issue #5, branch `issue-5` (commit e274ad2, NOT released)
Implemented GitHub issue #5 items 1 and 3 (item 2 shipped in 1.1.2):
- **Game Data** choice: iOS Settings → "Game Data" section (2021 Re-release /
  Original (Classic)), shown only when both `Documents/rerelease/id1` and
  `Documents/id1` hold a pak0; `VKQ_iOS_BasedirPath` honours it with fallback;
  launch line `[vkquake] game data: …` in boot.log. Applies next launch (footer says so).
- **Console by touch**: CONSOLE pill in every menu, `~`/`` ` `` on the soft keyboard
  toggles the console, 3-finger tap opens it in game (keyboard toggle kept when a
  text field/console is active); back/gear move to the right edge in the console.
  Keyboard shift is now console-aware (0 pt half-screen, 188 pt full-screen on the
  Air) and the shell forces SDL's `updateKeyboard` after setting the rect (SDL had
  been applying the previous show's rect: −59 pt measured). Console scale left on
  the shared Menu/HUD slider: 80 columns, ~11.4 pt lines, 18 lines visible.
- Overlay **0030** adds the `vkq_ui` sim seam + `VKQ_TouchConForced`.
- `scripts/sim-verify-issue5.sh` PASSED on lane 2 (iPhone Air iOS 27.0), shut down
  after; screenshots in `artifacts/sim/issue5/` (local only — gitignored, like
  DECISIONS.md). Device `build-ios.sh` and `build-visionos.sh` build, link and sign.
  Details: DECISIONS.md "2026-10-07 — Issue #5".
Previous round (2026-10-06): iOS 27 SDK layout fix (SDL patch 0003) and release 1.1.2.

## Next steps
1. Orchestrator: review the `issue-5` diff (e274ad2), then publish an OTA dev build
   1.1.2.1 per OTA-PUBLISHING.md; on device check the CONSOLE pill, 3-finger tap and
   the real keyboard height (shift is computed from the live keyboard frame).
2. Reply on issue #5 once the build is out (Game Data row + three console paths).
3. Austin posts/closes issue #4; confirm SideStore source shows 1.1.2.
4. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
5. Consider upstream's per-game archived cvars in the iOS settings page.
6. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- None. (Release 1.1.2 decided 2026-10-07; a device check of the first iOS 27 SDK
  build was waived by Austin on the sim evidence — if the phone shows anything odd,
  the SDL patch 0003 path is the first suspect.)

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; branch `issue-5` committed, tree clean apart from
the untracked `.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md` (not this round's).
