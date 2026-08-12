#!/usr/bin/env bash
#
# sim-measure-vr-scale.sh — R3 measurement run: PACING at eye render scale
# 1.00 / 1.25 / 1.50 on the Vision Pro simulator, with the eye target size the
# engine actually built for each.
#
# READ THE CAVEAT BEFORE QUOTING ANY NUMBER FROM THIS. The simulator's drawable
# is ONE view (mono) at a size the runtime picks, its Metal is not the M5's, and
# its compositor is not pacing against a 120 Hz panel. These numbers establish
# the RELATIVE cost of the three scales and prove the resize path works; they do
# NOT predict device frame rate. The device budget arithmetic is in
# docs/VR-R3-NOTES.md, anchored on the user's own 4.06 MP/eye at 119.7 Hz.
#
# LANE 1: the existing "Apple Vision Pro". Never simctl create. Always shut down.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999   # the bridge's compiled-in port; only one sim session at a time
#          (there is one Vision Pro, so these two scripts can never overlap anyway)
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346}
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
PFX="$ARTS/$(date '+%Y-%m-%d')-vr-scale"
DWELL=${VKQ_SCALE_DWELL:-40}   # seconds at each scale (PACING lines land every 5 s)

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another sim session owns the bridge" >&2; exit 1
fi
mkdir -p "$ARTS"

cleanup () {
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null || true
}
trap cleanup EXIT

for _i in $(seq 1 60); do
	state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	case "$state" in Shutdown | Booted) break ;; esac
	echo "   waiting for $UDID to settle (currently: ${state:-unknown})"
	sleep 2
done
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/rerelease/id1"
[ -f "$DOCS/rerelease/id1/pak0.pak" ] || cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
printf 'r_indirect 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"
rm -f "$DOCS/vr-diagnostics.log"

SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_VKQ_CONSOLE_PORT=$PORT \
	SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	xcrun simctl launch "$UDID" $BUNDLE
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || { echo "FATAL: bridge never opened" >&2; exit 1; }
say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }

say 'vkqvr 1'; sleep 20
say 'map e1m1'; sleep 18
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3   # a hand, so the VR path is fully live

for s in 1.00 1.25 1.50; do
	echo "== render scale $s — dwelling ${DWELL}s"
	say "vkqvrrenderscale $s"
	sleep "$DWELL"
	say 'vkqvrdiag'; sleep 3
	xcrun simctl io "$UDID" screenshot "$PFX-$s.png" >/dev/null 2>&1 || true
	cp "$DOCS/vr-diagnostics.log" "$PFX-diag-$s.log"
	echo "-- eye target and the last few PACING lines at $s"
	grep -E '^EYE TARGET' "$PFX-diag-$s.log" | tail -1
	grep -E '^PACING' "$PFX-diag-$s.log" | tail -4
done

say 'vkqvr 0'; sleep 8
echo
echo "=== SUMMARY (simulator — relative cost only, see the caveat at the top) ==="
python3 - "$PFX" <<'PY'
import re, sys, glob
pfx = sys.argv[1]
print(f"{'scale':>6}  {'eye target':>13}  {'MP/eye':>7}  {'Hz (mean of last 4)':>21}  {'miss%':>6}")
for s in ('1.00', '1.25', '1.50'):
    try:
        txt = open(f"{pfx}-diag-{s}.log").read()
    except OSError:
        continue
    et = re.findall(r'EYE TARGET \d+x\d+ -> (\d+)x(\d+) \(([\d.]+) MP/eye\)', txt)
    pac = re.findall(r'PACING ([\d.]+) Hz presented, (\d+)/(\d+) rendezvous missed', txt)[-4:]
    if not et or not pac:
        print(f"{s:>6}  (no data)"); continue
    w, h, mp = et[-1]
    hz = sum(float(p[0]) for p in pac) / len(pac)
    tot = sum(int(p[2]) for p in pac)
    mis = sum(int(p[1]) for p in pac)
    print(f"{s:>6}  {w+'x'+h:>13}  {mp:>7}  {hz:>21.1f}  {(100.0*mis/tot if tot else 0.0):>5.1f}%")
PY
echo "artifacts: $PFX-*"
