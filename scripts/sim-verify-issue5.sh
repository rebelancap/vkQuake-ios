#!/usr/bin/env bash
#
# sim-verify-issue5.sh — GitHub issue #5 (touch-only player): console by touch
# and the Classic / 2021 game-data choice.
#
# WHAT THIS PROVES, on the lane-2 iPhone Air simulator (iOS 27.0):
#   a. with BOTH data sets on disk and no preference, the 2021 set loads (log line)
#   b. the CONSOLE pill is on screen in the main menu; pressing it (its own
#      UIButton target, via `vkq_ui console`) opens the console and raises the
#      soft keyboard; typed text lands on the input line and a command's output
#      shows above it, with the keyboard up
#   c. in-game, the 3-finger-tap action opens the console + keyboard; `~` typed
#      on the keyboard closes it and opens it again
#   d. the iOS settings sheet shows the Game Data section (both sets present)
#   e. after choosing Classic (the same NSUserDefaults key the picker writes) and
#      relaunching, the classic basedir is logged, `path` mounts id1/pak1.pak and
#      e1m1 renders with the classic status bar
#
# NOT proven here: real-finger delivery (injected UIKit touches never reach the
# shell on a simulator — `vkq_ui` calls the same methods the gestures call).
#
# Never simctl create. The device is shut down on every exit path.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22} # iPhone Air, iOS 27.0 (lane 2)
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim/issue5"
TAG=${VKQ_ISSUE5_TAG:-}
PFX="$ARTS/${TAG}"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
for p in PAK0.PAK PAK1.PAK; do [ -f "$ROOT/gamedata/id1/$p" ] || { echo "FATAL: gamedata/id1/$p missing" >&2; exit 1; }; done
[ -f "$ROOT/gamedata/rerelease/id1/pak0.pak" ] || { echo "FATAL: gamedata/rerelease/id1/pak0.pak missing" >&2; exit 1; }
if xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
	echo "FATAL: $UDID is already Booted — another session owns lane 2" >&2; exit 1
fi
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use" >&2; exit 1
fi

FAILED=0
cleanup () {
	local rc=$?
	set +e
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null
	echo "== shutting down $UDID (always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$rc" != 0 ] || [ "$FAILED" != 0 ]; then
		echo "ISSUE5 VERIFY: *** FAILED *** (status $rc, failures $FAILED)" >&2; exit 1
	fi
	echo "ISSUE5 VERIFY: PASSED (now LOOK at the screenshots)"
}
trap cleanup EXIT
trap 'exit 143' INT TERM
die  () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }
pass () { echo "   PASS  $1"; }
fail () { echo "   FAIL  $1" >&2; FAILED=1; }

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
LOG="$DOCS/console.log"

say   () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
mark  () { wc -l < "$LOG" | tr -d ' '; }
since () { tail -n +"$1" "$LOG"; }
shot  () { xcrun simctl io "$UDID" screenshot "$PFX$1.png" >/dev/null 2>&1 && echo "   shot: $PFX$1.png" || fail "screenshot $1"; }
autoexec () { printf 'r_indirect 0\ncon_notifytime 0\n' > "$1/autoexec.cfg"; }
launch () { # launch [extra env assignments...]
	rm -f "$LOG" "$DOCS/boot.log"
	env SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
		SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 "$@" xcrun simctl launch "$UDID" $BUNDLE >/dev/null
	local ok=0
	for _ in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
	[ "$ok" = 1 ] || { tail -30 "$DOCS/boot.log" >&2 2>/dev/null; die "bridge never opened"; }
	sleep 8
}
anylog () { cat "$DOCS/boot.log" "$LOG" 2>/dev/null; }
uistate () { local m; m=$(mark); say 'vkq_ui state'; sleep 1; since "$m" | grep 'vkq_ui state' | tail -1 || true; }

echo "== data: BOTH sets (rerelease + classic), no preference"
rm -rf "$DOCS/rerelease" "$DOCS/id1"
mkdir -p "$DOCS/rerelease/id1" "$DOCS/id1"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
cp -c "$ROOT/gamedata/id1/PAK0.PAK" "$DOCS/id1/pak0.pak"
cp -c "$ROOT/gamedata/id1/PAK1.PAK" "$DOCS/id1/pak1.pak"
autoexec "$DOCS/rerelease/id1"; autoexec "$DOCS/id1"
xcrun simctl spawn "$UDID" defaults delete $BUNDLE vkq.gameData >/dev/null 2>&1 || true
# Simulator-only: skip the one-time "slide to type" keyboard tip, which otherwise
# covers the keys in the first keyboard screenshot. A preference of the sim
# device's keyboard, not of the app.
for k in DidShowContinuousPathIntroduction KeyboardDidShowContinuousPathIntroduction; do
	xcrun simctl spawn "$UDID" defaults write com.apple.Preferences $k -bool true
done

# ---------------------------------------------------------------- (a) + (b)
launch
anylog | grep -q 'game data: 2021 re-release' && pass "(a) default with both sets = 2021 re-release" \
	|| { fail "(a) no 2021 game-data line"; anylog | grep 'game data' >&2 || true; }
anylog | grep 'game data:' | head -1 || true
M=$(mark); say 'scr_relativescale'; say 'scr_relconscale'; say 'scr_conscale'; say 'vid_width'; sleep 1
since "$M" | grep -E 'scr_|vid_' | sed 's/^/   cvar: /' || true

say 'togglemenu'; sleep 2
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'console_pill={' && pass "(b) CONSOLE pill on screen in the main menu" || fail "(b) CONSOLE pill not shown"
shot b1-menu-with-console-pill
say 'vkq_ui console'; sleep 3
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' && pass "(b) pill opened the console (keydest=1)" || fail "(b) console not open after the pill"
echo "$S" | grep -q 'kb_visible=1' && pass "(b) soft keyboard is up" || fail "(b) keyboard not up"
# half-screen console: its input line (y = 210 pt) already clears the keyboard
echo "$S" | grep -q 'sdl_view={{0, 0}' && pass "(b) no view shift for the half-screen console" || fail "(b) game view shifted under a half-screen console"
grep -h 'keyboard shown' "$LOG" | tail -1 | sed 's/^/   /' || true
say 'vkq_ui type version'; sleep 1; say 'vkq_ui enter'; sleep 1
say 'vkq_ui type "map e1m1"'; sleep 2
shot b2-console-from-menu-pill-keyboard-up
M=$(mark); say 'vkq_ui type "~"'; sleep 2
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' && fail "(b) ~ did not close the console" || pass "(b) ~ on the keyboard closed the console"

# ---------------------------------------------------------------- (c)
say 'map e1m1'; sleep 8
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=0' || fail "(c) not in game before the 3-finger tap"
say 'vkq_ui threefinger'; sleep 3
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' && pass "(c) 3-finger tap in game opened the console" || fail "(c) 3-finger tap did not open the console"
echo "$S" | grep -q 'kb_visible=1' && pass "(c) keyboard up" || fail "(c) keyboard not up"
echo "$S" | grep -q 'sdl_view={{0, 0}' && pass "(c) no view shift for the half-screen console" || fail "(c) view shifted"
say 'vkq_ui type version'; sleep 1; say 'vkq_ui enter'; sleep 1
say 'vkq_ui type "god"'; sleep 2
shot c1-console-in-game-3finger-keyboard-up
say 'vkq_ui threefinger'; sleep 2
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' && echo "$S" | grep -q 'kb_visible=0' && pass "(c) 3-finger tap with the console up hides only the keyboard" || fail "(c) 3-finger re-tap"
say 'vkq_ui threefinger'; sleep 2
S=$(uistate); echo "$S" | grep -q 'kb_visible=1' && pass "(c) 3-finger tap re-summons the keyboard" || fail "(c) keyboard not re-summoned"
say 'vkq_ui type "~"'; sleep 2
S=$(uistate); echo "$S" | grep -q 'keydest=0' && pass "(c) ~ closed the console back to the game" || fail "(c) ~ did not close"
say 'vkq_ui type "~"'; sleep 2
S=$(uistate); echo "$S" | grep -q 'keydest=1' && pass "(c) ~ from the game opened the console" || fail "(c) ~ from game"
shot c2-console-in-game-tilde
say 'vkq_ui type "~"'; sleep 2

# ---------------------------------------------------------------- (f)
echo "== (f) full-screen console (nothing running): the input line is at the bottom"
say 'disconnect'; sleep 3
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' || { say 'vkq_ui threefinger'; sleep 3; S=$(uistate); echo "   $S"; }
echo "$S" | grep -q 'keydest=1' && echo "$S" | grep -q 'kb_visible=1' && pass "(f) full-screen console with the keyboard up" || fail "(f) no console+keyboard"
# full-screen console: the view must rise by the whole keyboard (+10 pt margin)
SH_Y=$(echo "$S" | sed -n 's/.*sdl_view={{0, \(-*[0-9]*\)}.*/\1/p')
echo "   view origin y = $SH_Y pt"
[ -n "$SH_Y" ] && [ "$SH_Y" -le -150 ] && pass "(f) view raised ${SH_Y} pt so the bottom input line clears the keyboard" || fail "(f) view not raised (y=$SH_Y)"
grep -h 'keyboard shown' "$LOG" | tail -1 | sed 's/^/   /' || true
say 'vkq_ui type version'; sleep 1; say 'vkq_ui enter'; sleep 1
say 'vkq_ui type "map e1m1"'; sleep 2
shot f1-fullscreen-console-keyboard-up
cp "$LOG" "${PFX}rerelease-console.log"

# ---------------------------------------------------------------- (d)
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true; sleep 2
launch SIMCTL_CHILD_VKQ_SHOW_SETTINGS=1
sleep 2
shot d1-settings-game-data-row

# ---------------------------------------------------------------- (e)
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true; sleep 2
xcrun simctl spawn "$UDID" defaults write $BUNDLE vkq.gameData -float 1
launch
anylog | grep 'game data:' | head -1 || true
anylog | grep -q 'game data: classic' && pass "(e) classic basedir after switching" || fail "(e) no classic game-data line"
M=$(mark); say 'path'; sleep 2
since "$M" | grep -q 'id1/pak1.pak' && pass "(e) id1/pak1.pak mounted" || fail "(e) pak1 not on the search path"
since "$M" | grep -q 'rerelease/' && fail "(e) rerelease/ on the search path" || pass "(e) no rerelease/ on the search path"
say 'map e1m1'; sleep 8
shot e1-classic-e1m1
anylog | grep -E 'game data:|^Command line' > "${PFX}classic-launch-log.txt" || true
cp "$LOG" "${PFX}classic-console.log"

xcrun simctl spawn "$UDID" defaults delete $BUNDLE vkq.gameData >/dev/null 2>&1 || true
# public repo: no home-directory paths in committed logs
sed -i '' "s|$HOME|~|g" "$PFX"*.log "$PFX"*.txt 2>/dev/null || true
[ "$FAILED" = 0 ] || exit 1
