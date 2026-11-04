# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-04 afternoon) — 1.2.1.6 test build (branch `dp7`): #7 round 5 render scale
- Reporter on 1.2.1.5: first-click fix CONFIRMED. In-game pointer-lock paste:
  `prefersPointerLocked=1 pointerlock=unlocked` → scene eligible, iPadOS declines the lock
  on the external display. System policy; only the split-scene idea remains (3c).
- Monitor is really 4K UHD @ 120 Hz; iPadOS presents it as a 6016x3384 canvas at 120 Hz
  (`frames: screen max=120`). The 1.2.1.4 60 Hz pacing theory was WRONG (kept: correct
  binding). Real suspect: 20 Mpixel full-canvas passes/present/system downscale, which
  r_scale never touches.
- 1.2.1.6 (9fb89f4 + 85163ff): Display > "External Display Render Scale" (Native/75%/50%)
  lowers the Metal layer's contentsScale while external; patch 0039 makes the engine use
  bounds x contentsScale (= MoltenVK currentExtent) and rebuild the swapchain; vkq_mouse
  `drawable:` line. Sim: scripts/sim-verify-extscale.sh PASS (50% → 1024x1366 drawable on
  the 2048x2732 panel, full-screen; Native → full). vr-syntax-check OK.
- First 1.2.1.6 archive FAILED to link (_VKQ_iOS_DrawableSizeChanged): build-sim.sh does
  not rebuild build/ios/libvkquake.a — ran build-ios.sh, republished. Served IPA verified:
  1.2.1.6/49, setting + hook strings present, no remoteConsole. visionOS engine lib not
  rebuilt (shell stubs only; harmless). Copy: build/ota/vkQuake-1.2.1.6-iOS.ipa; replies:
  build/reply-7-1.2.1.6.md, build/reply-6-1.2.1.6.md. DECISIONS.md entry added.

## Previous round (2026-11-04 morning) — 1.2.1.5 test build (branch `dp7`): #7 round 4 + #6 menu flicker
- Reporter (robimart) on 1.2.1.3: **#8 confirmed working** on every server tried incl.
  hipnotic ("all seems to work well"). **#7 renders full-screen and upright on the
  monitor**; two leftovers: (a) still no pointer lock, (b) fps fell from a locked 120 to
  60-80 and does not improve at 320x200 / no MSAA.
- (b) diagnosed + fixed (b57d88f): the monitor is a 6K panel (6016x3384 ⇒ 60 Hz). The
  shell built its CADisplayLink with the class method, paced by the iPad's 120 Hz, while
  presents blocked on the 60 Hz monitor ⇒ pacing-bound 60-80. Now
  `[window.screen displayLinkWithTarget:]`, rebind on scene-screen change / screen mode
  change / connect / disconnect, and `vkq_mouse` prints a `frames:` line (bound screen
  max, preferred range, boundToWindowScreen). Sim: issue7 emulation PASS on the iPad
  Air 13" (M4) sim (D804DBF5), `boundToWindowScreen=1`, screenshots upright
  (artifacts/sim/2026-11-04-issue7r3-*; artifacts/ is gitignored).
- (a) pointer lock: the paste was from the console (relative=0, prefers=0) so it shows
  nothing about in-game. Reply asks for `bind f9 vkq_mouse` + in-game presses +
  condump; `unlocked` ⇒ iPadOS refuses on the external display (policy, next idea is
  the split-scene approach), `unavailable` ⇒ scene not eligible.
- #6 follow-up (reporter, 2026-11-04): first mouse click during the attract demo opened
  the menu and closed it again; click-hold-move kept it. Cause: the transparent
  attract-demo tap catcher's UITapGestureRecognizer also recognises indirect-pointer
  touches — the click opened the menu via SDL/GCMouse, then completed as a tap →
  Escape. Fix (2831ec5): allowedTouchTypes = direct + pencil. Not sim-testable (no
  mouse on the sim); sim issue7 run re-passed on the build.
- 1.2.1.4/47 then 1.2.1.5/48 OTA PUBLISHED (OTA_PUBLIC_GATE=1); 1.2.1.5 supersedes.
  Served IPA verified: 1.2.1.5/48, boundToWindowScreen present, no remoteConsole;
  copy at build/ota/vkQuake-1.2.1.5-iOS.ipa; reply drafts build/reply-7-1.2.1.5.md
  (carries the build + pointer-lock ask + #6 note) and build/reply-6-1.2.1.5.md.

## Previous round (2026-11-03 night) — 1.2.1.3 test build (branch `dp7`, RC line)
- `dp7` now carries, on top of 1.2.1.2: #7 round 3 (landscape-native predicate, SDL 0003
  + ios_touch.m; version line in `vkq_mouse`/`version`, patch 0037); DP7 Phase 0
  (0035, browser DP tag) and Phase A (0036, cl_dp7.c, + bounds fixes); #8 round 3
  (0038: plaque lowered on every content exit, 20 s signon watchdog, game-dir revert
  via `CL_ContentDownload_PreConnect` at the top of Host_Connect_f, early switch when
  the server's gamedir is installed, maps install into id1, abandoned plans cancelled,
  `fullserverinfo` executed, no LAN broadcast for explicit hosts). moddl harness
  94/94 PASS incl. live hipnotic switch + pieter switch-back; timedemo 969.
- 1.2.1.3 / build 46 OTA PUBLISHED (OTA_PUBLIC_GATE=1; first attempt refused: notes >
  420 chars — the hub kept serving 1.2.1.2, caught by the served-IPA check). Served IPA
  verified: 1.2.1.3/46, no remoteConsole, cl_dp7status/landscape-native/watchdog strings
  present, 7 mod entries. Copy for the issue: build/ota/vkQuake-1.2.1.3-iOS.ipa; reply:
  build/reply-8-1.2.1.3.md.
- Orchestrator lesson: `git commit -a` on STATUS.md swept an agent's files (e94e525);
  commit STATUS.md by path only while agents own the tree.

## Next steps
1. Perf on device: SSAO now defaults on for GPUs with subgroup ops, and fresh installs
   get vid_fsaa 4x. Measure timedemo on the iPhone Air; if it misses 60 fps, default
   r_ssao 0 / vid_fsaa 0 on iOS.
2. Device checks the sim can't do: real controller gyro/rumble, headset VR (rebuilt
   present path, depth copy), surface-loss recovery on backgrounding.
3. **#7 round 3 DONE on `dp7`** (fix files landed in e94e525 by accident of a `commit -a`
   on STATUS.md, plus 69d1cf1 = patch 0037 version line; nothing lost). Predicate =
   landscape-native panel OR not-main-screen OR hint, in SDL 0003
   (`UIKit_IsExternalDisplayScene`, + SetupWindowData no longer swaps w/h for external)
   and ios_touch.m `vkq_external_reason()`. `vkq_mouse` prints the app version first
   and `external=1 reason=landscape-native WxH`. Sim-proven for the hint and the
   un-hinted paths; the reporter's real case is the hardware test. Original finding: reporter's
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
   "fullserverinfo"`, `UDP_Write, sendto: No route to host` bursts. Diagnosis DONE
   (scratchpad mp8c/REPORT.md + proposed.diff): (c) not reproduced on the oracle
   (direct -game hipnotic join completes; moddl is iOS-only) BUT the loading plaque is
   never lowered on the "Fetching…" Host_EndGame exits (cl_parse.c ~1264/~1312 and
   0026's) → blank screen up to 60 s hides the console; fix SCR_EndLoadingPlaque
   there + a 20 s signon watchdog; (a) only moddl issues `game`, nothing switches back;
   policy: `CL_ContentDownload_PreConnect` at the top of Host_Connect_f switches back
   when connecting elsewhere; maps install into id1 unless the server gamedir == ours;
   (b) moddl/mapdl state returns to idle only on reconnect or menu Cancel → PreConnect
   cancels both plans for a different target, Begin cancels an unattended prompt;
   (d) FTE sends `fullserverinfo "<info>"` without `//` → run via
   Cmd_ExecuteString(src_server) in the 0034 stufftext filter (not the cbuf: `;` in
   the info), fix the 8192-byte memcpy into a 1024 slot in cl_main.c:1348; (e) the
   "No route to host" bursts = NET_Connect's LAN broadcast search (255.255.255.255 +
   ff03::1) without Local Network permission; it also busy-waits ~1.5-2 s per
   connect → skip the LAN search for explicit IPs/DNS names. Fix round next on `dp7`. (#7 external display, #8 servers incl. TF and
   pieter). If #7 is still rotated, read the `vkq_mouse` paste (expect external scene
   orient=portrait, bounds 3008x1692, drawable 6016x3384, supported=0x2).
3a. DarkPlaces support — APPROVED by Austin. Plan: docs/DP7-PLAN.md on branch
   `dp7-plan` (d59edfc). Survey 2026-11-03: 26 DP servers listed, 13 answer, 0 players
   on any; 4 run protocol 15 and are joinable TODAY but our `*` rule stars them
   (DP never sends `nqprotocol`); 7 are DP7 Quake servers (no CSQC); 2 are Xonotic
   (CSQC, never joinable). Phase 0 DONE (a66b149, patch 0035 on the RC): DP rows tagged "DP ", stars only for needpass/Xonotic; 4 protocol-15 DP servers joinable; oracle joined 47.190.124.72:26001.
   Phase A DONE on `dp7` (35aa39c, b28f016; patch 0036, cl_dp7.c ~700 lines; gates: timedemo 969/985/1090 identical, 36 non-DP7 move packets byte-identical, moddl harness PASS, sim joined a local DP server + live Coopera/PART1CL3; Zeus needs mod content; Phase B = DP temp entities/effects/attachments/DP7 demos). Sonnet review: no non-DP7 regressions; bounds fixes DONE (e8c1b45, patch 0036; negative test with injected bad indices via a UDP relay passed). Were: (i) cl_dp7.c CLDP7_ParseSound — reject sound_num < 0 / msg_badread (MSG_ReadByte returns -1 past end → cl.sound_precache[-1]); (ii) cl_parse.c CL_ParseStatic via CL_ParseBaseline v7 (spawnstatic2): modelindex is a short → check < MAX_MODELS before cl.model_precache[]; CL_ParseStaticSound v2: sound_num short → check < MAX_SOUNDS (both upstream/666 paths too — guard without changing valid behaviour). Design was: new cl_dp7.c behind
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
- Austin: post build/reply-7-1.2.1.6.md on issue #7 with build/ota/vkQuake-1.2.1.6-iOS.ipa
  (verified) and build/reply-6-1.2.1.6.md on #6. Default if not done: reporter stays on
  1.2.1.5 (60-80 fps on the monitor). Next data needed: fps at 50%/75% + the `drawable:` line.
- #8 is confirmed fixed by the reporter on 1.2.1.3; close it at the 1.2.2 release.
- Release `dp7` as 1.2.2? #8 confirmed, #7 orientation confirmed, fps fix awaiting the
  reporter. Default: wait (release numbers are Austin's call). Release checklist: plists → 1.2.2 (build 50),
  merge dp7 → main, RELEASING.md loop, verify dispatch chain; mods/ reaching main makes
  the live mod-table URL work. Close #6 (confirmed fixed).
- DP7 Phase B (DP-only temp entities/effects, attachments, DP7 demos): default later.
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
None. No agents running; iPad Air 13" sim shut down; tree clean (untracked .claude/, docs/IOS-AUDIO-SESSION-GUIDE.md pre-existing). Branches pushed:
issue-6-7-followup, mod-download, issue-7-external-display, dp7-plan, dp7 (RC, 1.2.1.6).
`main` = `origin/main` = v1.2.1.
