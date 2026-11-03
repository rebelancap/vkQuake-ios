# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-03 late) — 1.2.1.2 test build staged (branch `issue-7-external-display`)
- Branch `issue-7-external-display` (from mod-download; pushed, NOT merged; plists
  1.2.1.2 / build 45) = issue-6-7-followup + mod-download + #7 fix + review fixes +
  TF coverage/retry guard + DarkPlaces-protocol graceful refusal. It is the release
  candidate for 1.2.2 once the reporter confirms.
- #7: root cause = both orientation sources said landscape-only, so UIKit rotated
  the external scene 90° (external scenes count orientation from the panel's NATIVE
  orientation). 1.2.1.1's hook never ran: SDL's app delegate on iOS 13+ is
  `SDLUIKitSceneShim`. Fix in SDL patch 0003 (`UIKit_IsExternalDisplayScene`,
  Portrait = native off the main screen) + shell hook on the shim. Proven only under
  emulation (`VKQ_EMULATE_EXTERNAL_DISPLAY=1`, scripts/sim-verify-issue7.sh); the sim
  cannot extend a display. Reporter has no rotation setting; monitor is horizontal.
- mod-download (patch 0034, cl_moddl.c): review fixes (no install into id1 when the
  server names no gamedir; unpacked-size cap = maxpkg×4); retry guard keyed per
  server + missing-file set; package type "file"; entries combine per gamedir; table
  now 7 entries (FortressOne pak + tpad/qpi/ammopack.mdl from FortressOne/map-repo
  @5b31e00, Threewave CTF, AirQuake, Copper), all verified by
  scripts/mod-sources-verify.py. Live harness 66/66 PASS incl. TF on 2nuke2, a
  map-change rejoin, and a DarkPlaces refusal.
- #8 reporter hit "Server returned version 3504" on 5-6 servers = DarkPlaces protocol
  7, which vkQuake cannot speak (pre-existing). Now `CL_RefuseServerProtocol`:
  message + return to join menu, no stack wall; `cl_serverextension_download`
  stufftext dropped. The browser's `*` marking works for DP servers that answer getinfo.
- 1.2.1.2 OTA published (OTA_PUBLIC_GATE=1, no Remote Console); served IPA checked:
  1.2.1.2/45, remoteConsole absent, DP message present, bundled mod-sources.json ==
  repo. Copy for the issue: build/ota/vkQuake-1.2.1.2-iOS.ipa; reply text:
  build/reply-8-1.2.1.2.md. Austin uploads (gh cannot attach files to issues).
- Note from the harness: sim-verify.sh's log ends with "Unknown command GET/Host:…" —
  something on the Mac sends an HTTP request to the console bridge port 27999
  (harmless, untraced).

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. Wait for robimart's test of 1.2.1.2 (#7 external display, #8 servers incl. TF and
   pieter). If #7 is still rotated, read the `vkq_mouse` paste (expect external scene
   orient=portrait, bounds 3008x1692, drawable 6016x3384, supported=0x2).
3a. DECISION FOR AUSTIN: DarkPlaces protocol 7 client support (13 of 28 listed DP
   servers answer; the reporter's first picks were all DP). Large engine feature;
   default: not planned, DP servers stay marked `*` and refuse cleanly.
3c. Later candidates: NetQuake.io in-protocol download (`cl_serverextension_download`);
   #7 split-scene idea (input scene on iPad + render scene on external display, how
   Jump Desktop does it) if pointer lock on external displays matters; 0026's
   missing-map exit still lacks SCR_EndLoadingPlaque (60 s freeze, untested).
3b. Release: when Austin OKs, set both plists to 1.2.2 (build 46) on `issue-7-external-display`,
   merge, release (RELEASING.md loop), ask robimart for `vkq_mouse` output and the
   external-display result. If the orientation hook does not fix #7, next candidates:
   log the scene's interfaceOrientation/screen on `windowScene:didUpdateEffectiveGeometry:`
   and SDL's UIKit_ComputeViewFrame on the external screen.
4. Investigate the iPad-sim square frame (see Last round): compare vid.width/height
   and the CAMetalLayer drawableSize on the iPad Air 13" sim vs the iPhone Air. Issue #4/#5 replies; `~` in menu text fields; add a shutdown trap to
   `scripts/sim-verify.sh`; drop SDL patch 0003 when upstream SDL moves off
   statusBarOrientation; consider a different bridge port than quake3e's 27999.

## Open questions
- Austin: upload build/ota/vkQuake-1.2.1.2-iOS.ipa to issue #8 with build/reply-8-1.2.1.2.md
  (gh has no attachment API). Default if not done: the reporter stays on 1.2.1.1.
- Release `issue-7-external-display` as 1.2.2 after the reporter confirms? Default: wait
  (release numbers are Austin's call). Close #6 (confirmed fixed; classifier blocks me).
- DarkPlaces protocol 7 support? Default: no (see Next step 3a).
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. Simulators shut down; no agents running; tree clean. Branches pushed:
issue-6-7-followup (1.2.1.1), mod-download, issue-7-external-display (1.2.1.2, RC).
`main` = `origin/main` = v1.2.1.
