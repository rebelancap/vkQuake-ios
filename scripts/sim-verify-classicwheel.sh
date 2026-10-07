#!/usr/bin/env bash
#
# sim-verify-classicwheel.sh — GitHub issue #4: the weapon wheel on ORIGINAL id1.
#
# WHAT THIS PROVES, on an iOS simulator:
#   a. original id1 (pak0+pak1, no rerelease dir) boots and `map e1m1` renders
#   b. `weaponwheel` opens the wheel on classic data: the classic-path log line,
#      `weapon wheel: 8 slots` (developer 1), and a screenshot of the ring
#   c. the wheel really switches weapons: impulse 9, `weaponwheel` (preselects
#      slot 5 = super nailgun), `-weaponwheel` (Close -> impulse 5); readback is
#      the server edict's `weapon` (8 = IT_SUPER_NAILGUN) + `weaponmodel`
#   d. no `W_GetLumpName: inv*/inv2* not found` warnings (a wrong lump name would
#      draw the pic_nul checkerboard instead of the icon)
#   e. regression: rerelease id1 still gets the rerelease wheel (no classic line)
#
# NOT proven here: the touch BUTTON path (UIKit -> SCR_WeaponWheel_TouchOpen) —
# synthetic UIKit touches do not reach it on a simulator. It is unchanged by the
# issue-#4 fix, which lives entirely in the engine's slot loader; the console
# commands above drive the same Open/Close/Load functions.
#
# LANE 2 (~/dev/CLAUDE.md): the EXISTING iPhone Air on iOS 27.0. Never simctl
# create. The device is shut down on every exit path, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999                      # console bridge (8765-8769 are OTHER sessions' — never use them)
UDID=${VKQ_SIM_UDID:-45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22} # iPhone Air, iOS 27.0 (lane 2)
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-classicwheel"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
for p in PAK0.PAK PAK1.PAK; do [ -f "$ROOT/gamedata/id1/$p" ] || { echo "FATAL: gamedata/id1/$p missing" >&2; exit 1; }; done
[ -f "$ROOT/gamedata/rerelease/id1/pak0.pak" ] || { echo "FATAL: gamedata/rerelease/id1/pak0.pak missing" >&2; exit 1; }

# refuse a lane someone else is using (checked BEFORE the trap, so we never shut it down)
if xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
	echo "FATAL: $UDID is already Booted — another session owns lane 2" >&2; exit 1
fi
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another session owns it" >&2; exit 1
fi

FAILED=0
INTERRUPTED=0
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	set +e
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$INTERRUPTED" != 0 ]; then
		echo "CLASSICWHEEL VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "CLASSICWHEEL VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "CLASSICWHEEL VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die  () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "== install"
xcrun simctl install "$UDID" "$APP"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
LOG="$DOCS/console.log"

say   () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
mark  () { wc -l < "$LOG" | tr -d ' '; }
since () { tail -n +"$1" "$LOG"; }
shot  () { xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 \
	&& echo "   shot: $PFX-$1.png" || fail "screenshot $1 unavailable"; }
# r_indirect 0 / the env below: simulator-only MoltenVK workarounds (sim-verify.sh).
autoexec () {
	cat > "$1/autoexec.cfg" <<'CFG'
r_indirect 0
developer 1
con_notifytime 0
CFG
}
launch () {
	rm -f "$LOG"
	SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
		SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
		xcrun simctl launch "$UDID" $BUNDLE
	local ok=0
	for _ in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
	[ "$ok" = 1 ] || { tail -30 "$DOCS/boot.log" >&2 2>/dev/null; die "the console bridge never opened"; }
	sleep 8
}
# edict field readback: `edict 1` is the player; print "<field> <value>" of the last dump
edictfield () { # edictfield <since-line> <field>
	since "$1" | grep -E "^$2[[:space:]]" | tail -1 | awk '{print $2}'
}

# ===========================================================================
echo
echo "== data: ORIGINAL id1 only (the shell prefers Documents/rerelease when present)"
# ===========================================================================
# This is a simulator container — no user data. VKQ_iOS_BasedirPath picks
# Documents/rerelease if rerelease/id1/pak0.pak exists, so it must be gone.
rm -rf "$DOCS/rerelease"
mkdir -p "$DOCS/id1"
cp -c "$ROOT/gamedata/id1/PAK0.PAK" "$DOCS/id1/pak0.pak.tmp" && mv -f "$DOCS/id1/pak0.pak.tmp" "$DOCS/id1/pak0.pak"
cp -c "$ROOT/gamedata/id1/PAK1.PAK" "$DOCS/id1/pak1.pak.tmp" && mv -f "$DOCS/id1/pak1.pak.tmp" "$DOCS/id1/pak1.pak"
autoexec "$DOCS/id1"
ls -l "$DOCS/id1"

launch
alive && pass "boot smoke: the app is up and the bridge answers" || die "app not answering"
# `path` prints the search path; the classic set mounts id1/pak1.pak, never rerelease/
M=$(mark); say 'path'; sleep 2
since "$M" | grep -q 'id1/pak1.pak' && pass "classic id1/pak1.pak is on the search path" \
	|| { fail "id1/pak1.pak not on the search path — not the classic data set"; since "$M" >&2; }
since "$M" | grep -q 'rerelease/' && fail "a rerelease/ dir is on the search path" || pass "no rerelease/ on the search path"

# ===========================================================================
echo
echo "== (a) map e1m1 renders"
# ===========================================================================
say 'map e1m1'; sleep 8
since 1 | grep -q 'e1m1\|The Slipgate Complex' && pass "(a) e1m1 loaded" || fail "(a) e1m1 not in the log"
shot 01-a-e1m1

# ===========================================================================
echo
echo "== (b) the wheel opens on classic data"
# ===========================================================================
M=$(mark)
say 'weaponwheel'; sleep 3
since "$M" | grep -q 'weapon wheel: no wwheel.txt (classic data)' \
	&& pass "(b) classic-path line logged" || fail "(b) no classic-path line"
since "$M" | grep -q 'weapon wheel: 8 slots' \
	&& pass "(b) weapon wheel: 8 slots" || { fail "(b) no '8 slots' line"; since "$M" | grep 'weapon wheel' >&2; }
shot 02-b-wheel-classic-unowned
say 'weaponwheel'; sleep 2      # toggle closed (no switch)

# ===========================================================================
echo
echo "== (c) the wheel switches the weapon (impulse 9 -> wheel slot 5 -> impulse 5)"
# ===========================================================================
say 'impulse 9'; sleep 2
M=$(mark); say 'edict 1'; sleep 2
W0=$(edictfield "$M" weapon); WM0=$(edictfield "$M" weaponmodel)
echo "   after impulse 9: weapon=$W0 weaponmodel=$WM0"
[ "$W0" = 32 ] && pass "(c) impulse 9 selected the rocket launcher (weapon 32)" \
	|| fail "(c) unexpected weapon after impulse 9: '$W0'"
say 'weaponwheel'; sleep 2      # opens, preselects slot 5 (super nailgun)
shot 03-c-wheel-classic-allowned
say '-weaponwheel'; sleep 3     # Close -> impulse 5 for the owned slot
M=$(mark); say 'edict 1'; sleep 2
W1=$(edictfield "$M" weapon); WM1=$(edictfield "$M" weaponmodel)
echo "   after -weaponwheel: weapon=$W1 weaponmodel=$WM1"
[ "$W1" = 8 ] && pass "(c) the wheel switched to the super nailgun (weapon 8 = IT_SUPER_NAILGUN)" \
	|| fail "(c) weapon is '$W1', expected 8"
case "$WM1" in *v_nail2.mdl*) pass "(c) viewmodel is $WM1" ;; *) fail "(c) viewmodel is '$WM1', expected progs/v_nail2.mdl" ;; esac
shot 04-c-hud-supernailgun

# ===========================================================================
echo
echo "== (d) no missing status-bar icon lumps"
# ===========================================================================
if grep -E 'not found' "$LOG" | grep -Eq 'inv2?_'; then
	fail "(d) missing inv lumps:"; grep -E 'not found' "$LOG" | grep -E 'inv2?_' >&2
else
	pass "(d) no W_GetLumpName inv_*/inv2_* warnings"
fi
cp "$LOG" "$PFX-classic-console.log"

# ===========================================================================
echo
echo "== (e) regression: rerelease id1 still gets the rerelease wheel"
# ===========================================================================
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
sleep 2
rm -rf "$DOCS/id1"
mkdir -p "$DOCS/rerelease/id1"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
autoexec "$DOCS/rerelease/id1"
launch
alive || die "(e) the rerelease boot did not answer"
say 'map e1m1'; sleep 8
M=$(mark)
say 'weaponwheel'; sleep 3
since "$M" | grep -q 'weapon wheel: 8 slots' && pass "(e) rerelease wheel loaded 8 slots" || fail "(e) no '8 slots' line"
grep -q 'classic data' "$LOG" && fail "(e) the classic path ran on rerelease data" || pass "(e) no classic-path line on rerelease data"
shot 05-e-wheel-rerelease
say 'weaponwheel'; sleep 1
cp "$LOG" "$PFX-rerelease-console.log"

[ "$FAILED" = 0 ] || { echo "CLASSICWHEEL VERIFY: see the FAIL lines above" >&2; exit 1; }
echo "CLASSICWHEEL VERIFY DONE"
