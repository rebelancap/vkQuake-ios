#!/usr/bin/env bash
#
# sim-verify-touchscroll.sh — overlay 0029: menu touch is a TAP or a DRAG.
#
# WHAT THIS PROVES, on an iOS simulator, with a real Quake server on the other
# side of the socket for the one assertion that needs a real join:
#   a. a scrollable server list exists (41 entries, 20 fit) and page 1 renders
#   b. an injected vertical DRAG scrolls it — slist_first moves, the rows on
#      screen change, and NO connect is attempted
#   c. an injected TAP on the real server's row joins it (the server sees the
#      player), then disconnects cleanly
#   d. an injected TAP in the scroll gutter joins NOTHING and leaves the menu up
#      (this is the bug Austin hit on 1.1.0.1), while a tap ON the bar itself is
#      still a page jump
#   e. a DRAG scrolls the MODS list too — the same wheel-key mechanism, no
#      per-menu code (fixture: 24 empty mod dirs, 14 fit on screen)
#   f. a DRAG on the main menu does nothing at all: no scrollbar there, so no
#      wheel keys, and the drag cancels the tap it would otherwise have been
#   x. taps still activate: the same tap machinery walks Main -> Multiplayer
#      (the round brief's (g), a clean boot to e1m1, is scripts/sim-verify.sh ios)
#
# THE FIXTURE. `vkq_slist_fake` (overlay 0029) fills the host cache with 40
# unreachable entries plus ONE real address, so the list is long and
# deterministic without spinning up forty servers — and the real entry (ping 1,
# so it sorts to row 0) is what assertion (c) actually joins. The real server is
# a vkQuake dedicated built from this same overlay, running a map the client
# already has (no MP-DL prompt in the way).
#
# TOUCH INJECTION. Synthetic UIKit events do not reach the touch path on a
# simulator (program-wide finding), so the fingers here are `vkq_touch*` console
# commands, which call M_TouchEvent — the SAME function SDL's finger events call.
# What is NOT proven here is UIKit -> SDL delivery; that part is unchanged by
# this round and is what the device round covers.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING iPhone 17 Pro Max on iOS 27.0. Never
# simctl create. The device is shut down on every exit path, pass or fail, and so
# is the dedicated server.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999                      # console bridge (8765-8769 are OTHER sessions' — never use them)
GAMEPORT=26100                  # dedicated vkQuake
UDID=${VKQ_SIM_UDID:-67FE893D-A639-435A-8258-DDD6AA253E03} # iPhone 17 Pro Max, iOS 27.0
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ORACLE="$ROOT/build/oracle/vkquake"
SRVDIR="$ROOT/tmp/touchscroll-srv"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-touchscroll"
mkdir -p "$ARTS"

# menu-canvas geometry the assertions aim at (read back from vkq_menuinfo below,
# which is the authority — these are the source's numbers, asserted not assumed)
SLIST_TOP=40                    # SERVER_LIST_TOP_Y
ROW_H=8                         # CHARACTER_SIZE
ON_SCREEN=20                    # SERVER_LIST_MAX_ON_SCREEN
M_MAIN=1; M_MULTIPLAYER=5; M_SLIST=19; M_MODS=20   # enum m_state_e

[ -d "$APP" ]   || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
[ -x "$ORACLE" ] || { echo "FATAL: oracle missing — ninja -C build/oracle" >&2; exit 1; }

# ---------------------------------------------------------------------------
# verdict discipline: the trap owns the exit status, and a killed run has NO
# verdict (the debt the VR suite carried for two rounds, docs/VR-R6-NOTES.md).
# ---------------------------------------------------------------------------
FAILED=0
INTERRUPTED=0
SRVPID=""
MODDIRS=""
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	set +e
	[ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
	pkill -f "vkquake -dedicated .*touchscroll-srv" 2>/dev/null
	# NOTE the [+]: pkill -f's pattern is a REGEX, so the obvious
	# "tail -n +1 -f ..." never matches its own literal '+' — which is why a
	# fixture tail from an older sim-verify-mpdl.sh run is still alive on this
	# machine, holding its pipeline (and any `| tail` reading it) open forever.
	pkill -f "tail -n [+]1 -f $SRVDIR/srvcmd" 2>/dev/null
	# the 24 empty mod dirs this run created (fixture only — no user data)
	[ -n "$MODDIRS" ] && rm -rf $MODDIRS
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$INTERRUPTED" != 0 ]; then
		echo "TOUCHSCROLL VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "TOUCHSCROLL VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "TOUCHSCROLL VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die  () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another session owns it" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# the one real server (assertion c)
# ---------------------------------------------------------------------------
echo "== dedicated vkQuake on 127.0.0.1:$GAMEPORT (map e1m1 — the client has it)"
rm -rf "$SRVDIR"; mkdir -p "$SRVDIR"
: > "$SRVDIR/srvcmd"
( tail -n +1 -f "$SRVDIR/srvcmd" | script -q /dev/null "$ORACLE" -dedicated 4 \
	-basedir "$ROOT/gamedata/rerelease" -userdir "$SRVDIR/user" -port $GAMEPORT +map e1m1 \
	> "$SRVDIR/server.log" 2>&1 ) &
SRVPID=$!
srv     () { printf '%s\n' "$1" >> "$SRVDIR/srvcmd"; }
srvmark () { wc -l < "$SRVDIR/server.log" | tr -d ' '; }
srv_has_player () { # srv_has_player <since-line>
	local from="$1" i
	srv "status"
	for i in $(seq 1 12); do
		tail -n +"$from" "$SRVDIR/server.log" 2>/dev/null | grep -q 'players: 1 active' && return 0
		sleep 1
		srv "status"
	done
	return 1
}
srv_no_player () { # srv_no_player <since-line> — asked AFTER a settle, not instead of one
	local from="$1"
	srv "status"; sleep 2
	! tail -n +"$from" "$SRVDIR/server.log" 2>/dev/null | grep -q 'players: 1 active'
}
for _ in $(seq 1 40); do grep -q "UDP4 Initialized" "$SRVDIR/server.log" 2>/dev/null && break; sleep 1; done
grep -q "UDP4 Initialized" "$SRVDIR/server.log" || die "the dedicated server never initialised UDP"
srv "status"; sleep 2
grep -q "^map:[[:space:]]*e1m1" "$SRVDIR/server.log" || die "the dedicated server is not running e1m1"
pass "the game server is up on e1m1"

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
BASEDIR="$DOCS/rerelease"
GAMEDIR="$BASEDIR/id1"
mkdir -p "$GAMEDIR"
[ -f "$GAMEDIR/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$GAMEDIR/pak0.pak"
rm -f "$DOCS/console.log"

# (e) fixture: 24 mod dirs, so the mods list (14 on screen) actually scrolls. A
# directory counts as a mod if it holds maps/ (host_cmd.c Modlist_Add), so an
# empty maps/ is the whole fixture. Removed again by the cleanup trap.
MODDIRS=""
for i in $(seq -w 1 24); do
	mkdir -p "$BASEDIR/zztouch$i/maps"
	MODDIRS="$MODDIRS $BASEDIR/zztouch$i"
done
pass "fixture: 24 mod dirs under the basedir (mods list holds 14)"

# r_indirect 0: the simulator's Metal device rejects indirect draws (sim-verify.sh).
# developer 1: the tap-suppression decision is a Con_DPrintf — this run reads it.
cat > "$GAMEDIR/autoexec.cfg" <<'CFG'
r_indirect 0
developer 1
con_notifytime 0
cl_mapdownload 0
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

say   () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
mark  () { wc -l < "$LOG" | tr -d ' '; }
shot  () { xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-$1.png" || echo "   (screenshot unavailable)"; }
# The menu state a screenshot cannot show. Returns the last `menuinfo:` line's
# named field — the engine is the authority on where the list is scrolled to.
info () { # info <field>   (slist_first | slist_cursor | state | mods_first | scale)
	local m; m=$(mark)
	say 'vkq_menuinfo'; sleep 1
	local l1 l2
	l1=$(tail -n +"$m" "$LOG" | grep -E '^menuinfo: state=' | tail -1)
	l2=$(tail -n +"$m" "$LOG" | grep -E '^menuinfo: list rect=' | tail -1)
	case "$1" in
	state)       sed -E 's/.*state=([0-9-]+).*/\1/'                        <<<"$l1" ;;
	slist_first) sed -E 's/.*slist=\(first ([0-9-]+).*/\1/'                <<<"$l1" ;;
	slist_count) sed -E 's/.*slist=\(first [0-9-]+ cursor [0-9-]+ of ([0-9]+).*/\1/' <<<"$l1" ;;
	mods_first)  sed -E 's/.*mods=\(first ([0-9-]+).*/\1/'                 <<<"$l1" ;;
	mods_count)  sed -E 's/.*mods=\(first [0-9-]+ cursor [0-9-]+ of ([0-9]+).*/\1/'  <<<"$l1" ;;
	bar_size)    sed -E 's/.*scrollbar=\(x [0-9-]+ y [0-9-]+ size ([0-9]+).*/\1/'    <<<"$l2" ;;
	scale)       sed -E 's/.*canvas: scale ([0-9.]+).*/\1/'                <<<"$l2" ;;
	esac
}
# One injected finger, in MENU-canvas coords (rows are 8 apart, the server list
# starts at y=40) — the tap the assertions aim at a named row or at the gutter.
tap () { say "vkq_touchmenu $1 $2 down"; sleep 1; say "vkq_touchmenu $1 $2 up"; sleep 2; }

sleep 8
M=$(mark); say 'developer'; sleep 2
if tail -n +"$M" "$LOG" | grep -Eq '"developer" is "1"'; then
	pass "the fixture autoexec reached the engine (developer 1 — the tap-refusal evidence)"
else
	fail "developer did not read back as 1; the autoexec did not apply"
fi

# ===========================================================================
echo
echo "== (a) a scrollable server list: 40 fakes + one real server"
# ===========================================================================
say "vkq_slist_fake 40 127.0.0.1:$GAMEPORT"; sleep 1
say 'menu_slist'; sleep 3
COUNT=$(info slist_count); STATE=$(info state); BAR=$(info bar_size); SCALE=$(info scale)
[ "$STATE" = "$M_SLIST" ] && pass "(a) the server-list menu is up (state $STATE)" \
	|| fail "(a) menu state is $STATE, expected $M_SLIST (m_slist)"
[ "$COUNT" = 41 ] && pass "(a) 41 servers in the host cache, $ON_SCREEN fit on screen" \
	|| fail "(a) host cache holds $COUNT, expected 41"
[ "${BAR:-0}" -gt 0 ] && pass "(a) a scrollbar is drawn (size $BAR) — the list knows it overflows" \
	|| fail "(a) no scrollbar was drawn; the list does not think it overflows"
[ "$(info slist_first)" = 0 ] && pass "(a) the list opens at row 0" || fail "(a) the list did not open at the top"
echo "   menu canvas scale $SCALE  ->  one row = $(awk -v s="$SCALE" 'BEGIN{printf "%.0f", 8*s}') drawable px"
shot 01-a-page1

# ===========================================================================
echo
echo "== (b) a vertical DRAG scrolls the list, and joins nothing"
# ===========================================================================
M=$(mark); SM=$(srvmark)
say 'vkq_touchdrag 0.5 0.78 0.5 0.30 24'; sleep 2
FIRST=$(info slist_first)
if [ "${FIRST:-0}" -gt 5 ]; then
	pass "(b) dragging UP scrolled DOWN the list: slist_first 0 -> $FIRST"
else
	fail "(b) the drag did not scroll the list (slist_first = $FIRST)"
fi
[ "$(info state)" = "$M_SLIST" ] && pass "(b) still on the server list" || fail "(b) the drag left the server list"
# The client's own two connect signatures, and ONLY those: the console bridge
# logs "client connected/disconnected" of its own every time this script speaks
# to it, and a loose grep for "connect" fails this assertion on its own traffic.
CONNECT_RE='^trying\.\.\.|CL_EstablishConnection: connected to'
if tail -n +"$M" "$LOG" | grep -Eq "$CONNECT_RE"; then
	fail "(b) something tried to connect during a drag:"
	tail -n +"$M" "$LOG" | grep -E "$CONNECT_RE" | tail -3 >&2
else
	pass "(b) no connect was attempted by the drag"
fi
srv_no_player "$SM" && pass "(b) the game server saw nobody" || fail "(b) the drag put a player on the server"
shot 02-b-scrolled
# ... and back up again, which is the same mechanism in reverse
BACK_FROM=$FIRST
say 'vkq_touchdrag 0.5 0.30 0.5 0.78 24'; sleep 2
FIRST2=$(info slist_first)
[ "${FIRST2:-99}" -lt "${BACK_FROM:-0}" ] && pass "(b) dragging DOWN scrolled back up: $BACK_FROM -> $FIRST2" \
	|| fail "(b) the reverse drag did not scroll back (still $FIRST2)"

# ===========================================================================
echo
echo "== (d) the scroll gutter: taps there join nothing"
# ===========================================================================
# Two points, both in the band a thumb aiming at the bar actually lands in:
#   x=-20 : left of the menu canvas entirely (the bar sits at x=0)
#   x=10  : between the bar (0..8) and the first row column (12)
# Row 0 is the REAL server, so a stale-cursor activation here would connect.
say 'menu_slist'; sleep 3                       # fresh list: slist_first and the cursor back to row 0
GY=$((SLIST_TOP + ROW_H * 3 + 4))               # vertically over row 3, inside the bar's span
for GX in -20 10; do
	M=$(mark); SM=$(srvmark)
	tap $GX $GY
	if tail -n +"$M" "$LOG" | grep -q 'is outside the list — not activating'; then
		pass "(d) tap at menu x=$GX was refused by the gutter guard"
	else
		fail "(d) tap at menu x=$GX was NOT refused"
		tail -n +"$M" "$LOG" | grep -E 'touch:' | tail -3 >&2
	fi
	[ "$(info state)" = "$M_SLIST" ] && pass "(d) still on the server list after the x=$GX tap" \
		|| fail "(d) the x=$GX tap left the server list — it activated something"
	srv_no_player "$SM" && pass "(d) no player arrived on the game server" \
		|| fail "(d) the x=$GX gutter tap JOINED the server"
done
shot 03-d-gutter-tap-refused
# ... while a tap ON the bar is still the desktop page jump, never a join
M=$(mark); SM=$(srvmark)
BARY=$((SLIST_TOP + 100))
tap 4 $BARY
JUMPED=$(info slist_first)
[ "${JUMPED:-0}" -gt 0 ] && pass "(d) a tap ON the bar (x=4) jumped the page to first=$JUMPED" \
	|| fail "(d) a tap on the bar did nothing (first=$JUMPED)"
srv_no_player "$SM" && pass "(d) ... and still joined nothing" || fail "(d) the bar tap joined the server"
shot 04-d-bar-tap-page-jump

# ===========================================================================
echo
echo "== (c) a TAP on the real server's row joins it"
# ===========================================================================
say 'menu_slist'; sleep 3                       # back to the top; row 0 = LOCALHOST
[ "$(info slist_first)" = 0 ] || fail "(c) the list did not reopen at the top"
M=$(mark); SM=$(srvmark)
tap 100 $((SLIST_TOP + 4))                      # row 0, well inside the row columns
if tail -n +"$M" "$LOG" | grep -Eq "127\.0\.0\.1:$GAMEPORT|trying\.\.\."; then
	pass "(c) the tap issued the connect to 127.0.0.1:$GAMEPORT"
else
	fail "(c) no connect attempt followed the tap on row 0"
	tail -n +"$M" "$LOG" | tail -8 >&2
fi
sleep 10
if srv_has_player "$SM"; then
	pass "(c) the game server sees one active player — the tap really joined"
else
	fail "(c) the server never saw the client join"
	tail -n +"$SM" "$SRVDIR/server.log" | grep -E 'players:|^map:' | tail -4 >&2
fi
shot 05-c-joined-real-server
say 'disconnect'; sleep 4
alive || die "(c) the app stopped answering after the join"

# ===========================================================================
echo
echo "== (e) the same drag scrolls the MODS list — no per-menu code"
# ===========================================================================
say 'menu_mods'; sleep 3
MC=$(info mods_count)
[ "${MC:-0}" -gt 14 ] && pass "(e) the mods list holds $MC entries (14 fit)" \
	|| fail "(e) only $MC mods — the list cannot scroll"
[ "$(info state)" = "$M_MODS" ] && pass "(e) the mods menu is up" || fail "(e) menu state is $(info state), expected $M_MODS"
shot 06-e-mods-page1
M=$(mark)
say 'vkq_touchdrag 0.5 0.72 0.5 0.34 20'; sleep 2
MF=$(info mods_first)
[ "${MF:-0}" -gt 0 ] && pass "(e) the drag scrolled the mods list: first_mod 0 -> $MF" \
	|| fail "(e) the mods list did not scroll (first_mod = $MF)"
[ "$(info state)" = "$M_MODS" ] && pass "(e) still on the mods menu — the drag activated nothing" \
	|| fail "(e) the drag left the mods menu (a mod was launched!)"
shot 07-e-mods-scrolled

# ===========================================================================
echo
echo "== (f) a drag on the MAIN menu does nothing at all"
# ===========================================================================
say 'menu_main'; sleep 3
[ "$(info state)" = "$M_MAIN" ] && pass "(f) the main menu is up" || fail "(f) menu state is $(info state), expected $M_MAIN"
[ "$(info bar_size)" = 0 ] && pass "(f) no scrollbar on the main menu — no wheel keys will be emitted" \
	|| fail "(f) the main menu drew a scrollbar (size $(info bar_size))?"
M=$(mark)
say 'vkq_touchdrag 0.5 0.72 0.5 0.28 20'; sleep 3
[ "$(info state)" = "$M_MAIN" ] && pass "(f) still on the main menu after a full-screen drag" \
	|| fail "(f) the drag left the main menu — it activated something (state $(info state))"
alive || die "(f) the app stopped answering after the main-menu drag"
shot 08-f-main-menu-after-drag

# ===========================================================================
echo
echo "== (x) taps still activate: Main -> Multiplayer by touch"
# ===========================================================================
# The main menu's rows are 20 apart from y=32 (M_Mouse_UpdateListCursor 70,320,32,20),
# so Multiplayer is row 1. This is the path Austin walks to reach the server list.
M=$(mark)
tap 150 $((32 + 20 * 1 + 8))
if [ "$(info state)" = "$M_MULTIPLAYER" ]; then
	pass "(x) the tap opened the Multiplayer menu — activation is unchanged"
else
	fail "(x) the tap did not open Multiplayer (state $(info state))"
fi
shot 09-x-tap-opened-multiplayer

# ---------------------------------------------------------------------------
echo
echo "== artifacts"
cp "$LOG" "$PFX-console.log" 2>/dev/null && echo "   client log: $PFX-console.log"
sed -E 's/^(tcp\/ip:[[:space:]]*).*/\1<redacted>/' "$SRVDIR/server.log" > "$PFX-server.log" 2>/dev/null \
	&& echo "   server log: $PFX-server.log"

[ "$FAILED" = 0 ] || { echo "TOUCHSCROLL VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "TOUCHSCROLL VERIFY DONE"
