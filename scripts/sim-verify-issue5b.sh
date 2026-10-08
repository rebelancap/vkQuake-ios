#!/usr/bin/env bash
#
# sim-verify-issue5b.sh — issue #5 follow-ups (1.1.2.1 review):
#   1. the console button is a glyph-only 64x46 button in the back / gear column,
#      directly under the gear (same x, same 58 pt pitch)
#   2. QUICK SAVE / QUICK LOAD stack below it; all five never overlap
#   3. the console text is indented past the notch / Dynamic Island (overlay
#      0031), and the indent is 0 when the cutout is on the right (then only the
#      line width shrinks). iOS reports symmetric left/right safe-area insets in
#      both landscape sides, so the cutout side comes from the orientation.
#   +  the quick pills' glyphs are the same 20 pt bold size as back / gear
#
# Lane 2 (iPhone Air, iOS 27.0). The headless sim cannot be rotated with simctl;
# `vkq_ui orient left|right|any` asks the window scene for one landscape side
# (requestGeometryUpdate), which is the same path a physical rotation ends in.
# Never simctl create. The device is shut down on every exit path.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
# Lane 2: the existing iPhone Air on iOS 27.0, looked up by name (never created).
UDID=${VKQ_SIM_UDID:-$(xcrun simctl list devices available | awk '/^-- iOS 27.0 --/{f=1;next} /^--/{f=0} f && /^ *iPhone Air \(/' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}
[ -n "$UDID" ] || { echo "FATAL: no iPhone Air on iOS 27.0 — ask the user; never simctl create" >&2; exit 1; }
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim/issue5b"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh ios" >&2; exit 1; }
[ -f "$ROOT/gamedata/rerelease/id1/pak0.pak" ] || { echo "FATAL: gamedata/rerelease/id1/pak0.pak missing" >&2; exit 1; }
if xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
	echo "FATAL: $UDID is already Booted — another session owns lane 2" >&2; exit 1
fi
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then echo "FATAL: port $PORT already in use" >&2; exit 1; fi

FAILED=0
cleanup () {
	local rc=$?
	set +e
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null
	echo "== shutting down $UDID (always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null
	if [ "$rc" != 0 ] || [ "$FAILED" != 0 ]; then
		echo "ISSUE5B VERIFY: *** FAILED *** (status $rc, failures $FAILED)" >&2; exit 1
	fi
	echo "ISSUE5B VERIFY: PASSED (now LOOK at the screenshots)"
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
shot  () { xcrun simctl io "$UDID" screenshot "$ARTS/$1.png" >/dev/null 2>&1 && echo "   shot: $ARTS/$1.png" || fail "screenshot $1"; }
anylog () { cat "$DOCS/boot.log" "$LOG" 2>/dev/null; }
uistate () { local m; m=$(mark); say 'vkq_ui state'; sleep 1; since "$m" | grep 'vkq_ui state' | tail -1 || true; }
# frame <name> <state line>  ->  "x y w h" of {{x, y}, {w, h}}
frame () { echo "$2" | sed -n "s/.* $1={{\([-0-9.]*\), \([-0-9.]*\)}, {\([0-9.]*\), \([0-9.]*\)}}.*/\1 \2 \3 \4/p"; }
safe_left () { echo "$1" | sed -n 's/.*safe={[-0-9.]*, \([-0-9.]*\),.*/\1/p'; }

echo "== data: 2021 re-release only"
rm -rf "$DOCS/rerelease" "$DOCS/id1"
mkdir -p "$DOCS/rerelease/id1"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
printf 'r_indirect 0\ncon_notifytime 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"
rm -f "$DOCS/rerelease/id1/quick.sav" "$DOCS"/rerelease/id1/*/quick.sav 2>/dev/null || true
for k in DidShowContinuousPathIntroduction KeyboardDidShowContinuousPathIntroduction; do
	xcrun simctl spawn "$UDID" defaults write com.apple.Preferences $k -bool true
done

rm -f "$LOG" "$DOCS/boot.log"
env SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 xcrun simctl launch "$UDID" $BUNDLE >/dev/null
ok=0
for _ in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || { tail -30 "$DOCS/boot.log" >&2 2>/dev/null; die "bridge never opened"; }
sleep 8

# ---------------------------------------------------------------- (a) column
say 'togglemenu'; sleep 2
S=$(uistate); echo "   $S"
read -r bx by bw bh <<<"$(frame back "$S")"
read -r gx gy gw gh <<<"$(frame gear "$S")"
read -r cx cy cw ch <<<"$(frame console_pill "$S")"
echo "   back=$bx,$by ${bw}x$bh  gear=$gx,$gy ${gw}x$gh  console=$cx,$cy ${cw}x$ch"
[ -n "$cx" ] || die "(a) console button not shown in the main menu"
[ "$cw" = 64 ] && [ "$ch" = 46 ] && pass "(a) console button is 64x46 like back/gear" || fail "(a) console size ${cw}x$ch"
[ "$cx" = "$bx" ] && [ "$cx" = "$gx" ] && pass "(a) console x = back x = gear x ($cx)" || fail "(a) column x mismatch"
python3 -I -c "import sys; b,g,c=map(float,sys.argv[1:]); sys.exit(0 if abs((g-b)-(c-g))<0.5 else 1)" "$by" "$gy" "$cy" \
	&& pass "(a) console directly under the gear, same pitch as gear under back" || fail "(a) pitch mismatch ($by $gy $cy)"
shot a-menu-back-gear-console-column

# ---------------------------------------------------------------- (b) all five
say 'togglemenu'; sleep 1
say 'map e1m1'; sleep 10
say 'save quick'; sleep 3   # vkq_quicksave (the pill) is refused outside the menu
say 'togglemenu'; sleep 2
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'qsave={' && echo "$S" | grep -q 'qload={' && echo "$S" | grep -q 'console_pill={' \
	&& pass "(b) back, gear, console, quick save, quick load all visible" || fail "(b) not all five visible"
if python3 -I - "$S" <<'PY'
import re, sys
s = sys.argv[1]
fr = {}
for n in ("back", "gear", "console_pill", "qsave", "qload"):
    m = re.search(r" %s=\{\{([-\d.]+), ([-\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}" % n, s)
    if not m: sys.exit("missing " + n)
    fr[n] = tuple(map(float, m.groups()))
order = ["back", "gear", "console_pill", "qsave", "qload"]
bad = 0
for i, a in enumerate(order):
    for b in order[i + 1:]:
        ax, ay, aw, ah = fr[a]; bx, by, bw, bh = fr[b]
        if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
            print("   OVERLAP", a, b); bad = 1
for a, b in zip(order, order[1:]):
    if fr[b][1] <= fr[a][1]: print("   ORDER", a, b); bad = 1
if fr["qload"][1] + fr["qload"][3] > 420: print("   OFF-SCREEN qload"); bad = 1
if fr["qsave"][0] != fr["back"][0]: print("   left edges differ"); bad = 1
for n in order: print("   %-12s %s" % (n, fr[n]))
sys.exit(bad)
PY
then pass "(b) column order back/gear/console/qsave/qload, no overlap, on screen"; else fail "(b) overlap/order"; fi
shot b-live-game-menu-all-five

# ---------------------------------------------------------------- (c) indent
say 'togglemenu'; sleep 2
S=$(uistate); echo "   $S"
SL=$(safe_left "$S"); echo "   safe-area left = $SL pt (orientation $(echo "$S" | sed -n 's/.*orient=\([0-9]*\).*/\1/p'): 3 = LandscapeRight = cutout LEFT, 4 = LandscapeLeft = cutout RIGHT)"
say 'vkq_ui threefinger'; sleep 3
say 'vkq_ui type version'; sleep 1; say 'vkq_ui enter'; sleep 1
say 'vkq_ui type "map e1m1"'; sleep 2
S=$(uistate); echo "   $S"
echo "$S" | grep -q 'keydest=1' && echo "$S" | grep -q 'kb_visible=1' && pass "(c) console + keyboard up" || fail "(c) console/keyboard"
INSET=$(anylog | grep 'console inset:' | tail -2); echo "$INSET" | sed 's/^/   /'
python3 -I -c "import sys; sys.exit(0 if float(sys.argv[1])>0 else 1)" "${SL:-0}" \
	&& { echo "$S" | grep -q 'orient=3' && echo "$INSET" | tail -1 | grep -qv 'left 0 px' && pass "(c) engine got a non-zero inset with the cutout on the left" || fail "(c) engine inset not set"; } \
	|| fail "(c) default orientation has no left inset — expected the island on the left"
shot c-console-indented-keyboard-up

# ---------------------------------------------------------------- (d) flipped
say 'vkq_ui type "~"'; sleep 2
say 'vkq_ui orient left'; sleep 4
S=$(uistate); echo "   $S"
SL2=$(safe_left "$S"); echo "   after orient left: safe-area left = $SL2 pt (iOS keeps it symmetric)"
echo "$S" | grep -q 'orient=4' && pass "(d) flipped to LandscapeLeft (cutout on the right)" || fail "(d) flip did not happen"
say 'vkq_ui threefinger'; sleep 3
say 'vkq_ui type version'; sleep 1; say 'vkq_ui enter'; sleep 1
anylog | grep 'console inset:' | tail -2 | sed 's/^/   /'
anylog | grep 'console inset:' | tail -1 | grep -q 'left 0 px, right [1-9]' && pass "(d) engine indent 0 px (right inset only) with the cutout on the right" || fail "(d) indent not 0 after flip"
shot d-flipped-console-zero-indent
say 'vkq_ui type "~"'; sleep 2
say 'togglemenu'; sleep 2
S=$(uistate); echo "   $S"
shot d2-flipped-menu-column
say 'vkq_ui orient any'; sleep 2

grep -h -E 'console inset|safe area changed|vkq_ui orient' "$DOCS/boot.log" "$LOG" 2>/dev/null > "$ARTS/inset-log.txt" || true
cp "$LOG" "$ARTS/console.log"
sed -i '' "s|$HOME|~|g" "$ARTS"/*.log "$ARTS"/*.txt 2>/dev/null || true
[ "$FAILED" = 0 ] || exit 1
