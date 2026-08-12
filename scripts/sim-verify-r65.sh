#!/usr/bin/env bash
#
# sim-verify-r65.sh — VR R6.5 targeted verification (expedited round).
#
#   item 1  THE DUAL-WIELD MIRAGE. With one weapon in each hand, holding the OFF
#           hand's trigger must not change what the AIM hand is RENDERING.
#           Asserted on per-hand model identity from VIEWMODELNOW, not on pixels.
#   item 3  PING ACCURACY. A local server must read a few milliseconds, not a
#           multiple of the old 100 ms poll interval.
#   item 4  regression only: a normal join must still work. The missing-map
#           pre-check sweeps every precache name, so a false positive there would
#           break EVERY server join — that is the risk this round introduces and it
#           is the half of item 4 a single machine can actually test.
#
# What this canNOT prove: the crown (item 2) — the simulator has no Digital Crown —
# and the real missing-map message, which needs a server running a map we lack.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING Apple Vision Pro. Never simctl create.
# Shut down on every exit path, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346}
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
DATASET=${VKQ_SIM_DATASET:-rerelease}
PFX="$ARTS/$(date '+%Y-%m-%d')-r65-$DATASET"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another sim session owns the bridge" >&2; exit 1
fi

FAILED=0
INTERRUPTED=0
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null || true
	if [ "$INTERRUPTED" != 0 ]; then
		echo "R65 VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "R65 VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "R65 VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

for _i in $(seq 1 60); do
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
mkdir -p "$DOCS/rerelease/id1"
STAMPF="$DOCS/rerelease/id1/.vkq-dataset"
if [ "$(cat "$STAMPF" 2>/dev/null || true)" != "$DATASET" ]; then
	rm -f "$DOCS/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak1.pak"
	if [ "$DATASET" = rerelease ]; then
		cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$DOCS/rerelease/id1/pak0.pak"
	else
		cp -c "$ROOT/gamedata/id1/PAK0.PAK" "$DOCS/rerelease/id1/pak0.pak"
		cp -c "$ROOT/gamedata/id1/PAK1.PAK" "$DOCS/rerelease/id1/pak1.pak"
	fi
	printf '%s' "$DATASET" > "$STAMPF"
fi
printf 'r_indirect 0\n' > "$DOCS/rerelease/id1/autoexec.cfg"
rm -f "$DOCS/vr-diagnostics.log" "$DOCS/console.log"

echo "== launch"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	xcrun simctl launch "$UDID" $BUNDLE
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened"
echo "   PASS  boot smoke: the app is up and the bridge answers"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
nowseq () { grep -E '^NOWSEQ [0-9]+$' "$DOCS/vr-diagnostics.log" 2>/dev/null | tail -1 | awk '{print $2+0}' || true; }
dump () { # fresh on-demand dump, with the R6.1 freshness rule
	local before after
	before=$(nowseq); before=${before:-0}
	say 'vkqvrzones'; sleep 3
	after=$(nowseq); after=${after:-0}
	if [ "$after" -le "$before" ]; then
		echo "   FAIL  no fresh dump during '$1' — the app stopped answering" >&2; FAILED=1
		alive || die "the app stopped answering during '$1'"
	fi
}
vmline () { grep -E '^VIEWMODELNOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true; }
handmodel () { printf '%s' "$1" | grep -oE "$2=\([^ ]+ " | sed -E "s/$2=\(//;s/ $//" || true; }

sleep 6
echo "== VR entry + e1m1"
say 'vkqvr 1'; sleep 20
say 'map e1m1'; sleep 18
alive || die "the app stopped answering after map load"

# ---------------------------------------------------------------------------
echo "== R6.5 item 1: one weapon per hand, and the AIM hand must keep its own"
# Same setup the R6 suites use: Convenience first (no v2 idle sync to undo the
# impulse), then Immersive seeds the aim hand, then the RL is stowed and taken by
# the left hand while the aim hand flicks to the nailgun.
say 'vkqvrstyle 0'; sleep 3
say 'impulse 9'; sleep 3
say 'impulse 7'; sleep 3         # rocket launcher active
say 'vkqvrstyle 1'; sleep 3      # seed v2: the aim hand takes the RL
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
say 'vkqvrhandbtn r grip 0'; say 'vkqvrhandbtn l grip 0'; sleep 2
say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
for _f in 1 2 3 4 5 6; do
	say 'vkqvrhandstick r 0 1'; sleep 1; say 'vkqvrhandstick r 0 0'; sleep 2
	dump "weapon flick"
	VM=$(vmline)
	RM=$(handmodel "$VM" R)
	case "$RM" in *v_nail.mdl) break ;; esac
done
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 3

dump "dual wield idle"
VM0=$(vmline)
echo "   $VM0"
L0=$(handmodel "$VM0" L); R0=$(handmodel "$VM0" R)
if [ -n "$L0" ] && [ -n "$R0" ] && [ "$L0" != "$R0" ] && [ "$L0" != "-" ] && [ "$R0" != "-" ]; then
	echo "   PASS  setup: the two hands render DIFFERENT weapons (L=$L0 R=$R0)"
else
	echo "   FAIL  setup did not put a different weapon in each hand (L=$L0 R=$R0) — the mirage test below would prove nothing" >&2
	FAILED=1
fi
xcrun simctl io "$UDID" screenshot "$PFX-01-dual-idle.png" >/dev/null 2>&1 && echo "   shot: $PFX-01-dual-idle.png" || true

echo "== hold the OFF (left) hand's trigger — this is the exact repro"
say 'vkqvrhandbtn l trigger 1'; sleep 6
dump "off-hand trigger held"
VM1=$(vmline)
echo "   $VM1"
L1=$(handmodel "$VM1" L); R1=$(handmodel "$VM1" R)
xcrun simctl io "$UDID" screenshot "$PFX-02-offhand-firing.png" >/dev/null 2>&1 && echo "   shot: $PFX-02-offhand-firing.png" || true

# THE ASSERTION. the user's bug: the aim hand's rendered model became the off hand's
# weapon while the off trigger was held, so both hands drew the same gun.
if [ "$R1" = "$R0" ]; then
	echo "   PASS  the AIM hand kept its own weapon while the off hand fired ($R1)"
else
	echo "   FAIL  THE MIRAGE: the aim hand was rendering $R0 and became $R1 while the off hand fired" >&2; FAILED=1
fi
if [ -n "$L1" ] && [ "$L1" != "$R1" ]; then
	echo "   PASS  the two hands are still rendering different weapons while firing (L=$L1 R=$R1)"
else
	echo "   FAIL  both hands rendered the same model while the off hand fired (L=$L1 R=$R1)" >&2; FAILED=1
fi
# The off hand is the one that should be animating, since it holds the live weapon.
VH=$(printf '%s' "$VM1" | grep -oE 'viewhand=[LR]' | cut -d= -f2 || true)
if [ "$VH" = "L" ]; then
	echo "   PASS  cl.viewent followed the firing hand (viewhand=L)"
else
	echo "   FAIL  cl.viewent stayed at viewhand=$VH while the LEFT hand held the trigger" >&2; FAILED=1
fi

say 'vkqvrhandbtn l trigger 0'; sleep 5
dump "trigger released"
VM2=$(vmline)
echo "   $VM2"
R2=$(handmodel "$VM2" R); L2=$(handmodel "$VM2" L)
if [ "$R2" = "$R0" ] && [ "$L2" = "$L0" ]; then
	echo "   PASS  both hands returned to their own weapons after release (L=$L2 R=$R2)"
else
	echo "   FAIL  after release L=$L2 (was $L0) R=$R2 (was $R0)" >&2; FAILED=1
fi

# Standing invariant, as R6.4 established for dupes: no holster dump may ever show
# a duplicate, whatever the test was actually about.
DUP=$(grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -o 'dupes=[0-9]*' | cut -d= -f2 || true)
if [ -n "$DUP" ] && [ "$DUP" != 0 ]; then
	echo "   FAIL  duplicate item in the physical inventory (dupes=$DUP)" >&2; FAILED=1
else
	echo "   PASS  no duplicate in the physical inventory (dupes=${DUP:-0})"
fi

# ---------------------------------------------------------------------------
echo "== R6.5 item 3: ping reads milliseconds, not multiples of the poll interval"
say 'vkqvr 0'; sleep 12
say 'listen 1'; sleep 3
say 'slist'; sleep 8
say 'echo R65MARK'; sleep 3
LOG="$DOCS/console.log"
[ -f "$LOG" ] || die "no console.log"
cp "$LOG" "$PFX-console.log"
PINGROW=$(grep -E '^.{1,13} +.{1,11} +[0-9 ]+/[0-9 ]+ +(-{2}|[0-9]+)$' "$LOG" | tail -1 || true)
PINGVAL=$(printf '%s' "$PINGROW" | awk '{print $NF}')
echo "   row: $PINGROW"
if printf '%s' "$PINGVAL" | grep -Eq '^[0-9]+$'; then
	if [ "$PINGVAL" -le 50 ]; then
		echo "   PASS  a local server reads ${PINGVAL} ms (was quantised to 100/200 before R6.5)"
	else
		echo "   FAIL  a local server still reads ${PINGVAL} ms — the poll quantisation is not gone" >&2; FAILED=1
	fi
else
	echo "   FAIL  no measured ping on the local server row (got '$PINGVAL')" >&2; FAILED=1
fi

# ---------------------------------------------------------------------------
echo "== R6.5 item 4 regression: the missing-map sweep must not break a NORMAL join"
say 'connect 127.0.0.1'; sleep 12
say 'echo R65JOINMARK'; sleep 3
cp "$LOG" "$PFX-console-join.log"
if grep -q "which you do not have" "$PFX-console-join.log"; then
	echo "   FAIL  the missing-map pre-check FIRED on a map we do have — this would break every join" >&2; FAILED=1
else
	echo "   PASS  the pre-check did not fire on a server whose content we have"
fi
xcrun simctl io "$UDID" screenshot "$PFX-03-after-join.png" >/dev/null 2>&1 && echo "   shot: $PFX-03-after-join.png" || true
alive || die "the app stopped answering after the join"

cp "$DOCS/vr-diagnostics.log" "$PFX-diagnostics.log" 2>/dev/null || true
[ "$FAILED" = 0 ] || { echo "R65 VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "R65 VERIFY DONE"
