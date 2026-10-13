# STATUS — vkQuake iOS

## Current state
Engine (main) is on upstream vkQuake **1.36.0**; branch `upstream-1.37.0` carries the 1.37.0 bump, unverified on sim (`1b948e29`) with a 28-patch overlay
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

## Last round (2026-10-12) — upstream 1.37.0 bump, branch `upstream-1.37.0` (NOT merged/published)
- Pin → 1.37.0 (`749b4fd4`), 28 patches rebased via 3-way (12 conflicted). 0010/0018
  rebuilt on upstream's new `r_passes.c` (`R_UIRenderPass`, `ui_framebuffer_override`;
  per-eye depth copy only when render res == output res). 0013 partly superseded:
  upstream's Load menu now lists quicksave/autosaves; only `vkq_quicksave/quickload`
  remain. 0016 kept. VR: r_scale removed upstream → r_width/r_height -1; r_ssao forced
  off in VR. Commits 7a62929, 86e8116, 40a32d0. DECISIONS.md entry written (file is
  gitignored, local only).
- Green: sync-overlay, ios/vr syntax checks, oracle ninja (fresh meson setup needed),
  build-ios, build-visionos, build-sim ios/visionos.
- **NOT sim-verified**: CoreSimulatorService crashes on every boot since ~17:51
  (iOS/visionOS 27.0 runtime "manifest is out of date", "Scrivener signing failed");
  `simctl list` hangs. Machine-wide — other sessions stuck too.
Previous round (2026-10-08): issue #5 follow-ups → released as 1.1.3.

## Next steps
1. Once simulators boot again: `VKQ_SIM_UDID=45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22
   scripts/sim-verify.sh ios`, `scripts/sim-verify-issue5b.sh`, then
   `VKQ_SIM_UDID=9D4499E9-CCED-4AF1-9303-925E9515D346 scripts/sim-verify.sh visionos`;
   eyeball Options → Controller, Video/Graphics, Load menu quicksave/autosave rows
   under the touch chrome; landscape full-screen (not a portrait column).
2. Measure perf on device: SSAO now on by default for everyone, fresh installs get
   vid_fsaa 4x. Fallback: iOS defaults r_ssao 0 / vid_fsaa 0.
3. Merge to main, set version (Austin's number), publish OTA, GitHub release, verify
   SideStore dispatch chain.
4. Older items: issue #4/#5 replies; `~` in menu text fields; sim-verify.sh shutdown trap;
   drop SDL patch 0003 when upstream SDL moves off statusBarOrientation.

## Open questions
- Release number for the 1.37.0 fold-in: it brings user-visible features (autosaves,
  controller menu + controller gyro/flick/rumble, device-language text, render
  resolution, SSAO). Default if unanswered: 1.2.0 suggested, but no release until Austin picks.
- Simulator service is broken machine-wide; needs a Mac restart or runtime refresh.
  Default: wait, do not restart it while other sessions are mid-run.
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
Branch `upstream-1.37.0` committed (not pushed). vendor/vkQuake checked out at 1.37.0
(main's pin is still 1.36.0 — re-checkout vendor at the pin if building main). No
simulators booted by this session; no agents running.
