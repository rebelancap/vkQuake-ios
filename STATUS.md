# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.37.0** (`749b4fd4`) with a 29-patch overlay plus
3 SDL patches. **Public release 1.2.1** (tag `v1.2.1`, 2026-11-02) is live on GitHub,
the OTA hub (https://goomba.tailc8f64e.ts.net/ota/vkquake/) and the SideStore sources
(quake-ports + all-ports; chain verified, see Last round). `origin/main` = release.
Next OTA dev builds are 1.2.1.1, 1.2.1.2, … Local branch `vr-notes-private` holds the
unpushed VR docs. DECISIONS.md is gitignored (local-only); the issue #6 entry lives there.

## Last round (2026-11-03 evening) — mod-content download (branch `mod-download`), reporter feedback, #7 data
- Reporter: #6 CONFIRMED fixed on 1.2.1.1 (close it); #8 testing servers now; #7 sent a
  `vkq_mouse` dump: external scene says landscape-right but UIScreen/window bounds are
  PORTRAIT-shaped 1692x3008 pt (native 6016x3384), identity transform, SDL view
  3008x1692 with a 6016x3384 drawable inside the portrait window ⇒ rotated. Hook +
  bounds patch did nothing. Asked about the iPad Settings → Displays rotation setting.
- `mod-download` (from issue-6-7-followup, pushed, NOT merged): patch 0034 + cl_moddl.c
  state machine; sources = server `sv_dlURL` (read via getstatus; NO live server sets
  it) then curated `mods/mod-sources.json` (bundled, overridable from raw.github main;
  entries: FortressOne pak for fortress, Threewave CTF 3.01, AirQuake 1.02, Copper 1.30,
  all sha256-pinned and downloaded/listed by scripts/mod-sources-verify.py). One cvar
  `cl_mapdownload` (Settings row renamed "Download Missing Content"). Harness
  scripts/sim-verify-moddl.sh 43/43 PASS on iPhone Air; LIVE join of NetQuake.io TF
  (52.14.57.255:26023) downloaded + rejoined into game (artifacts/sim/2026-11-03-moddl-*).
  Also registers `sv_public` (upstream never did) and adds serverinfo to getstatus.
  Sonnet review: no bugs; two gaps TO FIX (Next step 3d).
- NetQuake.io (QSS-M) servers advertise `cl_serverextension_download 1` (in-protocol
  file push); supporting it would cover them without the table — candidate later.
- Sim note: on the iOS 27 sim the first join to a LOCAL server after launch can stall
  (pre-existing); harness does a warm-up join.

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
3a. Mod content download (Austin approved 2026-11-03, options 1+2): reuse the 0028
   per-file downloader/consent/rejoin for missing precache MODELS/SOUNDS: (1) a small
   curated table mapping common public-server mods (fortress, crmod, xmen, airquake,
   ctf, lq1…) to a package URL + files to install; (2) honor a DarkPlaces/FTE-style
   `sv_downloadurl`-type server info key and fetch each missing precache file from it.
   Separate round after the reporter confirms 1.2.1.1; candidate 1.2.3 / 1.3.0.
3c. #7 idea from the reporter: split scenes — full-screen input scene on the iPad
   holding the pointer lock, separate non-interactive external-display scene for the
   render (Jump Desktop does this). Parked until the orientation fix is judged.
3d. DONE (3a8c059 on issue-7-external-display): review fixes landed, harness legs (h)/(i) added, 52/53 PASS — (g) live TF failed because the server moved to blitzkrieg2 (tpad.mdl not in the FortressOne entry) and the once-per-session retry guard blocked a second attempt. Original brief was:
   (i) cl_moddl.c ~:740 `mod_begin_server`: if the server sent no usable gamedir
   (`servergd` empty) fall through to `mod_begin_table()` instead of installing
   server files into com_gamedir/id1; (ii) cap the summed uncompressed size of the zip
   (cl_moddl.c ~:930 / COM_UnzipToDir, common.c ~:4404) against cl_mapdownload_maxpkg
   × a small factor before extracting. Regenerate 0034, rebuild, re-run
   sim-verify-moddl.sh. Then 1.2.1.2 test build (OTA_PUBLIC_GATE=1) for the reporter.
3e. #7 DONE on branch `issue-7-external-display` (61aa1da, from mod-download):
   root cause = both orientation sources answered landscape-only so UIKit rotated the
   external scene 90° (external scenes count orientation from the panel's NATIVE
   orientation; "landscape" = rotated, portrait-shaped bounds). The 1.2.1.1 hook
   never ran: SDL's real app delegate on iOS 13+ is `SDLUIKitSceneShim`, not
   `SDLUIKitDelegate`. Fix: SDL patch 0003 `UIKit_IsExternalDisplayScene()` →
   supported orientations = Portrait (native) off the main screen; shell hook now on
   the scene shim too; re-asks supported orientations on screen/scene changes.
   Proven only under emulation (`VKQ_EMULATE_EXTERNAL_DISPLAY=1` hint; the sim cannot
   extend a display — its TVOut screen is mirror-only): scripts/sim-verify-issue7.sh.
   Expected on the reporter's hardware: `vkq_mouse` shows external scene
   orient=portrait, bounds 3008x1692, drawable=6016x3384, supported=0x2.
   Side finding: the iPad-sim "square frame" oddity is a headless-sim artifact
   (panel never rotates; landscape scene drawn unrotated into a portrait buffer).
3f. Opus agent in flight on issue-7-external-display: (A) TF table coverage + retry
   guard keyed on the missing-file set; (B) DarkPlaces protocol-7 servers (reporter
   hit "Server returned version 3504" on 5-6 servers): graceful disconnect + message
   instead of Host_Error stack wall, silence `cl_serverextension_download`, check the
   `*` marking. DECISION FOR AUSTIN: DP7 client protocol support is a large engine
   feature; decide after the reporter names the servers / how many populated ones
   are DP-only.
3g. Then: bump both plists to 1.2.1.2 (build 45) on issue-7-external-display,
   `OTA_PUBLIC_GATE=1 OTA_NOTES=... scripts/publish-ota.sh`, verify served IPA, Austin
   uploads to #8 (gh cannot attach), reply on #7/#8.
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
- (done 2026-11-03) Austin posted the 1.2.1.1 IPA on #8 via WeTransfer. Reporter's
  SideStore shows "1.2.1"; replied with the in-app check (`vkq_mouse` unknown on 1.2.1).
- Release `issue-6-7-followup` as 1.2.2 after the reporter confirms? Default: wait
  (release numbers are Austin's call).
- VR docs on `vr-notes-private`: default keep local, never push.

## Live claims
Opus agent in flight (TF coverage + DP7 message) on branch `issue-7-external-display`;
owns the tree + iPhone Air (lane 2). Branches pushed: issue-6-7-followup (1.2.1.1),
mod-download, issue-7-external-display. `main` = `origin/main` = v1.2.1.
