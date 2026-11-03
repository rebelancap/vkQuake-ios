#!/usr/bin/env bash
#
# sim-verify-dp7.sh — DarkPlaces protocol 7 (overlay 0036, docs/DP7-PLAN.md Phase A)
# on the iPhone Air simulator against a REAL DarkPlaces dedicated server on this Mac.
#
# WHAT THIS PROVES, end to end, in the shipping iOS build:
#   1. the client joins a DP7 server ("Using protocol 3504") and reaches signon 4
#      (cl_dp7status reports "signon 4" and a growing E5 frame count)
#   2. entities arrive (cl_dp7status "entities N", N > 0) and the map + HUD draw
#      (simulator panel screenshot and engine screenshot)
#   3. the server accepts our 56-byte DP7 clc_move: +forward moves the player
#      (origin changes) and +attack fires (shells drop below 25)
#   4. 30 s more in the game with no Host_Error / "DarkPlaces server:" abort and
#      the app still answering
#
# The DP server: DarkPlacesEngine/darkplaces @ 10d48635 (GPLv2), built here with
# `make sv-release` into build/darkplaces (gitignored; ~3 s, zlib only; re-fetched
# from GitHub when missing). It reads gamedata/ as -basedir and writes ONLY into
# -userdir build/dp7-userdir — gamedata is never written. Coop e1m1, port 26120.
#
# LANE: iPhone Air on iOS 27.0 (lane 2 by default). Never simctl create. The device
# and the DP server are shut down on every exit path, pass or fail. Silent: the
# app's volume is 0 and the DP server has no sound at all.
#
#   scripts/build-sim.sh ios && scripts/sim-verify-dp7.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999 # console bridge (8765-8769 are OTHER sessions' — never use them)
DPPORT=26120
DPREV=10d486356ad22a19aca3dfc3bb1694ecd241c706
UDID=${VKQ_SIM_UDID:-45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22} # iPhone Air, iOS 27.0 (lane 2)
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
DPSRC="$ROOT/build/darkplaces"
DPBIN="$DPSRC/darkplaces-dedicated"
DPUSER="$ROOT/build/dp7-userdir"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-dp7"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
[ -f "$ROOT/gamedata/id1/PAK0.PAK" ] || [ -f "$ROOT/gamedata/id1/pak0.pak" ] || { echo "FATAL: gamedata/id1 missing (the DP server's data)" >&2; exit 1; }

FAILED=0
DPPID=""
cleanup () {
	local rc=$?
	set +e
	[ -n "$DPPID" ] && kill "$DPPID" 2>/dev/null
	pkill -f "darkplaces-dedicated .*dp7-userdir" 2>/dev/null
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	timeout 60 xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "DP7 VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "DP7 VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
trap 'exit 143' INT TERM
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && die "port $PORT already in use — another session owns it"

# ---------------------------------------------------------------------------
# DarkPlaces dedicated server
# ---------------------------------------------------------------------------
if [ ! -x "$DPBIN" ]; then
	echo "== building the DarkPlaces dedicated server ($DPREV) into build/darkplaces"
	if [ ! -d "$DPSRC/.git" ]; then
		git clone --quiet https://github.com/DarkPlacesEngine/darkplaces "$DPSRC"
	fi
	git -C "$DPSRC" checkout --quiet "$DPREV"
	make -C "$DPSRC" -j8 sv-release > "$ROOT/build/darkplaces-build.log" 2>&1 || die "DP build failed (build/darkplaces-build.log)"
fi
mkdir -p "$DPUSER"
"$DPBIN" -basedir "$ROOT/gamedata" -userdir "$DPUSER" +sv_public 0 +port $DPPORT +maxplayers 4 \
	+coop 1 +map e1m1 > "$ROOT/build/dp7-server.log" 2>&1 < /dev/null &
DPPID=$!
for _ in $(seq 1 40); do grep -q "Server spawned" "$ROOT/build/dp7-server.log" 2>/dev/null && break; sleep 0.5; done
grep -q "Server spawned" "$ROOT/build/dp7-server.log" || die "the DP server did not start (build/dp7-server.log)"
pass "DarkPlaces $(head -1 "$ROOT/build/dp7-server.log" | awk '{print $4}') dedicated up on :$DPPORT, coop e1m1, sv_protocolname DP7 (default)"

# ---------------------------------------------------------------------------
# simulator
# ---------------------------------------------------------------------------
for _ in $(seq 1 60); do
	state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	case "$state" in Shutdown | Booted) break ;; esac
	echo "   waiting for $UDID to settle (${state:-unknown})"; sleep 2
done
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; then
	timeout 60 xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
fi
echo "== install"
xcrun simctl install "$UDID" "$APP"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
GAMEDIR="$DOCS/rerelease/id1"
mkdir -p "$GAMEDIR"
[ -f "$GAMEDIR/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$GAMEDIR/pak0.pak"
rm -f "$DOCS/console.log"
# sim-only: no indirect draws on sim Metal; silent; mouse-look off so the view is
# exactly what the server set
printf 'r_indirect 0\nvolume 0\nbgmvolume 0\nsensitivity 0\n' > "$GAMEDIR/autoexec.cfg"

echo "== launch"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
	timeout 60 xcrun simctl launch "$UDID" $BUNDLE
ok=0
for _ in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened"
LOG="$DOCS/console.log"
pass "the app is up and the bridge answers"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
mark () { wc -l < "$LOG" | tr -d ' '; }
shot () { xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-$1.png" || echo "   (screenshot unavailable)"; }
status () { # status <tag> -> the cl_dp7status line, also kept in the artifacts
	local M; M=$(mark)
	say 'cl_dp7status'
	for _ in $(seq 1 10); do
		tail -n +"$M" "$LOG" | grep -aq 'dp7: signon' && break
		sleep 1
	done
	tail -n +"$M" "$LOG" | grep -a 'dp7: signon' | tail -1 | tee -a "$PFX-status.txt" | sed "s/^/   [$1] /"
}
field () { echo "$1" | sed -nE "s/.* $2 ([-0-9.]+).*/\1/p"; }
origin () { echo "$1" | sed -nE 's/.* origin ([-0-9.]+ [-0-9.]+ [-0-9.]+).*/\1/p'; }
: > "$PFX-status.txt"

sleep 6
# The first joins to a server on THIS Mac after an app launch can stall on the iOS
# 27 simulator (see sim-verify-moddl.sh's warm-up); retry until the serverinfo lands.
joined=0
for attempt in 1 2 3 4 5 6 7 8; do
	say 'disconnect'; sleep 2
	M=$(mark)
	say "connect 127.0.0.1:$DPPORT"
	for _ in $(seq 1 75); do
		tail -n +"$M" "$LOG" | grep -aq 'Using protocol\|load failed\|DarkPlaces server:' && break
		sleep 1
	done
	if tail -n +"$M" "$LOG" | grep -aq 'Using protocol 3504'; then joined=1; break; fi
	tail -n +"$M" "$LOG" | grep -aq 'DarkPlaces server:\|vkQuake cannot join' && break
	echo "   join $attempt stalled (simulator local-network quirk); retrying"
done
JM=$M
[ "$joined" = 1 ] && pass "1. \"Using protocol 3504\" (after $attempt attempt(s))" || die "never got a DP7 serverinfo: $(tail -n +"$JM" "$LOG" | tail -5)"

s0=""
for _ in $(seq 1 30); do
	s0=$(status join)
	echo "$s0" | grep -q 'signon 4' && break
	sleep 1
done
echo "$s0" | grep -q 'signon 4' && pass "1. signon 4 reached" || die "no signon 4: $s0"
f0=$(field "$s0" frames); e0=$(field "$s0" entities)
[ "${e0:-0}" -gt 0 ] && pass "2. $e0 entities live from svc_entities (E5)" || fail "2. no entities"
say 'centerview'; sleep 2
shot 01-joined
npng () { find "$GAMEDIR" -maxdepth 1 -name '*.png' | wc -l | tr -d ' '; }
before=$(npng)
say 'screenshot png 90'; sleep 3
if [ "$(npng)" -gt "$before" ]; then
	eng=$(ls -t "$GAMEDIR"/*.png | head -1)
	cp "$eng" "$PFX-02-joined-engine.png" && pass "2. engine screenshot (the drawable): $PFX-02-joined-engine.png"
else
	fail "2. engine screenshot not written"
fi

o0=$(origin "$s0")
say '+forward'; sleep 2; say '-forward'; sleep 1
s1=$(status walked)
o1=$(origin "$s1")
[ -n "$o1" ] && [ "$o1" != "$o0" ] && pass "3. +forward moved the player: ($o0) -> ($o1)" || fail "3. the player did not move ($o0 -> $o1)"
shot 03-walked

say '+attack'; sleep 3; say '-attack'; sleep 1
s2=$(status fired)
sh=$(field "$s2" shells)
[ -n "$sh" ] && [ "$sh" -lt 25 ] && pass "3. +attack fired: shells 25 -> $sh" || fail "3. shells did not drop (${sh:-?})"
shot 04-fired

sleep 30
s3=$(status 30s)
f3=$(field "$s3" frames)
echo "$s3" | grep -q 'signon 4' && [ "${f3:-0}" -gt "${f0:-0}" ] \
	&& pass "4. still in game 30 s later: E5 frames $f0 -> $f3" || fail "4. not in game after 30 s: $s3"
tail -n +"$JM" "$LOG" | grep -aq 'Host_Error' && fail "4. Host_Error in the console log" || pass "4. no Host_Error"
tail -n +"$JM" "$LOG" | grep -aq 'DarkPlaces server:' && fail "4. the DP7 parser aborted: $(tail -n +"$JM" "$LOG" | grep -a 'DarkPlaces server:' | head -1)" || pass "4. no DP7 parse abort"
alive && pass "4. the app is alive" || fail "4. the app stopped answering"
shot 05-30s
grep -q 'entered the game' "$ROOT/build/dp7-server.log" && pass "the server saw the client enter the game" || fail "the server never logged 'entered the game'"

say 'disconnect'; sleep 2
cp "$LOG" "$PFX-console.log" 2>/dev/null && echo "   client log: $PFX-console.log"
sed -E 's/^(Server listening on address).*/\1 <redacted>/' "$ROOT/build/dp7-server.log" > "$PFX-server.log"
echo "   server log: $PFX-server.log; status lines: $PFX-status.txt"
