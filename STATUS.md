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
**OTA dev build 1.1.2.1 (build 39)** is on the hub (2026-10-07): issue #5 —
console by touch (CONSOLE pill in every menu, `~` on the keyboard, 3-finger tap
in-game; console-aware keyboard shift) + Settings → Game Data (2021 / Classic,
shown when both sets exist, applies next launch). Sim-verified on lane 2,
Sonnet-reviewed (no blockers), merged to local `main`. Awaiting Austin's
device check; the reporter is on 1.1.1 and issue item 2 is already in 1.1.2.
Local `main` once carried 19 unpushed VR-doc commits (first name throughout);
they now live on local branch `vr-notes-private`, and `main` tracks `origin/main`.

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
1. Push `main` (`git push origin main`) — the session's push was blocked by the
   auto-mode classifier.
2. Austin: install 1.1.2.1 from the hub and check the CONSOLE pill, `~`, the
   3-finger tap, and that the console input line clears the real keyboard
   (the shift is computed from the live keyboard frame; the sim keyboard was
   178 pt). Then post the issue #5 reply (item 2 fixed in 1.1.2, items 1 and 3
   in 1.1.2.1).
3. Known rare edge cases from review, fix if Austin hits them: `~` typed into a
   menu text field (server address, save name) opens the console instead of
   typing; opening the console while the keyboard is already up keeps the
   previous shift.
4. Austin posts/closes issue #4; confirm SideStore source shows 1.1.2.
5. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
6. Consider upstream's per-game archived cvars in the iOS settings page.
7. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- Should the VR docs on local branch `vr-notes-private` (VR charter, R0–R6 notes,
  porting guide; Austin's first name ~97 times) be scrubbed and pushed to the
  public repo? Default if unanswered: keep them local, never push.
- When Austin wants a public release of the issue #5 work, he picks the number
  (1.1.3 presumably). Default: stay on 1.1.2.x dev builds.

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; local `main` is 5 commits
ahead of `origin/main` until pushed; tree clean apart from the untracked
`.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md`.

- None. (Release 1.1.2 decided 2026-10-07; a device check of the first iOS 27 SDK
  build was waived by Austin on the sim evidence — if the phone shows anything odd,
  the SDL patch 0003 path is the first suspect.)

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; branch `issue-5` committed, tree clean apart from
the untracked `.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md` (not this round's).
