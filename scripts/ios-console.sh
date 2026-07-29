#!/bin/bash
# Device identifiers come from an untracked local file (see
# scripts/device.local.sh.example) or the environment — never hardcoded here.
[ -f "$(dirname "$0")/device.local.sh" ] && . "$(dirname "$0")/device.local.sh"
# Interactive remote console for vkQuake on the iPhone (charter's "most
# valuable debugging tool").
#
#   ./scripts/ios-console.sh                 # launch app + attach console
#   ./scripts/ios-console.sh --install       # reinstall current build first
#   ./scripts/ios-console.sh -- +map e1m1    # extra engine args at launch
#
# Every engine console line streams to your terminal (tee'd from stdout);
# anything you type runs as an engine command (bind · impulse 2 · map e1m1 ·
# host_maxfps 120 · developer 1 ...). Ctrl-C detaches; the app keeps running.
# Reattaching only needs nc:  nc "$DEVICE_HOST" 27999
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE_UDID:?set DEVICE_UDID (see scripts/device.local.sh.example)}"
BUNDLE=com.rebelancap.vkquake
HOST="${DEVICE_HOST:-my-iphone.local}"
PORT=27999
APP="$ROOT/build/ios/xcode/Release-iphoneos/vkQuake.app"
DO_INSTALL=0

while [ $# -gt 0 ]; do
	case "$1" in
		--install) DO_INSTALL=1; shift;;
		--host) HOST=$2; shift 2;;
		--device) DEVICE=$2; shift 2;;
		--) shift; break;;
		*) echo "unknown arg $1" >&2; exit 2;;
	esac
done

if [ "$DO_INSTALL" = "1" ]; then
	xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
	echo "installed $(cat "$APP/BUILD_STAMP.txt" 2>/dev/null || echo '(no stamp)')"
fi

echo "== launching with console bridge ($*)"
xcrun devicectl device process launch --terminate-existing \
	--environment-variables '{"VKQ_CONSOLE_BRIDGE":"1"}' \
	--device "$DEVICE" "$BUNDLE" "$@" >/dev/null

echo "== waiting for engine boot / bridge port..."
for i in $(seq 1 30); do
	sleep 1
	if nc -z -G 2 "$HOST" "$PORT" 2>/dev/null; then
		echo "== connected — type engine commands (Ctrl-C detaches, app keeps running)"
		exec nc "$HOST" "$PORT"
	fi
done
echo "ERROR: bridge port $PORT on $HOST never opened" >&2
exit 1
