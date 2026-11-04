#!/usr/bin/env bash
#
# sim-verify-extscale.sh — "External Display Render Scale" (issue #7 round 5)
# on the iPad simulator. The sim has no extended external display, so the
# external path is emulated (VKQ_EMULATE_EXTERNAL_DISPLAY=1, as in
# sim-verify-issue7.sh) and the setting is preset to 50% through the app's
# NSUserDefaults (vkq.extRenderScale = 2). Pass = vkq_mouse reports the Metal
# layer at half the native scale with natural = half the panel, the engine
# screenshot (= the drawable) is that half size, and the panel screenshot still
# shows the game full-screen. A second run with the setting back at Native must
# report the full panel again.
#
#   VKQ_SIM_UDID=<ipad udid> scripts/sim-verify-extscale.sh     (build-sim.sh ios first)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:?set VKQ_SIM_UDID to an iPad simulator}
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"; STAMP=$(date '+%Y-%m-%d')-extscale
[ -d "$APP" ] || { echo "FATAL: run scripts/build-sim.sh ios" >&2; exit 1; }
nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { echo "FATAL: port $PORT busy" >&2; exit 1; }
trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
DOCS="$(xcrun simctl get_app_container "$UDID" $BUNDLE data)/Documents"
mkdir -p "$DOCS/rerelease/id1" "$ARTS"
[ -f "$DOCS/rerelease/id1/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
printf 'r_indirect 0\nvolume 0\nbgmvolume 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"
con () { (printf '%s\n' "$1"; sleep 3) | nc -w 5 127.0.0.1 $PORT | grep -v '^20\|^\]' || true; }

run_once () { # $1 choice (0 native, 2 half)  $2 tag
	xcrun simctl spawn "$UDID" defaults write $BUNDLE vkq.extRenderScale -float "$1"
	SIMCTL_CHILD_VKQ_EMULATE_EXTERNAL_DISPLAY=1 SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 \
	SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
		timeout 60 xcrun simctl launch "$UDID" $BUNDLE
	for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && break; sleep 1; done
	nc -z -G 1 127.0.0.1 $PORT 2>/dev/null || { echo "FATAL: bridge never opened" >&2; exit 1; }
	sleep 4
	con 'map e1m1' >/dev/null; sleep 5
	con 'vkq_mouse' > "$ARTS/$STAMP-$2-vkq_mouse.txt"
	before=$(ls "$DOCS/rerelease/id1/"*.png 2>/dev/null | wc -l)
	con 'screenshot' >/dev/null; sleep 1
	shot=$(ls -t "$DOCS/rerelease/id1/"*.png 2>/dev/null | head -1)
	[ "$(ls "$DOCS/rerelease/id1/"*.png 2>/dev/null | wc -l)" -gt "$before" ] || { echo "FATAL: engine screenshot not written" >&2; exit 1; }
	cp "$shot" "$ARTS/$STAMP-$2-drawable.png"
	xcrun simctl io "$UDID" screenshot "$ARTS/$STAMP-$2-panel.png" >/dev/null
	timeout 60 xcrun simctl terminate "$UDID" $BUNDLE || true
	sleep 2
	cat "$ARTS/$STAMP-$2-vkq_mouse.txt"
}

run_once 2 half
native=$(grep -o 'native=[0-9]*x[0-9]*' "$ARTS/$STAMP-half-vkq_mouse.txt" | head -1 | cut -d= -f2)
nat_w=${native%x*}; nat_h=${native#*x}
line=$(grep '^  drawable:' "$ARTS/$STAMP-half-vkq_mouse.txt")
want="natural=$((nat_w/2))x$((nat_h/2))"
case "$line" in *"$want"*) ;; *) echo "FATAL: half run: expected $want in: $line" >&2; exit 1 ;; esac
case "$line" in *"extRenderScale=2"*) ;; *) echo "FATAL: half run: setting not read: $line" >&2; exit 1 ;; esac
shotsz=$(sips -g pixelWidth -g pixelHeight "$ARTS/$STAMP-half-drawable.png" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
[ "$shotsz" = "$((nat_w/2))x$((nat_h/2))" ] || { echo "FATAL: half run: engine screenshot is $shotsz, want $((nat_w/2))x$((nat_h/2))" >&2; exit 1; }
echo "half: $line; engine-shot=$shotsz"

run_once 0 native
line=$(grep '^  drawable:' "$ARTS/$STAMP-native-vkq_mouse.txt")
case "$line" in *"natural=${nat_w}x${nat_h}"*) ;; *) echo "FATAL: native run: expected natural=${nat_w}x${nat_h} in: $line" >&2; exit 1 ;; esac
shotsz=$(sips -g pixelWidth -g pixelHeight "$ARTS/$STAMP-native-drawable.png" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
[ "$shotsz" = "${nat_w}x${nat_h}" ] || { echo "FATAL: native run: engine screenshot is $shotsz" >&2; exit 1; }
echo "native: $line; engine-shot=$shotsz"
echo "EXTSCALE PASS — inspect $ARTS/$STAMP-{half,native}-{drawable,panel}.png (half drawable, full panel)"
