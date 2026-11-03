# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-02) — issue #6: hardware mouse + keyboard → release 1.2.1
- Cause: SDL3's iOS GCMouse backend needs `UIApplicationSupportsIndirectInputEvents`
  in Info.plist (we had none), and overlay 0004 forced `no_mouse` on iOS. Fix: plist
  key; new overlay 0032 (desktop mouse path on iOS, pointer lock in game, free pointer
  + `M_MouseHover` in menus, macOS warp compiled out); shell: mouse+hw keyboard hides
  the touch overlay, mouse disables gyro, indirect-pointer touches filtered out of
  the overlay, hw-keyboard Enter/Backspace/backquote de-duplicated in VKQKeyInput.
- `build/` had been purged: oracle, ios-deps, visionos-deps, sim deps all rebuilt.
  All builds green. Sim round lane 2 (iPhone Air 45A5059C…, iOS 27.0): sim-verify
  ios + issue5b console round PASS (artifacts/sim/2026-11-02-ios-*.png, issue5b/).
  The simulator cannot present a GCMouse, so the mouse path itself is unverified on
  hardware; the reporter (robimart) is the first real test — replied on the issue.
- Published OTA (notes on hub), GitHub release v1.2.1 with both IPAs (version
  asserted from the served IPA plists), dispatch chain kicked by the release.

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. Issue #6 follow-up: wait for robimart's hardware report (mouse sensitivity, pointer
   lock, bindings); external-display rotation is a separate open item (asked for a
   new issue). Issue #4/#5 replies; `~` in menu text fields; add a shutdown trap to
   `scripts/sim-verify.sh`; drop SDL patch 0003 when upstream SDL moves off
   statusBarOrientation; consider a different bridge port than quake3e's 27999.

## Open questions
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. No simulators booted by this session; no agents running; `main` = `origin/main`.
