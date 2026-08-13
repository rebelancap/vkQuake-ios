#!/usr/bin/env bash
#
# sim-verify-mpdl.sh — MP-DL1 (overlay 0028): joining a server that runs a map
# you do not have downloads it, installs it, and rejoins.
#
# WHAT THIS PROVES, end to end, on an iOS simulator with a real Quake server and
# real HTTP on the other side of the socket:
#   a. the consent prompt appears, naming the map, its size and its source
#   b. accepting downloads it, installs it under Documents/<gamedir>/maps, and
#      the client rejoins and renders the map
#   c. the package path (source B) resolves through a Quaddicted-shaped index,
#      verifies sha256, and SKIPS a file the player already has
#   d. a zip-slip entry is refused and nothing lands outside Documents
#   e. a map neither source has fails cleanly to the menu, no crash
#   f. cl_mapdownload 0 restores overlay 0026's behaviour exactly
#   g. a mid-game changelevel to a missing map takes the same route
#   h. the REAL sources work: one live download of blitzkrieg2.bsp from
#      maps.quakeworld.nu over TLS (this is the map the whole feature exists for)
#
# THE FIXTURE. Two sources on one local port (scripts/mpdl-fixture), and a real
# vkQuake dedicated server built from the same overlay, running six maps the
# client does not have. The maps are one real id1 .bsp renamed six ways — a .bsp
# does not carry its own name, the engine loads it purely by filename — so a
# single 600 KB file stands in for six community maps without shipping any.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING iPhone 17 Pro Max on iOS 27.0. Never
# simctl create. The device is shut down on every exit path, pass or fail, and so
# are the fixture server and the game server.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999						# console bridge (8765-8769 are OTHER sessions' — never use them)
FIXPORT=18777					# fixture HTTP
GAMEPORT=26100					# dedicated vkQuake
UDID=${VKQ_SIM_UDID:-67FE893D-A639-435A-8258-DDD6AA253E03} # iPhone 17 Pro Max, iOS 27.0
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ORACLE="$ROOT/build/oracle/vkquake"
FIX="$ROOT/tmp/mpdl-fixture"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-mpdl"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
[ -x "$ORACLE" ] || { echo "FATAL: oracle missing — ninja -C build/oracle" >&2; exit 1; }

# ---------------------------------------------------------------------------
# verdict discipline: the trap owns the exit status, and a killed run has NO
# verdict (the debt the VR suite carried for two rounds, docs/VR-R6-NOTES.md).
# ---------------------------------------------------------------------------
FAILED=0
INTERRUPTED=0
SRVPID=""
FIXPID=""
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	set +e
	[ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
	[ -n "$FIXPID" ] && kill "$FIXPID" 2>/dev/null
	pkill -f "vkquake -dedicated .*mpdl-fixture" 2>/dev/null
	pkill -f "mpdl-fixture/fixture-server.py" 2>/dev/null
	# pkill -f is a REGEX match: a literal "+1" never matches itself (the + is a
	# quantifier), so the old pattern orphaned this tail every run (found in MP-DL2).
	pkill -f "mpdl-fixture/srvcmd" 2>/dev/null
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$INTERRUPTED" != 0 ]; then
		echo "MPDL VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "MPDL VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "MPDL VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

# ---------------------------------------------------------------------------
# ports must be ours before anything starts
# ---------------------------------------------------------------------------
for p in $PORT $FIXPORT; do
	if nc -z -G 1 127.0.0.1 $p 2>/dev/null; then
		echo "FATAL: port $p already in use — another session owns it" >&2; exit 1
	fi
done
if nc -z -u -G 1 127.0.0.1 $GAMEPORT 2>/dev/null; then
	echo "note: udp/$GAMEPORT probe answered; continuing (UDP probes are advisory)" >&2
fi

# ---------------------------------------------------------------------------
# fixture + servers
# ---------------------------------------------------------------------------
echo "== building the fixture (derived from gamedata/, never committed)"
"$ROOT/scripts/mpdl-fixture/build-fixture.sh"

echo "== fixture HTTP on 127.0.0.1:$FIXPORT"
python3 "$ROOT/scripts/mpdl-fixture/fixture-server.py" $FIXPORT > "$FIX/fixture.log" 2>&1 &
FIXPID=$!
for _ in $(seq 1 20); do nc -z -G 1 127.0.0.1 $FIXPORT 2>/dev/null && break; sleep 0.5; done
nc -z -G 1 127.0.0.1 $FIXPORT 2>/dev/null || die "the fixture HTTP server never came up"
curl -sf -o /dev/null "http://127.0.0.1:$FIXPORT/all/qdl_test1.bsp" || die "fixture does not serve qdl_test1.bsp"
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FIXPORT/all/qdl_test2.bsp" | grep -q 404 \
	|| die "fixture must 404 qdl_test2.bsp (that is what drives source B)"
pass "fixture serves source A and 404s the source-B map"

echo "== dedicated vkQuake on 127.0.0.1:$GAMEPORT (map qdl_test1)"
# stdin over a plain file that `tail -f` follows: this is how the run drives the
# server's console (`map`, `changelevel`, `status`). `script` gives it a pty so
# its stdout is line-buffered and readable while it runs.
: > "$FIX/srvcmd"
( tail -n +1 -f "$FIX/srvcmd" | script -q /dev/null "$ORACLE" -dedicated 4 \
	-basedir "$FIX/server" -userdir "$FIX/serveruser" -port $GAMEPORT +map qdl_test1 \
	> "$FIX/server.log" 2>&1 ) &
SRVPID=$!
srv () { printf '%s\n' "$1" >> "$FIX/srvcmd"; }
srvmark () { wc -l < "$FIX/server.log" | tr -d ' '; }
# "did a client actually arrive" asked of the SERVER, since this run: the client's
# own log would only tell us what it tried to do.
srv_has_player () { # srv_has_player <since-line>
	local from="$1" i
	srv "status"
	for i in $(seq 1 15); do
		tail -n +"$from" "$FIX/server.log" 2>/dev/null | grep -q 'players: 1 active' && return 0
		sleep 1
		srv "status"
	done
	return 1
}
srv_map () { # switch the server's map and confirm it took
	srv "map $1"; sleep 3; srv "status"
	for _ in $(seq 1 20); do
		grep -q "^map:[[:space:]]*$1" "$FIX/server.log" && return 0
		sleep 1
	done
	fail "the game server never reported map $1"; return 1
}
for _ in $(seq 1 40); do grep -q "UDP4 Initialized" "$FIX/server.log" 2>/dev/null && break; sleep 1; done
grep -q "UDP4 Initialized" "$FIX/server.log" || die "the dedicated server never initialised UDP"
srv "status"; sleep 2
grep -q "^map:[[:space:]]*qdl_test1" "$FIX/server.log" || die "the dedicated server is not running qdl_test1"
pass "the game server is up on qdl_test1 with six maps the client does not have"

# ---------------------------------------------------------------------------
# simulator
# ---------------------------------------------------------------------------
for _ in $(seq 1 60); do
	state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	case "$state" in Shutdown | Booted) break ;; esac
	echo "   waiting for $UDID to settle (${state:-unknown})"; sleep 2
done
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "== install"
xcrun simctl install "$UDID" "$APP"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
GAMEDIR="$DOCS/rerelease/id1"
mkdir -p "$GAMEDIR"
[ -f "$GAMEDIR/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$GAMEDIR/pak0.pak"
# A clean slate for every guardrail this run asserts.
rm -rf "$GAMEDIR/maps" "$DOCS/console.log" "$CONT/Library/Caches/quaddicted-index.json" \
	"$DOCS/evil_mapdl.txt" "$DOCS/../evil_mapdl.txt" "$GAMEDIR/../evil_mapdl.txt" \
	"$DOCS/evil_mapdl2.txt" "$GAMEDIR/../evil_mapdl2.txt" "$GAMEDIR/mapdl"
# The file the source-B package also contains: it must be SKIPPED, not replaced.
printf 'PRE-EXISTING — the extractor must not overwrite this.\n' > "$GAMEDIR/readme_qdl.txt"

# r_indirect 0: the simulator's Metal device rejects indirect draws (see
# sim-verify.sh). The three cvars below point the downloader at the local
# fixture; allowhttp is what lets a 127.0.0.1 fixture stand in for two https
# hosts, and it is OFF by default in the shipped build.
cat > "$GAMEDIR/autoexec.cfg" <<CFG
r_indirect 0
cl_mapdownload_allowhttp 1
cl_mapdownload_bspurl "http://127.0.0.1:$FIXPORT/all/"
cl_mapdownload_pkgurl "http://127.0.0.1:$FIXPORT/api/"
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
# Wait for a regex to appear in the engine's own console log. Every assertion in
# this run is on engine output, not on a sleep that was long enough yesterday.
waitlog () { # waitlog <regex> <seconds> [<since-line>]
	local re="$1" secs="$2" from="${3:-1}" i
	for i in $(seq 1 "$secs"); do
		tail -n +"$from" "$LOG" 2>/dev/null | grep -Eq "$re" && return 0
		sleep 1
	done
	return 1
}
mark () { wc -l < "$LOG" | tr -d ' '; } # log line count, for "since here" greps
shot () { xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-$1.png" || echo "   (screenshot unavailable)"; }

sleep 8
say 'cl_mapdownload'; sleep 2
grep -q 'cl_mapdownload_bspurl' "$LOG" || true
if grep -Eq '"cl_mapdownload" is "1"' "$LOG"; then
	pass "the fixture autoexec reached the engine (cl_mapdownload = 1, ask)"
else
	fail "cl_mapdownload did not read back as 1 — the autoexec did not apply"
fi

# ===========================================================================
echo
echo "== (a) join a server running a map we do not have -> consent prompt"
# ===========================================================================
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'mapdl: qdl_test1\.bsp found on 127\.0\.0\.1:'"$FIXPORT"' \(607420 bytes\)' 40 "$M"; then
	pass "(a) source A answered the probe and the size is known"
else
	fail "(a) the probe never resolved on source A"
fi
say 'mapdl_status'; sleep 2
if tail -n +"$M" "$LOG" | grep -Eq 'mapdl status: state=prompt map=qdl_test1'; then
	pass "(a) the state machine is waiting for consent"
else
	fail "(a) the state machine is not in the prompt state"
	tail -n +"$M" "$LOG" | grep -E 'mapdl' | tail -5 >&2 || true
fi
sleep 2; shot 01-a-consent-prompt

# ===========================================================================
echo
echo "== (b) accept -> download, install, rejoin"
# ===========================================================================
M=$(mark)
say 'mapdl_accept'
if waitlog 'mapdl: installed maps/qdl_test1\.bsp' 60 "$M"; then
	pass "(b) the map was downloaded and installed"
else
	fail "(b) the map never installed"
fi
if [ -f "$GAMEDIR/maps/qdl_test1.bsp" ]; then
	sz=$(stat -f%z "$GAMEDIR/maps/qdl_test1.bsp")
	pass "(b) Documents/rerelease/id1/maps/qdl_test1.bsp exists ($sz bytes)"
	[ "$sz" = 607420 ] || fail "(b) installed size $sz != the served 607420"
else
	fail "(b) no file at $GAMEDIR/maps/qdl_test1.bsp"
fi
if waitlog 'mapdl: rejoining 127\.0\.0\.1' 30 "$M"; then
	pass "(b) the client reissued the original connect"
else
	fail "(b) the client never tried to rejoin"
fi
# In-map proof, from the server's side of the wire and from the client's screen.
SM=$(srvmark); sleep 14
if srv_has_player "$SM"; then
	pass "(b) the game server sees one active player — the client is IN the map"
else
	fail "(b) the server never saw the client join"
	tail -n +"$SM" "$FIX/server.log" | grep -E 'players:|^map:' | tail -4 >&2 || true
fi
shot 02-b-in-downloaded-map

# ===========================================================================
echo
echo "== (g) mid-game changelevel to a map we do not have"
# ===========================================================================
M=$(mark)
srv "changelevel qdl_test4"
if waitlog 'mapdl: qdl_test4\.bsp missing' 45 "$M"; then
	pass "(g) the changelevel re-entered the missing-map path with no menu behind it"
else
	fail "(g) the changelevel did not trigger the downloader"
fi
say 'mapdl_accept'
if waitlog 'mapdl: installed maps/qdl_test4\.bsp' 60 "$M"; then
	pass "(g) qdl_test4 downloaded and installed after the changelevel"
else
	fail "(g) qdl_test4 never installed"
fi
SM=$(srvmark); sleep 16
if srv_has_player "$SM"; then
	pass "(g) the client rejoined the server on the new map"
else
	fail "(g) the client did not rejoin after the changelevel"
fi
shot 03-g-after-changelevel

say 'disconnect'; sleep 3

# ===========================================================================
echo
echo "== (c) source B: package archive, sha256, and skip-never-overwrite"
# ===========================================================================
srv_map qdl_test2 || true
say 'cl_mapdownload 2'; sleep 1   # auto mode: this leg also proves 'always'
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'mapdl: qdl_test2\.bsp is not on the bare-map mirror \(http 404\)' 40 "$M"; then
	pass "(c) source A missed and the client moved to the package archive"
else
	fail "(c) the client did not fall through to source B"
fi
if waitlog 'mapdl: found "QDL Fixture Pack Two" in the archive .* on 127\.0\.0\.1:'"$FIXPORT" 45 "$M"; then
	pass "(c) the package was resolved LOCALLY out of the cached index"
else
	fail "(c) the archive index did not resolve the map"
fi
if waitlog 'mapdl: sha256 verified' 60 "$M"; then
	pass "(c) the package hash matched the record"
else
	fail "(c) sha256 was not verified"
fi
if waitlog 'mapdl: skip \(exists\) readme_qdl\.txt' 20 "$M"; then
	pass "(c) an existing file was skipped and the skip was logged"
else
	fail "(c) the extractor did not log a skip for readme_qdl.txt"
fi
if grep -q 'PRE-EXISTING' "$GAMEDIR/readme_qdl.txt"; then
	pass "(c) the pre-existing file was NOT overwritten"
else
	fail "(c) the pre-existing file was replaced by the package's copy"
fi
[ -f "$GAMEDIR/maps/qdl_test2.bsp" ] \
	&& pass "(c) maps/qdl_test2.bsp installed from the package" \
	|| fail "(c) maps/qdl_test2.bsp is not installed"
SM=$(srvmark); sleep 16
if srv_has_player "$SM"; then
	pass "(c) the client rejoined and is in the packaged map"
else
	fail "(c) the client did not rejoin after the package install"
fi
shot 04-c-source-b-installed
say 'disconnect'; sleep 3

# ===========================================================================
echo
echo "== (d) zip-slip: escaping entries refused, nothing written outside Documents"
# ===========================================================================
srv_map qdl_test3 || true
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'rejected (unsafe|escaping) zip entry' 90 "$M"; then
	pass "(d) the traversal entry was refused, loudly"
	tail -n +"$M" "$LOG" | grep -E 'rejected .* zip entry' | sed 's/^/        /' | head -4
else
	fail "(d) no rejection was logged for the hostile package"
fi
esc=0
for p in "$DOCS/evil_mapdl.txt" "$DOCS/evil_mapdl2.txt" "$CONT/evil_mapdl.txt" \
		 "$CONT/../evil_mapdl.txt" "$DOCS/rerelease/evil_mapdl.txt" "$DOCS/rerelease/evil_mapdl2.txt"; do
	[ -e "$p" ] && { fail "(d) a file ESCAPED to $p"; esc=1; }
done
# and nothing anywhere under the whole app container
if find "$CONT" -name 'evil_mapdl*' 2>/dev/null | grep -q .; then
	fail "(d) an escaping entry landed somewhere in the container:"
	find "$CONT" -name 'evil_mapdl*' >&2
	esc=1
fi
[ "$esc" = 0 ] && pass "(d) nothing was written outside the extraction root"
[ -f "$GAMEDIR/maps/qdl_test3.bsp" ] \
	&& pass "(d) the package's legitimate map still installed (the bad entry alone was dropped)" \
	|| fail "(d) the legitimate entry did not install"
sleep 14
shot 05-d-zip-slip-rejected
say 'disconnect'; sleep 3

# ===========================================================================
echo
echo "== (e) a map neither source has -> clean failure, no crash"
# ===========================================================================
srv_map qdl_test9 || true
say 'cl_mapdownload 1'; sleep 1
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'mapdl: qdl_test9\.bsp is not on the bare-map mirror' 45 "$M"; then
	pass "(e) source A missed, as expected for a map nobody publishes"
else
	fail "(e) the probe against source A never resolved"
fi
say 'mapdl_accept'
if waitlog 'mapdl: FAILED — not found in community archives' 90 "$M"; then
	pass "(e) both sources missed and the failure is explicit"
else
	fail "(e) the unknown map did not produce the expected failure"
	tail -n +"$M" "$LOG" | grep -E 'mapdl' | tail -6 >&2 || true
fi
alive || die "(e) the app stopped answering — a missing map must never crash it"
pass "(e) the app is still alive and on the menu"
sleep 2; shot 06-e-not-found
say 'mapdl_cancel'; sleep 2

# ===========================================================================
echo
echo "== (f) cl_mapdownload 0 -> exactly overlay 0026's behaviour"
# ===========================================================================
srv_map qdl_test6 || true
say 'cl_mapdownload 0'; sleep 1
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'mapdl: cl_mapdownload is 0 — not offering to download' 40 "$M"; then
	pass "(f) the downloader stood down"
else
	fail "(f) the downloader did not respect cl_mapdownload 0"
fi
if waitlog 'This server is running a map "qdl_test6\.bsp", which you do not have' 20 "$M"; then
	pass "(f) overlay 0026's message is the one the player sees"
else
	fail "(f) the R6.5 failure message did not appear"
fi
if tail -n +"$M" "$LOG" | grep -q 'vkQuake cannot download game content from servers'; then
	pass "(f) 0026's second line is intact"
else
	fail "(f) 0026's message was altered"
fi
alive || die "(f) the app stopped answering"
sleep 2; shot 07-f-mapdownload-off

# ===========================================================================
echo
echo "== (h) REAL SOURCES: one live download of blitzkrieg2.bsp over TLS"
# ===========================================================================
# The map this whole feature exists for. It is a DEATHMATCH map and is NOT in
# the Quaddicted archive, which is exactly why source A exists — so this leg also
# proves the source ordering was the right way round.
srv_map blitzkrieg2 || true
say 'cl_mapdownload 1'
say 'cl_mapdownload_allowhttp 0'
say 'cl_mapdownload_bspurl "https://maps.quakeworld.nu/all/"'
say 'cl_mapdownload_pkgurl "https://www.quaddicted.com/api/v1/"'
sleep 2
M=$(mark)
say "connect 127.0.0.1:$GAMEPORT"
if waitlog 'mapdl: blitzkrieg2\.bsp found on maps\.quakeworld\.nu \(2527992 bytes\)' 60 "$M"; then
	pass "(h) the real mirror answered the probe with the expected size"
else
	fail "(h) the live probe against maps.quakeworld.nu did not resolve"
	tail -n +"$M" "$LOG" | grep -E 'mapdl' | tail -6 >&2 || true
fi
sleep 2; shot 08-h-real-source-prompt
say 'mapdl_accept'
if waitlog 'mapdl: installed maps/blitzkrieg2\.bsp' 120 "$M"; then
	pass "(h) the real map downloaded over TLS and installed"
else
	fail "(h) the live download did not install"
fi
if [ -f "$GAMEDIR/maps/blitzkrieg2.bsp" ]; then
	sz=$(stat -f%z "$GAMEDIR/maps/blitzkrieg2.bsp")
	[ "$sz" = 2527992 ] && pass "(h) installed blitzkrieg2.bsp is 2527992 bytes, byte-exact" \
		|| fail "(h) blitzkrieg2.bsp is $sz bytes, expected 2527992"
else
	fail "(h) blitzkrieg2.bsp was not installed"
fi
sleep 10; shot 09-h-real-map

# ---------------------------------------------------------------------------
echo
echo "== artifacts"
cp "$LOG" "$PFX-console.log" 2>/dev/null && echo "   client log: $PFX-console.log"
# The server log carries this machine's LAN/tailnet address in its `status`
# banner. artifacts/ is git-ignored, but scrub it anyway — it is the kind of file
# that gets pasted into a report.
sed -E 's/^(tcp\/ip:[[:space:]]*).*/\1<redacted>/' "$FIX/server.log" > "$PFX-server.log" 2>/dev/null \
	&& echo "   server log: $PFX-server.log"
ls -l "$GAMEDIR/maps" > "$PFX-installed-maps.txt" 2>/dev/null && cat "$PFX-installed-maps.txt"

[ "$FAILED" = 0 ] || { echo "MPDL VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "MPDL VERIFY DONE"
