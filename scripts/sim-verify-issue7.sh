#!/usr/bin/env bash
#
# sim-verify-issue7.sh — external-display orientation (GitHub issue #7) on the iPad
# simulator. The simulator's external screen (TVOut) only MIRRORS: SpringBoard
# registers it as "derived(mirroredDisplay)", the app never sees it in
# UIScreen.screens, and SBSExternalDisplayService refuses to un-mirror it (error 1,
# no extended-display hardware). So the external path is emulated:
# VKQ_EMULATE_EXTERNAL_DISPLAY=1 makes SDL (patch 0003) and the shell (ios_touch.m)
# treat the iPad's own screen as an external one. Pass = the scene stays in the
# panel's native orientation (portrait), and the SDL view and the Metal drawable
# match the native panel exactly; the engine screenshot (= the drawable) and the
# panel framebuffer screenshot both show the game upright and full.
#
#   VKQ_SIM_UDID=<ipad udid> scripts/sim-verify-issue7.sh     (build-sim.sh ios first)
#
# Shuts the device down on exit (pass or fail).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:?set VKQ_SIM_UDID to an iPad simulator}
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"; STAMP=$(date '+%Y-%m-%d')-issue7
[ -d "$APP" ] || { echo "FATAL: run scripts/build-sim.sh ios" >&2; exit 1; }
nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { echo "FATAL: port $PORT busy" >&2; exit 1; }
trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
DOCS="$(xcrun simctl get_app_container "$UDID" $BUNDLE data)/Documents"
mkdir -p "$DOCS/rerelease/id1" "$ARTS"
[ -f "$DOCS/rerelease/id1/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
printf 'r_indirect 0\nvolume 0\nbgmvolume 0\n' > "$DOCS/rerelease/id1/autoexec.cfg" # sim-only; silent
SIMCTL_CHILD_VKQ_EMULATE_EXTERNAL_DISPLAY=1 SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 \
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
	timeout 60 xcrun simctl launch "$UDID" $BUNDLE
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && break; sleep 1; done
nc -z -G 1 127.0.0.1 $PORT 2>/dev/null || { echo "FATAL: bridge never opened" >&2; exit 1; }
con () { (printf '%s\n' "$1"; sleep 3) | nc -w 5 127.0.0.1 $PORT | grep -v '^20\|^\]' || true; }
sleep 4
con 'map e1m1' >/dev/null; sleep 5
con 'vkq_mouse' > "$ARTS/$STAMP-emu-vkq_mouse.txt"
before=$(ls "$DOCS/rerelease/id1/"*.png 2>/dev/null | wc -l)
con 'screenshot' >/dev/null; sleep 1
shot=$(ls -t "$DOCS/rerelease/id1/"*.png 2>/dev/null | head -1)
[ "$(ls "$DOCS/rerelease/id1/"*.png 2>/dev/null | wc -l)" -gt "$before" ] || { echo "FATAL: engine screenshot not written" >&2; exit 1; }
cp "$shot" "$ARTS/$STAMP-emu-drawable.png"
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMP-emu-panel.png" >/dev/null
timeout 60 xcrun simctl terminate "$UDID" $BUNDLE || true
cat "$ARTS/$STAMP-emu-vkq_mouse.txt"
native=$(sed -n 's/.*screen(main): .*native=\([0-9]*x[0-9]*\).*/\1/p' "$ARTS/$STAMP-emu-vkq_mouse.txt" | head -1)
drawable=$(grep 'vc=SDL_uikitviewcontroller' "$ARTS/$STAMP-emu-vkq_mouse.txt" | sed -n 's/.*drawable=\([0-9]*x[0-9]*\).*/\1/p' | head -1)
shotsize=$(sips -g pixelWidth -g pixelHeight "$ARTS/$STAMP-emu-drawable.png" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w "x" h}')
echo "native=$native drawable=$drawable engine-shot=$shotsize"
grep -q 'scene(main).* orient=portrait ' "$ARTS/$STAMP-emu-vkq_mouse.txt" || { echo "FAIL: scene not in native (portrait) orientation" >&2; exit 1; }
[ -n "$native" ] && [ "$native" = "$drawable" ] && [ "$native" = "$shotsize" ] || { echo "FAIL: drawable does not match the native panel" >&2; exit 1; }
echo "ISSUE7 EMULATION PASS — inspect $ARTS/$STAMP-emu-{drawable,panel}.png (upright, full panel)"
