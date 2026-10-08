# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`) with a 28-patch overlay
plus 3 SDL patches. **Public release 1.1.2** (tag `v1.1.2`, 2026-10-07) is live
on GitHub and the OTA hub. **OTA dev build 1.1.2.2 (build 40)** is on the hub
(2026-10-08, https://goomba.tailc8f64e.ts.net/ota/vkquake/): 1.1.2.1 added issue
#5 (console by touch: console button in every menu, `~` on the keyboard,
3-finger tap in-game, console-aware keyboard shift; Settings → Game Data 2021 /
Classic, applies next launch). 1.1.2.2 made the menu chrome one column with
matching 20 pt glyphs (back, gear, console, quick save, quick load) and indents
the console away from the notch / Dynamic Island, side chosen from
`windowScene.interfaceOrientation` (landscape safe-area insets are symmetric on
iOS, so `safeAreaInsets.left` cannot tell the side). Both rounds sim-verified on
lane 2 and Sonnet-reviewed with no blockers; merged to local `main`, NOT yet
pushed (the session's push was blocked by the auto-mode classifier). Awaiting
Austin's device check. Local `main` once carried 19 unpushed VR-doc commits;
they live on local branch `vr-notes-private`.

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
1. Orchestrator: review `issue-5b` (light Sonnet pass), merge to `main`, then
   decide whether it rides the next OTA dev build (1.1.2.2) — needs the usual
   sim-verified publish gate (this round's run counts if nothing changes).
2. Push `main` (`git push origin main`) — earlier push was blocked by the
   auto-mode classifier.
3. Austin: on device, check the console column, the quick pills, and the console
   indent in BOTH landscape sides (real rotation; the sim used a scene geometry
   request).
4. Pre-existing, seen in this round's shots: the keyboard-dismiss button sits on
   top of the console's version string at the right end of the input row. Cosmetic.
5. Known rare edge cases from the issue #5 review: `~` typed into a menu text
   field opens the console; opening the console with the keyboard already up keeps
   the previous shift.
6. Add a shutdown trap to `scripts/sim-verify.sh` (it leaves the device booted).
7. When upstream SDL moves off `statusBarOrientation`, drop SDL patch 0003.

## Open questions
- Should the VR docs on local branch `vr-notes-private` (VR charter, R0–R6 notes,
  porting guide; Austin's first name ~97 times) be scrubbed and pushed to the
  public repo? Default if unanswered: keep them local, never push.
- When Austin wants a public release of the issue #5 work, he picks the number
  (1.1.3 presumably). Default: stay on 1.1.2.x dev builds.

## Live claims
None. iPhone Air (lane 2) shut down; no agents running; local `main` is ahead
of `origin/main` until pushed; tree clean apart from the untracked `.claude/`
and `docs/IOS-AUDIO-SESSION-GUIDE.md`.
