# vkQuake — a frame from input to present, and the pacing model

Phase 0.1 / 0.5 deliverable. **Read depth:** `host.c`, `cl_demo.c`, `sys_sdl_unix.c`,
`common.c` (filesystem), `gl_vidsdl.c` (init / present / screenshot), `meson.build`
read directly. Renderer-internal Vulkan structure (render passes, command-buffer
layout, staging) is sketched from `gl_vidsdl.c` + `gl_*.c`/`r_*.c` symbols and boot
logs — **flagged _to deepen_** below. QuakeC VM not yet deep-read.

vkQuake is QuakeSpasm/QSS lineage with a Vulkan renderer and multithreaded
rendering/loading (`tasks.c` worker pool).

## Who owns the loop
`main_sdl.c` → `Sys_Init` (sets `basedir`/`userdir`) → `Host_Init` → a loop that
calls **`Host_Frame(dt)`** repeatedly, `dt` = real elapsed seconds
(`SDL_GetPerformanceCounter`). **On iOS this loop is replaced by a CADisplayLink**
firing `Host_Frame(dt)` once per display refresh (Phase 1) — exactly one present
per fire.

## One frame — `_Host_Frame(dt)` (host.c:958)
1. **`Host_FilterTime(dt)`** (host.c:705): accrues `realtime`; throttles to
   `host_maxfps` — but **skips the throttle during `cls.timedemo`** (host.c:725).
   Sets `host_frametime`.
2. **Input**: `Sys_SendKeyEvents` → `IN_SendKeyEvents` (SDL events → key events),
   `IN_Commands` (controllers). _iOS: the shell synthesizes touch/gamepad into
   SDL/engine key + analog events._
3. **`Cbuf_Execute`** — run queued console commands.
4. **`NET_Poll`** — read inbound packets.
5. **Server / physics catch-up loop** (host.c:1013):
   `while (host_netinterval == 0 || accumtime >= host_netinterval)` →
   `Host_ServerFrame` (runs QuakeC `SV_Physics` in `sv.qcvm`) at fixed ~72 Hz ticks,
   **draining accumulated real time across as many ticks as needed per rendered
   frame.** Then client-side `SV_Physics` on `cl.qcvm`.
6. **`CL_ReadFromServer`** — apply/interpolate server state.
7. **`SCR_UpdateScreen(true)`** (host.c:1071) — render + present (below). One present.
8. **Audio**: `BGM_Update` (music streaming), `S_Update` (3D mix), `CDAudio_Update`.

## Render + present — `SCR_UpdateScreen` → `gl_vidsdl.c`  _(to deepen)_
- Acquire swapchain image (`vkAcquireNextImageKHR`).
- Build the scene into **secondary command-buffer contexts** (world/brush, alias +
  MD5/MD3 models, particles, sky, HUD/2D). Compute shaders do lightmap updates
  (`update_lightmap.comp`) and screen effects (`screen_effects.comp`); geometry via
  indirect draws. _(Structure inferred from boot log + `gl_r*`/`r_*` symbols.)_
- Submit primaries (`vkQueueSubmit`), then `vkQueuePresentKHR`.
- **Present mode**: IMMEDIATE when `vid_vsync 0` (the default), else FIFO.
  `VK_KHR_present_wait` paces frame latency **only when `vid_vsync > 0`**
  (gl_vidsdl.c:3910) — so it does not gate the vsync-off oracle.
  - _macOS: Metal caps drawable acquisition at the display refresh → measured fps ≈
    cadence, not work (min frame time reveals the sub-ms real work; M-001/M-002)._
  - _iOS MoltenVK: **FIFO only** (quake3e M-008) → on-device fps = presentation
    cadence; throughput needs Instruments / Metal System Trace._
- **Screenshot**: `screenshot` sets `take_screenshot`; capture is a deferred
  swapchain→buffer copy in `GL_EndRenderingTask` (gl_vidsdl.c:4045-4085) — currently
  writes nothing in headless runs (D-006; on-device blocker, fix with console bridge).

## The pacing model (Phase 0.5 crux — vkQuake already decouples sim from render)
- `host_maxfps` default **200** (CVAR_ARCHIVE); `MAX_PHYSICS_FREQ = 72.0` ("don't
  modify!"); `HOST_NETITERVAL_FREQ = 71.9990`.
- `host_maxfps > 72` (or ≤ 0) → **renderer/server isolation ON**
  (`host_netinterval = 1/71.999`): physics ticks at a fixed ~72 Hz while the renderer
  free-runs (host.c:135-149). This is the readme's "run above 72 Hz without breaking
  physics." `host_maxfps ≤ 72` → isolation OFF (classic framerate-coupled physics).
- Because step 5 drains `accumtime` across multiple fixed-rate ticks, **simulation
  stays correct even when the outer loop (a display link) fires at 60/120 Hz with
  variable `dt`** — the one-tick-per-callback starvation trap both sibling ports had
  to *patch in* (q2repro fix 0021, quake3e patch 0002) is **native here**.
- **iOS plan (provisional; verify with a device spike):** CADisplayLink is the only
  pacer, one `Host_Frame(dt)` per fire with real `dt`; set `host_maxfps ≥ display
  rate` (or 0) so `Host_FilterTime` never skips a frame; verify **sim-rate**
  (game-seconds vs wall-seconds) and slow-mo capture at both 60 and 120 Hz — Quake 1
  physics is rate-sensitive and the community will notice.

## Subsystems (brief)
- **QuakeC VM** — `pr_exec.c`/`pr_edict.c`/`pr_cmds.c`/`pr_ext.c`: interpreted
  `progs.dat` bytecode. Mods are **data**, so on iOS they Just Work — no code-signing
  wall (the headline iOS feature). _Not yet deep-read; measure interpreter cost on
  the oracle before the port (Phase 0.1 remaining)._
- **Music / audio** — `bgmusic.c` streams external `<game>/music/trackNN.ogg` via
  `snd_vorbis` (libvorbis); flac/mp3(mpg123)/opus/wav codecs all present and
  meson-wired. Rerelease OGG soundtracks are in the local data.
- **Filesystem** — `-basedir` reads paks; with `do_userdirs` enabled, `-userdir`
  isolates all writes to `userdir/<game>` (common.c:2557-2590). Rerelease flavor
  detected via `QuakeEX.kpf` / store heuristics (common.c:2807+).
