#!/usr/bin/env bash
#
# sim-verify-r66.sh — VR R6.6: the dead trigger.
#
# the user: "sometimes shooting doesn't work... pressing left trigger but it won't
# fire my left gun. once it happened on BOTH weapons. most commonly at the
# beginning of a new level", and later: it reproduces EVERY time on `restart`.
#
# ROOT CAUSE (sv_phys.c): the per-weapon clocks store ABSOLUTE attack_finished
# values and sv.qcvm.time restarts at 0 on every new server. A clock saved late in
# one level, restored early in the next, puts attack_finished far in the future —
# and W_WeaponFrame returns ABOVE ImpulseCommands, so the weapon switch is never
# even read. The scheduler re-issues it forever and the gate refuses to fire.
#
# THE RECIPE IS THE COORDINATOR'S, from a live bridge capture on the device:
# restart the level repeatedly, then pull a trigger. Before this round that is a
# dead gun; after it, it fires.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING Apple Vision Pro. Shut down on every exit.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346}
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
DATASET=${VKQ_SIM_DATASET:-rerelease}
PFX="$ARTS/$(date '+%Y-%m-%d')-r66-$DATASET"
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
		echo "R66 VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "R66 VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "R66 VERIFY: PASSED"
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
# developer 1 so the dead-trigger rescue messages (Con_DPrintf) reach the log —
# they are the direct evidence that the root-cause guard fired.
printf 'r_indirect 0\ndeveloper 1\n' > "$DOCS/rerelease/id1/autoexec.cfg"
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
dump () {
	local before after
	before=$(nowseq); before=${before:-0}
	say 'vkqvrzones'; sleep 3
	after=$(nowseq); after=${after:-0}
	if [ "$after" -le "$before" ]; then
		echo "   FAIL  no fresh dump during '$1' — the app stopped answering" >&2; FAILED=1
		alive || die "the app stopped answering during '$1'"
	fi
}
fireline () { grep -E '^FIRENOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true; }
shotsL () { printf '%s' "$1" | grep -oE 'shots=L[0-9]+' | sed -E 's/shots=L//' || true; }
shotsR () { printf '%s' "$1" | grep -oE '/R[0-9]+' | sed -E 's|/R||' || true; }
pendW ()  { printf '%s' "$1" | grep -oE 'pendingW=imp-?[0-9]+' | sed -E 's/pendingW=imp//' || true; }

sleep 6
echo "== VR entry + e1m1 + a weapon in each hand"
say 'vkqvr 1'; sleep 20
say 'map e1m1'; sleep 18
dual_setup () {
	say 'vkqvrstyle 0'; sleep 3
	say 'impulse 9'; sleep 3
	say 'impulse 7'; sleep 3
	say 'vkqvrstyle 1'; sleep 3
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
	say 'vkqvrhandbtn r grip 0'; say 'vkqvrhandbtn l grip 0'; sleep 2
	say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3
	say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
	say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3
	say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
	for _f in 1 2 3 4 5 6; do
		say 'vkqvrhandstick r 0 1'; sleep 1; say 'vkqvrhandstick r 0 0'; sleep 2
		dump "flick to a second weapon"
		VM=$(grep -E '^VIEWMODELNOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true)
		case "$VM" in *v_nail.mdl*) break ;; esac
	done
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 3
}
dual_setup

# Fire once BEFORE any restart, so the per-weapon clocks hold real values and the
# jam has something stale to restore. Without this the repro proves nothing.
echo "== prime the per-weapon clocks (fire both hands once)"
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 6
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 3
dump "after priming"
PRIME=$(fireline); echo "   $PRIME"

# ---------------------------------------------------------------------------
# THE REPRO. Five restarts in a row, then a trigger. Each restart re-bases server
# time at 0 while the stored clocks still hold the previous run's absolute values.
echo "== R6.6: five restarts, then pull a trigger each time"
for R in 1 2 3 4 5; do
	say 'restart'; sleep 14
	dump "after restart $R"
	AFTER=$(fireline)
	P=$(pendW "$AFTER")
	if [ "${P:-x}" = "0" ]; then
		echo "   PASS  restart $R: the scheduler came up with no pending switch (pendingW=imp0)"
	else
		echo "   FAIL  restart $R: stale pending switch survived the restart (pendingW=imp$P)" >&2; FAILED=1
	fi
	L0=$(shotsL "$AFTER"); R0=$(shotsR "$AFTER")
	# `restart` STRIPS the player back to the starting shotgun, so the off hand is
	# legitimately empty here and only the AIM hand can fire. That is precisely the
	# case the user hit ("most commonly at the beginning of a new level") and it is a
	# complete dead-trigger test on its own: pre-fix the aim hand fired NOTHING.
	# Both hands together are tested across a changelevel below, which keeps the belt.
	say 'vkqvrhandbtn l trigger 1'; say 'vkqvrhandbtn r trigger 1'; sleep 4
	say 'vkqvrhandbtn l trigger 0'; say 'vkqvrhandbtn r trigger 0'; sleep 2
	dump "restart $R: triggers pulled"
	FIRED=$(fireline)
	L1=$(shotsL "$FIRED"); R1=$(shotsR "$FIRED")
	echo "   $FIRED"
	if [ "${R1:-0}" -gt "${R0:-0}" ]; then
		echo "   PASS  restart $R: the trigger fired straight after the restart (R $R0->$R1)"
	else
		echo "   FAIL  restart $R: DEAD TRIGGER — R $R0->$R1 (L $L0->$L1)" >&2; FAILED=1
	fi
done

# ---------------------------------------------------------------------------
echo "== R6.6: BOTH hands, across a real changelevel (which keeps the belt)"
# The restarts above stripped the inventory, so re-arm and re-fill both hands
# before the changelevel — otherwise "both hands fired" would prove nothing.
dual_setup
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 5
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 3
dump "re-armed before the changelevel"
PRE=$(fireline); PL=$(shotsL "$PRE"); PR=$(shotsR "$PRE")
echo "   $PRE"
{ [ "${PL:-0}" -gt 0 ] && [ "${PR:-0}" -gt 0 ]; } \
	|| { echo "   FAIL  setup: both hands were not firing BEFORE the changelevel — the test below proves nothing" >&2; FAILED=1; }
say 'changelevel e1m2'; sleep 20
dump "after changelevel"
CL=$(fireline)
P=$(pendW "$CL")
[ "${P:-x}" = "0" ] && echo "   PASS  changelevel: no pending switch survived (pendingW=imp0)" \
	|| { echo "   FAIL  changelevel: stale pending switch survived (pendingW=imp$P)" >&2; FAILED=1; }
L0=$(shotsL "$CL"); R0=$(shotsR "$CL")
say 'vkqvrhandbtn l trigger 1'; say 'vkqvrhandbtn r trigger 1'; sleep 4
say 'vkqvrhandbtn l trigger 0'; say 'vkqvrhandbtn r trigger 0'; sleep 2
dump "changelevel: triggers pulled"
CF=$(fireline); L1=$(shotsL "$CF"); R1=$(shotsR "$CF")
echo "   $CF"
if [ "${L1:-0}" -gt "${L0:-0}" ] && [ "${R1:-0}" -gt "${R0:-0}" ]; then
	echo "   PASS  both hands fired immediately after a changelevel (L $L0->$L1, R $R0->$R1)"
else
	echo "   FAIL  dead trigger after changelevel — L $L0->$L1, R $R0->$R1" >&2; FAILED=1
fi

# The regression half: no shot may leave a weapon no trigger authorised.
UA=$(printf '%s' "$CF" | grep -oE 'unauthfired=[0-9]+' | cut -d= -f2 || true)
[ "${UA:-0}" = "0" ] && echo "   PASS  no unauthorised discharges through the whole run (unauthfired=0)" \
	|| { echo "   FAIL  unauthfired=$UA — a shot left a weapon no trigger authorised" >&2; FAILED=1; }

cp "$DOCS/console.log" "$PFX-console.log" 2>/dev/null || true
cp "$DOCS/vr-diagnostics.log" "$PFX-diagnostics.log" 2>/dev/null || true
echo "   logs: $PFX-console.log / $PFX-diagnostics.log"
# Direct evidence that the root-cause guard actually engaged.
if grep -q "server time went backwards" "$PFX-console.log" 2>/dev/null; then
	echo "   PASS  the time-base guard fired (server time went backwards -> clocks reset)"
	grep -m2 "server time went backwards" "$PFX-console.log" | sed 's/^/     /'
else
	echo "   NOTE  the time-base guard did not log — the clocks may have been empty at each restart"
fi
xcrun simctl io "$UDID" screenshot "$PFX-01-final.png" >/dev/null 2>&1 && echo "   shot: $PFX-01-final.png" || true

[ "$FAILED" = 0 ] || { echo "R66 VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "R66 VERIFY DONE"
