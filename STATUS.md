# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-03) — issue #6 follow-up + issue #7, branch `issue-6-7-followup` (pushed, NOT merged)
- robimart on 1.2.1: bindings + touch-hiding work, but the pointer stays visible and
  motion stops at the screen edge (= iPadOS did not grant pointer lock); aim feels
  accelerated. New issue #7: on an external 4K display the game is drawn rotated 90°.
- Pointer lock is granted only to a FULL-SCREEN foregroundActive scene (Apple doc);
  an external display forces Stage Manager / windowing, so their scene was not
  eligible. Proven on the iPad Air 13" (M4) sim, iOS 27.0: `vkq_mouse` shows
  pointerlock=LOCKED in game, unlocked with the console open — our plumbing works.
- Branch adds: `vkq_mouse` console diagnostic (engine + UIKit state), lock-state
  logging, re-request of the lock on scene activation / while missing in game, a
  one-time console notice telling the player iPadOS needs full screen; and for #7 an
  `application:supportedInterfaceOrientationsForWindow:` on SDL's delegate (any
  orientation when the scene is not on the main screen). All builds green (visionOS
  needed a stub). sim-verify ios (iPhone Air) PASS; iPad sim e1m1 + console OK.
- NOT verified: the external-display fix (sim's external display not drivable from
  this session) and the lock on the reporter's hardware. Replied on #6 and #7 with
  the diagnosis and questions.
- Oddity, pre-existing (A/B with the hook disabled is identical): on the iPad Air 13"
  sim the engine draws an almost square ~2048x2036 px frame at the top of a portrait
  buffer while UIKit reports a 1366x1024 pt landscape window and SDL metal view
  (artifacts/sim/2026-11-03-ipad-*.png). Unknown whether a sim artifact; the reporter
  has not complained about the iPad's own screen.

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. Issue #6/#7: when Austin OKs a release, bump to 1.2.2 on `issue-6-7-followup`,
   merge, release (RELEASING.md loop), ask robimart for `vkq_mouse` output and the
   external-display result. If the orientation hook does not fix #7, next candidates:
   log the scene's interfaceOrientation/screen on `windowScene:didUpdateEffectiveGeometry:`
   and SDL's UIKit_ComputeViewFrame on the external screen.
4. Investigate the iPad-sim square frame (see Last round): compare vid.width/height
   and the CAMetalLayer drawableSize on the iPad Air 13" sim vs the iPhone Air. Issue #4/#5 replies; `~` in menu text fields; add a shutdown trap to
   `scripts/sim-verify.sh`; drop SDL patch 0003 when upstream SDL moves off
   statusBarOrientation; consider a different bridge port than quake3e's 27999.

## Open questions
- Release the `issue-6-7-followup` branch as 1.2.2? Default if unanswered: wait (release
  numbers are Austin's call); the reporter cannot reach the OTA hub.
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. Simulators shut down (iPhone Air lane 2, iPad Air 13" M4); no agents running;
`main` = `origin/main` = v1.2.1; `issue-6-7-followup` pushed, one commit ahead.
