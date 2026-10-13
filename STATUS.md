# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 28-patch overlay plus
3 SDL patches. **Public release 1.2.0** (tag `v1.2.0`, 2026-10-13) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and all SideStore sources
(quake-ports + all-ports, iOS + visionOS, verified). `origin/main` = release (branch
`release-1.2.0`). Next OTA dev builds are 1.2.0.1, 1.2.0.2, …
Local branch `vr-notes-private` holds the unpushed VR docs. DECISIONS.md is gitignored
(local-only); the 1.37.0 bump entry lives there.

## Last round (2026-10-12/13) — upstream 1.37.0 bump → release 1.2.0
- Pin → 1.37.0, 28 patches rebased via 3-way (12 conflicted). 0010/0018 rebuilt on
  upstream's new `r_passes.c` (`R_UIRenderPass`, `ui_framebuffer_override`; per-eye depth
  copy only when render res == output res). 0013 partly superseded (upstream's Load menu
  lists quicksave/autosaves; only `vkq_quicksave/quickload` remain). 0016 kept. VR:
  r_scale removed upstream → r_width/r_height -1; r_ssao forced off in VR.
- All 4 builds + syntax checks green. Sim round (after Austin restarted the Mac to fix a
  broken CoreSimulatorService): iOS sim-verify, issue5b, menu tour (Options/Controller/
  Video/Graphics/Load/console), visionOS sim-verify, 3D, vr-quick — all PASS
  (artifacts/sim/2026-10-13-*, menutour/). SSAO is auto-disabled on the sim (no subgroup
  ops), so SSAO is unverified on real hardware.
- Austin picked 1.2.0. Published OTA, GitHub release, dispatch chain verified (~30 s).
- Lane contention: the iPhone Air and Vision Pro were being booted by other sessions;
  quake3e harnesses also use console port 27999 on the Vision Pro.

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. Issue #4/#5 replies; `~` in menu text fields; add a shutdown trap to
   `scripts/sim-verify.sh`; drop SDL patch 0003 when upstream SDL moves off
   statusBarOrientation; consider a different bridge port than quake3e's 27999.

## Open questions
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. No simulators booted by this session; no agents running; `main` = `origin/main`.
