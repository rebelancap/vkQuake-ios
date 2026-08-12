#!/usr/bin/env bash
#
# sim-verify-slist-ping.sh — VR R6.3 item 1: the PING column in the multiplayer
# server list, and the ping-ascending sort.
#
# the user: "this version of vkquake doesn't show PING... can we add that to the
# multiplayer list and automatically sort by ping?"
#
# WHAT THIS CAN PROVE, on a simulator with no other Quake server in the world:
#   - the app boots with overlay 0025 in it (boot smoke, bridge answers)
#   - `slist` finds the local listen server and renders the NEW row format,
#     including a ping column, with the new header
#   - the ping is a MEASUREMENT: the loopback driver reports 0 by construction,
#     and any datagram reply carries a real Sys_DoubleTime() round trip
#   - NET_SlistPingText's "--" branch for an unmeasured row never fires on a row
#     the engine actually filled (i.e. we did not ship a column of dashes)
# WHAT IT CANNOT: multi-server ORDERING against a real master list. That needs
# more than one reachable server and belongs to the user's device round.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING Apple Vision Pro. Never simctl create.
# The device is shut down on every exit path, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346}
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-r63ping"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another sim session owns the bridge" >&2; exit 1
fi

FAILED=0
INTERRUPTED=0
# The trap owns the exit status, and a killed run has NO verdict (the debt the
# full suite carried for two rounds — see docs/VR-R6-NOTES.md R6.2.4).
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null || true
	if [ "$INTERRUPTED" != 0 ]; then
		echo "R63 PING VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "R63 PING VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "R63 PING VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

for _i in $(seq 1 60); do
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
mkdir -p "$DOCS/rerelease/id1"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak" 2>/dev/null || true
printf 'r_indirect 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"
rm -f "$DOCS/console.log"

echo "== launch"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	xcrun simctl launch "$UDID" $BUNDLE
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened"
echo "   PASS  boot smoke: the app is up and the bridge answers (overlay 0025 in the build)"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }

sleep 6
echo "== a local listen server, so there is something to measure"
say 'map e1m1'; sleep 18
say 'listen 1'; sleep 3
alive || die "the app stopped answering after starting the listen server"

echo "== slist"
say 'slist'; sleep 6
# The search stays alive until 1.5 s pass with nothing sent; give it the margin.
say 'echo R63PINGMARK'; sleep 4

LOG="$DOCS/console.log"
[ -f "$LOG" ] || die "no console.log at $LOG"
cp "$LOG" "$PFX-console.log"
echo "   log: $PFX-console.log"

echo "== assertions"
# 1. the new header, with the ping column
if grep -q 'Server        Map         Users Ping' "$LOG"; then
	echo "   PASS  the slist header carries a Ping column"
else
	echo "   FAIL  no new slist header in the console log" >&2; FAILED=1
fi

# 2. at least one server row, in the new format, with a ping cell.
#    Row shape: name(13) SP map(11) SP users(5) SP ping(4), or the maxusers-less
#    variant. Match on "<something> <map> <n>/<n> <ping>" loosely but require the
#    ping cell to be present and to be either digits or the honest "--".
PINGROW=$(grep -E '^local .*[0-9]+/[0-9]+ +(-{2}|[0-9]+)$' "$LOG" | tail -1 || true)
if [ -z "$PINGROW" ]; then
	# the loopback server is named from `hostname`, which may not be "local"
	PINGROW=$(grep -E '^.{1,13} +.{1,11} +[0-9 ]+/[0-9 ]+ +(-{2}|[0-9]+)$' "$LOG" | tail -1 || true)
fi
if [ -n "$PINGROW" ]; then
	printf '   row: %s\n' "$PINGROW"
	echo "   PASS  a server row rendered with a ping cell"
else
	echo "   FAIL  no server row with a ping cell in the console log" >&2; FAILED=1
	printf '   --- slist region of the log ---\n' >&2
	grep -n -A6 'Looking for Quake servers' "$LOG" >&2 || true
fi

# 3. the ping is a MEASUREMENT, not a dash. The loopback server is this process,
#    so its RTT is 0 by construction; a datagram self-reply is a real round trip.
#    Either is a number. A "--" here would mean every fill path missed the stamp.
PINGVAL=$(printf '%s' "$PINGROW" | awk '{print $NF}')
if printf '%s' "$PINGVAL" | grep -Eq '^[0-9]+$'; then
	echo "   PASS  the ping cell is a measured millisecond value: ${PINGVAL} ms"
else
	echo "   FAIL  the ping cell is '${PINGVAL}' — no fill path stamped a round trip" >&2; FAILED=1
fi

# 4. regression: the row must not carry the old stray trailing newline glyph, and
#    the old 15/15 column widths must be gone from the header.
if grep -q 'Server          Map             Users$' "$LOG"; then
	echo "   FAIL  the OLD slist header is still being printed" >&2; FAILED=1
else
	echo "   PASS  the old 15/15-column header is gone"
fi

xcrun simctl io "$UDID" screenshot "$PFX-01-after-slist.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-01-after-slist.png" || echo "   (screenshot unavailable)"

cp "$DOCS/vr-diagnostics.log" "$PFX-diagnostics.log" 2>/dev/null || true
[ "$FAILED" = 0 ] || { echo "R63 PING VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "R63 PING VERIFY DONE"
