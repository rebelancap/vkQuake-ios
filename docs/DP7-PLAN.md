# DarkPlaces protocol 7 (DP7) client support: feasibility and plan

Issue #8 follow-up. Written 2026-11-03 by a read-only planning agent. Nothing in
the engine has changed yet. Everything below comes from a live master/server
survey, the DarkPlaces source (DarkPlacesEngine/darkplaces `10d48635`,
2026-10-20), FTEQW (`f09ac7cc`, 2026-11-02), and the vendored vkQuake 1.37.0
(`749b4fd4`) plus our overlay through 0034.

## TL;DR

- **Cheap win, can ship now (about half a round):** 4 of the 13 DarkPlaces
  servers that answer queries run **protocol 15**. The oracle joins them today
  (the logs reach `CL_SignonReply: 4`), but our browser marks them `*` because
  overlay 0033 stars *every* `DarkPlaces-Quake` row that has no `nqprotocol`
  key. DarkPlaces never sends that key, so the rule stars every DP server,
  including the joinable ones. Remove the DP clause and keep (or hide) only the
  two Xonotic servers that show up in the Quake list.
- **DP7 itself** would add **7 more id1/mod servers**: 1 FFA, 1 coop, 1
  bot-DM, 1 Team Fortress, 3 id1. **None of them uses CSQC.** The 2 that do use
  CSQC are Xonotic servers, and Xonotic can't run in a Quake client anyway.
  **Population: 0 humans on all 13 DP servers in both snapshots** (about 21:45
  and 22:05 UTC). DP7 support is a UX fix ("every row I tap works"), not access
  to an active community.
- **The protocol work is smaller than it looks.** A 230-line Python prototype
  (Appendix A) completed the DP7 handshake, signon, every svc an id1-family
  server sent, EntityFrame5 decoding, and DP7 `clc_move` plus `clc_ackframe`
  against a locally built DP server and **4 live DP7 servers** (2014 and 2018
  builds, including Team Fortress and a Zeus-bot mod). On each one the server
  accepted its input: the player walked up to 1,000 units, and fired, with the
  shots coming back as `TE_GUNSHOT`s and the shells stat dropping. vkQuake already
  has most of the plumbing: the DP svc numbers, the `clcdp_ackframe` writer,
  float coords and short angles through `protocolflags`, the
  `CL_EntitiesDeltaed()` sink (its own comment says "called with both fte+dp
  deltas"), DP-ordered `effectinfo` particles, and the `getchallenge` connect
  path that already reaches DP7 servers.
- **Estimate:** Phase A (join, see, move, shoot) is **2 agent-rounds**. Phase B
  (DP temp-entities, effects, alpha/colormod/glow polish, DP7 demo playback) is
  **1–2 rounds**. Phase C (full CSQC) is **out of scope**. The patch is about
  600–800 lines, almost all in a new `Quake/cl_dp7.c`, behind
  `cl.protocol == PROTOCOL_DP7`.
- **Recommendation: GO on the cheap win now. GO on Phase A+B at normal-low
  priority**, because harm can be kept to zero by construction (see §3.3) and
  the test bed is cheap: a DP dedicated server builds on this Mac in 3 s. Don't
  expect it to bring players. Its value is that the browser stops lying, and
  that DP7 demos become playable.

---

## 1. Survey

### Method

`tools/survey.py` (scratchpad): `getservers <game> 3 empty full` to
master.frag-net.com, dpmaster.deathmask.net and dpmaster.tchr.no (the same
masters and game names as net_dgrm.c). Then `getinfo` and `getstatus` to every
listed server. Then, for every DarkPlaces-Quake server that answered, a real
DP-style connect (`getchallenge` → `connect\protocol\darkplaces 3\...` →
`accept`) that reads the first reliable message up to `svc_serverinfo` and
disconnects at once. That message carries the protocol number, the
`Server: <version>` print, and the `csqc_progname/progsize/progcrc` stufftexts.
DarkPlaces sends those stufftexts *before* `svc_serverinfo` whenever the server
has a `csprogs.dat` (sv_main.c `SV_SendServerinfo`), so their absence proves
there is no CSQC.

Note: DP's `infoResponse` `protocol` key is the **master** protocol
(`NET_PROTOCOL_VERSION` = 3, netconn.c:2795), never the game protocol. DP also
never sends `nqprotocol`. The browser can't learn a DP server's game protocol
without connecting.

Of the masters, only 107.161.23.68 returned DarkPlaces-Quake rows (26 listed).
Thirteen answered and thirteen did not.

### DarkPlaces-Quake servers that answer (snapshot 2026-11-03 ≈21:45 UTC; re-checked 22:05 UTC, still 0 clients)

| Address | Hostname | Map | Mod (modname) | Game protocol | DP build | CSQC | Players | Joinable today? |
|---|---|---|---|---|---|---|---|---|
| 47.190.124.72:26001 | PART1CL3.NET_COOP | e1m2 | 1DI (id1) | **15** | Apr 12 2018 | no | 0/16 | **yes** (oracle reached signon 4) |
| 47.190.124.72:26002 | PART1CL3.NET_MP1 SoA Hipnotic | hip1m1 | HIPNOTIC | **15** | Apr 12 2018 | no | 0/16 | yes (protocol), needs hipnotic data |
| 47.190.124.72:26003 | PART1CL3.NET_MP2 DoE Rogue | r1m1 | rogue | **15** | Apr 12 2018 | no | 0/16 | yes (protocol), needs rogue data |
| 138.197.138.140:26000 | Spaceball1 (CTF 3.3.12+) | e2m6 | spaceball1 | **15** | May 13 2014 | no | 0/16 | **yes** (oracle reached signon 4) |
| 47.190.124.72:26004 | Part1cl3.net FFA | dm6 | IDI | 3504 (DP7) | Apr 12 2018 | no | 0/16 | no |
| 35.237.45.226:26000 | Cheese Eating Surrender Monkey | end | id1 | 3504 | May 13 2014 | no | 0/8 | no |
| 35.237.45.226:27000 | Cheese Eating Surrender Monkey | e3m6 | fortress | 3504 | May 13 2014 | no | 0/8 | no |
| 5.196.63.132:26000 | Coopera | e1m1 | id1 | 3504 | 0~20180908~beta1-2 Ubuntu | no | 0/12 | no |
| 91.189.78.62:26000 | Polski serwer FFA z ZEUSBot - FX160 | dm1 | ZEUS | 3504 | 0~20180908~beta1-3 Debian | no | 0/12 | no |
| 37.153.1.44:26000 | WEBA ISP Quake 1 Server | dm1 | id1 | 3504 | Dec 22 2018 | no | 0/32 | no (also stuffs `curl --pak id1pak1.pak`, which 0034 correctly refuses) |
| 103.192.193.214:26000 | UNNAMED | start | id1 | 3504 | May 13 2014 | no | 0/16 | no |
| 3.138.68.75:26000 | Fear The KR2 \| US #1 [BETA] | implosion | data (**Xonotic**, qcstatus `MXonotic`) | 3504 | v1.2.103~ Oct 27 2026 | **yes** (csprogs 4.25 MB) | 0/16 | never (Xonotic content) |
| 92.5.104.122:26000 | LIZA | liza_district | data (**Xonotic**) | 3504 | d93f9c4 Oct 31 2026 | **yes** (csprogs 4.02 MB) | 0/8 | never (Xonotic content) |

### DarkPlaces-Quake servers listed but silent (invisible today, and they'd stay invisible)

`104.148.183.178:26000, 149.115.73.113:26000, 170.103.12.69:26000,
170.103.12.69:26001, 178.22.53.56:26000, 216.59.232.7:26000, 216.59.232.7:26003,
216.59.232.7:26004, 24.107.160.157:17481, 24.107.160.157:26503,
24.107.160.157:58174, 82.196.100.250:26000, 97.119.147.163:26000`. These
didn't answer `getinfo` or `getstatus` across 2 retries. Most look like dead
registrations, NAT'd home hosts, or random-port hosts.

### For comparison: FTE-Quake list (already joinable, not affected by this plan)

57 listed, 25 answering. The people are here: X-Men SF (7 bots),
q1.pieter.com QW (6), NetQuake.io Shareware FFA (4 humans), NetQuake.io
FrogBots/Shareware Bots (3 bots each), Alex Frikbot (3 bots). These run
QSS-M or FTE and speak 15/666/999+FTE.

### Conclusion

- Protocol-7 support unlocks **7 Quake servers**: 1 FFA dm6, 1 coop, 1 id1
  "end", 1 Team Fortress, 1 Zeus-bot FFA, 2 id1 dm1/start. Nobody was on any of
  them in either snapshot. **None needs CSQC.**
- The browser fix alone unlocks **4 more** that already speak protocol 15.
- The 2 CSQC servers are Xonotic servers listed under the Quake game name. A
  Quake client can't play them under any protocol. They should be hidden or
  starred by an explicit Xonotic test (`qcstatus` contains `Xonotic`, or
  modname `data` with `gameversion` ≠ 0).
- The issue-#8 reporter's "5–6 servers, all DP" matches this list: they would
  have tapped the DP7 rows and the starred protocol-15 rows.

---

## 2. Protocol scope

### 2.1 Handshake: how a DP server picks the protocol

- The protocol is **per server, never per client.** It's set at map spawn from
  `sv_protocolname` (default `"DP7"`): `sv.protocol =
  Protocol_EnumForName(sv_protocolname.string)` at sv_main.c:1949. The
  `\protocols\` list the client sends in `connect` is **ignored** by the server
  (netconn.c:3296–3420 reads only `challenge`, `message` and `protocol` ==
  `"darkplaces 3"`). There is no `CCREQ_CONNECT` extension, and no way for a
  client to ask a DP7 server for 15 or 666.
- An NQ `CCREQ_CONNECT` is answered **only** when `sv.protocol` is
  QUAKE/QUAKEDP/NEHAHRA*/DP1–3 (netconn.c:3577). A DP7 server ignores it, and
  only the `getchallenge`/`connect` path works. vkQuake already sends both
  (net_dgrm.c:2064, `DPGETCHALLENGE`; reply at :2102). That's why we get
  `Server returned version 3504` today: **the connection and NQ netchan already
  work; only parsing is missing.**
- The netchan is the plain NQ datagram format (`NETFLAG_DATA/ACK/EOM/UNRELIABLE`,
  netconn.h:35–44). DP adds `NETFLAG_CRYPTO*` bits only when `d0_blind_id`
  crypto is negotiated, which a client that doesn't ask never gets. Reliable
  fragments are ≤ `MAX_PACKETFRAGMENT` 1024 bytes. vkQuake's `NET_MAXMESSAGE`
  of 64000 is enough. Verified: the oracle and the Python prototype both
  completed reliable exchanges with DP7 servers.
- `svc_serverinfo` for DP7 has **the same layout as NQ**: `long protocol`,
  `byte maxclients`, `byte gametype`, `string levelname`, model list, sound
  list (sv_main.c:880–895). The signon flow (`prespawn` / `spawn` / `begin`
  stringcmds, `svc_signonnum` 1–3) is unchanged. Signon 4 happens on the first
  `svc_entities`.

### 2.2 Encodings in DP7

| Item | DP7 | vkQuake equivalent |
|---|---|---|
| `MSG_ReadCoord` | 32-bit float (com_msg.c:389) | `PRFL_FLOATCOORD` |
| `MSG_ReadAngle` | 16-bit (`ReadAngle16i`) (com_msg.c:424) | `PRFL_SHORTANGLE` |
| Entity numbers | `ushort`, 15 bits (≤ 32767) | vkQuake `MAX_EDICTS` is 32000; clamp or refuse above it |
| Stats | `svc_updatestat` (long) / `svc_updatestatubyte` (51), all of 0–255, sent unreliably inside the entity frame (sv_ents5.c:518–550) | `CL_ParseStatInt`, `MAX_CL_STATS` 256 |

### 2.3 Server→client opcodes a DP7 client must handle

"Seen live" counts each opcode in a ~8 s session from the Appendix A prototype,
on dm6 FFA, Coopera coop, Zeus-bot DM and TF, plus the local id1 dm1 server.
"DP lines" is the size of the reference client code in darkplaces.

| svc | # | Seen live | Needed for play? | Notes / DP reference | DP lines |
|---|---|---|---|---|---|
| nop, disconnect, print, stufftext, centerprint, setview, lightstyle, updatename, updatefrags, updatecolors, signonnum, killedmonster, foundsecret, cdtrack, intermission, finale, cutscene, sellscreen, setpause, stopsound, skybox (37) | 1,2,8,9,26,5,12,13,14,17,25,27,28,32,30,31,34,33,24,16,37 | yes | **required** | Same layout as NQ. vkQuake's existing cases work unchanged. | 0 |
| time | 7 | every frame | **required** | Same | 0 |
| updatestat | 3 | yes | **required** | Same. Stats 220–255 are DP movevars (float bits). Store them and ignore. | 0 |
| setangle | 10 | yes | **required** | Angle16 via protocolflags | 0 |
| sound | 6 | yes | **required** | Field-mask bit **4 (`1<<2`) is `SND_LOOPING` in DP but `SND_FTE_MOREFLAGS` in vkQuake**. Must not read a moreflags byte in DP7. `1<<5` = `SND_SPEEDUSHORT4000` (vkQuake already parses it as `SND_DP_PITCH`, gated on pext2). `1<<3` largeentity, `1<<4` largesound: same as Fitz. Coords float. | cl_parse.c CL_ParseStartSoundPacket ~70 |
| **clientdata** | 15 | every frame | **required, DP7-specific** | `ushort bits` (+EXTEND1/2 bytes). viewheight char, idealpitch char, per axis: punch **angle16**, punchvector **float** (SU 16–18), velocity **float**. `SU_ITEMS` long only if set. onground and inwater are bits. viewzoom `ushort` (SU 19). **No health/ammo/weapon fields:** those arrive as stats. The bit layout above 1<<15 differs from Fitz's, so this needs its own parser. | cl_parse.c CL_ParseClientdata, DP7 branch ~45 |
| particle | 18 | — | required (id1 QC uses it) | Same layout, float coords | 0 |
| damage | 19 | — | required | Same, float coords | 0 |
| spawnstatic | 20 | yes | **required** | NQ layout with float coords and short angles (byte model/frame) | 0 (version 1 path with flags) |
| spawnstaticsound | 29 | yes | **required** | NQ layout, float coords | 0 |
| temp_entity | 23 | yes (TE_GUNSHOT) | **required** for 0–13. DP extensions 50–79 are needed by DP-extension mods | vkQuake knows 0–13 plus TEDP 55/56. **Unknown TE types are fatal** (no length prefix). DP's parser covers 35 TE types. | cl_parse.c CL_ParseTempEntity 530 (DP-only cases ≈250) |
| spawnbaseline / spawnbaseline2 | 22 / **55** | not sent on the servers tested (E5 deltas from `defaultstate`, not baselines) | required if sent | DP 55 = `short ent, short model, short frame, byte colormap, byte skin, coord/angle×3`. **Not** Fitz's bit-flagged 42. | 30 |
| spawnstatic2 | **56** | not seen (needs >255 models) | required if sent | DP 56 = short model/frame form. **Collides with rerelease `svc_localsound` 56 in vkQuake's switch.** Must be dispatched before it. | 40 |
| spawnstaticsound2 | **59** | not seen | required if sent | Same layout as Fitz 44: `coord3, short samp, byte vol, byte atten` | 0 (reuse version 2) |
| precache | **54** | not seen on the servers tested | required (late precache, sv_main.c:1452,1500) | `short index` (`|0x8000` = sound), string. vkQuake's `CL_ParsePrecache` uses `>>14` (0x4000 = particle, an FTE extension). Compatible for models and sounds. Currently gated on `protocol_pext2`, so the gate must allow DP7. | 0 |
| updatestatubyte | 51 | yes | **required** | Same as vkQuake `svcdp_updatestatbyte`. Gated on REPLACEMENTDELTAS today, so the gate must allow DP7. | 0 |
| **entities** | **57** | every frame | **required, the core** | EntityFrame5: `long framenum`, `long servermovesequence` (DP7+), then `ushort n` until `0x8000`. `n & 0x8000` = remove. Else a delta with bits byte (+EXTEND1/2/3): FULLUPDATE resets to DP `defaultstate`; FLAGS, ORIGIN (13.3 fixed or `ORIGIN32` float), ANGLES (8-bit or `ANGLES16`), MODEL (byte or `MODEL16`), FRAME (byte or `FRAME16`), SKIN, EFFECTS (8/16/32), ALPHA, SCALE, COLORMAP, ATTACHMENT, LIGHT, GLOW, COLORMOD, GLOWMOD, COMPLEXANIMATION (5 subtypes; type 4 is skeletal, with bone count in-packet so it can be skipped without the model), TRAILEFFECTNUM. **The client keeps no frame database.** The "5-frame database" and priority resend logic are server-side only (sv_ents5.c). The client applies deltas to its current state and acks frame numbers. | cl_ents5.c 346 (≈150 without debug prints and skeletal) |
| effect / effect2 | **52** / 53 | not seen | optional (QC `effect()` builtin) | `vec org, byte/short model, byte/short startframe, byte count, byte rate`. **52 collides with vkQuake `svc_achievement`.** Dispatch before the switch. | 30 |
| trailparticles / pointparticles / pointparticles1 | 60 / 61 / 62 | not seen | optional (DP-extension QC) | vkQuake already parses these (`CL_ParseParticles`) and `CL_ForceProtocolParticles()` maps effect numbers in **DP effectinfo.txt order**, as DP numbers them. Works as-is. | 0 |
| downloaddata | 50 | no | ignorable | Sent only after the client asks for `download`. vkQuake never does, so it never arrives. | — |
| csqcentities | 58 | no | ignorable here | Sent only when the server runs CSQC (only the Xonotic servers). Refuse those servers (§3.4). | — |
| showlmp / hidelmp | 35 / 36 | no | optional | Nehahra-style. Parse and skip (needs a DP-only branch: currently fatal in vkQuake). | 15 |
| fast update (`cmd & 0x80`) | — | never | n/a | DP7 never sends NQ fast updates. | — |

Stufftext extensions seen: `cl_serverextension_download 2` (harmless), the
`csqc_*` trio (only on Xonotic), `curl --clear_autodownload / --pak ... /
--finish_autodownload` (0034 already handles these; an id1 pak request is
refused), and TF's usual `color`/`alias` traffic (331 stufftexts in 8 s on the
TF server, all ordinary console commands). DP's prydon cursor is a server-side
QC feature fed by `clc_move` fields: send zeros.

### 2.4 Client→server (required for the server to accept input)

- **`clc_move` for DP7 is 56 bytes per move** (DP cl_input.c:2096–2122; FTE
  cl_input.c:1932–1990 matches): `byte clc_move(3)`, `long movesequence` (0 =
  not predicted; we send 0), `float time` (last server time), `3×angle16`,
  `3×short fwd/side/up`, **`long buttons`**, `byte impulse`, then the prydon
  cursor `short sx, short sy, 3×float start, 3×float impact, short entnum`
  (all zero). vkQuake's current writer sends `byte buttons` with no sequence,
  which would desync the server parser. This is the one writer that has to
  change.
- **`clc_ackframe` (50) `long framenum`** for each `svc_entities` frame
  received. vkQuake already writes `clcdp_ackframe` from `cl.ackframes[8]`
  (cl_input.c:490–495). For DP7, push the **E5 framenum**, not the netchan
  sequence that `CLFTE_ParseEntitiesUpdate` pushes today. A missed ack only
  makes DP mark the frame lost and resend changed fields, so it's harmless.
- `clc_stringcmd` / `clc_disconnect`: unchanged. Verified: the prototype's
  `prespawn`, `name`, `color`, `spawn` and `begin` drove all four live servers
  to "entered the game".

### 2.5 Evidence that this scope is complete for id1-family servers

The Appendix A prototype implements only what's listed above, raising an error
on any unknown svc or TE. It ran for 8–10 s on each of 5 servers: local DP
`10d4863` dm1, and live DP7 Coopera, PART1CL3 FFA, Zeus-bot FFA and CESM TF.
On every one it saw only svcs {1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17,
20, 23, 25, 26, 29, 30, 32, 51, 57} and only TE 2. The union of E5 bits was
`0x59ff`: FULLUPDATE, ORIGIN, ANGLES, MODEL, FRAME, SKIN, EFFECTS, FLAGS, ALPHA,
ORIGIN32, ANGLES16, COLORMAP. No `COMPLEXANIMATION` and no >255 models.

- Coopera: the player walked from y=-296 to y=688.
- TF: walked from -352 to 1065.
- Local dm1: `STAT_SHELLS` ended at 17 (an id1 DM spawn gives 25) after
  firing, with 48 `TE_GUNSHOT`s.
- Two servers changed map mid-session and the prototype re-signoned cleanly.

---

## 3. Fit into vkQuake

### 3.1 What already exists (upstream 1.37, inherited from QSS/Spike)

- **The connection path**: the DP `getchallenge`/`connect` handshake (net_dgrm.c:2064–2115). It already reaches DP7 servers.
- **Encodings**: `PRFL_FLOATCOORD | PRFL_SHORTANGLE` give DP7's coords and angles everywhere the code calls `MSG_ReadCoord/Angle(cl.protocolflags)`: setangle, particle, damage, statics, sounds, TEs, svcdp particles.
- **DP opcode numbers** `svcdp_*` 50–62 and **`clcdp_ackframe`** 50, with a working ack writer.
- **The delta sink**: `entity_t.netstate` + `update_type` + `CL_EntitiesDeltaed()` (cl_parse.c:521, "called with both fte+dp deltas"). It does lerp, model change, skin translation, alpha and step-lerp. An E5 reader only has to fill `netstate`, set `update_type`, and call it. `CL_RelinkEntities` keeps such entities alive (cl_main.c:712, via `msgtime`).
- **Stats**: `CL_ParseStatInt`, `MAX_CL_STATS` 256, and `STAT_ITEMS` 15 / `STAT_VIEWHEIGHT` 16 / `STAT_VIEWZOOM` 21 all use DP's numbering (quakedef.h:141–143).
- **Particles**: `svcdp_pointparticles/trailparticles` and `CL_ForceProtocolParticles()` (DP effectinfo order).
- **Precache**: `CL_ParsePrecache` handles DP's model/sound index form.
- **Signon**: the "first entity update = signon 4" logic exists in `CLFTE_ParseEntitiesUpdate`. Copy it.
- **SimpleCSQC only** (host.c:1031 `CL_LoadCSProgs`): it loads a csprogs *only* if it has `CSQC_DrawHud` and treats it as HUD-only. There is no `CSQC_UpdateView`/`CSQC_Ent_Update` support, so full DP CSQC mods are out of reach (§5 Phase C).

### 3.2 What is new: the mapping

| DP7 piece | Where in vkQuake | Size |
|---|---|---|
| `#define PROTOCOL_DP7 3504` | protocol.h | 1 |
| Accept 3504 in `CL_ParseServerInfo`: `cl.protocol = PROTOCOL_DP7; cl.protocolflags = PRFL_FLOATCOORD\|PRFL_SHORTANGLE`, rest NQ | cl_parse.c (and narrow 0034's `CL_RefuseServerProtocol` to 3500–3503/3505/96/97) | ~10 |
| `CLDP7_ParseCommand(cmd)`: returns true if it consumed the opcode. Called **before** the main `switch` only when DP7. Handles 15 (clientdata), 51 (statbyte), 52/53 (effect), 54 (precache), 55 (baseline2), 56 (static2), 57 (entities), 59 (staticsound2), 23 (TE, DP-extended table), 35/36 (skip), 58 (refuse, CSQC). Everything else falls through to the existing switch. | new `Quake/cl_dp7.c` | ~120 |
| EntityFrame5 reader → `ent->netstate` + `update_type` + `CL_EntitiesDeltaed()`. Map DP alpha (255 = opaque) to `ENTALPHA_ENCODE`. Scale ×16 and colormod ×32 are the same encoding. DP effects bits 1–8 equal Quake's. `RENDER_STEP` (flags bit 0) = `EFLAGS_STEP`. `RENDER_EXTERIORMODEL`: don't draw in first person. Push framenum to `cl.ackframes`. Store `servermovesequence`. Skip COMPLEXANIMATION by its in-packet sizes. | cl_dp7.c | ~200 |
| DP7 clientdata parser (§2.3) → `cl.mvelocity`, `cl.punchangle` (+ `v_punchangles` shift as the PREDINFO path does), `cl.idealpitch`, `cl.onground`, `cl.inwater`, `STAT_VIEWHEIGHT`, `STAT_VIEWZOOM` | cl_dp7.c | ~60 |
| DP baseline/static (55/56) readers | cl_dp7.c, or a new `version` value in `CL_ParseBaseline`/`CL_ParseStatic` | ~40 |
| `CL_SendMove`: `if (cl.protocol == PROTOCOL_DP7) { write DP7 move; } else { existing }`, acks unchanged | cl_input.c (one branch) + cl_dp7.c writer | ~40 |
| Sound flag gate: don't treat bit 2 as `SND_FTE_MOREFLAGS`, and do read bit 5 as speed, when DP7 | cl_parse.c `CL_ParseStartSoundPacket` (2 conditions) | ~4 |
| Gates on 51/54 opened for DP7 (or handled entirely in the pre-dispatcher, leaving the switch untouched; preferred) | — | 0 |
| DP TE table (Phase B): sizes for all DP TE types, rendered through PScript names (`TE_BLOOD`, `TE_SPARK`, `TE_GUNSHOTQUAD`, …) with a classic-particle fallback | cl_dp7.c (calls into cl_tent.c helpers) | ~250 |
| Browser: drop the DP `nqprotocol` star rule. Star or hide Xonotic rows. | net_dgrm.c (0033's hunk) | ~10 |
| meson.build: add `Quake/cl_dp7.c`. iOS/visionOS pick it up automatically: `scripts/build-ios.sh` enumerates the oracle's `vkquake.p/Quake_*.c.o`. | meson.build | 1 |

**Netchan: unchanged.** **Demo recording: unchanged.** vkQuake writes raw
server messages, so a demo recorded on a DP7 server starts with a 3504
serverinfo and plays back through the same parser. **Playing DP's own .dem
files** (also raw DP7 messages) becomes possible as a free side effect. It
needs a check with a demo that has `svc_csqcentities` (refuse) and
`svc_downloaddata` (skip).

### 3.3 Harm surface: how 15/666/999, FTE, demos and SP stay identical

1. Every new branch tests `cl.protocol == PROTOCOL_DP7`. `cl.protocol` is set
   only from `svc_serverinfo`, so local single player (always 15/666/999),
   every FTE/QSS server, and every existing demo never enter new code.
2. The pre-dispatcher runs before the existing `switch`, which stays
   byte-identical. That leaves the opcode collisions (52 `svc_achievement` vs
   DP `svc_effect`, 56 `svc_localsound` vs DP `svc_spawnstatic2`, 54
   `svc_levelcompleted` vs DP `svc_precache`) unchanged for rerelease/KEX
   demos and servers.
3. `CL_SendMove` gains one `if` at the top. The non-DP7 bytes on the wire are
   unchanged. **Check:** a packet capture or `cl_shownet`-style dump of
   `clc_move` against a QSS-M server, before and after, must be byte-identical.
4. The sound-flag change is guarded by the same test.
5. **Regression gate for the patch:** `timedemo demo1`, demo2 and demo3 on
   the oracle must give identical frame counts. A rerelease demo must still
   play. A join to a NetQuake.io QSS-M server and to an FTE server must reach
   signon 4. `scripts/ios-syntax-check.sh` and the VR syntax check must be green
   (memory: a green oracle build hides iOS/VR-only breakage).
6. Keep the code in a **new file** so that upstream bumps rebase cleanly. The
   hunks in upstream files stay at ~6 one-liners.

### 3.4 What we refuse, gracefully

Reuse 0034's `CL_RefuseServerProtocol` style:

- **DP 3500–3503 (DP3–6) and 3505 (DP8).** DP6 is DP7 minus the move sequence
  and minus `servermovesequence`, so adding it would cost about 10 lines. Do it
  only if a DP6 server ever appears; the survey found none.
- **Any DP7 server that sends the `csqc_progname` stufftext:** refuse before
  signon with "This server needs DarkPlaces CSQC (Xonotic-style game code),
  which vkQuake can't run."

---

## 4. Reference implementations

- **FTEQW is the only non-DP client that speaks DP5–DP7**:
  `engine/client/cl_ents.c` `DP5_ParseDelta` (line 1505, ~300 lines with
  `CLDP_ParseDarkPlaces5Entities` at 1716), `cl_input.c` DP7 move writer
  (1932–1990), and `cl_parse.c` protocol selection (3948–3968, `CPNQ_DP5..7`).
  https://github.com/fte-team/fteqw/blob/f09ac7cccd2d713ddf881d3f1324703082c2cfe4/engine/client/cl_ents.c#L1505
  FTE also has `dpcompat_nopreparse` because "DP mods that send unknowable
  svc_tempentity messages" break preparsing (cl_main.c:1248). That's the same
  risk as our TE table (§6). FTE is GPLv2, like vkQuake.
- **DarkPlaces itself** (GPLv2): `cl_ents5.c` (the E5 reader),
  `cl_parse.c` (`CL_ParseServerMessage` from line 3435, `CL_ParseClientdata`,
  `CL_ParseTempEntity` 2413–2943), `cl_input.c` `CL_SendMove` (1771). Port
  with attribution in the file header.
- **QuakeSpasm-Spiked / vkQuake:** never implemented DP7. vkQuake inherits a
  QSS comment (protocol.h:309–310): "fte reuses the dp svcs for nq ... this
  should make dpp7 support a little easier if you ever want to implement that".
  GitHub issue search for "darkplaces", "DP7" and "3504" in Novum/vkQuake,
  Shpoike/Quakespasm, sezero/quakespasm and andrei-drexler/ironwail found **no
  DP7 request or PR**. Related only: vkQuake #915 "Auto-download a server's
  map?" (open), QSS #146 (`CL_SERVEREXTENSION_DOWNLOAD` unknown in other
  engines), Ironwail #306 "Support for the FTE or QuakeWorld protocol" (open).
  A GitHub code search for `PROTOCOL_DARKPLACES7` found only DP forks
  (DarkPlacesRM, QuakeQuest, QuakeGVR, Wrath, the Q3E Android bundle). So if we
  ship this, it's a first for a QuakeSpasm-lineage engine and worth offering
  upstream.

---

## 5. Plan

All work goes in **overlay patch `0035-dp7-client.patch`**: a new
`Quake/cl_dp7.c` plus small hunks in protocol.h, cl_parse.c, cl_input.c,
net_dgrm.c and meson.build. The Phase 0 browser fix is a smaller,
earlier change. If it ships first as its own patch, it takes 0035 and the DP7
client becomes 0036.

### Phase 0: cheap win (½ round, can go in the next dev build)

- **Change:** in the 0033 browser hunk, stop starring `DarkPlaces-Quake` rows
  for lacking `nqprotocol`. Star (or hide) only rows that look like Xonotic.
  The DP7 rows then show as joinable and still refuse cleanly with 0034's
  message until Phase A lands. That's acceptable, and the refusal reason is
  already on the join screen.
- **Optional:** append a short tag such as `DP` to the row label for DP-family
  servers, so users can tell them apart, which is what Austin asked for.
- **Test:** oracle `slist` shows PART1CL3 COOP and Spaceball without `*`. A join
  to each reaches `CL_SignonReply: 4` (already shown in this session's logs for
  both). A join to a DP7 row shows the 0034 refusal. Sim: a browser screenshot.
- **Risk:** none for play. The only behaviour change is fewer stars.

### Phase A: join, see entities, move, shoot on id1 DP7 (2 rounds)

- **Round A1 (execute, Opus):** write `cl_dp7.c` with the serverinfo accept,
  pre-dispatcher, E5 reader, DP7 clientdata, DP baseline/static/staticsound2,
  stat gates, the sound-flag gate, the DP7 `clc_move` writer, E5-framenum acks,
  TE 0–13 through the existing path, the CSQC refusal and the 0x7FFF clamp.
  Use Appendix A as the byte-level reference. It was proven against the same
  servers.
- **Test bed (deterministic):**
  ```
  cd <scratch>/darkplaces && make -j8 sv-release        # 3 s on this Mac; zlib only
  ./darkplaces-dedicated -basedir ~/dev/vkQuake-ios/gamedata -userdir <scratch>/dpuser \
      +sv_public 0 +port 26999 +maxplayers 4 +deathmatch 1 +map dm1
  ```
  Use a port outside the reserved :8765–8769. `-userdir` keeps gamedata
  untouched (verified). `+sv_protocolname QUAKE` on the same server gives the
  protocol-15 control. Add `+coop 1 +map e1m1` for monsters, and
  `+developer_networkentities 10` on the server to log acks. Connect the
  oracle with `autoexec.cfg` (`connect 127.0.0.1:26999`): `+connect` on the
  command line was swallowed by the demo loop in this session, which is how the
  mp8 harness already does it.
- **Acceptance evidence (round A2: fix, verify, review):**
  1. Oracle log on the local DP7 server: `Using protocol 3504` (new line),
     signon 4, no Host_Error over 2 minutes.
  2. Content screenshots of dm1 with the other player visible and animated,
     doors/plats moving, an item rotating, the viewmodel and HUD stats correct.
  3. Movement and fire accepted: the server log shows the frag and the shells
     stat drops. A second client (a DP probe, or a second oracle on the
     protocol-15 control) sees our player move.
  4. Coop e1m1 on the local server: monsters animate and die, and
     gibs/particles show.
  5. Live: a join to Coopera and PART1CL3 FFA (on empty servers only, and
     disconnect promptly).
  6. Regression gate §3.3 item 5, byte-identical `clc_move` for non-DP7.
  7. iOS sim (Lane 2, iPhone Air) join to the local DP server via the console
     bridge, with a screenshot.
  8. Sonnet diff review (light).
- **Risks:**
  - Entity lerp feel at DP's tick rate (sys_ticrate 0.0138, 72 Hz). It uses the
    same lerp code as FTE deltas. Verify there's no judder in a slow-mo capture
    against the protocol-15 control.
  - No client-side prediction. That's the same as playing NQ 15 today, and
    `movesequence` = 0 tells DP not to expect replay.
  - A DP server with a >255-model mod sends 55/56 forms we haven't seen. They
    are implemented from source; test them with a local mod or by forcing
    `sv_protocolname DP7` on a big map such as `ad_sepulcher` if AD is present.

### Phase B: effects/particles/sounds parity (1–2 rounds)

- DP TE table 50–79 (blood, spark, bloodshower, explosionrgb, particlecube/rain/snow,
  quad variants, customflash, flamejet, plasmaburn, TEI_*), `svc_effect/effect2`
  (sprite effect via a temp entity), `showlmp/hidelmp` skip, E5 `GLOW`/
  `LIGHT` → dlight, `EF_*` DP bits (NODRAW 16, ADDITIVE 32, BLUE 64, RED 128,
  FULLBRIGHT 512, FLAME, STARDUST, NOSHADOW, DOUBLESIDED …) mapped where
  vkQuake has an equivalent, `colormod`, `RENDER_VIEWMODEL` attached ents, DP7
  demo playback check.
- **Test:** a local DP server running a small QC test mod (or DP's own
  `dpmod` progs from the DP repo history) that fires every TE type and builtin
  once, then screenshots. Live Zeus-bot and TF servers for 5 minutes each, with
  no parse errors.
- **Acceptance:** every DP TE type parses (an unknown TE is a graceful refusal,
  never a desync), there are screenshots of the representative effects, and
  the §3.3 regression gate stays green.
- **Risk:** mods that write raw bytes with `WriteByte(MSG_*, SVC_TEMPENTITY)`
  and a custom TE type. No client can parse those (FTE's preparse has the same
  limitation). The behaviour is a clean disconnect with a message, never a
  crash.

### Phase C: CSQC, out of scope

- vkQuake has only SimpleCSQC (HUD-only, `CSQC_DrawHud`). DP CSQC mods need the
  full client VM (`CSQC_UpdateView`, `CSQC_Ent_Update` from
  `svc_csqcentities`, `CSQC_Parse_*`), hundreds of DP-specific builtins, and in
  practice Xonotic content (4 MB csprogs, Xonotic pk3s), which no Quake player
  has.
- **In the survey, the only CSQC servers are Xonotic's.** The cost is months
  and the benefit is zero Quake servers. **No-go.** Refuse them by name
  (§3.4).

### Effort and recommendation

| Phase | Agent-rounds | Lines (patch) | Benefit today |
|---|---|---|---|
| 0 browser fix | 0.5 | ~10 | +4 joinable servers, honest stars |
| A DP7 core | 2 | ~450 | +7 joinable servers (0 players observed) |
| B parity | 1–2 | ~300 | correct effects on DP-extension mods, DP7 demos |
| C CSQC | — | — | none (Xonotic only) |

**Go/no-go:**

- **Phase 0: GO now.** It's free and fixes a real mistake in our own 0033
  heuristic.
- **Phase A+B: GO, at low priority.** The protocol is fully understood and
  machine-verified against live servers. vkQuake already carries most of the
  plumbing. Everything is gated on `cl.protocol == PROTOCOL_DP7` in a separate
  file, so the harm surface is effectively zero. A local DP server gives fast,
  deterministic iteration.
- **Against it:** nobody was playing on any DP Quake server in either snapshot,
  and the work adds ~750 lines that each upstream bump has to carry. They live
  mostly in a new file, so rebases should be painless.
- If Austin wants only the UX promise ("users can't tell them apart"), Phase 0
  plus a `DP` tag on the row delivers most of it. Phase A then turns those rows
  from "tap → clean refusal" into "tap → play".

---

## 6. Immediate cheap wins (answers to the brief)

- **Can a client ask a DP7 server for 666 or 15?** No. `sv_protocolname` is
  global per map (sv_main.c:1949). The `\protocols\` list in `connect` is
  ignored. `CCREQ_CONNECT` is ignored entirely on DP4+ servers
  (netconn.c:3577). There is no `nqprotocol` serverinfo key in DP at all.
- **Are some of the 13 already joinable through what they advertise?** **Yes,
  4**: PART1CL3 COOP / Hipnotic / Rogue and Spaceball CTF run
  `sv_protocolname QUAKE` (protocol 15). The oracle joined COOP and Spaceball
  to signon 4 in this session. They're hidden behind our own `*` (0033). That's
  the Phase 0 fix.
- **The browser can't know a DP server's protocol** from getinfo or getstatus
  (the `protocol` key is the master protocol, 3). The only way to know is to
  connect, as the survey did. Don't probe from the browser: a probe makes the
  server allocate a client slot and print "connected" to everyone. Accept that
  DP rows are "probably DP7" until joined, and let the Phase A parser (or 0034's
  refusal) handle it.

---

## Appendix A: DP7 wire-format prototype (Python, test-only)

It was run from the scratchpad as `python3 -I dp7client.py <host> <port> <secs>`.
It's a reference for the byte layouts in §2, not product code. Results are
quoted in §2.5. Copy it to `scripts/` when Phase A starts if you want it as a
probe.

```python
# Minimal DP7 (protocol 3504) client: handshake, signon, svc coverage,
# EntityFrame5 decode, clc_move(DP7)+clc_ackframe. Raises on any unknown svc/TE.
import socket,struct,time,sys,collections
addr=(sys.argv[1],int(sys.argv[2])); dur=float(sys.argv[3]) if len(sys.argv)>3 else 8
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.05)
def ctl(m): s.sendto(b"\xff\xff\xff\xff"+m,addr)
chal=None
for _ in range(20):
    ctl(b"getchallenge\n")
    try: d,_=s.recvfrom(65536)
    except socket.timeout: continue
    if d.startswith(b"\xff\xff\xff\xffchallenge "): chal=d[14:].split(b"\0")[0]; break
ctl(b"connect\\protocol\\darkplaces 3\\protocols\\DP7\\challenge\\"+chal+b"\\name\\dp7probe")
while True:
    try: d,_=s.recvfrom(65536)
    except socket.timeout: continue
    if d.startswith(b"\xff\xff\xff\xffaccept"): break
rel_out_seq=0; unrel_out_seq=0; rel_in_expect=0; relbuf=b""; pending=[]; awaiting=None
def send_rel(p): pending.append(p)
def pump_rel():                       # NQ reliable: one in flight, DATA|EOM, wait for ACK
    global awaiting
    if awaiting is None and pending: awaiting=pending.pop(0)
    if awaiting is not None:
        s.sendto(struct.pack(">II",0x00090000|(8+len(awaiting)),rel_out_seq)+awaiting,addr)
def send_unrel(p):
    global unrel_out_seq
    s.sendto(struct.pack(">II",0x00100000|(8+len(p)),unrel_out_seq)+p,addr); unrel_out_seq+=1
class R:
    def __init__(s,b): s.b=b; s.i=0
    def byte(s): v=s.b[s.i]; s.i+=1; return v
    def char(s): v=struct.unpack_from("<b",s.b,s.i)[0]; s.i+=1; return v
    def short(s): v=struct.unpack_from("<h",s.b,s.i)[0]; s.i+=2; return v
    def ushort(s): v=struct.unpack_from("<H",s.b,s.i)[0]; s.i+=2; return v
    def long(s): v=struct.unpack_from("<i",s.b,s.i)[0]; s.i+=4; return v
    def float(s): v=struct.unpack_from("<f",s.b,s.i)[0]; s.i+=4; return v
    def string(s):
        j=s.b.index(b"\0",s.i); v=s.b[s.i:j].decode('latin1'); s.i=j+1; return v
    def coord(s): return s.float()                      # DP7: float coords
    def angle(s): return s.ushort()*360/65536           # DP7: 16-bit angles
    def vec(s): return (s.coord(),s.coord(),s.coord())
hist=collections.Counter(); te_hist=collections.Counter(); ents={}; stats={}
signon=0; viewent=0; frames=[]; servermoveseq=0; svtime=0.0; prints=[]
def e5(r,st):                                           # cl_ents5.c EntityState5_ReadUpdate
    bits=r.byte()
    if bits&0x80:
        bits|=r.byte()<<8
        if bits&0x8000:
            bits|=r.byte()<<16
            if bits&0x800000: bits|=r.byte()<<24
    if bits&1: st.clear(); st.update(alpha=255,scale=16)                  # FULLUPDATE
    if bits&(1<<8): st['flags']=r.byte()
    if bits&(1<<1): st['origin']=r.vec() if bits&(1<<11) else tuple(r.short()/8 for _ in range(3))
    if bits&(1<<2): st['angles']=tuple(r.angle() for _ in range(3)) if bits&(1<<12) else tuple(r.byte()*360/256 for _ in range(3))
    if bits&(1<<3): st['model']=r.ushort() if bits&(1<<13) else r.byte()
    if bits&(1<<4): st['frame']=r.ushort() if bits&(1<<21) else r.byte()
    if bits&(1<<5): st['skin']=r.byte()
    if bits&(1<<6): st['effects']=r.long() if bits&(1<<20) else (r.ushort() if bits&(1<<19) else r.byte())
    if bits&(1<<9): st['alpha']=r.byte()
    if bits&(1<<10): st['scale']=r.byte()
    if bits&(1<<14): st['colormap']=r.byte()
    if bits&(1<<16): st['tag']=(r.ushort(),r.byte())
    if bits&(1<<17): st['light']=[r.ushort() for _ in range(4)]+[r.byte(),r.byte()]
    if bits&(1<<18): st['glow']=(r.byte(),r.byte())
    if bits&(1<<22): st['colormod']=(r.byte(),r.byte(),r.byte())
    if bits&(1<<23): st['glowmod']=(r.byte(),r.byte(),r.byte())
    if bits&(1<<24): raise Exception("E5_COMPLEXANIMATION seen")
    if bits&(1<<25): st['trail']=r.ushort()
    return bits
e5bits=collections.Counter()
def parse(b):
    global signon,viewent,servermoveseq,svtime
    r=R(b)
    while r.i<len(b):
        c=r.byte(); hist[c]+=1
        if c==1: pass
        elif c==2: print("svc_disconnect"); sys.exit(0)
        elif c==3: i=r.byte(); stats[i]=r.long()
        elif c==51: i=r.byte(); stats[i]=r.byte()
        elif c==5: viewent=r.ushort()
        elif c==6:                                                         # svc_sound (DP bits)
            m=r.byte()
            if m&1: r.byte()
            if m&2: r.byte()
            if m&32: r.ushort()
            if m&8: r.ushort(); r.byte()
            else: r.ushort()
            r.ushort() if m&16 else r.byte(); r.vec()
        elif c==7: svtime=r.float()
        elif c==8: prints.append(r.string())
        elif c==9: prints.append("stuff:"+r.string())
        elif c==10: r.angle();r.angle();r.angle()
        elif c==11:
            r.long(); r.byte(); r.byte(); r.string()
            while r.string(): pass
            while r.string(): pass
        elif c==12: r.byte(); r.string()
        elif c==13: r.byte(); r.string()
        elif c==14: r.byte(); r.short()
        elif c==15:                                                        # DP7 clientdata
            bits=r.ushort()
            if bits&0x8000: bits|=r.byte()<<16
            if bits&0x800000: bits|=r.byte()<<24
            if bits&1: r.char()
            if bits&2: r.char()
            for k in range(3):
                if bits&(4<<k): r.short()              # punchangle, angle16
                if bits&(0x10000<<k): r.float()        # punchvector
                if bits&(32<<k): r.float()             # velocity
            if bits&(1<<9): r.long()                   # items
            if bits&(1<<19): r.ushort()                # viewzoom
        elif c==16: r.ushort()
        elif c==17: r.byte(); r.byte()
        elif c==18: r.vec(); r.char();r.char();r.char(); r.byte(); r.byte()
        elif c==19: r.byte(); r.byte(); r.vec()
        elif c==20 or c==56:
            if c==56: r.ushort(); r.ushort()
            else: r.byte(); r.byte()
            r.byte(); r.byte()
            for k in range(3): r.coord(); r.angle()
        elif c==22 or c==55:
            r.ushort()
            if c==55: r.ushort(); r.ushort()
            else: r.byte(); r.byte()
            r.byte(); r.byte()
            for k in range(3): r.coord(); r.angle()
        elif c==23:
            t=r.byte(); te_hist[t]+=1
            if t in (0,1,2,3,4,7,8,10,11,57,58,59,70,72,75): r.vec()
            elif t in (5,6,9,13): r.ushort(); r.vec(); r.vec()
            elif t==12: r.vec(); r.byte(); r.byte()
            elif t in (50,51): r.vec(); r.char();r.char();r.char(); r.byte()
            else: raise Exception("TE %d unhandled"%t)
        elif c==25:
            signon=r.byte(); print("signonnum",signon)
            if signon==1: send_rel(b"\x04prespawn\0")
            elif signon==2: send_rel(b"\x04name dp7probe\0"+b"\x04color 4 4\0"+b"\x04spawn \0")
            elif signon==3: send_rel(b"\x04begin\0")
        elif c==26: r.string()
        elif c==27 or c==28: pass
        elif c==29: r.vec(); r.byte(); r.byte(); r.byte()
        elif c==59: r.vec(); r.ushort(); r.byte(); r.byte()
        elif c==30: pass
        elif c==32: r.byte(); r.byte()
        elif c==52: r.vec(); r.byte(); r.byte(); r.byte(); r.byte()
        elif c==53: r.vec(); r.ushort(); r.ushort(); r.byte(); r.byte()
        elif c==54: r.ushort(); r.string()
        elif c==57:                                                        # svc_entities (E5)
            fn=r.long(); servermoveseq=r.long(); frames.append(fn)
            while True:
                n=r.ushort()
                if n==0x8000: break
                num=n&0x7fff
                if n&0x8000: ents.pop(num,None); continue
                st=ents.setdefault(num,{}); e5bits[e5(r,st)]+=1
        elif c==60: r.ushort(); r.ushort(); r.vec(); r.vec()
        elif c==61: r.ushort(); r.vec(); r.vec(); r.ushort()
        elif c==62: r.ushort(); r.vec()
        else: raise Exception("unhandled svc %d at %d"%(c,r.i))
t0=time.time(); last_move=0; origins=[]
while time.time()-t0<dur:
    pump_rel()
    try:
        d,_=s.recvfrom(65536)
        hdr,seq=struct.unpack(">II",d[:8]); fl=hdr&0xffff0000
        if fl&0x00020000:
            if awaiting is not None and seq==rel_out_seq: awaiting=None; rel_out_seq+=1
        elif fl&0x00010000:
            s.sendto(struct.pack(">II",0x00020000|8,seq),addr)
            if seq==rel_in_expect:
                rel_in_expect+=1; relbuf+=d[8:]
                if fl&0x00080000: parse(relbuf); relbuf=b""
        elif fl&0x00100000: parse(d[8:])
    except socket.timeout: pass
    if signon>=3 and time.time()-last_move>0.03:                         # DP7 clc_move, 56 bytes
        last_move=time.time(); el=time.time()-t0
        fwd=200 if el>dur*0.3 else 0; buttons=1 if el>dur*0.6 else 0     # walk, then fire
        mv=b"\x03"+struct.pack("<if",0,svtime)+struct.pack("<hhh",0,int(90*65536/360)&0x7fff,0)
        mv+=struct.pack("<hhh",fwd,0,0)+struct.pack("<iB",buttons,0)+struct.pack("<hhffffffh",0,0,0,0,0,0,0,0,0)
        acks=b"".join(b"\x32"+struct.pack("<i",f) for f in frames[-3:]); frames.clear()   # clc_ackframe
        send_unrel(mv+acks)
    if viewent in ents and 'origin' in ents[viewent]: origins.append((round(time.time()-t0,2),ents[viewent]['origin']))
send_unrel(b"\x02")                                                      # clc_disconnect
print("viewent",viewent,"ents tracked",len(ents))
print("svc histogram",dict(sorted(hist.items())))
print("temp ents",dict(te_hist))
print("stats",{k:v for k,v in sorted(stats.items())})
print("player origin first/mid/last",origins[0] if origins else None,origins[len(origins)//2] if origins else None,origins[-1] if origins else None)
```

Sample output, local DP `10d4863`, dm1, 10 s:
`svc histogram {1:1, 3:28, 5:1, 6:9, 7:713, 8:3, 9:2, 10:2, 11:1, 12:13, 13:2, 14:1, 15:713, 17:2, 20:31, 23:48, 25:3, 29:32, 32:1, 51:64, 57:220}`,
`temp ents {2: 48}`, stats `6 (shells)=17` (an id1 DM spawn gives 25), server log
`dp7probe entered the game`.
