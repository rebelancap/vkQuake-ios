# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`) with a 28-patch overlay
plus 3 SDL patches. **Public release 1.1.3** (tag `v1.1.3`, 2026-10-08) is live
on GitHub and on the OTA hub at the same number
(https://goomba.tailc8f64e.ts.net/ota/vkquake/); `origin/main` = release
(branch `release-1.1.3`). 1.1.3 = issue #5: console by touch (console button in
every menu, `~` on the keyboard, 3-finger tap in-game, console-aware keyboard
shift, notch-side console inset chosen from `windowScene.interfaceOrientation`
since landscape safe-area insets are symmetric) + Settings → Game Data (2021 /
Classic, applies next launch) + one-column menu chrome with matching 20 pt
glyphs. Sim-verified on lane 2 across 1.1.2.1 / 1.1.2.2, Austin verified on
device and chose 1.1.3. Next OTA dev builds are 1.1.3.1, 1.1.3.2, …
Local `main` once carried 19 unpushed VR-doc commits; they live on local branch
`vr-notes-private`. Note: `git push` from a session is NOT blocked — the earlier
denial was the classifier rejecting a long combined command, not the push.

## Last round (2026-10-08) — issue #5 follow-ups, branch `issue-5b` (NOT merged/published)
- **Console button**: glyph-only (`terminal.fill`), 64x46, same tint/background/
  radius/20 pt bold symbol as back and gear, same x, directly under the gear at
  the same 58 pt pitch (frames on the Air sim: back 80,7 / gear 80,65 /
  console 80,123). `vkq_ui console` still presses the real button.
- **Quick save / load** stack under it (80,181 and 80,239, 148x46, 12 pt gaps,
  bottom at 285 of 420 pt); their glyphs now use the same 20 pt bold symbol.
  Sim check: all five visible in a live SP game's main menu, no overlap.
- **Console vs notch, overlay 0031**: finding — iOS reports SYMMETRIC safe-area
  insets in landscape on the Air ({0, 68, 20, 68} in BOTH landscape sides), so
  `safeAreaInsets.left` alone cannot tell the cutout side. The shell picks it from
  `windowScene.interfaceOrientation` (LandscapeRight = cutout left — the sim's
  default; LandscapeLeft = cutout right) and pushes
  `VKQ_TouchSetConsoleInset(left_px, right_px)` (points x Metal layer
  drawableSize/bounds = 3.0 → 204 px). The engine indents the console by whole
  characters on the left and shortens `con_linewidth` on either side (version
  string and wrapped lines end clear of the cutout). Re-checked every frame, so
  rotation applies live. iPhone only (not visionOS).
- New sim seam `vkq_ui orient left|right|any` (scene geometry request) proved the
  flip on the headless sim; `vkq_ui state` now logs orientation, safe area and
  every column frame.
- `scripts/sim-verify-issue5b.sh` PASSED on lane 2 (shut down after); shots in
  `artifacts/sim/issue5b/` (local, gitignored). Device `build-ios.sh` and
  `build-visionos.sh` green.
Previous round (2026-10-07): issue #5 (console by touch, Game Data choice), 1.1.2.1.

## Next steps
1. Confirm the SideStore source shows 1.1.3 (quake-ports `build-sources.yml` run
   37854711034 was fired; check apps-ios.json / apps-visionos.json via the API).
2. Reply on issue #5 (item 2 was fixed in 1.1.2; items 1 and 3 in 1.1.3) and on
   issue #4; close both when the reporters confirm or after a reasonable wait.
3. Known rare edge cases, fix if reported: `~` typed into a menu text field opens
   the console instead of typing; opening the console while the keyboard is
   already up keeps the previous shift; keyboard-dismiss button overlaps the
   console version string.
4. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
5. Consider upstream's per-game archived cvars in the iOS settings page.
6. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- Should the VR docs on local branch `vr-notes-private` (VR charter, R0–R6 notes,
  porting guide; Austin's first name ~97 times) be scrubbed and pushed to the
  public repo? Default if unanswered: keep them local, never push.
- When Austin wants a public release of the issue #5 work, he picks the number
  (1.1.3 presumably). Default: stay on 1.1.2.x dev builds.

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; `main` = `origin/main`;
tree clean apart from the untracked `.claude/` and `docs/IOS-AUDIO-SESSION-GUIDE.md`.
