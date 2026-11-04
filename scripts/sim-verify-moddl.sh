#!/usr/bin/env bash
#
# sim-verify-moddl.sh — MOD-DL (overlay 0034): joining a MOD server whose
# models the client lacks downloads the content, installs it as a mod folder,
# switches to it and rejoins.
#
# WHAT THIS PROVES, end to end, on the iPhone Air simulator against real vkQuake
# dedicated servers running a real mod's progs ("qdlmod" = Copper 1.30 under a
# name nobody knows — see scripts/moddl-fixture/build-fixture.sh):
#   a. SERVER URL: a server advertising sv_dlURL (read via getstatus) gets every
#      missing file fetched from <url>/<gamedir>/<path>; a garbage file is
#      rejected by magic number and skipped; the client switches to the mod
#      folder and is IN the game (asked of the server)
#   b. LOCAL SWITCH: back in id1, rejoining the same server switches to the
#      already-installed mod folder with no download
#   c. CURATED TABLE, tampered package: the live table is fetched, Copper is
#      matched by its file list, and a package whose sha256 is wrong is refused
#   d. CURATED TABLE, fixed: the table is corrected on the "repository" side (no
#      app change) and the next join downloads, verifies, installs and plays
#   e. cl_mapdownload 0 leaves the old failure, naming the mod
#   f. BUNDLED TABLE + REAL HOST: the live table is unreachable, the copy in the
#      app bundle is used, and Copper comes from www.quaddicted.com over TLS
#   h. NO GAMEDIR: a server advertising sv_dlURL while running the mod as "id1"
#      is NOT trusted to write into id1 — the client goes to the curated table,
#      which names its own folder (copper); the server URL is never fetched
#   i. UNPACK CAP: a correctly-pinned zip that downloads under
#      cl_mapdownload_maxpkg but unpacks to more than 4x it is refused before
#      anything is extracted
#   g. (VKQ_MODDL_LIVE=1) a REAL public mod server: NetQuake.io Team Fortress,
#      FortressOne assets from GitHub + the map from maps.quakeworld.nu; on a map
#      whose entities need a model the pak lacks (2nuke2 -> progs/tpad.mdl) the pak
#      and that loose-file entry are combined into one plan; a map change that
#      needs more content gets a fresh attempt instead of "not retrying"
#  g2. (live) lose that loose model and rejoin: the retry guard is keyed on the
#      missing SET, so the same server gets a 1-file plan, not a refusal
#   j. (live) a DarkPlaces protocol 7 server (overlay 0036): joined, signon 4, no
#      stack trace / Host_Error / DP7 parse abort, no "Unknown command
#      cl_serverextension_download" (before 0036 this leg proved a clean refusal)
#   k. (overlay 0038) a consent prompt the player left via the main menu does not
#      block the next join: same server -> a fresh plan; togglemenu + another
#      server -> the stale plan is abandoned and the new one starts (never "a
#      download is already in progress"). (live) the same with a real TF plan
#      followed by a Copper fixture server.
#   l. (0038) after a moddl LOCAL switch to a mod, joining an id1 server switches
#      back to id1 and joins; going back to the mod server switches again
#   m. (0038) the loading plaque is down behind the consent prompt (plaque=0) and the menu after declining is DRAWN (frames
#      change), not frozen behind the loading plaque Host_Connect_f raised
#   n. (live, 0038) FTE hipnotic server 192.99.32.215:27501 from id1 -> local
#      switch to hipnotic and in the game; then q1.pieter.com:27500 -> back to
#      id1 and in the game, fullserverinfo applied (no "Unknown command"), no
#      "No route to host" from the LAN search
#
# LANE: iPhone Air on iOS 27.0 (lane 2 by default). Never simctl create. The
# device, the fixture HTTP server and every game server are shut down on every
# exit path, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999						# console bridge (8765-8769 are OTHER sessions' — never use them)
FIXPORT=18778					# fixture HTTP (mpdl uses 18777)
SRV_URL=26111					# qdlmod server that advertises sv_dlURL
SRV_TAB=26112					# qdlmod server with no URL (curated table legs)
SRV_BUN=26113					# qdlmod server for the bundled-table leg
SRV_WARM=26110					# plain id1 server: the warm-up join (see below)
SRV_NOGD=26114					# mod content in id1 + sv_dlURL: no usable gamedir (leg h)
SRV_BIG=26115					# qdlmod server, no URL: the oversized-zip leg (i)
UDID=${VKQ_SIM_UDID:-45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22} # iPhone Air, iOS 27.0 (lane 2)
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ORACLE="$ROOT/build/oracle/vkquake"
FIX="$ROOT/tmp/moddl-fixture"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-moddl"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
[ -x "$ORACLE" ] || { echo "FATAL: oracle missing — ninja -C build/oracle" >&2; exit 1; }

FAILED=0
INTERRUPTED=0
PIDS=()
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	set +e
	for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
	pkill -f "vkquake -dedicated .*moddl-fixture" 2>/dev/null
	pkill -f "http.server $FIXPORT" 2>/dev/null
	pkill -f "moddl-fixture/srvcmd" 2>/dev/null
	# terminate only if running: terminating a NOT-running app has wedged
	# CoreSimulator before (STATUS 2026-11-03); shutdown clears everything anyway.
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	timeout 60 xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$INTERRUPTED" != 0 ]; then
		echo "MODDL VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "MODDL VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "MODDL VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

for p in $PORT $FIXPORT; do
	if nc -z -G 1 127.0.0.1 $p 2>/dev/null; then
		echo "FATAL: port $p already in use — another session owns it" >&2; exit 1
	fi
done

# ---------------------------------------------------------------------------
# fixture + servers
# ---------------------------------------------------------------------------
echo "== building the fixture"
"$ROOT/scripts/moddl-fixture/build-fixture.sh" $FIXPORT

echo "== fixture HTTP on 127.0.0.1:$FIXPORT"
python3 -m http.server $FIXPORT --bind 127.0.0.1 --directory "$FIX/www" > "$FIX/fixture.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 20); do nc -z -G 1 127.0.0.1 $FIXPORT 2>/dev/null && break; sleep 0.5; done
curl -sf -o /dev/null "http://127.0.0.1:$FIXPORT/dl/qdlmod/progs/v_axe2.mdl" || die "fixture does not serve the server download tree"
pass "fixture serves the server download tree, the packages and the tables"

# start_server <port> <tag>: a dedicated vkQuake running the fake mod on e1m1
start_server () {
	local port=$1 tag=$2
	: > "$FIX/srvcmd-$tag"
	mkdir -p "$FIX/serveruser-$tag"
	( tail -n +1 -f "$FIX/srvcmd-$tag" | script -q /dev/null "$ORACLE" -dedicated 4 \
		-basedir "$FIX/server" -userdir "$FIX/serveruser-$tag" -game qdlmod -port $port +map e1m1 \
		> "$FIX/server-$tag.log" 2>&1 ) &
	PIDS+=($!)
}
# One command per write, a beat apart: the dedicated console's stdin reader
# glues lines that arrive in one read ("statussv_gravity").
srv () { printf '%s\n' "$2" >> "$FIX/srvcmd-$1"; sleep 1; }
srvmark () { wc -l < "$FIX/server-$1.log" | tr -d ' '; }
srv_has_player () { # srv_has_player <tag> <since-line>
	local tag=$1 from=$2 i
	for i in $(seq 1 20); do
		srv "$tag" "status"
		tail -n +"$from" "$FIX/server-$tag.log" 2>/dev/null | grep -q 'players: 1 active' && return 0
		sleep 1
	done
	return 1
}
start_server $SRV_URL url
# the warm-up server runs id1, no mod
: > "$FIX/srvcmd-warm"; mkdir -p "$FIX/serveruser-warm"
( tail -n +1 -f "$FIX/srvcmd-warm" | script -q /dev/null "$ORACLE" -dedicated 4 \
	-basedir "$FIX/server" -userdir "$FIX/serveruser-warm" -port $SRV_WARM +map e1m1 \
	> "$FIX/server-warm.log" 2>&1 ) &
PIDS+=($!)
start_server $SRV_TAB tab
start_server $SRV_BUN bun
start_server $SRV_BIG big
# the no-gamedir server: Copper's content as id1/pak1.pak, no -game
: > "$FIX/srvcmd-nogd"; mkdir -p "$FIX/serveruser-nogd"
( tail -n +1 -f "$FIX/srvcmd-nogd" | script -q /dev/null "$ORACLE" -dedicated 4 \
	-basedir "$FIX/server-nogd" -userdir "$FIX/serveruser-nogd" -port $SRV_NOGD +map e1m1 \
	> "$FIX/server-nogd.log" 2>&1 ) &
PIDS+=($!)
for tag in url tab bun big nogd; do
	for _ in $(seq 1 40); do grep -q "UDP4 Initialized" "$FIX/server-$tag.log" 2>/dev/null && break; sleep 1; done
	sleep 3
	srv $tag "sv_public -1"   # answer getstatus, never heartbeat to the masters
done
srv url 'sv_dlURL "http://127.0.0.1:'$FIXPORT'/dl/"'
srv nogd 'sv_dlURL "http://127.0.0.1:'$FIXPORT'/nogd/"'
st=$(python3 -I - $SRV_URL <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(b"\xff\xff\xff\xffgetstatus t", ("127.0.0.1", int(sys.argv[1])))
print(s.recvfrom(4096)[0].decode("latin1"))
PY
) || die "the sv_dlURL server does not answer getstatus"
echo "$st" | grep -q 'sv_dlURL\\http://127.0.0.1' || die "getstatus does not carry sv_dlURL: $st"
echo "$st" | grep -q 'modname\\qdlmod' || die "getstatus does not carry modname qdlmod"
pass "three qdlmod servers up; :$SRV_URL advertises sv_dlURL in its status reply"
st=$(python3 -I - $SRV_NOGD <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(b"\xff\xff\xff\xffgetstatus t", ("127.0.0.1", int(sys.argv[1])))
print(s.recvfrom(4096)[0].decode("latin1"))
PY
) || die "the no-gamedir server does not answer getstatus"
echo "$st" | grep -q 'sv_dlURL\\http://127.0.0.1' || die "no-gamedir server: getstatus does not carry sv_dlURL: $st"
echo "$st" | grep -q 'modname\\qdlmod' && die "no-gamedir server reports a mod folder: $st"
pass "no-gamedir server :$SRV_NOGD up: sv_dlURL advertised, game is id1"

# ---------------------------------------------------------------------------
# simulator
# ---------------------------------------------------------------------------
for _ in $(seq 1 60); do
	state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	case "$state" in Shutdown | Booted) break ;; esac
	echo "   waiting for $UDID to settle (${state:-unknown})"; sleep 2
done
xcrun simctl bootstatus "$UDID" -b >/dev/null
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; then
	timeout 60 xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
fi
echo "== install"
xcrun simctl install "$UDID" "$APP"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
BASE="$DOCS/rerelease"
GAMEDIR="$BASE/id1"
mkdir -p "$GAMEDIR"
[ -f "$GAMEDIR/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$GAMEDIR/pak0.pak"
rm -rf "$BASE/qdlmod" "$BASE/copper" "$BASE/fortress" "$BASE/.moddl" "$DOCS/console.log" \
	"$CONT/Library/Caches/mod-sources.json" "$CONT/Library/Caches/mod-sources.json.part"

cat > "$GAMEDIR/autoexec.cfg" <<CFG
r_indirect 0
volume 0
bgmvolume 0
cl_mapdownload_allowhttp 1
cl_mapdownload_bspurl "http://127.0.0.1:$FIXPORT/all/"
cl_moddownload_tableurl "http://127.0.0.1:$FIXPORT/table/mod-sources.json"
cl_mapdownload 1
CFG

echo "== launch"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
	xcrun simctl launch "$UDID" $BUNDLE
ok=0
for _ in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened"
LOG="$DOCS/console.log"
pass "boot smoke: the app is up and the bridge answers"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
waitlog () { # waitlog <regex> <seconds> [<since-line>]
	local re="$1" secs="$2" from="${3:-1}" i
	for i in $(seq 1 "$secs"); do
		tail -n +"$from" "$LOG" 2>/dev/null | grep -Eq "$re" && return 0
		sleep 1
	done
	return 1
}
mark () { wc -l < "$LOG" | tr -d ' '; }
shot () { xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-$1.png" || echo "   (screenshot unavailable)"; }
# live_frames <tag>: four screenshots in a row; PASS when they are not all the
# same image. A screen frozen behind the loading plaque presents nothing new; a
# live menu blinks its cursor (2-4 Hz) and the shots land at varying phases.
live_frames () {
	local tag=$1 i
	for i in 1 2 3 4; do xcrun simctl io "$UDID" screenshot "$PFX-$tag-$i.png" >/dev/null 2>&1; done
	python3 -I - "$PFX-$tag-1.png" "$PFX-$tag-2.png" "$PFX-$tag-3.png" "$PFX-$tag-4.png" <<'PY'
import sys
from PIL import Image, ImageChops
ims = [Image.open(p).convert("RGB") for p in sys.argv[1:]]
diffs = [ImageChops.difference(ims[0], im).getbbox() for im in ims[1:]]
print("   frames: " + ", ".join("differs %s" % (d,) if d else "same" for d in diffs))
sys.exit(0 if any(diffs) else 1)
PY
}
showtail () { tail -n +"$1" "$LOG" | grep -E 'moddl|mapdl|which you do not have|belongs to' | tail -"${2:-8}" >&2 || true; }
back_to_id1 () {
	say 'disconnect'; sleep 2
	local M; M=$(mark)
	say 'game id1'
	waitlog '"game" changed to "id1"|"game" is already "id1"' 30 "$M" || fail "could not switch the client back to id1"
	sleep 3
}

sleep 8

# WARM-UP. On the iOS 27 simulator (2026-11-03) the first joins to a server on
# THIS Mac after an app launch can stall: "trying..." for 25-45 s, "Connection
# accepted", then the reliable serverinfo never arrives and the loading plaque
# times out ("load failed"); connects print "UDP_Write, sendto: No route to host"
# meanwhile. Internet servers join instantly, and once one local join has
# succeeded every later one does. Reproduced with the pre-0034 build too, so it
# is the simulator's local-network path, not this feature — but it would fail
# every leg below, so the run first joins a plain id1 server until it works.
warm=0
for attempt in 1 2 3 4 5 6 7 8; do
	say 'disconnect'; sleep 2
	M=$(mark)
	say "connect 127.0.0.1:$SRV_WARM"
	for _ in $(seq 1 75); do
		tail -n +"$M" "$LOG" | grep -aq 'Using protocol\|load failed' && break
		sleep 1
	done
	if tail -n +"$M" "$LOG" | grep -aq 'Using protocol'; then warm=1; break; fi
	echo "   warm-up join $attempt stalled (simulator local-network quirk); retrying"
done
[ "$warm" = 1 ] && pass "warm-up: a local join works (after $attempt attempt(s))" || die "no local join ever succeeded — the simulator cannot reach this Mac's servers"
say 'disconnect'; sleep 2

say 'cl_moddownload_tableurl'; sleep 2
grep -q "\"cl_moddownload_tableurl\" is \"http://127.0.0.1:$FIXPORT/table/mod-sources.json\"" "$LOG" \
	&& pass "the fixture autoexec reached the engine" || fail "cl_moddownload_tableurl did not read back — autoexec not applied"

# ===========================================================================
echo
echo "== (a) server-advertised URL: per-file download, garbage rejected, mod switch, in game"
# ===========================================================================
M=$(mark)
say "connect 127.0.0.1:$SRV_URL"
waitlog 'moddl: server advertises a download URL \(http://127\.0\.0\.1:'$FIXPORT'/dl/\)' 30 "$M" \
	&& pass "(a) the status query found sv_dlURL" || { fail "(a) the server URL was not picked up"; showtail "$M"; }
waitlog 'moddl: server URL layout: <url>/<gamedir>/<path>' 30 "$M" \
	&& pass "(a) FTE's <url>/<gamedir>/<path> layout answered" || fail "(a) layout not decided"
if waitlog 'moddl: plan — [0-9]+ item\(s\), [0-9]+ bytes, from 127\.0\.0\.1:'$FIXPORT', into qdlmod' 60 "$M"; then
	pass "(a) $(tail -n +"$M" "$LOG" | grep -Eo 'plan — [0-9]+ item\(s\), [0-9]+ bytes' | tail -1) planned into qdlmod"
else
	fail "(a) no plan"; showtail "$M"
fi
say 'moddl_status'; sleep 2
tail -n +"$M" "$LOG" | grep -q 'moddl status: state=prompt' && pass "(a) waiting for consent" || fail "(a) not in the prompt state"
sleep 1; shot 01-a-server-url-prompt
SM=$(srvmark url)
say 'moddl_accept'
waitlog 'moddl: rejected sound/items/patch\.wav .*not a valid \.wav' 60 "$M" \
	&& pass "(a) the garbage .wav was rejected by magic number and skipped" || fail "(a) the bad file was not rejected"
waitlog 'moddl: switching to game "qdlmod" to rejoin' 60 "$M" \
	&& pass "(a) installed; switching to the mod folder" || { fail "(a) never reached the rejoin"; showtail "$M"; }
[ -f "$BASE/qdlmod/progs/v_axe2.mdl" ] && pass "(a) Documents/rerelease/qdlmod/progs/v_axe2.mdl installed" || fail "(a) v_axe2.mdl not installed"
[ -e "$BASE/qdlmod/sound/items/patch.wav" ] && fail "(a) the garbage patch.wav was installed" || pass "(a) the garbage file is not on disk"
[ -d "$BASE/.moddl" ] && fail "(a) staging dir left behind" || pass "(a) staging dir cleaned up"
sleep 10
if srv_has_player url "$SM"; then pass "(a) the qdlmod server sees one active player — IN the game"; else fail "(a) the server never saw the client join"; fi
sleep 2; shot 02-a-in-game-qdlmod

# ===========================================================================
echo
echo "== (b) back in id1, same server -> switch to the installed mod, no download"
# ===========================================================================
back_to_id1
M=$(mark); SM=$(srvmark url)
say "connect 127.0.0.1:$SRV_URL"
waitlog 'moddl: you already have "qdlmod" — switching to it and rejoining' 30 "$M" \
	&& pass "(b) local switch, no download" || { fail "(b) no local switch"; showtail "$M"; }
tail -n +"$M" "$LOG" | grep -q 'moddl: downloading' && fail "(b) it downloaded anyway" || true
sleep 10
if srv_has_player url "$SM"; then pass "(b) rejoined via the local mod folder"; else fail "(b) did not rejoin"; fi
shot 03-b-local-switch

# ===========================================================================
echo
echo "== (c) curated table, tampered package -> sha256 refused"
# ===========================================================================
back_to_id1
rm -rf "$BASE/qdlmod"
M=$(mark)
say "connect 127.0.0.1:$SRV_TAB"
waitlog 'moddl: server reports mod "qdlmod"|moddl: [0-9]+ model\(s\) missing for qdlmod' 30 "$M" && pass "(c) the server's mod name is known" || true
waitlog 'moddl: mod table refreshed' 40 "$M" && pass "(c) the live table was fetched" || { fail "(c) table not fetched"; showtail "$M"; }
waitlog 'moddl: downloaded table matched "Copper 1\.30" by files' 40 "$M" \
	&& pass "(c) Copper matched by its file list (the real table's list covers Copper's real precaches)" || { fail "(c) no table match"; showtail "$M"; }
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes, from 127\.0\.0\.1:'$FIXPORT', into copper' 40 "$M" \
	&& pass "(c) one package, 5197459 bytes, into copper" || { fail "(c) unexpected plan"; showtail "$M"; }
shot 04-c-table-prompt
say 'moddl_accept'
waitlog 'moddl: FAILED — package sha256 mismatch' 60 "$M" && pass "(c) the tampered package was refused" || { fail "(c) sha mismatch not caught"; showtail "$M"; }
[ -e "$BASE/copper/pak0.pak" ] && fail "(c) the tampered pak was installed" || pass "(c) nothing installed"
alive || die "(c) the app stopped answering"
sleep 1; shot 05-c-sha-refused
say 'moddl_cancel'; sleep 2

# ===========================================================================
echo
echo "== (d) the table is fixed on the server side -> download, verify, install, play"
# ===========================================================================
cp "$FIX/www/table/good.json" "$FIX/www/table/mod-sources.json"
M=$(mark); SM=$(srvmark tab)
say "connect 127.0.0.1:$SRV_TAB"
waitlog 'moddl: mod table refreshed' 40 "$M" && pass "(d) the corrected table was fetched" || fail "(d) table not refetched"
waitlog 'moddl: plan — 1 item' 40 "$M" || { fail "(d) no plan"; showtail "$M"; }
say 'moddl_accept'
waitlog 'moddl: sha256 verified' 60 "$M" && pass "(d) package sha256 verified" || { fail "(d) sha not verified"; showtail "$M"; }
waitlog 'moddl: installed copper/pak0\.pak' 30 "$M" && pass "(d) installed Documents/rerelease/copper/pak0.pak" || fail "(d) pak not installed"
waitlog 'moddl: switching to game "copper" to rejoin' 30 "$M" && pass "(d) switching to copper" || fail "(d) no switch"
cmp -s "$BASE/copper/pak0.pak" "$FIX/server/qdlmod/pak0.pak" && pass "(d) the installed pak is byte-identical to Copper's" || fail "(d) installed pak differs"
ls "$BASE/copper" | grep -Eqv '^pak0\.pak$' && fail "(d) more than pak0.pak installed: $(ls "$BASE/copper" | tr '\n' ' ')" \
	|| pass "(d) ONLY pak0.pak installed (no progs.dat, quake.rc, csprogs.dat)"
sleep 10
if srv_has_player tab "$SM"; then pass "(d) in the game on the table-installed mod"; else fail "(d) did not rejoin"; fi
shot 06-d-in-game-copper

# ===========================================================================
echo
echo "== (e) cl_mapdownload 0 -> the old failure, naming the mod"
# ===========================================================================
back_to_id1
say 'cl_mapdownload 0'; sleep 1
M=$(mark)
say "connect 127.0.0.1:$SRV_BUN"
waitlog 'moddl: cl_mapdownload is 0' 30 "$M" && pass "(e) the downloader stood down" || fail "(e) cl_mapdownload 0 not honoured"
waitlog 'It belongs to the mod "qdlmod"' 20 "$M" && pass "(e) the failure names the mod (a model, not the map)" || { fail "(e) message missing"; showtail "$M"; }
alive || die "(e) the app stopped answering"
sleep 1; shot 07-e-off

# ===========================================================================
echo
echo "== (h) sv_dlURL but no mod folder named -> nothing goes into id1; the table is used"
# ===========================================================================
say 'cl_mapdownload 1'; sleep 1
rm -rf "$BASE/copper"
M=$(mark); FM=$(wc -l < "$FIX/fixture.log" | tr -d ' ')
say "connect 127.0.0.1:$SRV_NOGD"
waitlog 'moddl: the server advertises a download URL but names no mod folder; not installing into id1, trying the mod table' 40 "$M" \
	&& pass "(h) the gamedir-less server URL was refused for id1" || { fail "(h) the server URL was not refused"; showtail "$M"; }
waitlog 'moddl: (downloaded|bundled) table matched "Copper 1\.30" by files' 40 "$M" \
	&& pass "(h) fell through to the table (Copper matched by files)" || { fail "(h) no table match"; showtail "$M"; }
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes, from 127\.0\.0\.1:'$FIXPORT', into copper' 40 "$M" \
	&& pass "(h) planned into copper, not id1" || { fail "(h) unexpected plan"; showtail "$M"; }
tail -n +"$((FM + 1))" "$FIX/fixture.log" | grep -q '/nogd/' && fail "(h) the client fetched from the server URL" || pass "(h) nothing was requested from the server URL"
[ -e "$GAMEDIR/progs/v_axe2.mdl" ] && fail "(h) mod files were written into id1" || pass "(h) id1 untouched"
sleep 1; shot 08h-nogd-table-prompt
say 'moddl_cancel'; sleep 2

# ===========================================================================
echo
echo "== (i) a correctly-pinned zip that unpacks past 4x cl_mapdownload_maxpkg -> refused"
# ===========================================================================
cp "$FIX/www/table/big.json" "$FIX/www/table/mod-sources.json"
say 'cl_mapdownload_maxpkg 6'; sleep 1
M=$(mark)
say "connect 127.0.0.1:$SRV_BIG"
waitlog 'moddl: plan — 1 item\(s\), 5242799 bytes, from 127\.0\.0\.1:'$FIXPORT', into copper' 40 "$M" \
	&& pass "(i) the padded package is planned (5242799 bytes, under the 6 MB download limit)" || { fail "(i) unexpected plan"; showtail "$M"; }
say 'moddl_accept'
waitlog 'moddl: sha256 verified' 60 "$M" && pass "(i) the padded package matches its pin" || { fail "(i) sha not verified"; showtail "$M"; }
waitlog 'moddl: FAILED — the package unpacks to more than the 24 MB limit' 60 "$M" \
	&& pass "(i) refused: unpacks past 4 x 6 MB" || { fail "(i) the oversized zip was not refused"; showtail "$M"; }
find "$BASE/copper" -type f 2>/dev/null | grep -q . && fail "(i) something was installed: $(find "$BASE/copper" -type f | head -3 | tr '\n' ' ')" || pass "(i) nothing installed"
[ -d "$BASE/.moddl" ] && fail "(i) staging dir left behind" || pass "(i) staging dir cleaned up"
alive || die "(i) the app stopped answering"
sleep 1; shot 08i-unpack-cap-refused
say 'moddl_cancel'; sleep 2
say 'cl_mapdownload_maxpkg 512'
cp "$FIX/www/table/good.json" "$FIX/www/table/mod-sources.json"
say 'disconnect'; sleep 2

# ===========================================================================
echo
echo "== (f) bundled table + the REAL host: Copper from www.quaddicted.com over TLS"
# ===========================================================================
rm -rf "$BASE/copper"
# first-run conditions: no cached copy of the live table (leg d cached the
# fixture's), so the only table left is the one in the app bundle
rm -f "$CONT/Library/Caches/mod-sources.json"
say 'cl_mapdownload 2'
say "cl_moddownload_tableurl \"http://127.0.0.1:$FIXPORT/table/none.json\""
sleep 1
M=$(mark); SM=$(srvmark bun)
say "connect 127.0.0.1:$SRV_BUN"
waitlog 'moddl: mod table refresh failed' 40 "$M" && pass "(f) the live table is unreachable (404)" || fail "(f) expected a refresh failure"
waitlog 'moddl: bundled table matched "Copper 1\.30" by files' 40 "$M" && pass "(f) the BUNDLED table answered" || { fail "(f) bundled table not used"; showtail "$M"; }
waitlog 'moddl: downloading https://www\.quaddicted\.com/files/by-sha256/' 30 "$M" && pass "(f) cl_mapdownload 2 accepted without a prompt; fetching from quaddicted.com" || fail "(f) no real download"
waitlog 'moddl: sha256 verified' 180 "$M" && pass "(f) the real package hashed to the pinned sha256" || { fail "(f) real download not verified"; showtail "$M"; }
waitlog 'moddl: switching to game "copper"' 30 "$M" || fail "(f) no switch"
sleep 10
if srv_has_player bun "$SM"; then pass "(f) in the game on content from the real host"; else fail "(f) did not rejoin"; fi
shot 08-f-real-host


# ===========================================================================
echo
echo "== (k) a consent prompt left via the main menu does not block the next one (0038)"
# ===========================================================================
back_to_id1
rm -rf "$BASE/copper" "$BASE/qdlmod"
say 'cl_mapdownload 1'
say "cl_moddownload_tableurl \"http://127.0.0.1:$FIXPORT/table/mod-sources.json\""
sleep 1
M=$(mark)
say "connect 127.0.0.1:$SRV_NOGD"
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes, from 127\.0\.0\.1:'$FIXPORT', into copper' 40 "$M" \
	&& pass "(k) a Copper plan is waiting for consent" || { fail "(k) no plan"; showtail "$M"; }
say 'menu_main'; sleep 2
say 'moddl_status'; sleep 2
tail -n +"$M" "$LOG" | grep -q 'moddl status: state=prompt' && pass "(k) the player walked away: the prompt is unanswered, off screen" || fail "(k) not in the prompt state after menu_main"
M=$(mark)
say "connect 127.0.0.1:$SRV_NOGD"
waitlog 'moddl: abandoning the plan for 127\.0\.0\.1:'$SRV_NOGD' \(the prompt was left unanswered\)' 30 "$M" \
	&& pass "(k) same server: the unattended prompt was dropped" || { fail "(k) the stale prompt was not dropped"; showtail "$M"; }
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes' 40 "$M" && pass "(k) same server: a fresh plan started" || { fail "(k) no fresh plan"; showtail "$M"; }
tail -n +"$M" "$LOG" | grep -q 'already in progress' && fail "(k) \"a download is already in progress\"" || pass "(k) no \"already in progress\""
say 'togglemenu'; sleep 2
M=$(mark)
say "connect 127.0.0.1:$SRV_BIG"
waitlog 'moddl: abandoning the plan for 127\.0\.0\.1:'$SRV_NOGD' \(now joining 127\.0\.0\.1:'$SRV_BIG'\)' 30 "$M" \
	&& pass "(k) togglemenu + another server: the old plan was abandoned" || { fail "(k) old plan not abandoned"; showtail "$M"; }
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes, from 127\.0\.0\.1:'$FIXPORT', into copper' 40 "$M" \
	&& pass "(k) the new server's Copper plan started" || { fail "(k) no plan for the new server"; showtail "$M"; }
tail -n +"$M" "$LOG" | grep -q 'already in progress' && fail "(k) \"a download is already in progress\"" || pass "(k) no \"already in progress\""
shot 13-k-new-plan-after-abandon
say 'moddl_cancel'; sleep 2

# ===========================================================================
echo
echo "== (l) after a LOCAL switch to a mod, an id1 server switches back to id1 and joins (0038)"
# ===========================================================================
back_to_id1
mkdir -p "$BASE/qdlmod"
cp -c "$FIX/server/qdlmod/pak0.pak" "$BASE/qdlmod/pak0.pak"
M=$(mark); SM=$(srvmark tab)
say "connect 127.0.0.1:$SRV_TAB"
waitlog 'moddl: you already have "qdlmod" — switching to it and rejoining' 30 "$M" \
	&& pass "(l) local switch to qdlmod" || { fail "(l) no local switch"; showtail "$M"; }
sleep 10
if srv_has_player tab "$SM"; then pass "(l) in the game on qdlmod"; else fail "(l) did not join the qdlmod server"; fi
say 'moddl_status'; sleep 2
tail -n +"$M" "$LOG" | grep -q "moddl restore: game=id1 from=id1;qdlmod for=127.0.0.1:$SRV_TAB" \
	&& pass "(l) moddl recorded the switch (id1 -> id1;qdlmod for :$SRV_TAB)" || { fail "(l) restore record missing"; tail -n +"$M" "$LOG" | grep 'moddl restore' >&2 || true; }
M=$(mark); SM=$(srvmark warm)
say "connect 127.0.0.1:$SRV_WARM"
waitlog 'moddl: leaving "id1;qdlmod" \(switched for 127\.0\.0\.1:'$SRV_TAB'\); back to "id1" to join 127\.0\.0\.1:'$SRV_WARM 30 "$M" \
	&& pass "(l) joining the id1 server undoes moddl's switch" || { fail "(l) no switch back"; showtail "$M"; }
waitlog '"game" changed to "id1"' 30 "$M" && pass "(l) game is id1 again" || fail "(l) game not changed to id1"
sleep 8
if srv_has_player warm "$SM"; then pass "(l) in the game on the id1 server"; else fail "(l) the re-queued connect did not join"; fi
say 'game'; sleep 2
tail -n +"$M" "$LOG" | grep -q '"game" is "id1"' && pass "(l) \"game\" reads back id1" || fail "(l) game does not read back id1"
shot 14-l-reverted-in-game-id1
M=$(mark); SM=$(srvmark tab)
say "connect 127.0.0.1:$SRV_TAB"
waitlog 'moddl: you already have "qdlmod" — switching to it and rejoining' 30 "$M" \
	&& pass "(l) back to the mod server: switches to qdlmod again (not refused as already switched)" || { fail "(l) no second local switch"; showtail "$M"; }
sleep 10
if srv_has_player tab "$SM"; then pass "(l) in the game on qdlmod again"; else fail "(l) did not rejoin the qdlmod server"; fi

# ===========================================================================
echo
echo "== (m) a declined download leaves the menu DRAWN, not frozen behind the plaque (0038)"
# ===========================================================================
back_to_id1
rm -rf "$BASE/copper"
M=$(mark)
say "connect 127.0.0.1:$SRV_NOGD"
waitlog 'moddl: plan — 1 item\(s\), 5197459 bytes' 40 "$M" && pass "(m) a plan is offered" || { fail "(m) no plan"; showtail "$M"; }
sleep 2
# The engine's own answer first: is the loading plaque (which suppresses ALL
# drawing) still up while the prompt waits? Before 0038 it was, for 60 s.
PM=$(mark); say 'moddl_status'; sleep 2
tail -n +"$PM" "$LOG" | grep -q 'moddl restore: .* plaque=0' && pass "(m) the loading plaque is down while the prompt waits (plaque=0)" \
	|| { fail "(m) the loading plaque is still up behind the prompt"; tail -n +"$PM" "$LOG" | grep 'moddl restore' >&2 || true; }
# Frame change is informational here: the prompt's only animation is the row
# cursor, which is not drawn at all when the touch layer has no hovered row.
live_frames 15-m-prompt && echo "   note  (m) the prompt screen is animating" || echo "   note  (m) no animation on the prompt screen (no cursor drawn); see $PFX-15-m-prompt-1.png"
say 'moddl_cancel'; sleep 3
live_frames 16-m-declined-menu && pass "(m) after declining, the menu is being drawn" || fail "(m) the screen is frozen after declining"

# ===========================================================================
if [ "${VKQ_MODDL_LIVE:-0}" = 1 ]; then
echo
echo "== (g) LIVE: NetQuake.io Team Fortress (52.14.57.255:26023)"
# ===========================================================================
# The real sources from here on. Written into autoexec.cfg too, not just set:
# `game fortress` re-execs autoexec.cfg, which would otherwise put the fixture
# URLs back mid-leg (the first live run fetched the next map from the fixture).
#
# Which table: VKQ_MODDL_LIVE_TABLE=bundled (default) makes the live refresh 404
# so the copy IN THIS BUILD answers — the one that carries this branch's entries.
# =main fetches mods/mod-sources.json from GitHub main, as players do.
if [ "${VKQ_MODDL_LIVE_TABLE:-bundled}" = main ]; then
	LIVE_TABLE="https://raw.githubusercontent.com/rebelancap/vkQuake-ios/main/mods/mod-sources.json"
else
	LIVE_TABLE="https://raw.githubusercontent.com/rebelancap/vkQuake-ios/main/mods/no-such-table-harness.json"
fi
cat > "$GAMEDIR/autoexec.cfg" <<CFG
r_indirect 0
volume 0
bgmvolume 0
cl_mapdownload 1
cl_moddownload_tableurl "$LIVE_TABLE"
CFG
back_to_id1
rm -rf "$BASE/fortress"
rm -f "$CONT/Library/Caches/mod-sources.json" "$CONT/Library/Caches/mod-sources.json.part"
say 'cl_mapdownload 1'
say 'cl_mapdownload_allowhttp 0'
say 'cl_mapdownload_bspurl "https://maps.quakeworld.nu/all/"'
say "cl_moddownload_tableurl \"$LIVE_TABLE\""
sleep 2
tfmap () {
	python3 -I - <<'PY' 2>/dev/null || echo "?"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(b"\xff\xff\xff\xffgetstatus t", ("52.14.57.255", 26023))
kv = s.recvfrom(8192)[0].decode("latin1").split("\n")[1].split("\\")[1:]
print(dict(zip(kv[0::2], kv[1::2])).get("mapname", "?"))
PY
}
LMAP=$(tfmap)
echo "   the TF server is on: $LMAP"
if [ "$LMAP" = "?" ]; then
	fail "(g) the live TF server does not answer getstatus — it is down; leg (g) proves nothing"
else
echo
echo "== (k-live) a real TF plan left via togglemenu, then the Copper fixture server -> the Copper plan starts (0038)"
# qdlmod too: leg (l) left a local copy, and a local switch is not a plan
rm -rf "$BASE/fortress" "$BASE/copper" "$BASE/qdlmod"
M=$(mark)
say "connect 52.14.57.255:26023"
if waitlog 'moddl: plan — [0-9]+ item\(s\), [0-9]+ bytes, from github\.com( and more)?, into fortress' 90 "$M"; then
	pass "(k-live) a TF plan is waiting for consent"
	say 'togglemenu'; sleep 2
	M=$(mark)
	say "connect 127.0.0.1:$SRV_BIG"
	waitlog 'moddl: abandoning the plan for 52\.14\.57\.255:26023 \(now joining 127\.0\.0\.1:'$SRV_BIG'\)' 30 "$M" \
		&& pass "(k-live) the TF plan was abandoned" || { fail "(k-live) TF plan not abandoned"; showtail "$M" 12; }
	waitlog 'moddl: plan — [0-9]+ item\(s\), [0-9]+ bytes, from .*, into copper' 60 "$M" \
		&& pass "(k-live) the Copper plan started: $(tail -n +"$M" "$LOG" | grep -Eo 'plan — [0-9]+ item\(s\), [0-9]+ bytes, from [^,]*' | tail -1)" \
		|| { fail "(k-live) no Copper plan"; showtail "$M" 12; }
	tail -n +"$M" "$LOG" | grep -q 'already in progress' && fail "(k-live) \"a download is already in progress\"" || pass "(k-live) no \"already in progress\""
	shot 13b-k-live-copper-after-tf
	say 'moddl_cancel'; sleep 2
else
	fail "(k-live) no TF plan"; showtail "$M" 12
fi
back_to_id1
M=$(mark)
say "connect 52.14.57.255:26023"
waitlog 'moddl: (downloaded|bundled) table matched "Team Fortress \(FortressOne assets\)" by gamedir' 60 "$M" \
	&& pass "(g) TF matched on the server's gamedir ($(tail -n +"$M" "$LOG" | grep -Eo 'moddl: (downloaded|bundled) table' | tail -1))" || { fail "(g) no TF match"; showtail "$M" 12; }
# the maps whose entities need a model the FortressOne pak lacks (mod-sources.json)
case "$LMAP" in
	2nuke2) XMDL=tpad.mdl ;; 2tech3) XMDL=qpi.mdl ;; 2trench1) XMDL=ammopack.mdl ;; *) XMDL= ;;
esac
if [ -n "$XMDL" ]; then
	waitlog "moddl: (downloaded|bundled) table matched \"Team Fortress map model: ${XMDL//./\\.}\" by gamedir" 30 "$M" \
		&& pass "(g) $LMAP: the pak AND the loose $XMDL entry combined into one plan" || { fail "(g) $XMDL not planned with the pak"; showtail "$M" 12; }
fi
waitlog 'moddl: plan — [0-9]+ item\(s\), [0-9]+ bytes, from github\.com( and more)?, into fortress' 60 "$M" \
	&& pass "(g) one prompt: $(tail -n +"$M" "$LOG" | grep -Eo 'plan — [0-9]+ item\(s\), [0-9]+ bytes' | tail -1)" \
	|| { fail "(g) unexpected plan"; showtail "$M" 12; }
sleep 1; shot 09-g-live-tf-prompt
say 'moddl_accept'
waitlog 'moddl: installed fortress/pak0\.pak' 240 "$M" && pass "(g) FortressOne pak0.pak installed" || { fail "(g) pak not installed"; showtail "$M" 12; }
if [ -n "$XMDL" ]; then
	waitlog "moddl: installed fortress/progs/${XMDL//./\\.}" 60 "$M" && pass "(g) fortress/progs/$XMDL installed" || { fail "(g) $XMDL not installed"; showtail "$M" 12; }
fi
waitlog 'moddl: rejoining 52\.14\.57\.255:26023' 120 "$M" && pass "(g) rejoining the live server" || { fail "(g) no rejoin"; showtail "$M" 12; }
# A live server can change map under us (the first live run caught it moving on
# to a map with a model the pak lacks). A NEW missing set must get a fresh
# attempt now — accept it and rejoin again — instead of "not retrying".
ingame=0
# Start each round AT the rejoin line, not at "now": since 0038 skips the LAN
# search the rejoin can reach "Using protocol" within the same second as the
# "rejoining" line, and a mark taken after it missed the signon (false FAIL).
rejoin_line () { grep -n 'moddl: rejoining 52\.14\.57\.255:26023' "$LOG" | tail -1 | cut -d: -f1; }
RM0=$(rejoin_line)
for round in 1 2 3; do
	RM=${RM0:-$(mark)}; RM0=
	for _ in $(seq 1 90); do
		tail -n +"$RM" "$LOG" | grep -Eq 'Using protocol|moddl: plan —|moddl: FAILED|not retrying|Host_Error' && break
		sleep 1
	done
	sleep 5
	if tail -n +"$RM" "$LOG" | grep -q 'moddl: plan —'; then
		pass "(g) round $round: the server needs more content (map change?) — a fresh attempt was offered: $(tail -n +"$RM" "$LOG" | grep -Eo 'plan — [0-9]+ item\(s\), [0-9]+ bytes' | tail -1)"
		say 'moddl_accept'
		waitlog 'moddl: rejoining 52\.14\.57\.255:26023' 180 "$RM" || { fail "(g) round $round: no rejoin"; showtail "$RM" 12; break; }
		RM0=$(rejoin_line)
		continue
	fi
	if tail -n +"$RM" "$LOG" | grep -Eq 'which you do not have|moddl: FAILED|not retrying|Host_Error'; then
		fail "(g) the rejoin still failed:"; showtail "$RM" 12; break
	fi
	if tail -n +"$RM" "$LOG" | grep -q 'Using protocol'; then
		ingame=1; shot 10-g-live-tf-in-game
		pass "(g) signon completed on the live TF server with no missing content"
	else
		fail "(g) no signon after the rejoin"; showtail "$RM" 12
	fi
	break
done
[ -f "$BASE/fortress/maps/$LMAP.bsp" ] && pass "(g) maps/$LMAP.bsp installed with it" || echo "   note  (g) $LMAP.bsp not in fortress/maps (server may have changed map)"

echo
echo "== (g2) retry guard is keyed on the MISSING SET: lose one map model, rejoin -> a 1-file plan, not \"not retrying\""
GMDL=$(cd "$BASE/fortress/progs" 2>/dev/null && ls *.mdl 2>/dev/null | head -1 || true)
if [ "$ingame" = 1 ] && [ -n "$GMDL" ]; then
	say 'disconnect'; sleep 2
	rm -f "$BASE/fortress/progs/$GMDL"
	M=$(mark)
	say "connect 52.14.57.255:26023"
	waitlog "moddl: (downloaded|bundled) table matched \"Team Fortress map model: ${GMDL//./\\.}\" by gamedir" 60 "$M" \
		&& pass "(g2) a second attempt on the same server, for the new set: the loose $GMDL entry alone" \
		|| { fail "(g2) no second attempt"; showtail "$M" 12; }
	tail -n +"$M" "$LOG" | grep -q 'not retrying' && fail "(g2) the guard refused a different missing set" || true
	waitlog 'moddl: plan — 1 item\(s\), [0-9]+ bytes, from raw\.githubusercontent\.com, into fortress' 30 "$M" \
		&& pass "(g2) plan: 1 item from raw.githubusercontent.com" || { fail "(g2) unexpected plan"; showtail "$M" 12; }
	say 'moddl_accept'
	waitlog "moddl: installed fortress/progs/${GMDL//./\\.}" 60 "$M" && pass "(g2) $GMDL reinstalled (sha256-pinned, IDPO checked)" || { fail "(g2) not installed"; showtail "$M" 12; }
	RM=$(mark)
	waitlog 'Using protocol' 90 "$RM" && { sleep 5; tail -n +"$RM" "$LOG" | grep -Eq 'which you do not have|moddl: FAILED|Host_Error' \
		&& { fail "(g2) rejoin failed"; showtail "$RM" 12; } || { pass "(g2) back in the game"; shot 10b-g2-live-tf-rejoined; }; } \
		|| { fail "(g2) no signon"; showtail "$RM" 12; }
	say 'disconnect'; sleep 2
else
	echo "   note  (g2) skipped: the server's map ($LMAP) needed no loose map model (or (g) did not get in)"
fi
fi

echo
echo "== (j) LIVE: a DarkPlaces protocol 7 server -> joined and in the game (0036; was a clean refusal in 0034)"
# ===========================================================================
back_to_id1
DPSRV=""
for cand in 5.196.63.132:26000 47.190.124.72:26004; do # both DP7 (3504), id1 content
	if python3 -I - "$cand" <<'PY' >/dev/null 2>&1
import socket, sys
h, p = sys.argv[1].rsplit(":", 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(b"\xff\xff\xff\xffgetinfo t", (h, int(p)))
assert b"DarkPlaces-Quake" in s.recvfrom(4096)[0]
PY
	then DPSRV=$cand; break; fi
done
if [ -z "$DPSRV" ]; then
	fail "(j) none of the known DarkPlaces servers answered getinfo — leg (j) proves nothing"
else
	M=$(mark)
	say "connect $DPSRV"
	waitlog 'Using protocol 3504' 60 "$M" \
		&& pass "(j) $DPSRV: \"Using protocol 3504\" (DarkPlaces protocol 7 accepted)" \
		|| { fail "(j) no DP7 serverinfo"; tail -n +"$M" "$LOG" | tail -12 >&2; }
	in_game=0
	for _ in $(seq 1 30); do
		say 'cl_dp7status'; sleep 2
		tail -n +"$M" "$LOG" | grep -aq 'dp7: signon 4' && { in_game=1; break; }
	done
	[ "$in_game" = 1 ] && pass "(j) in the game: $(tail -n +"$M" "$LOG" | grep -a 'dp7: signon 4' | tail -1)" \
		|| { fail "(j) never reached signon 4 on the DP7 server"; tail -n +"$M" "$LOG" | tail -12 >&2; }
	sleep 3
	tail -n +"$M" "$LOG" | grep -q 'STACK TRACE' && fail "(j) a stack trace was printed" || pass "(j) no stack trace"
	tail -n +"$M" "$LOG" | grep -q 'Host_Error' && fail "(j) Host_Error" || pass "(j) no Host_Error"
	tail -n +"$M" "$LOG" | grep -aq 'DarkPlaces server:' && fail "(j) the DP7 parser aborted" || pass "(j) no DP7 parse abort"
	tail -n +"$M" "$LOG" | grep -q 'Unknown command "cl_serverextension_download"' && fail "(j) \"Unknown command cl_serverextension_download\" printed" \
		|| pass "(j) DarkPlaces' cl_serverextension_download stufftext is silent"
	alive && pass "(j) the app is alive" || fail "(j) the app stopped answering"
	shot 11-j-darkplaces-dp7-in-game
	say 'disconnect'; sleep 2
fi

echo
echo "== (n) LIVE: FTE hipnotic server from id1 -> hipnotic; then q1.pieter.com -> back to id1 (0038)"
# ===========================================================================
back_to_id1
mkdir -p "$BASE/hipnotic"
[ -f "$BASE/hipnotic/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/hipnotic/pak0.pak" "$BASE/hipnotic/pak0.pak"
say 'developer 1'; sleep 1
M=$(mark)
say 'connect 192.99.32.215:27501'
waitlog 'moddl: you already have "hipnotic" — switching to it and rejoining' 90 "$M" \
	&& pass "(n) 192.99.32.215:27501 (FTE, hipnotic): local switch to hipnotic" || { fail "(n) no switch to hipnotic"; showtail "$M" 12; }
waitlog 'CL_SignonReply: 4' 90 "$M" && pass "(n) in the game on the hipnotic server (signon 4)" || { fail "(n) no signon 4 on the hipnotic server"; tail -n +"$M" "$LOG" | tail -15 >&2; }
tail -n +"$M" "$LOG" | grep -Eq 'which you do not have|Host_Error|Join stalled' && { fail "(n) the hipnotic join failed"; showtail "$M" 12; } || true
sleep 2; shot 17-n-live-hipnotic-in-game
M=$(mark)
say 'connect q1.pieter.com:27500'
waitlog 'moddl: leaving "id1;hipnotic" \(switched for 192\.99\.32\.215:27501\); back to "id1" to join q1\.pieter\.com:27500' 30 "$M" \
	&& pass "(n) q1.pieter.com: moddl's hipnotic switch is undone first" || { fail "(n) no switch back"; showtail "$M" 12; }
waitlog '"game" changed to "id1"' 30 "$M" && pass "(n) game is id1 again" || fail "(n) game not changed to id1"
waitlog 'CL_SignonReply: 4' 90 "$M" && pass "(n) in the game on q1.pieter.com (signon 4)" || { fail "(n) no signon 4 on q1.pieter.com"; tail -n +"$M" "$LOG" | tail -15 >&2; }
sleep 3
tail -n +"$M" "$LOG" | grep -q 'Unknown command "fullserverinfo"' && fail "(n) \"Unknown command fullserverinfo\"" || pass "(n) no \"Unknown command fullserverinfo\""
tail -n +"$M" "$LOG" | grep -q 'No route to host' && fail "(n) \"No route to host\" (the LAN search ran for an explicit address)" || pass "(n) no \"No route to host\" from the LAN search"
say 'serverinfo'; sleep 2
tail -n +"$M" "$LOG" | grep -Eq '^ *\*version: FTE' && pass "(n) fullserverinfo applied: $(tail -n +"$M" "$LOG" | grep -E '^ *\*version:' | tail -1 | sed 's/^ *//')" \
	|| { fail "(n) cl.serverinfo does not carry FTE's *version"; tail -n +"$M" "$LOG" | grep -A12 'Serverinfo:' | tail -14 >&2; }
shot 18-n-live-pieter-in-game-id1
say 'developer 0'
say 'disconnect'; sleep 2
fi # VKQ_MODDL_LIVE

# ---------------------------------------------------------------------------
echo
echo "== artifacts"
cp "$LOG" "$PFX-console.log" 2>/dev/null && echo "   client log: $PFX-console.log"
for tag in url tab bun big nogd; do
	sed -E 's/^(tcp\/ip:[[:space:]]*).*/\1<redacted>/' "$FIX/server-$tag.log" > "$PFX-server-$tag.log" 2>/dev/null
done
( cd "$BASE" && find . -path ./id1 -prune -o -type f -print | sort ) > "$PFX-installed.txt" 2>/dev/null
echo "   installed files: $(wc -l < "$PFX-installed.txt" | tr -d ' ') (list: $PFX-installed.txt)"

[ "$FAILED" = 0 ] || { echo "MODDL VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "MODDL VERIFY DONE"
