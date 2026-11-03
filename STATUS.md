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
3. **#7 round 3 (NEXT, right after Phase A frees the tree; RC branch):** reporter's
   1.2.1.2 dump shows the external panel reported AS `UIScreen.mainScreen` with
   `screens=1` (the iPad's own panel is not listed while the game is on the monitor),
   so `UIKit_IsExternalDisplayScene()` / the shell hook (both keyed on
   "screen != mainScreen") never fire: supported=0x18, scene landscape-right, bounds
   1692x3008, drawable 3384x6016 ⇒ still rotated. New signal: the panel is
   LANDSCAPE-NATIVE (`nativeBounds` 6016x3384) while every iPad panel is
   portrait-native (2064x2752 etc.) ⇒ key both checks on
   `screen.nativeBounds.size.width > height` (plus the emulation hint). Expected after
   fix: orient=portrait, bounds 3008x1692, drawable 6016x3384, supported=0x2. Also
   reporter asks: print CFBundleShortVersionString/CFBundleVersion in `vkq_mouse`
   (iOS Settings shows no version). Then 1.2.1.3 test build (OTA_PUBLIC_GATE=1).
   Pointer lock on the external display is still not granted (Apple policy).
3'. **#8 round 3 (reporter condump on 1.2.1.2):** CTF download worked, `*` rows refuse
   cleanly. BUGS: (a) game dir sticks after moddl's `game hipnotic` → every later
   join "gamedir mismatch", a map was installed into hipnotic/maps; (b) stale
   "moddl: a download is already in progress" after an abandoned TF plan blocked
   AirQuake/Copper downloads; (c) hipnotic server 192.99.32.215:27501 stalled on the
   loading screen after the switch+rejoin (no error); (d) noise: `Unknown command
   "fullserverinfo"`, `UDP_Write, sendto: No route to host` bursts. Read-only Opus
   diagnosis in flight on the oracle; fix round follows on `dp7` once the tree is free
   (after #7 round 3 + the DP7 bounds fixes), then 1.2.1.3. (#7 external display, #8 servers incl. TF and
   pieter). If #7 is still rotated, read the `vkq_mouse` paste (expect external scene
   orient=portrait, bounds 3008x1692, drawable 6016x3384, supported=0x2).
3a. DarkPlaces support — APPROVED by Austin. Plan: docs/DP7-PLAN.md on branch
   `dp7-plan` (d59edfc). Survey 2026-11-03: 26 DP servers listed, 13 answer, 0 players
   on any; 4 run protocol 15 and are joinable TODAY but our `*` rule stars them
   (DP never sends `nqprotocol`); 7 are DP7 Quake servers (no CSQC); 2 are Xonotic
   (CSQC, never joinable). Phase 0 DONE (a66b149, patch 0035 on the RC): DP rows tagged "DP ", stars only for needpass/Xonotic; 4 protocol-15 DP servers joinable; oracle joined 47.190.124.72:26001.
   Phase A DONE on `dp7` (35aa39c, b28f016; patch 0036, cl_dp7.c ~700 lines; gates: timedemo 969/985/1090 identical, 36 non-DP7 move packets byte-identical, moddl harness PASS, sim joined a local DP server + live Coopera/PART1CL3; Zeus needs mod content; Phase B = DP temp entities/effects/attachments/DP7 demos). Sonnet review: no non-DP7 regressions; TWO bounds fixes to apply before 1.2.1.3 (patch 0036): (i) cl_dp7.c CLDP7_ParseSound — reject sound_num < 0 / msg_badread (MSG_ReadByte returns -1 past end → cl.sound_precache[-1]); (ii) cl_parse.c CL_ParseStatic via CL_ParseBaseline v7 (spawnstatic2): modelindex is a short → check < MAX_MODELS before cl.model_precache[]; CL_ParseStaticSound v2: sound_num short → check < MAX_SOUNDS (both upstream/666 paths too — guard without changing valid behaviour). Design was: new cl_dp7.c behind
   cl.protocol==PROTOCOL_DP7 — entity-delta reader, DP7 clientdata, opcodes 55/56/59,
   56-byte clc_move + frame acks; ~450 lines, 2 rounds; regression gate = identical
   timedemo counts + byte-identical move packet for non-DP7. A 230-line Python
   prototype in the plan's Appendix A already joined/walked/fired on 4 live DP7
   servers; a local DP dedicated server builds in 3 s for deterministic tests.
   Phase B (effects, DP7 demos) later; Phase C (CSQC) no-go.
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
- (done) Austin attached the 1.2.1.2 IPA on #8; awaiting the reporter's results.
- Release `issue-7-external-display` as 1.2.2 after the reporter confirms? Default: wait
  (release numbers are Austin's call). Close #6 (confirmed fixed; classifier blocks me).
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
`dp7` is now the RC line (issue-7-external-display + Phase 0 + Phase A + STATUS commits).
Opus agent in flight: #7 round 3 (landscape-native predicate + version in vkq_mouse) on
`dp7`; owns the tree, iPhone Air (lane 2) and iPad Air 13" sims. Sonnet review of
Phase A in flight (read-only). Then: 1.2.1.3 test build (OTA_PUBLIC_GATE=1).
`main` = `origin/main` = v1.2.1.
