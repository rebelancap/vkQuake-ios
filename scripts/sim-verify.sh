#!/usr/bin/env bash
#
# sim-verify.sh <ios|visionos> — install the sim build in the session's own
# simulator, inject rerelease id1, boot, drive to real map content via the
# console bridge (localhost:27999 — sims share the Mac loopback, so verify ONE
# platform at a time), and capture content screenshots into artifacts/sim/.
#
# This is the mandatory pre-OTA gate (CLAUDE.md REMOTE OPERATIONS): screenshots,
# never logs alone. Sims are THIS session's own (created 2026-07-11, D-025):
#   vkQuake-iPhone-Air   E9D5BD7B-D5EB-4841-A894-300D41AE2236  (iOS 26.5)
#   vkQuake-Vision-Pro   5ACC8FB7-17D2-450B-8A88-F8FD5FC5792F  (visionOS 26.5, 4K)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999

case "${1:-}" in
ios)      UDID=E9D5BD7B-D5EB-4841-A894-300D41AE2236; APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/vkQuake.app" ;;
visionos) UDID=5ACC8FB7-17D2-450B-8A88-F8FD5FC5792F; APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app" ;;
*) echo "usage: $0 <ios|visionos>" >&2; exit 2 ;;
esac
PLAT="$1"
ARTS="$ROOT/artifacts/sim"
STAMPD=$(date '+%Y-%m-%d')

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh $PLAT" >&2; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null

# one bridge at a time on the shared loopback
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another bridge (device tunnel or other sim app) is live" >&2
	exit 1
fi

xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "== install"
xcrun simctl install "$UDID" "$APP"

echo "== inject game data (rerelease id1, APFS clone)"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/rerelease/id1"
[ -f "$DOCS/rerelease/id1/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
ls -lh "$DOCS/rerelease/id1/pak0.pak"

# r_indirect 0 via injected autoexec.cfg: the SIMULATOR's Metal device does not
# support indirect drawing — MoltenVK rejects vkCmdDrawIndexedIndirect
# (VK_ERROR_FEATURE_NOT_PRESENT) and the engine Sys_Errors on
# vkEndCommandBuffer(-8) at the first world frame. All indirect call sites are
# gated on r_indirect (R_DrawIndirectBrushes*), and quake.rc execs autoexec.cfg
# before startdemos (verified in console.log ordering), so this covers the whole
# session. autoexec.cfg is the mechanism because simctl-launch argv does NOT
# reach the engine through the scene-grafted SDL main path (tried; crash
# persisted). Real devices support indirect draws; the shipped build and its
# data are untouched — this file exists only in the sim container.
printf 'r_indirect 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"

echo "== launch (bridge enabled)"
# MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0: on the SIMULATOR, MoltenVK's Metal
# argument buffers (default on) silently break every descriptor read — all
# texture samples return zero, giving an entirely black screen (2D included)
# with zero mvk-errors. Diagnosed empirically 2026-07-11; devices are fine.
# SDL_JOYSTICK_MFI=0: the simulator forwards any game controller paired to the
# MAC into the guest, SDL opens it, and the shell correctly hides the whole touch
# overlay whenever the engine holds a gamepad. That is why NO sim screenshot in
# this project's history has ever shown the touch controls (diagnosed 2026-07-28:
# inGame=1 ctrl=1 hidden=1). Disabling SDL's MFi backend keeps the sim on the
# touch path so the on-screen controls are actually verifiable here.
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
	xcrun simctl launch "$UDID" $BUNDLE

echo "== waiting for console bridge on :$PORT"
ok=0
for i in $(seq 1 60); do
	if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then ok=1; break; fi
	sleep 1
done
[ "$ok" = 1 ] || { echo "FATAL: bridge never opened — engine likely died; boot.log:" >&2; tail -30 "$DOCS/boot.log" 2>/dev/null >&2; exit 1; }

mkdir -p "$ARTS"
sleep 4 # let the engine settle into the demo/menu loop
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMPD-$PLAT-boot.png" >/dev/null
echo "== boot screenshot: $ARTS/$STAMPD-$PLAT-boot.png"

echo "== console: map e1m1"
printf 'map e1m1\n' | nc -w 3 127.0.0.1 $PORT >/dev/null || true
sleep 6
xcrun simctl io "$UDID" screenshot "$ARTS/$STAMPD-$PLAT-e1m1.png" >/dev/null
echo "== content screenshot: $ARTS/$STAMPD-$PLAT-e1m1.png"

echo "== engine log tail (console.log)"
tail -8 "$DOCS/console.log" 2>/dev/null || tail -8 "$DOCS/boot.log" 2>/dev/null || true

xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "SIM VERIFY DONE: $PLAT — inspect the two screenshots before shipping OTA"
