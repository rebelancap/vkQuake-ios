#!/usr/bin/env bash
#
# sim-verify-vr-quick.sh — the TARGETED pass, for an expedited round.
#
# This is NOT a replacement for sim-verify-vr.sh and must never be treated as
# one. It exists because R6.2 was authorised as an expedited fix round (the user,
# explicitly): two small changes on top of a build he had already confirmed
# himself on the device, where a 45-minute both-pak regression before publishing
# buys less than getting the fix into his hands. The full suites run AFTER the
# publish and must be green before the public 1.1.0.
#
# What it covers, and nothing else:
#   1. boot smoke — the app comes up, the bridge answers, VR enters, e1m1 is a
#      world frame
#   2. the message panel: still drawn, still single-inked (R6.2 item 1)
#   3. the physical inventory across a CHANGELEVEL (R6.2 item 2) — the actual
#      bug, asserted on the actual transition
#   4. dual wield, quickly — R6.2 item 2 touches inventory state that lives next
#      door to the fire scheduler, so "I did not break firing" is a claim this
#      round has to make rather than assume
#   5. settings smoke, including that B no longer closes the sheet (R6.2 item 3)
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING Apple Vision Pro. Shut down on every
# exit path, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346}
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
DATASET=${VKQ_SIM_DATASET:-rerelease}
PFX="$ARTS/$(date '+%Y-%m-%d')-vrquick-$DATASET"
mkdir -p "$ARTS"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another sim session owns the bridge" >&2; exit 1
fi

FAILED=0
INTERRUPTED=0
# THE TRAP OWNS THE EXIT STATUS. R6.2 added the signal half after watching the
# full suite's trap print "SIM VR VERIFY: PASSED" for a run that had just been
# SIGTERMed halfway through: the trap read $? from the last completed command,
# which was a successful one. A verdict that survives having the run cut out from
# under it is exactly the "assertion that cannot fail" this project has now paid
# for four times.
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
	local rc=$?
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null || true
	if [ "$INTERRUPTED" != 0 ]; then
		echo "VR QUICK VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "VR QUICK VERIFY: *** FAILED *** (status $rc, assertion failures ${FAILED:-0})" >&2
		exit 1
	fi
	echo "VR QUICK VERIFY: PASSED"
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
rm -f "$DOCS/vr-diagnostics.log"

echo "== launch"
SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
	xcrun simctl launch "$UDID" $BUNDLE
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened"
echo "   PASS  boot smoke: the app is up and the bridge answers"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
shot () {
	for _t in 1 2 3 4 5 6; do
		xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 && { echo "   shot: $PFX-$1.png"; return 0; }
		sleep 4
	done
	alive || die "screenshot '$1' never landed and the app is not answering — it has crashed"
	die "screenshot '$1' never landed"
}
nowseq () { grep -E '^NOWSEQ [0-9]+$' "$DOCS/vr-diagnostics.log" 2>/dev/null | tail -1 | awk '{print $2+0}' || true; }
zoneline () { say 'vkqvrzones'; sleep 3; }
zone_assert () { # <label> <prefix> <regex>
	local before after line
	before=$(nowseq); before=${before:-0}
	zoneline
	after=$(nowseq); after=${after:-0}
	if [ "$after" -le "$before" ]; then
		printf '   FAIL  %s  (NO FRESH DUMP — the app did not answer)\n' "$1" >&2; FAILED=1
		alive || die "the app stopped answering during '$1'"
		die "the app is up but stopped writing dumps during '$1'"
	fi
	line=$(grep -E "^$2 " "$DOCS/vr-diagnostics.log" | tail -1 || true)
	printf '   %s: %s\n' "$2" "$line"
	# R6.4 item 1 — THE STANDING INVARIANT. Every holster dump the suite reads,
	# for any reason, is also a duplicate check. A weapon that appears in two of
	# {left hand, right hand, right hip, left hip} is the bug the user hit, and it
	# should be caught by whatever the harness happens to ask next rather than
	# only by the test written for it.
	DUP=$(grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -o 'dupes=[0-9]*' | cut -d= -f2 || true)
	if [ -n "$DUP" ] && [ "$DUP" != 0 ]; then
		printf '   FAIL  DUPLICATE ITEM in the physical inventory (dupes=%s) during "%s"\n' "$DUP" "$1" >&2; FAILED=1
	fi
	if printf '%s' "$line" | grep -Eq "$3"; then printf '   PASS  %s\n' "$1"
	else printf '   FAIL  %s  (no /%s/ in the last %s line)\n' "$1" "$3" "$2" >&2; FAILED=1; fi
}
need () { grep -Eq "$3" "$1" && printf '   PASS  %s\n' "$2" || { printf '   FAIL  %s (no /%s/)\n' "$2" "$3" >&2; FAILED=1; }; }
MSGREGION="--region 900,450,2950,1250"
countpx () { python3 "$ROOT/scripts/sim-pixel-count.py" "$PFX-$1.png" "$2" $MSGREGION 2>/dev/null | grep -o 'pixels=[0-9]*' | head -1 | cut -d= -f2 || true; }

sleep 6
echo "== VR entry + e1m1"
say 'vkqvr 1'; sleep 20
say 'map e1m1'; sleep 18
say 'vkqvrstyle 1'; say 'vkqvrpose 0 0 0 0 0'; sleep 3
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 5
zone_assert "boot smoke: VR is live with both hands tracked" MOVENOW 'hands=1'

# ---------------------------------------------------------------------------
# R6.2 item 1 — the message panel is still there, and is SINGLE-inked.
#
# THE HONEST FRAMING, because this matters more than the number: the user's
# doubling does NOT reproduce off-device. The simulator is mono, has no
# rasterization rate map and no compositor reprojection, and it renders this
# panel perfectly at every size tried. So this cannot be an assertion that
# reproduces his artifact and then shows it gone — there is nothing to reproduce
# here.
#
# What it CAN be is a guard on the property whose violation would produce
# doubling from OUR side: ink per glyph. A panel that draws its glyphs twice at
# an offset, or grows a shadow pass, inflates the lit-pixel count per glyph well
# beyond the band a single clean draw produces. The band below is calibrated on
# this build and is deliberately tight enough that a second inking cannot hide
# inside it.
# ---------------------------------------------------------------------------
echo "== R6.2 item 1: the message panel, and its ink per glyph"
say 'scr_centertime 25'; say 'con_notifytime 0.2'; sleep 4
shot 90a-msg-none
BASE_W=$(countpx 90a-msg-none msgwhite)
[ -n "$BASE_W" ] || die "could not measure the empty-panel baseline"
echo "   baseline white ink in the panel region: $BASE_W (static furniture; subtracted below)"

say 'vkqvrmsg You need the silver key'; sleep 3
shot 90b-msg-centerprint
MSG_W=$(countpx 90b-msg-centerprint msgwhite)
say 'vkqvrdiag'; sleep 3
need "$DOCS/vr-diagnostics.log" "the panel drew the centerprint" "MSGNOW .*centre='You need the silver key'"
need "$DOCS/vr-diagnostics.log" "the panel published its geometry" 'MSGGEOM tex=1024x448 glyph=40px stroke=5px'
GLYPHS=$(grep -E "^MSGNOW .*centre='You need the silver key'" "$DOCS/vr-diagnostics.log" | tail -1 | grep -o 'glyphs=[0-9]*' | cut -d= -f2 || true)
python3 - "$BASE_W" "$MSG_W" "${GLYPHS:-0}" <<'PY' || FAILED=1
import sys
base, meas, glyphs = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
ink = meas - base
if glyphs <= 0:
    print("   FAIL  no glyph count from MSGNOW — nothing to normalise against", file=sys.stderr); sys.exit(1)
per = ink / glyphs
# Calibrated on the R6.2 build. A second inking offset by a few pixels adds
# roughly a third again; the upper bound sits well inside that.
LO, HI = 90.0, 260.0
ok = ink >= 800 and LO <= per <= HI
print(f"   {'PASS' if ok else 'FAIL'}  message ink {ink} px over {glyphs} glyphs = {per:.1f} px/glyph "
      f"(single-draw band {LO:.0f}-{HI:.0f}; ink floor 800)", file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

# ---------------------------------------------------------------------------
# R6.2 item 2 — THE ACTUAL BUG, on the actual transition.
# ---------------------------------------------------------------------------
echo "== R6.2 item 2: the physical inventory survives a CHANGELEVEL"
# The hip POSES are the ones the full suite proved (0.22 -0.66 0.06 is the right
# hip in the published zone layout). The first draft of this section used a
# neutral in-front pose, put nothing on the belt at all, and would then have
# "passed" a changelevel that carried nothing — a persistence test whose subject
# was never created proves nothing, so the setup is asserted before the subject.
say 'impulse 9'; sleep 4                                   # own everything
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3           # aim hand at the RIGHT hip
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2   # stow
zone_assert "SETUP: a weapon is on the right hip" HOLSTERNOW 'rhip=imp[1-8]'
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2          # out of the zone
say 'vkqvrhandstick r 0 1'; sleep 2; say 'vkqvrhandstick r 0 0'; sleep 3     # take another
say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3          # LEFT hip
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2   # stow it there
say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3          # off hand at the LEFT hip
say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2   # off hand takes it
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 3
zone_assert "SETUP: the off hand is holding a weapon" HOLSTERNOW 'L\(grip=0 zone=- hold=imp[1-8]\)'
zoneline
BEFORE=$(grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true)
echo "   before: $BEFORE"
RHIP0=$(printf '%s' "$BEFORE" | grep -o 'rhip=imp[0-9]*' | cut -d= -f2 || true)
LHOLD0=$(printf '%s' "$BEFORE" | sed -E 's/.*L\(grip=[0-9]+ zone=[^ ]* hold=(imp[0-9]+)\).*/\1/' || true)
echo "   captured rhip=$RHIP0 left-hand=$LHOLD0"
{ [ -n "$RHIP0" ] && [ "$RHIP0" != "imp0" ]; } || { echo "   FAIL  setup put nothing on the right hip — the changelevel result proves nothing" >&2; FAILED=1; }
{ [ -n "$LHOLD0" ] && [ "$LHOLD0" != "imp0" ]; } || { echo "   FAIL  setup put nothing in the off hand — the changelevel result proves nothing" >&2; FAILED=1; }

say 'changelevel e1m2'; sleep 28
zone_assert "after the changelevel the world is live again" MOVENOW 'hands=1'
AFTER=$(grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true)
echo "   after:  $AFTER"
RHIP1=$(printf '%s' "$AFTER" | grep -o 'rhip=imp[0-9]*' | cut -d= -f2 || true)
LHOLD1=$(printf '%s' "$AFTER" | sed -E 's/.*L\(grip=[0-9]+ zone=[^ ]* hold=(imp[0-9]+)\).*/\1/' || true)
{ [ -n "$RHIP0" ] && [ "$RHIP0" != "imp0" ] && [ "$RHIP1" = "$RHIP0" ]; } \
	&& echo "   PASS  the right hip kept its weapon across the changelevel ($RHIP0)" \
	|| { echo "   FAIL  right hip was '$RHIP0' before the changelevel and '$RHIP1' after" >&2; FAILED=1; }
{ [ -n "$LHOLD0" ] && [ "$LHOLD0" != "imp0" ] && [ "$LHOLD1" = "$LHOLD0" ]; } \
	&& echo "   PASS  the off hand kept its weapon across the changelevel ($LHOLD0)" \
	|| { echo "   FAIL  off hand was '$LHOLD0' before and '$LHOLD1' after" >&2; FAILED=1; }
shot 91-after-changelevel

echo "== R6.2 item 2: a restart that STRIPS inventory still empties the belt"
# THE WEAPON HAS TO BE ONE A RESTART ACTUALLY TAKES AWAY. The first version of
# this check left the SHOTGUN on the hip and then demanded the slot be empty
# after `map e1m1` — but a restarted player still owns the shotgun, so keeping it
# was the policy behaving correctly and the assertion was simply wrong. The
# lightning gun is stripped, which is what makes this a test of the rule rather
# than of the wording.
say 'vkqvrstyle 0'; sleep 3      # Convenience clears v2 state, so the re-seed is deterministic
say 'impulse 9'; sleep 3
say 'impulse 8'; sleep 3         # lightning gun active
say 'vkqvrstyle 1'; sleep 3      # the aim hand seeds with it, holsters empty
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
zone_assert "SETUP: the right hip holds the lightning gun" HOLSTERNOW 'rhip=imp8'
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
say 'map e1m1'; sleep 24
zone_assert "new level, inventory stripped back to the starting weapons" MOVENOW 'hands=1'
NEW=$(grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true)
echo "   after map restart: $NEW"
printf '%s' "$NEW" | grep -q 'rhip=imp0' \
	&& echo "   PASS  a restart clears a hip holding a weapon the player no longer owns" \
	|| { echo "   FAIL  the hip kept the lightning gun across a restart that strips it: $NEW" >&2; FAILED=1; }
# ---------------------------------------------------------------------------
# R6.2 — dual wield, quickly. Item 2 edits inventory state that lives next door
# to the fire scheduler, so this is a no-regression claim, not a feature test.
# ---------------------------------------------------------------------------
echo "== R6.2: dual wield still fires from both hands, no cross-fire"
# The claim is "item 2 did not break firing", and its sharpest form is that the
# OFF hand still discharges — that is the whole of R6 part A and the code nearest
# the state this round edited. The first draft watched nails and rockets while
# both hands held a shotgun, and so watched nothing.
say 'vkqvrstyle 0'; sleep 3
say 'impulse 9'; sleep 3
say 'impulse 7'; sleep 3        # rocket launcher active in Convenience (no v2 sync to undo it)
say 'vkqvrstyle 1'; sleep 3     # seed v2: the aim hand takes it
say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 3
say 'vkqvrhandstick r 0 1'; sleep 2; say 'vkqvrhandstick r 0 0'; sleep 3
zoneline
SH0=$(grep -E '^FIRENOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -oE 'shots=L[0-9]+' | sed -E 's/shots=L//' || true)
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 12
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 3
zoneline
FIRELINE=$(grep -E '^FIRENOW ' "$DOCS/vr-diagnostics.log" | tail -1 || true)
SH1=$(printf '%s' "$FIRELINE" | grep -oE 'shots=L[0-9]+' | sed -E 's/shots=L//' || true)
RH1=$(printf '%s' "$FIRELINE" | grep -oE '/R[0-9]+' | sed -E 's|/R||' || true)
echo "   $FIRELINE"
python3 - "${SH0:-0}" "${SH1:-0}" "${RH1:-0}" <<'PY' || FAILED=1
import sys
l0, l1, r1 = (int(x) for x in sys.argv[1:4])
ok = (l1 - l0) > 0 and r1 > 0
print(f"   {'PASS' if ok else 'FAIL'}  both triggers held: off-hand shots {l0}->{l1}, aim-hand total {r1}",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
zone_assert "no cross-fire" FIRENOW 'unauthfired=0'
shot 92-dual-fire
# ---------------------------------------------------------------------------
echo "== R6.4 item 1: stowing your ONLY gun leaves the hand EMPTY (no phantom duplicate)"
# the user's exact repro: a new game has the axe and the shotgun and nothing else,
# so stowing the shotgun is the case where the STAT re-seed is most tempted to
# put it straight back in the hand it just left.
say 'vkqvrstyle 0'; sleep 3
say 'map e1m1'; sleep 22          # a NEW game: axe + shotgun only, and no stale belt
say 'vkqvrstyle 1'; sleep 3
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 4
zone_assert "SETUP: the aim hand starts with the server's weapon" HOLSTERNOW 'R\(grip=0 zone=- hold=imp[1-8]\)'
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 4
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 4
zone_assert "the hip has it AND the hand is empty" HOLSTERNOW 'R\(grip=0 zone=- hold=imp0\).*rhip=imp[1-8]'
zone_assert "no duplicated item bit anywhere" HOLSTERNOW 'dupes=0'
# hold it a few seconds: the re-seed runs on a timer, so the duplicate can appear
# AFTER the gesture rather than during it
sleep 6
zone_assert "...and still none once the re-seed has had time to run" HOLSTERNOW 'R\(grip=0 zone=- hold=imp0\).*rhip=imp[1-8].*dupes=0'

echo "== R6.4 item 2: the OFF-hand stick click clears both holsters"
zone_assert "SETUP: a hip is occupied" HOLSTERNOW 'rhip=imp[1-8]'
say 'vkqvrhandbtn l stick 1'; sleep 1; say 'vkqvrhandbtn l stick 0'; sleep 3
zone_assert "both hips are empty now" HOLSTERNOW 'rhip=imp0 lhip=imp0'
need "$DOCS/vr-diagnostics.log" "the clear is logged, and says the weapons are still owned" 'CLEARED both holsters'
# and the weapons are still OWNED: a flick must still find one
say 'vkqvrhandstick r 0 1'; sleep 2; say 'vkqvrhandstick r 0 0'; sleep 3
zone_assert "a cleared weapon is still reachable on the cycle" HOLSTERNOW 'R\(grip=0 zone=- hold=imp[1-8]\)'

echo "== R6.4 item 3: a NEW GAME clears the belt (a changelevel does not)"
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 3
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
zone_assert "SETUP: something is holstered again" HOLSTERNOW 'rhip=imp[1-8]'
say 'map e1m1'; sleep 24          # `map` IS the engine's new-game boundary
zone_assert "a new game starts you with an EMPTY belt" HOLSTERNOW 'rhip=imp0 lhip=imp0'

# ---------------------------------------------------------------------------
echo "== R6.2 item 3: the sheet closes from the CONSOLE, and B does NOT close it"
say 'vkqsettings'; sleep 8
zone_assert "the sheet is open and the engine can see it" MOVENOW 'sheet=1'
say 'vkqvrhandbtn r b 1'; sleep 1; say 'vkqvrhandbtn r b 0'; sleep 6
zone_assert "B leaves the sheet ALONE now (the user: Done is how you close it)" MOVENOW 'sheet=1'
say 'vkqvrhandbtn l menu 1'; sleep 1; say 'vkqvrhandbtn l menu 0'; sleep 6
zone_assert "MENU leaves it alone too" MOVENOW 'sheet=1'
say 'vkqsettings close'; sleep 8
zone_assert "'vkqsettings close' still dismisses it (the remote rescue)" MOVENOW 'sheet=0'

echo "== R6.2: settings smoke"
say 'vkqsettingsdump'; sleep 3
need "$DOCS/vr-diagnostics.log" "the VR section is present in VR mode" 'SETTINGSNOW mode=2 .*\[Vision Pro VR\]'
need "$DOCS/vr-diagnostics.log" "smooth turning is still the default" 'SETTINGSNOW .*vrSnapTurn=0\.0000'
zone_assert "swim-down is still on B" MOVENOW 'snapturn=0\.0'
say 'vkqvrhandbtn r b 1'; sleep 2
zone_assert "B still drives +movedown in gameplay" MOVENOW 'down=1 .*btnaim=0x08'
say 'vkqvrhandbtn r b 0'; sleep 2

cp "$DOCS/vr-diagnostics.log" "$PFX-diagnostics.log" 2>/dev/null || true
echo "   diagnostics: $PFX-diagnostics.log"
[ "$FAILED" = 0 ] || { echo "VR QUICK VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
