# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-03 pm) — #6 double-click, #7 external display, #8 multiplayer; 1.2.1.1 test build
- Branch `issue-6-7-followup` (pushed, NOT merged, now 1.2.1.1 / build 44) carries:
  - #6 double-click: SDL3 on iOS synthesizes a finger tap from every mouse click
    (SDL_HINT_MOUSE_TOUCH_EVENTS defaults on); in_sdl3.c now ignores finger events
    with SDL_MOUSE_TOUCHID / SDL_PEN_TOUCHID, hint set 0 as backstop (patch 0032).
    `vkq_fakemouseclick <x> <y> [touchid]` replays a click; VERIFIED on the iPhone Air
    sim: default id = one activation, id 7 = the old double activation
    (artifacts/sim/2026-11-03-ios-issue8-click-{default,tid7}.png, local only).
    Side effect: Apple Pencil taps in menus now act like a mouse (no drag-scroll).
  - #7: orientation hook kept; SDL patch 0003 now derives orientation from scene
    bounds when the scene is not on the main screen; `vkq_mouse` prints every
    screen/scene (orientation, bounds, transform, drawable). UNVERIFIED: Simulator.app
    is not installed on this Mac and the headless external screen captures black.
  - #8 (patch 0033, verified on the macOS oracle against live servers, and the sim
    joined q1.pieter.com:27500 with players for 25 s): FTE late .bsp precache → re-run
    R_NewMap + R_RebuildAllEfrags at signon (upstream bug, crash); CCREP_REJECT on
    the connected socket now ends the game with the reason (+SCR_EndLoadingPlaque,
    else LOADING freezes 60 s); scoreboard updates before serverinfo discarded;
    float svc_time precision loss after ~24 days uptime smoothed by
    CL_ServerTimeFromWire (4 → 39 time steps/s); browser marks needpass/DarkPlaces
    rows with `*`; clearer missing-mod-content message. Sonnet review: no findings.
- 1.2.1.1 OTA published (hub /ota/vkquake/, both platforms) with the gitignored
  publish-ota.sh's new `OTA_PUBLIC_GATE=1` (dev-numbered build WITHOUT the Remote
  Console, since the bridge binds INADDR_ANY and the IPA goes to a stranger).
  Served IPA checked: 1.2.1.1/44, no remoteConsole string.
- Replies posted on #6 and #7. #8 reply drafted at build/reply-8-1.2.1.1.md; the IPA
  copy for the issue is build/ota/vkQuake-1.2.1.1-iOS.ipa — gh cannot attach files
  to issues, so Austin must drag it into the comment (see Open questions).
- Sim trap today: `simctl terminate` of a NOT-running app hung CoreSimulator for the
  session (install/launch then hang too); a `simctl shutdown` + `boot` of the device
  cleared it. sim-verify.sh starts with that terminate — guard it with a timeout.
- Follow-up candidate from review: the 0026 "map you do not have" exit path also
  ends the game without SCR_EndLoadingPlaque (same 60 s freeze, untested).

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. Wait for robimart's test of 1.2.1.1 (#6/#7/#8). If #7 is still rotated, read their
   `vkq_mouse` paste: a window transform ⇒ UIKit rotation (hook not taking);
   swapped bounds ⇒ SDL view frame (patch 0003 branch). If #8 still misbehaves,
   ask for server name + console. Fix 0026's missing-map exit (SCR_EndLoadingPlaque).
3b. Release: when Austin OKs, set both plists to 1.2.2 (build 45) on `issue-6-7-followup`,
   merge, release (RELEASING.md loop), ask robimart for `vkq_mouse` output and the
   external-display result. If the orientation hook does not fix #7, next candidates:
   log the scene's interfaceOrientation/screen on `windowScene:didUpdateEffectiveGeometry:`
   and SDL's UIKit_ComputeViewFrame on the external screen.
4. Investigate the iPad-sim square frame (see Last round): compare vid.width/height
   and the CAMetalLayer drawableSize on the iPad Air 13" sim vs the iPhone Air. Issue #4/#5 replies; `~` in menu text fields; add a shutdown trap to
   `scripts/sim-verify.sh`; drop SDL patch 0003 when upstream SDL moves off
   statusBarOrientation; consider a different bridge port than quake3e's 27999.

## Open questions
- Austin: drag build/ota/vkQuake-1.2.1.1-iOS.ipa into a comment on issue #8 using the
  text in build/reply-8-1.2.1.1.md (gh has no issue-attachment API). Default if not
  done: the reporter has no build to test and the round stalls.
- Release `issue-6-7-followup` as 1.2.2 after the reporter confirms? Default: wait
  (release numbers are Austin's call).
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. Simulators shut down (iPhone Air lane 2, iPad Air 13" M4); no agents running;
tree clean; `issue-6-7-followup` pushed (1.2.1.1); `main` = `origin/main` = v1.2.1.
