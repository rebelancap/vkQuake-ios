#!/usr/bin/env bash
#
# sim-verify-3d.sh — stereoscopic 3D verification on the Vision Pro simulator.
# Extends sim-verify.sh: boot with data injected, load a map, then drive the
# `vkq3d` console command over the bridge to open the CompositorServices
# immersive space, and capture screenshots of the 3D panel + the return to 2D.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
# Default: vkQuake-Vision-Pro (26.5, D-025). Override with VKQ_SIM_UDID to run
# on another runtime (e.g. vkQuake-Vision-Pro-27, the xrOS 27 beta sim — D-028).
UDID=${VKQ_SIM_UDID:-5ACC8FB7-17D2-450B-8A88-F8FD5FC5792F}
VKQ_ART_SUFFIX=${VKQ_ART_SUFFIX:-} # artifact filename suffix (e.g. -xr27)
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
STAMPD=$(date '+%Y-%m-%d')

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use" >&2; exit 1
fi

xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "== install"
xcrun simctl install "$UDID" "$APP"

echo "== inject game data + sim-only autoexec"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/rerelease/id1"
[ -f "$DOCS/rerelease/id1/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
printf 'r_indirect 0\n' > "$DOCS/rerelease/id1/autoexec.cfg" # sim Metal lacks indirect draws (D-025)

echo "== launch (bridge + sim MoltenVK accommodations)"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	xcrun simctl launch "$UDID" $BUNDLE

echo "== waiting for console bridge"
ok=0
for i in $(seq 1 60); do
	nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }
	sleep 1
done
[ "$ok" = 1 ] || { echo "FATAL: bridge never opened; boot.log:" >&2; tail -25 "$DOCS/boot.log" 2>/dev/null >&2; exit 1; }

mkdir -p "$ARTS"
sleep 3
printf 'map e1m1\n' | nc -w 3 127.0.0.1 $PORT >/dev/null || true
sleep 6
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMPD-3d-before$VKQ_ART_SUFFIX.png" >/dev/null
echo "== 2D baseline: $ARTS/$STAMPD-3d-before$VKQ_ART_SUFFIX.png"

echo "== vkq3d 1 (enter stereoscopic 3D)"
printf 'vkq3d 1\n' | nc -w 3 127.0.0.1 $PORT >/dev/null || true
sleep 10 # space open + tracking convergence (~30 compositor frames)
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMPD-3d-immersive$VKQ_ART_SUFFIX.png" >/dev/null
echo "== 3D screenshot: $ARTS/$STAMPD-3d-immersive$VKQ_ART_SUFFIX.png"

echo "== engine 3D state over bridge"
printf 'echo 3dframes\n' | nc -w 2 127.0.0.1 $PORT >/dev/null || true

echo "== vkq3d 0 (exit back to 2D window)"
printf 'vkq3d 0\n' | nc -w 3 127.0.0.1 $PORT >/dev/null || true
sleep 6
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMPD-3d-after$VKQ_ART_SUFFIX.png" >/dev/null
echo "== back-to-2D screenshot: $ARTS/$STAMPD-3d-after$VKQ_ART_SUFFIX.png"

echo "== immersive NSLog markers"
xcrun simctl spawn "$UDID" log show --last 3m --style compact \
	--predicate 'eventMessage CONTAINS "[vkquake]"' 2>/dev/null | grep -E 'imm:|3D|immersive|Swift' | tail -25 || true

echo "== engine console tail"
tail -6 "$DOCS/console.log" 2>/dev/null || true
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "SIM 3D VERIFY DONE — inspect the three screenshots"
