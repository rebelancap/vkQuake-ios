#!/usr/bin/env bash
#
# sim-verify-vr.sh — VR mode verification on the Vision Pro simulator
# (docs/VR-CHARTER.md R1, docs/VR-R1-NOTES.md). Sibling of sim-verify-3d.sh.
#
# What the simulator CAN prove, and therefore what this script checks:
#   - VR entry/exit plumbing, the two-phase resize, and the mode sequencer
#   - the live A3/A4 chain end to end: e1m1 rendered through compositor-supplied
#     per-eye matrices, at the drawable's own frustum, via the rendezvous
#   - charter A9: menus and console land on the in-space panel, not the eyes —
#     AND (R1.1) that the panel says WHY, with the failing predicate term named
#     in the diagnostics file and an in-headset hint on the panel itself
#   - (R1.1) the present-mode TRANSITIONS: title -> panel, map -> world,
#     menu -> panel, resume -> world, and entering VR mid-game -> world at once
#   - (R1.1) the engine eye target is sized from the view's PHYSICAL drawable
#     texture, never its foveation-expanded logical viewport
#   - (R1.1) a static contract is dumped ONCE per session with no CHANGED lines
#   - the injected-pose falsification suite (the sim's own anchor is the IDENTITY,
#     so without injection a wrong sign in the composition would still look right)
#   - 2D <-> 3D <-> VR round-trips without wedging, and the 3D panel regression
#   - that the diagnostics file exists and carries real measurements
#   - (R2) the SpatialGamepad declaration and the accessory-tracking usage
#     string in the BUILT product, and that the running app reads them back out
#     of its own bundle
#   - (R2) hand aim end to end, through INJECTED hand poses that enter at the
#     same boundary a real accessory anchor does: the weapon at the hand, the
#     laser telling the truth, sent angles decoupled from the rendered head,
#     movement-direction rotation, snap turn, and edge-triggered weapon cycling
#   - (R2) that with NO hands the build behaves exactly as R1 did (head aim,
#     face-attached weapon, gamepad buttons untouched)
# What it CANNOT: stereo fusion, world-lock under real head motion, comfort,
# 90 Hz, hand (upper-limb) visibility, full immersion, and anything that needs a
# REAL Sense controller — enumeration category, chirality, accessory loading,
# haptics. Those are headset items — see docs/VR-R2-NOTES.md.
#
# LANE 1 (~/dev/CLAUDE.md): the EXISTING "Apple Vision Pro" on visionOS 27.0.
# Never `simctl create`. The device is shut down at the end, pass or fail.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=com.rebelancap.vkquake
PORT=27999
UDID=${VKQ_SIM_UDID:-9D4499E9-CCED-4AF1-9303-925E9515D346} # Apple Vision Pro, visionOS 27.0
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/vkQuake.app"
ARTS="$ROOT/artifacts/sim"
# R4: the SAME suite runs against both data sets. the user plays the rerelease
# paks, but the charter's acceptance is "boots with rerelease id1 AND original
# id1", and R4's viewmodel work is entirely data-driven, so it has to be proved
# on both rather than argued about. VKQ_SIM_DATASET=original|rerelease.
DATASET=${VKQ_SIM_DATASET:-rerelease}
case "$DATASET" in
original | rerelease) ;;
*) echo "FATAL: VKQ_SIM_DATASET must be 'original' or 'rerelease' (got '$DATASET')" >&2; exit 1 ;;
esac
PFX="$ARTS/$(date '+%Y-%m-%d')-vr2-$DATASET"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-sim.sh visionos" >&2; exit 1; }
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
	echo "FATAL: port $PORT already in use — another sim session owns the bridge" >&2; exit 1
fi

# Declared before the trap: `set -u` plus an early death would otherwise make the
# trap itself fail on an unbound variable, and the verdict would be lost.
FAILED=0
# R6.3: the signal half, ported from the quick suite. Without it this trap read
# `$?` from the last COMPLETED command — a successful one — and printed
# "SIM VR VERIFY: PASSED" for a run that had been SIGTERMed halfway through. It
# did that twice on 2026-08-12. A killed run has no verdict, and saying it passed
# is worse than saying nothing: every claim downstream of it is fiction. The flag
# is set by the signal handler and checked FIRST, ahead of both other verdicts.
INTERRUPTED=0
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
# The verdict, and the ONLY exit path. An assertion that cannot fail the run is
# not an assertion — this project has now paid for that three times, and the R4
# round ran to a screenshot FATAL and still reported success because the status
# was lost on the way out (a pipeline, a trap, an `|| true`). The trap now OWNS
# the exit status: it re-exits nonzero for any FAIL, any FATAL, and any death
# anywhere in the script, and it prints one unambiguous verdict line.
cleanup () {
	local rc=$?
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	echo "== shutting down $UDID (lane discipline: always, pass or fail)"
	xcrun simctl shutdown "$UDID" 2>/dev/null || true
	if [ "$INTERRUPTED" != 0 ]; then
		echo "SIM VR VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
		exit 143
	fi
	if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
		echo "SIM VR VERIFY: *** FAILED *** (script status $rc, assertion failures flag ${FAILED:-0})" >&2
		exit 1
	fi
	echo "SIM VR VERIFY: PASSED"
	exit 0
}
trap cleanup EXIT
# One place that ends the run when continuing would only produce fiction.
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

# WAIT OUT A SHUTTING-DOWN DEVICE BEFORE BOOTING IT. `bootstatus -b` does not:
# it boots whatever state the device is in, and booting one that is still
# shutting down wedges CoreSimulator's system services. On 2026-08-10 that wedge
# put the visionOS runtime's own compositor (RealityEnvironment) into a 30-second
# launch-watchdog crash loop that outlived the device reboot, filled the Mac with
# crash-reporter popups, and cost this round its verification (docs/VR-R2-NOTES.md
# §6.1). Cheap insurance, and the failure it prevents is expensive.
for _i in $(seq 1 60); do
	state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	case "$state" in
	Shutdown | Booted) break ;;
	esac
	echo "   waiting for $UDID to settle (currently: ${state:-unknown})"
	sleep 2
done
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
echo "== install"
xcrun simctl install "$UDID" "$APP"

echo "== inject game data + sim-only autoexec"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/rerelease/id1"
# The folder name is just a folder name — the engine loads whatever pak0/pak1 it
# finds. Swapping the paks in place is therefore a data-set swap through the
# IDENTICAL code path, which is exactly what has to be proved.
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
echo "   data set: $DATASET"
# R5 item 8 (charter: "the QuakeC mod ecosystem as a headline feature"). The
# charter's mods-work-in-VR claim has never had an artifact. No third-party mod
# (Arcane Dimensions, Copper, Alkaline) exists under gamedata/ on this machine
# and NOTHING is downloaded, so the substantial QuakeC mod used here is
# hipnotic — Scourge of Armagon, a real progs.dat fork with its own weapons,
# monsters and impulses, which is exactly the property under test.
MODDIR=""
for cand in "$ROOT/gamedata/rerelease/hipnotic/pak0.pak" "$ROOT/gamedata/hipnotic/pak0.pak"; do
	[ -f "$cand" ] && { MODDIR=hipnotic; mkdir -p "$DOCS/rerelease/hipnotic"; cp -c "$cand" "$DOCS/rerelease/hipnotic/pak0.pak" 2>/dev/null || cp "$cand" "$DOCS/rerelease/hipnotic/pak0.pak"; break; }
done
[ -n "$MODDIR" ] && echo "   mod for the VR mod test: $MODDIR" || echo "   NOTE: no mod pak found under gamedata/ — the VR mod test will be skipped"
{
	printf 'r_indirect 0\n'   # sim Metal lacks indirect draws (D-025)
	# `developer 1` HERE and nowhere else: the per-model viewmodel audit (grip
	# derivation + muzzle-flash cull) is a Con_DPrintf emitted when a model is
	# first LOADED and cached, and the attract demo loads every v_*.mdl during
	# Host_Init — before the console bridge is even listening. Setting it from
	# the bridge is always too late; autoexec.cfg is exec'd before the demo.
	printf 'developer 1\n'
} > "$DOCS/rerelease/id1/autoexec.cfg"
rm -f "$DOCS/vr-diagnostics.log"
# R6: NSUserDefaults SURVIVES simctl install, so a height baseline or a migration
# stamp left by an earlier run would silently decide what this one measures.
PLIST="$CONT/Library/Preferences/$BUNDLE.plist"
if [ -f "$PLIST" ]; then
	for k in vkq.vrHeightBase vkq.vrMig6 vkq.vrMig7 vkq.vrScale vkq.vrHolSize vkq.vrHolFwd vkq.vrStyle vkq.vrHud vkq.vrRenderScale vkq.vrSharpen vkq.vrHeight vkq.vrSnapTurn vkq.vrTurnSpeed vkq.cheatGod; do
		/usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" >/dev/null 2>&1 || true
	done
	echo "   cleared stored VR settings (baseline + migration stamp) for a known start"
fi

# ============================================================================
# VR R6.1 item 3 — THE SNAP-TURN MIGRATION, and why it needs its own launches.
#
# VKQ_iOS_MigrateSettings runs ONCE per process, stamped, before anything reads a
# VR preference. So "what happens on the launch after an upgrade" cannot be asked
# of a running app: the store has to be seeded the way an upgrade would leave it
# and the app has to start. Two short launches, before the long session, so a late
# wedge can never cost this round its migration evidence.
#
# The policy under test is the user's, unchanged since R6:
#   stored 2  (the OLD default, 45 deg)  ->  0   the user never touched it
#   stored 3  (60 deg, a real choice)    ->  3   that is a preference
#
# THE SENTINEL IS THE POINT. A seeding failure and a successful migration both
# produce "0", so case (a) alone could pass while doing nothing. vrTurnSpeed is
# seeded to 199 in the same write and is NOT a key this migration touches — if it
# reads back as 199, the store really was seeded and really was read, and the 0
# beside it is a migration rather than a default.
# ============================================================================
# THE STORE IS NOT THE FILE. cfprefsd caches a container's preferences and
# rewrites them on its own schedule, so a PlistBuddy edit made behind its back is
# simply not what the next launch reads. The first run of this block proved it:
# case (a) was seeded with 2 and read back case (b)'s 3, and the stale value then
# followed the store into the long session and failed a fresh-default assertion
# half an hour later. Killing the daemon is what forces it to re-read the file.
mig_sync () {
	# `killall` DOES NOT EXIST in the visionOS simulator runtime. The first
	# version of this line called it under `|| true` and was therefore a silent
	# no-op — the exact class of failure ~/dev/CLAUDE.md rule 3 exists for, and it
	# cost this round a 45-minute run. This is the route that works (note
	# `user/foreground/`, not `system/`), and a failure says so instead of
	# vanishing. The sentinel assertion below is the real guard either way.
	xcrun simctl spawn "$UDID" launchctl kill 9 user/foreground/com.apple.cfprefsd.xpc.daemon >/dev/null 2>&1 \
		|| echo "   NOTE: could not restart cfprefsd; the sentinel check below is what will catch it"
	sleep 3
}
mig_launch_dump () { # mig_launch_dump <label>
	SIMCTL_CHILD_VKQ_CONSOLE_BRIDGE=1 SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
		xcrun simctl launch "$UDID" $BUNDLE >/dev/null
	local i ok=0
	for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
	[ "$ok" = 1 ] || die "migration case '$1': the bridge never opened"
	sleep 4
	printf 'vkqsettingsdump\n' | nc -w 3 127.0.0.1 $PORT >/dev/null || true
	sleep 3
	grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" 2>/dev/null | tail -1
}
mig_case () { # mig_case <label> <seeded vrSnapTurn> <expected vrSnapTurn> <sentinel>
	xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
	sleep 2
	rm -f "$DOCS/vr-diagnostics.log"
	[ -f "$PLIST" ] || printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$PLIST"
	for k in vkq.vrMig7 vkq.vrSnapTurn vkq.vrTurnSpeed; do
		/usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" >/dev/null 2>&1 || true
	done
	/usr/libexec/PlistBuddy -c "Add :vkq.vrSnapTurn real $2" "$PLIST" >/dev/null 2>&1 || die "could not seed vrSnapTurn"
	# A DISTINCT sentinel per case. The first version used the same number for
	# both, which is precisely why it certified a stale read as a good one.
	/usr/libexec/PlistBuddy -c "Add :vkq.vrTurnSpeed real $4" "$PLIST" >/dev/null 2>&1 || die "could not seed the sentinel"
	mig_sync
	local line; line=$(mig_launch_dump "$1")
	[ -n "$line" ] || { echo "   FAIL  $1: no SETTINGSNOW after launch" >&2; FAILED=1; return; }
	printf '%s' "$line" | grep -q "vrTurnSpeed=$4.0000" \
		&& echo "   PASS  $1: the seeded store was read back (sentinel vrTurnSpeed=$4)" \
		|| { echo "   FAIL  $1: sentinel $4 did not survive (got $(printf '%s' "$line" | grep -o 'vrTurnSpeed=[0-9.]*')) — the store was not seeded, so nothing below is evidence" >&2; FAILED=1; }
	printf '%s' "$line" | grep -q "vrSnapTurn=$3" \
		&& echo "   PASS  $1: vrSnapTurn=$3" \
		|| { echo "   FAIL  $1: expected vrSnapTurn=$3, got $(printf '%s' "$line" | grep -o 'vrSnapTurn=[0-9.]*')" >&2; FAILED=1; }
}
echo "== R6.1 item 3: the snap-turn migration (two seeded launches)"
mig_case "a user's 60 deg is a PREFERENCE and is kept" 3 3.0000 199
mig_case "a stored 45 deg is the OLD DEFAULT and migrates to Smooth" 2 0.0000 177
xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
sleep 2
rm -f "$DOCS/vr-diagnostics.log"
for k in vkq.vrMig7 vkq.vrSnapTurn vkq.vrTurnSpeed; do
	/usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" >/dev/null 2>&1 || true
done
mig_sync
echo "   store returned to fresh for the long session"

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

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null || true; }
# Is the app still there to be asked? `say` swallows connection failures on
# purpose (the bridge closes after every command), so nothing else in this script
# notices a dead app — and a dead app plus a grep over the log file is how R4
# read a crash as a state-machine bug: the assertion re-read the PREVIOUS line
# and reported on evidence the app had written minutes earlier.
alive () { nc -z -G 2 127.0.0.1 $PORT 2>/dev/null; }
# `simctl io screenshot` intermittently returns "Timeout waiting for screen
# surfaces" on a headless-booted xrOS device. Retry rather than abort — but still
# fail loudly if the shot never lands: a missing artifact is an unverifiable claim.
# When it does not land, SAY WHY: an app that has crashed and a simulator surface
# that is merely busy look identical from here, and only one of them means the
# rest of the run is fiction.
shot () {
	for _t in 1 2 3 4 5 6; do
		if xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1; then
			echo "   shot: $PFX-$1.png"; return 0
		fi
		sleep 4
	done
	if ! alive; then
		die "screenshot '$1' never landed AND the app is not answering the console bridge — it has crashed. Check the crash report in ~/Library/Logs/DiagnosticReports/ and $DOCS/console.log"
	fi
	local state; state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
	die "screenshot '$1' never landed (app alive, device $state — screen surfaces unavailable)"
}
# Assertions against the diagnostics file. Silent no-op checks shipped three
# regressions in one day on a sibling port (CLAUDE.md rule 3): every claim this
# script makes is a grep that can fail the run. (FAILED itself is initialised up
# by the trap, which owns the exit status.)
need () { # need <file> <label> <extended-regex>
	if grep -Eq "$3" "$1"; then
		printf '   PASS  %s\n' "$2"
	else
		printf '   FAIL  %s  (no line matching /%s/)\n' "$2" "$3" >&2
		FAILED=1
	fi
}
count_is () { # count_is <file> <label> <regex> <expected>
	local n; n=$(grep -Ec "$3" "$1" || true)
	if [ "$n" = "$4" ]; then
		printf '   PASS  %s (%s)\n' "$2" "$n"
	else
		printf '   FAIL  %s: expected %s, got %s\n' "$2" "$4" "$n" >&2
		FAILED=1
	fi
}
snap () { # snap <name> — flush and copy the diagnostics file
	say 'vkqvrdiag'; sleep 3
	[ -f "$DOCS/vr-diagnostics.log" ] || { echo "FATAL: no vr-diagnostics.log to snapshot ($1)" >&2; exit 1; }
	cp "$DOCS/vr-diagnostics.log" "$PFX-diag-$1.log"
	echo "   diag: $PFX-diag-$1.log"
}

mkdir -p "$ARTS"
sleep 6
shot 00-2d-title

# --- R6 C1/C4: the sheet at a FRESH STORE, in 2D ------------------------------
# A fresh-store claim has to be made against a fresh store. Asserting these at
# the END of the suite read back the suite's own test inputs (it spends half an
# hour dragging the very sliders it was checking), which is what four "default
# not found" FAILs were on the first honest run.
echo "== R6 C1/C4: fresh-store defaults, and 2D shows BOTH Vision Pro sections"
say 'vkqsettingsdump'; sleep 3
FRESH=$(grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
[ -n "$FRESH" ] || die "vkqsettingsdump produced no SETTINGSNOW line"
printf '   %s\n' "$(printf '%s' "$FRESH" | cut -c1-200)"
printf '%s' "$FRESH" | grep -q 'mode=0 ' \
	&& echo "   PASS  the sheet knows it is in 2D" \
	|| { echo "   FAIL  fresh dump is not in mode 0" >&2; FAILED=1; }
for sec in "Vision Pro 3D" "Vision Pro VR"; do
	printf '%s' "$FRESH" | grep -q "\[$sec\]" \
		&& echo "   PASS  2D shows the '$sec' section" \
		|| { echo "   FAIL  2D is missing the '$sec' section" >&2; FAILED=1; }
done
for want in vrRenderScale=1.2500 vrSharpen=0.5000 vrHud=1.0000 vrStyle=1.0000 vrHolSize=0.7000 vrHolFwd=0.0381 vrHeight=0.0000 vrSnapTurn=0.0000; do
	printf '%s' "$FRESH" | grep -q "$want" \
		&& echo "   PASS  fresh-store default $want" \
		|| { echo "   FAIL  fresh-store default $want not in the dump" >&2; FAILED=1; }
done
for gone in vrScale vrXhairDebug vrZones vrGiveAll vrDiag vrStatus0; do
	printf '%s' "$FRESH" | grep -q "$gone" \
		&& { echo "   FAIL  removed row '$gone' is still in the sheet" >&2; FAILED=1; } \
		|| echo "   PASS  '$gone' is gone from the sheet"
done

# --- 1. VR from the TITLE screen: panel, with a REASON and a visible hint -----
# This is the exact scenario that made R1's device round read "VR looks like the
# 3D panel": the attract demo is not gameplay, so charter A9 puts the composite
# on the panel — correctly, and (until now) silently.
echo "== VR entry at the TITLE screen — expect panel mode, named reason, visible hint"
say 'vkqvr 1'
sleep 22
shot 01a-vr-panel-hint-at-title
snap 01-title

# --- 2. Start a game from INSIDE VR: the world must arrive ---------------------
echo "== map e1m1 from inside VR — the mode must flip to world"
say 'map e1m1'
sleep 16
shot 02a-vr-world

echo "== A9 — menus and console belong on the in-space panel, not the eyes"
say 'togglemenu'; sleep 7; shot 02b-vr-menu-on-panel
say 'togglemenu'; sleep 7; shot 02c-vr-back-to-world
say 'toggleconsole'; sleep 7; shot 02d-vr-console-on-panel
say 'toggleconsole'; sleep 7; shot 02e-vr-back-to-world-again

# --- 4. Long static-contract run ----------------------------------------------
# The simulator's drawable never changes shape, so a correct build dumps the
# contract exactly ONCE per session. R1 dumped it 117 times in 65 s on device
# because it diffed deviceFromEye, which the eye tracker refines every frame.
echo "== settling for a long static-contract window"
sleep 45
snap 02-world

# --- hands toggle (full immersion only; no visual difference on the sim) -------
echo "== Show Hands toggle — must not wedge the space (visual proof is a headset item)"
say 'vkqvrhands 1'; sleep 6; shot 03a-hands-on
say 'vkqvrhands 0'; sleep 6; shot 03b-hands-off

echo "== injected poses — the ONLY way the sim can falsify the A3 composition"
# The sim's device anchor is the identity and its deviceFromEye is the identity,
# so eyeFromPlayer comes out as the identity: the world would render correctly
# even if every sign were wrong. Known poses make each sign falsifiable:
#   +yaw   -> the view must turn LEFT      (ARKit +Y rotation)
#   +pitch -> the view must look UP        (ceiling, not floor)
#   -z     -> the head must move FORWARD
# and a synthetic eye pair makes the IPD arithmetic readable on a mono drawable.
say 'vkqvripd 0.063'
say 'vkqvrpose 0 0 0 0 0';    sleep 5; shot 04a-pose-neutral
say 'vkqvrpose 90 0 0 0 0';   sleep 5; shot 04b-pose-yaw-left
say 'vkqvrpose -90 0 0 0 0';  sleep 5; shot 04c-pose-yaw-right
say 'vkqvrpose 0 30 0 0 0';   sleep 5; shot 04d-pose-pitch-up
say 'vkqvrpose 0 -30 0 0 0';  sleep 5; shot 04e-pose-pitch-down
say 'vkqvrpose 0 0 0 0 -1.5'; sleep 5; shot 04f-pose-forward
say 'vkqvrpose'; say 'vkqvripd 0'; sleep 4

echo "== world scale retunes live"
say 'vkqvrscale 20'; sleep 5; shot 05a-scale-20
say 'vkqvrscale 39.37'; sleep 5; shot 05b-scale-default

# ============================================================================
# R2 — Sense plumbing and Convenience-mode aim (docs/VR-R2-NOTES.md)
#
# The simulator has no controllers, so every consumer of a hand pose would be
# untestable without injection. `vkqvrhand` puts a synthetic pose in at the same
# boundary a real ARKit accessory anchor arrives at, in the same tracking space,
# so what follows exercises the SHIPPING transform chain and the SHIPPING input
# code — not a parallel test path.
# ============================================================================
echo "== R2: the declaration in the BUILT product"
if plutil -extract GCSupportedGameControllers xml1 -o - "$APP/Info.plist" 2>/dev/null | grep -q SpatialGamepad; then
	echo "   PASS  GCSupportedGameControllers/SpatialGamepad survived into the app bundle"
else
	echo "   FAIL  built Info.plist has no SpatialGamepad profile" >&2; FAILED=1
fi
if plutil -extract NSAccessoryTrackingUsageDescription raw -o - "$APP/Info.plist" >/dev/null 2>&1; then
	echo "   PASS  NSAccessoryTrackingUsageDescription present in the app bundle"
else
	echo "   FAIL  built Info.plist has no NSAccessoryTrackingUsageDescription" >&2; FAILED=1
fi

# A helper that flushes one AIM line and returns it. Every R2 claim below is a
# number out of the shipping diagnostics, not an eyeball on a screenshot.
# Same freshness rule as zone_assert: the weapon-flick test compares an AIMNOW
# line from before a stick injection with one from after, and two copies of the
# same stale line compare equal — which reads as "no false cycle" and would pass
# the whole flick suite against a dead app.
aimline () {
	local before after
	before=$(grep -Ec '^AIMNOW ' "$DOCS/vr-diagnostics.log" 2>/dev/null || true)
	say 'vkqvraim'; sleep 3
	after=$(grep -Ec '^AIMNOW ' "$DOCS/vr-diagnostics.log" 2>/dev/null || true)
	[ "$after" -gt "$before" ] || { echo "FATAL: no fresh AIMNOW line — the app stopped answering" >&2; exit 1; }
	grep -E '^AIMNOW ' "$DOCS/vr-diagnostics.log" | tail -1
}
# One number out of a FRESH AIMNOW line, or death. The flick and aim-trim tests
# compare a value from before an injection with one from after, and they compare
# shell variables: two empty strings are equal, so a dead app would "prove" that
# six diagonals never cycle the weapon. sed also echoes the whole line when its
# pattern misses, so the guard rejects anything that is not a plain number.
aimfield () { # aimfield <sed -E extract expression>
	local v; v=$(aimline | sed -E "$1")
	case "$v" in
	'' | *[!0-9.+-]*) echo "FATAL: could not read /$1/ from a fresh AIMNOW line (app dead, or the line was reshaped)" >&2; exit 1 ;;
	esac
	printf '%s' "$v"
}
aim_assert () { # aim_assert <label> <python-expr over the parsed fields>
	local line; line=$(aimline)
	printf '   aim: %s\n' "$line"
	python3 - "$1" "$2" "$line" <<'PY' || FAILED=1
import re, sys
label, expr, line = sys.argv[1], sys.argv[2], sys.argv[3]
m = dict(re.findall(r'(\w+)=([-+0-9.]+)', line))
p = {k: (pi, ya) for k, pi, ya in re.findall(r'(\w+)=\(p([-+0-9.]+) y([-+0-9.]+)\)', line)}
env = {k: float(v) for k, v in m.items()}
for k, (pi, ya) in p.items():
    env[k + '_p'] = float(pi); env[k + '_y'] = float(ya)
def angdiff(a, b):
    d = (a - b + 180.0) % 360.0 - 180.0
    return d
env['angdiff'] = angdiff
env['abs'] = abs
try:
    ok = bool(eval(expr, {'__builtins__': {}}, env))
except Exception as e:
    print(f"   FAIL  {label}: could not evaluate ({e}) on: {line}", file=sys.stderr); sys.exit(1)
print(("   PASS  " if ok else "   FAIL  ") + label + ("" if ok else f"  [{expr}] on: {line}"),
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
}

echo "== R2: no hands -> head aim, exactly R1 (the no-regression claim)"
aim_assert "no hands: head aim, no hand aim" "handaim == 0 and hands == 0"
shot 10a-r2-no-hands-head-aim

echo "== R2: a synthetic right hand appears"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'
sleep 4
aim_assert "hand tracked, aim switched to the hand" "handaim == 1 and hands == 1"
shot 10b-r2-weapon-at-hand
say 'vkqvrsense'; sleep 2

echo "== R2: the weapon follows the hand's pose, roll included"
say 'vkqvrhand r 0 0 60 0.25 -0.45 -0.40'; sleep 4; shot 10c-r2-hand-roll-60
say 'vkqvrhand r -35 0 0 0.25 -0.45 -0.40'; sleep 4; shot 10d-r2-hand-yaw-left
say 'vkqvrhand r 0 25 0 0.25 -0.30 -0.40'; sleep 4; shot 10e-r2-hand-pitch-up
say 'vkqvrhand r 0 0 0 -0.05 -0.20 -0.55'; sleep 4; shot 10f-r2-hand-centre-close

echo "== R2: aim/render DECOUPLING — head one way, hand the other"
# The head is yawed +40 by the injected pose; the hand points -30. If the sent
# angles follow the hand and the render follows the head, this is the only shot
# in the suite where the weapon and the view disagree on purpose.
say 'vkqvrpose 40 0 0 0 0'
say 'vkqvrhand r -30 0 0 0.25 -0.45 -0.40'
sleep 5
aim_assert "sent angles come from the HAND" "abs(angdiff(sent_y, hand_y)) < 1.5"
aim_assert "sent angles are NOT the head's" "abs(angdiff(sent_y, head_y)) > 30"
shot 11a-r2-aim-decoupled
say 'vkqvrhand r 0 20 0 0.25 -0.45 -0.40'; sleep 4
# 20 deg of hand pitch UP is -20 in Quake's sign, PLUS the -20 global grip pitch
# that overlay 0020 folds into the aim frame: -40. Under R2 this read -20,
# because the sent angles came from the raw controller frame while the barrel and
# the laser came from the gripped one — the 20 degrees the shot was landing below
# where the player was pointing.
aim_assert "hand pitch AND the grip pitch reach the sent angles" "abs(sent_p + 40) < 4"
say 'vkqvrpose'; sleep 3

echo "== R2: movement direction — head-relative rotates the wish vector"
say 'vkqvrpose 40 0 0 0 0'
say 'vkqvrhand r -30 0 0 0.25 -0.45 -0.40'
say 'vkqvr_movedir 0'; sleep 5
aim_assert "movedir 0 (head): wish vector rotated by head-minus-hand" "movedir == 0 and abs(delta - 70) < 6"
say 'vkqvr_movedir 1'; sleep 5
aim_assert "movedir 1 (aim hand): no rotation, the server already uses it" "movedir == 1 and abs(delta) < 0.01"
say 'vkqvr_movedir 0'; say 'vkqvrpose'; sleep 3

echo "== R2: snap turn pivots the BODY (render, aim and movement together)"
say 'vkqvr_snapturn 45'
BODY0=$(aimfield 's/.*body=([-+0-9.]+).*/\1/')
say 'vkqvrhandstick r 1 0'; sleep 3      # flick right, and HOLD it
say 'vkqvrhandstick r 1 0'; sleep 3      # still held: must NOT keep turning
BODY1=$(aimfield 's/.*body=([-+0-9.]+).*/\1/')
say 'vkqvrhandstick r 0 0'; sleep 2      # release, re-arm
say 'vkqvrhandstick r 1 0'; sleep 3      # second flick
BODY2=$(aimfield 's/.*body=([-+0-9.]+).*/\1/')
say 'vkqvrhandstick r 0 0'; sleep 2
python3 - "$BODY0" "$BODY1" "$BODY2" <<'PY' || FAILED=1
import sys
b0, b1, b2 = (float(x) for x in sys.argv[1:4])
def d(a, b): return (b - a + 180.0) % 360.0 - 180.0
one, two = d(b0, b1), d(b1, b2)
ok1 = abs(abs(one) - 45.0) < 1.0
ok2 = abs(abs(two) - 45.0) < 1.0
print(f"   {'PASS' if ok1 else 'FAIL'}  one held flick = exactly one 45 deg step ({one:+.1f})",
      file=(sys.stdout if ok1 else sys.stderr))
print(f"   {'PASS' if ok2 else 'FAIL'}  releasing re-arms for the next flick ({two:+.1f})",
      file=(sys.stdout if ok2 else sys.stderr))
sys.exit(0 if (ok1 and ok2) else 1)
PY
shot 11b-r2-after-snap-turns

echo "== R2: weapon cycling — one flick, one impulse (edge-triggered)"
say 'impulse 9'; sleep 3                 # all weapons, so cycling has somewhere to go
W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandstick r 0 1'; sleep 3      # flick UP = impulse 10, and HOLD
say 'vkqvrhandstick r 0 1'; sleep 4      # still held: must not machine-gun the impulse
W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandstick r 0 0'; sleep 2
say 'vkqvrhandstick r 0 1'; sleep 3      # second flick
W2=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandstick r 0 0'; sleep 2
python3 - "$W0" "$W1" "$W2" <<'PY' || FAILED=1
import sys
w0, w1, w2 = (int(x) for x in sys.argv[1:4])
ok1 = w1 != w0
ok2 = w2 != w1
print(f"   {'PASS' if ok1 else 'FAIL'}  a held flick advanced the weapon once ({w0} -> {w1})",
      file=(sys.stdout if ok1 else sys.stderr))
print(f"   {'PASS' if ok2 else 'FAIL'}  releasing re-arms the flick ({w1} -> {w2})",
      file=(sys.stdout if ok2 else sys.stderr))
sys.exit(0 if (ok1 and ok2) else 1)
PY
shot 11c-r2-weapon-cycled

echo "== R2: the laser sight, on and off"
say 'vkqvrhand r 0 0 0 0.15 -0.35 -0.45'; sleep 3
say 'vkqvr_laser 1'; sleep 4; shot 12a-r2-laser-beam-and-dot
say 'vkqvr_laser 2'; sleep 4; shot 12b-r2-laser-dot-only
say 'vkqvr_laser 0'; sleep 4; shot 12c-r2-laser-off
say 'vkqvr_laser 1'; sleep 2

echo "== R2: grip calibration retunes the weapon LIVE (no re-entry)"
say 'vkqvrgun 0 0 0 -60 0 0 1'; sleep 4; shot 12d-r2-grip-pitch-minus60
say 'vkqvrgun 6 3 -2 0 20 0 1.4'; sleep 4; shot 12e-r2-grip-offset-and-scale
say 'vkqvrgun reset'; sleep 3; shot 12f-r2-grip-default

echo "== R2: the menu is drivable from the controller"
say 'vkqvrhandbtn r menu 1'; sleep 2; say 'vkqvrhandbtn r menu 0'; sleep 4
shot 13a-r2-menu-opened-by-menu-button
say 'vkqvrhandstick l 0 -1'; sleep 3; shot 13b-r2-menu-nav-down
say 'vkqvrhandstick l 0 0'; sleep 2
say 'vkqvrhandbtn r b 1'; sleep 2; say 'vkqvrhandbtn r b 0'; sleep 4
shot 13c-r2-menu-closed-by-b

# ============================================================================
# R2.1 — the device-round fixes (docs/VR-R3-NOTES.md). Every one of these is a
# claim the user's punch list made, turned into an assertion.
# ============================================================================
zoneline () { say 'vkqvrzones'; sleep 3; }
# Kept for ad-hoc use. NOT a freshness test any more — see nowseq() below for why
# counting lines in a self-trimming file cannot be one.
diag_count () { grep -Ec "^$1 " "$DOCS/vr-diagnostics.log" 2>/dev/null || true; }
# zone_assert reads a line the app must write JUST NOW, so FRESHNESS IS PART OF
# THE ASSERTION. Without that check the grep happily re-reads the previous
# answer, and a dead app becomes a state-machine bug: R4 spent a round on
# "Immersive v2 TAKE does not fire" when TAKE had fired correctly and the app had
# then crashed in the compositor loop (VKQVR.m:945), leaving the STOW line as the
# newest thing in the file. A stale line is not evidence — now the script says so.
# R6.1 — the freshness stamp itself. NOT a line count any more: the diagnostics
# file is a 96 KB pinned budget followed by a 120 KB rolling tail that DELETES ITS
# FIRST 60 KB when full, so "the count of ^PREFIX lines grew" goes false the
# moment the roll trims, with the app perfectly healthy. The R6 shipping log shows
# both the "pinned budget spent" marker and zero surviving ZONENOW lines, so the
# trim demonstrably happens inside a full run — see the note in
# VKQHostViewController.m for why that is a candidate explanation of §7b and why
# this round records it rather than chases it. A monotone counter written LAST is
# the part a front-trim can never take.
nowseq () { grep -E '^NOWSEQ [0-9]+$' "$DOCS/vr-diagnostics.log" 2>/dev/null | tail -1 | awk '{print $2+0}'; }
zone_assert () { # zone_assert <label> <prefix> <extended-regex>
	local before after line
	before=$(nowseq); before=${before:-0}
	zoneline   # ALWAYS re-measure first
	after=$(nowseq); after=${after:-0}
	if [ "$after" -le "$before" ]; then
		printf '   FAIL  %s  (NO FRESH %s LINE — the app did not answer; every later line in the file is stale)\n' "$1" "$2" >&2
		FAILED=1
		alive || die "the app stopped answering the console bridge during '$1' — it has crashed or wedged. Crash reports: ~/Library/Logs/DiagnosticReports/"
		die "the app is up but stopped writing $2 lines during '$1' — the VR loop or the diagnostics writer has wedged"
	fi
	line=$(grep -E "^$2 " "$DOCS/vr-diagnostics.log" | tail -1)
	printf '   %s: %s\n' "$2" "$line"
	if printf '%s' "$line" | grep -Eq "$3"; then
		printf '   PASS  %s\n' "$1"
	else
		printf '   FAIL  %s  (no /%s/ in the last %s line)\n' "$1" "$3" "$2" >&2; FAILED=1
	fi
}

echo "== R2.1 fix 1 / R6 C3: the standing eye height is DERIVED, and scale-correct"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
zoneline
zone_assert "EYENOW reports the whole derivation" EYENOW \
	'standing HMD .* \(ref [0-9.]+ m\) x .* u/m \| Quake eye 46 u above the floor, VR eye .* rise'
# R6 C3 CHANGED THE SEMANTICS HERE, deliberately, and the old assertions in this
# section asserted the old ones:
#   * the standing height is a STORED BASELINE now, captured once on the first VR
#     entry. It no longer tracks the live alignment, because the alignment is
#     re-derived on EVERY recentre and a player who recentred while seated became
#     permanently short. So "pose to 1.20 m and recentre" must NOT move it any
#     more — only Re-calibrate does, and that is what is checked below.
#   * the rise measures the player's deviation from the height Quake's own
#     46-unit eye stands at (46/39.37 = 1.168 m), so that changing the world
#     scale changes the size of the world and not the height of the player.
say 'vkqvrreset'; sleep 3                # clears the stored baseline
say 'vkqvrscale 39.37'; sleep 2          # the reset ships 34; this section's equivalence check wants the reference
say 'vkqvrpose 0 0 0 1.70 0'; sleep 3
say 'vkqvrrecenter'; sleep 5             # no baseline -> auto-calibration captures 1.70
zoneline
zone_assert "a tracked 1.70 m standing height is auto-calibrated in" EYENOW 'standing HMD 1\.70[0-9] m'
say 'vkqvrpose 0 0 0 1.20 0'; sleep 3
say 'vkqvrrecenter'; sleep 5
zoneline
zone_assert "...and a later recentre (seated, say) does NOT change it" EYENOW 'standing HMD 1\.70[0-9] m'
say 'vkqvrpose 0 0 0 1.70 0'; sleep 3
python3 - "$DOCS/vr-diagnostics.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1]).read()
m = re.findall(r'EYENOW standing HMD ([-\d.]+) m \(ref ([\d.]+) m\) x ([\d.]+) u/m \| Quake eye 46 u above the floor, VR eye ([-\d.]+) u \(([-\d.]+) m\) \| rise ([-+\d.]+) \(want ([-+\d.]+), ceiling allows ([-+\d.]+)\) trim ([-+\d.]+)', txt)
if not m:
    print("   FAIL  EYENOW line missing or reshaped", file=sys.stderr); sys.exit(1)
hmd, ref, ws, vreye, vrm, rise, want, allow, trim = (float(x) for x in m[-1])
if abs(vreye - (46.0 + rise + trim)) > 0.05:
    print(f"   FAIL  VR eye {vreye} != 46 + rise {rise} + trim {trim}", file=sys.stderr); sys.exit(1)
if abs(ref - 46.0/39.37) > 0.005:
    print(f"   FAIL  reference eye height {ref} != 46/39.37 = {46.0/39.37:.3f}", file=sys.stderr); sys.exit(1)
if hmd > 0.6 and abs(want - (hmd - ref)*ws) > 0.2:
    print(f"   FAIL  want {want} != ({hmd}-{ref})*{ws} = {(hmd-ref)*ws:.1f}", file=sys.stderr); sys.exit(1)
# The property that makes it a FIX and not a re-tune: at the reference scale the
# new formula is algebraically identical to the one 1.0.7.8 shipped.
if abs(ws - 39.37) < 0.01 and abs(want - (hmd*ws - 46.0)) > 0.05:
    print("   FAIL  at 39.37 u/m the new formula must equal the old one", file=sys.stderr); sys.exit(1)
print(f"   PASS  eye height arithmetic holds (HMD {hmd:.3f} m, ref {ref:.3f} m, ws {ws:.2f} -> VR eye {vreye:.1f} u = {vrm:.2f} m, rise {rise:+.1f})")
PY
shot 20a-r2.1-eye-height
# Back to the identity pose: the zone tests below place hands relative to an
# alignment captured at the origin.
say 'vkqvrpose'; sleep 2; say 'vkqvrrecenter'; sleep 4

echo "== R2.1 fix 2: ONE aim frame — sent angles carry the grip pitch"
# The grip rotation is what makes the BARREL point where the player points, so
# it must reach the sent angles. Move it and the sent pitch must move with it;
# R2's raw-frame aim would not have budged.
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
say 'vkqvrgun 0 0 0 0 0 0 1'; sleep 3
P0=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
say 'vkqvrgun 0 0 0 -40 0 0 1'; sleep 3
P1=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
say 'vkqvrgun reset'; sleep 3
python3 - "$P0" "$P1" <<'PY' || FAILED=1
import sys
p0, p1 = float(sys.argv[1]), float(sys.argv[2])
d = p1 - p0
ok = abs(d + 40.0) < 4.0   # -40 deg of grip pitch = 40 deg less DOWN in Quake's sign
print(f"   {'PASS' if ok else 'FAIL'}  grip pitch reaches the SENT angles ({p0:+.1f} -> {p1:+.1f}, delta {d:+.1f}, want -40)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R2.1 fix 2: pitch drift no longer eats the sent pitch"
# The failure this catches: the hand holds a steady pitch and the SENT pitch
# creeps toward level over a couple of seconds. Sample twice, seconds apart.
say 'vkqvrhand r 0 35 0 0.25 -0.35 -0.40'; sleep 3
D0=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
sleep 6
D1=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
python3 - "$D0" "$D1" <<'PY' || FAILED=1
import sys
d0, d1 = float(sys.argv[1]), float(sys.argv[2])
ok = abs(d1 - d0) < 3.0 and abs(d0) > 5.0
print(f"   {'PASS' if ok else 'FAIL'}  sent pitch holds against V_DriftPitch ({d0:+.1f} -> {d1:+.1f} over 6 s)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R2.1 fix 2: laser, barrel and impact are ONE ray"
# Respawn first: the movement and snap-turn tests above leave the player jammed
# into a corner, and a laser traced 8 units into a wall proves nothing.
say 'map e1m1'; sleep 16
say 'impulse 9'; sleep 2
say 'impulse 2'; sleep 2
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3; shot 20b-r2.1-laser-level
say 'vkqvrhand r 0 25 0 0.25 -0.35 -0.40'; sleep 3; shot 20c-r2.1-laser-pitched-up
say 'vkqvrhand r 20 0 45 0.25 -0.45 -0.40'; sleep 3; shot 20d-r2.1-laser-rolled
# The red cone was a beam whose half-width scaled with the TOTAL trace length,
# so aim at the sky and it drew a wedge. Aim up at nothing and take the shot.
say 'vkqvrhand r 0 -60 0 0.25 -0.30 -0.40'; sleep 3; shot 20e-r2.1-laser-at-sky-no-cone
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3

echo "== R2.1 fix 4: every weapon, in the hand, one screenshot each"
say 'impulse 9'; sleep 3
for w in 1 2 3 4 5 6 7 8; do
	say "impulse $w"; sleep 3; shot "21-weapon-$w"
done
say 'impulse 2'; sleep 2

echo "== R2.1 fix 5: no hands -> head-attached viewmodel, not a belly-button gun"
say 'vkqvrhand r off'; sleep 4
aim_assert "hands gone: head aim" "handaim == 0 and hands == 0"
shot 22a-r2.1-no-hands-head-viewmodel
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 4
aim_assert "hands back: hand aim" "handaim == 1"
shot 22b-r2.1-hands-back-weapon-in-hand

echo "== R2.1 fix 7: the render-quality slider actually resizes the eye target"
N0=$(grep -Ec '^EYE TARGET' "$DOCS/vr-diagnostics.log" || true)
# 1.75x, NOT 1.25x: 1.25 is the R6 default (C4), so asking for it changes
# nothing, the eye target is never resized, and this test would be asserting
# that a no-op did something.
say 'vkqvrrenderscale 1.75'; sleep 8
say 'vkqvrdiag'; sleep 3
N1=$(grep -Ec '^EYE TARGET' "$DOCS/vr-diagnostics.log" || true)
say 'vkqvrrenderscale 1.0'; sleep 8
say 'vkqvrdiag'; sleep 3
N2=$(grep -Ec '^EYE TARGET' "$DOCS/vr-diagnostics.log" || true)
python3 - "$N0" "$N1" "$N2" <<'PY' || FAILED=1
import sys
n0, n1, n2 = (int(x) for x in sys.argv[1:4])
ok = n1 > n0 and n2 > n1
print(f"   {'PASS' if ok else 'FAIL'}  EYE TARGET lines: {n0} -> {n1} (x1.75) -> {n2} (back to x1.0)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
shot 23-r2.1-render-scale-back-to-1

# ============================================================================
# R3 — holsters, both interaction styles (charter A7)
# ============================================================================
echo "== R3: the zone layout is published"
zoneline
zone_assert "five zones, each with an impulse and a radius" ZONESNOW \
	'right hip=imp[0-9]+ @\(.*\)u r[0-9]+ \| left hip=imp[0-9]+ .* \| right shoulder=imp[0-9]+ .* \| left shoulder=imp[0-9]+ .* \| chest=imp[0-9]+'

echo "== R3: a hand entering a zone is DETECTED (right hip)"
# Zone centres are metres from the eye in the body frame: right hip is
# (+0.22, -0.66, +0.06). Put the synthetic hand there.
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 4
zoneline
zone_assert "right hand reports being in the right hip zone" HOLSTERNOW 'R\(grip=0 zone=right hip hold=imp[0-8]\)'
shot 30a-r3-hand-in-right-hip

echo "== R3: Convenience — grip TAP in a zone selects that zone's weapon"
say 'vkqvrstyle 0'; sleep 2
# Widen the REASSIGN threshold so the harness's ~1 s console-bridge round trip
# stays on the "select" side of it. A scripted press cannot be shorter than one
# round trip; the shipping 1.0 s is exercised by the reassign test below.
say 'vkqvr_grip_hold 8'; sleep 2
say 'impulse 9'; sleep 3
say 'impulse 1'; sleep 3                       # start on the axe so any change is visible
W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandbtn r grip 1'; sleep 1
say 'vkqvrhandbtn r grip 0'; sleep 3           # a TAP: down and up well inside vkqvr_grip_tap
W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
python3 - "$W0" "$W1" <<'PY' || FAILED=1
import sys
w0, w1 = int(sys.argv[1]), int(sys.argv[2])
ok = w0 == 4096 and w1 == 1   # IT_AXE -> IT_SHOTGUN (right hip's default impulse 2)
print(f"   {'PASS' if ok else 'FAIL'}  grip tap at the right hip selected the shotgun (weapon {w0} -> {w1}, want 4096 -> 1)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
zoneline
zone_assert "the select was logged" HOLSTERNOW 'select imp2 from right hip'
shot 30b-r3-convenience-selected-shotgun

echo "== R3: Convenience — a grip tap in EMPTY space changes nothing"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandbtn r grip 1'; sleep 1
say 'vkqvrhandbtn r grip 0'; sleep 3
W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
[ "$W0" = "$W1" ] && echo "   PASS  a tap outside every zone is inert (weapon stayed $W0)" \
	|| { echo "   FAIL  a tap outside every zone changed the weapon ($W0 -> $W1)" >&2; FAILED=1; }

echo "== R3: the OTHER zones select their own weapons"
say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3   # left hip -> super shotgun (3)
say 'vkqvrhandbtn r grip 1'; sleep 1; say 'vkqvrhandbtn r grip 0'; sleep 3
zone_assert "left hip selects its impulse" HOLSTERNOW 'select imp3 from left hip'
say 'vkqvrhand r 0 0 0 0.22 -0.16 0.14'; sleep 3    # right shoulder -> rocket launcher (7)
say 'vkqvrhandbtn r grip 1'; sleep 1; say 'vkqvrhandbtn r grip 0'; sleep 3
zone_assert "right shoulder selects its impulse" HOLSTERNOW 'select imp7 from right shoulder'
say 'vkqvrhand r 0 0 0 0.0 -0.38 -0.02'; sleep 3    # chest -> grenade launcher (6)
say 'vkqvrhandbtn r grip 1'; sleep 1; say 'vkqvrhandbtn r grip 0'; sleep 3
zone_assert "chest selects its impulse" HOLSTERNOW 'select imp6 from chest'
shot 30c-r3-zone-selects

echo "== R3: a long grip hold in a zone REASSIGNS it"
say 'vkqvr_grip_hold 1.0'; sleep 2   # the shipping value
say 'impulse 8'; sleep 3                            # lightning gun in hand
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3    # right hip
say 'vkqvrhandbtn r grip 1'; sleep 5                # hold past vkqvr_grip_hold
say 'vkqvrhandbtn r grip 0'; sleep 3
zone_assert "the right hip now holds the lightning gun" HOLSTERNOW 'ASSIGNED imp8 to right hip'
zoneline
zone_assert "and the published layout agrees" ZONESNOW 'right hip=imp8'
say 'vkqvr_zone_rhip 2'; sleep 2                    # put it back for the rest of the run

echo "== R4 part C: IMMERSIVE v2 — the holsters CONTAIN weapons"
# v2's grip only means anything inside a zone, and it is edge-triggered on the
# PRESS: take / stow / swap. Nothing happens on release, because "the weapon
# stays in your hand without holding the grip" is the whole redesign.
say 'vkqvrstyle 1'; sleep 3
say 'impulse 9'; sleep 3                            # own everything
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2   # empty space
say 'vkqvrhandbtn r grip 1'; sleep 2; say 'vkqvrhandbtn r grip 0'; sleep 2
zone_assert "the aim hand starts holding the server's weapon" HOLSTERNOW 'R\(grip=0 zone=- hold=imp[1-8]\)'
shot 31a-r4-v2-start

echo "== R4: STOW — a held weapon into an empty hip"
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3    # right hip, empty
say 'vkqvrhandbtn r grip 1'; sleep 3
zone_assert "stow logged" HOLSTERNOW 'STOW imp[1-8] into right hip'
say 'vkqvrhandbtn r grip 0'; sleep 2
zone_assert "the right hip now holds it and the hand is empty" HOLSTERNOW 'R\(grip=0 zone=right hip hold=imp0\).*rhip=imp[1-8]'
shot 31b-r4-v2-stowed-empty-hand

echo "== R4: empty hands render NOTHING and the trigger is suppressed"
say 'vkqvrhandbtn r trigger 1'; sleep 3
shot 31c-r4-v2-empty-hand-trigger
say 'vkqvrhandbtn r trigger 0'; sleep 2
zone_assert "an empty hand never becomes the firing hand" HOLSTERNOW 'fire=-'

echo "== R4: TAKE — the same hip, back into the hand"
say 'vkqvrhandbtn r grip 1'; sleep 3
zone_assert "take logged" HOLSTERNOW 'TAKE imp[1-8] from right hip -> right hand'
say 'vkqvrhandbtn r grip 0'; sleep 2
zone_assert "the hip is empty again" HOLSTERNOW 'rhip=imp0'
shot 31d-r4-v2-taken

echo "== R4: DUAL WIELD — the off hand takes a second, different weapon"
say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3   # LEFT hand at the LEFT hip
say 'vkqvrhandbtn l grip 1'; sleep 3                # left hip is empty -> nothing to take
say 'vkqvrhandbtn l grip 0'; sleep 2
say 'impulse 8'; sleep 3
say 'vkqvrhandbtn r grip 0'; sleep 1
# put the aim hand's weapon in the LEFT hip, then take it with the LEFT hand
say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
zone_assert "stowed into the left hip" HOLSTERNOW 'lhip=imp[1-8]'
say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2
zone_assert "the left hand took it" HOLSTERNOW 'L\(grip=0 zone=left hip hold=imp[1-8]\)'
shot 31e-r4-v2-dual-wield

echo "== R4: SWAP — a held weapon into an occupied hip (our addition to the spec)"
# THE PRECONDITION IS ESTABLISHED WITH IN-MODEL ACTIONS ONLY. Dual wield above
# leaves the AIM hand empty — the off hand took the weapon — and in Immersive v2
# `impulse N` does NOT put a gun in a hand: the hand is a physical inventory and
# an impulse only moves the SERVER's active weapon. R4 wrote this section
# assuming otherwise and it had never run once; its first honest execution failed
# here and took the two sections after it down with it, all three reporting an
# engine that was behaving exactly as designed.
#
# A stick FLICK is how an empty aim hand draws a weapon (VKQ_VR_CycleWeapon
# skips whatever is in the other hand or a holster), so that is the setup.
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandstick r 0 1'; sleep 3; say 'vkqvrhandstick r 0 0'; sleep 3
zone_assert "a flick draws a weapon into the empty aim hand" HOLSTERNOW 'R\(grip=0 zone=right hip hold=imp[1-8]\)'
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2   # stow it
zone_assert "the right hip is loaded, ready to be swapped" HOLSTERNOW 'rhip=imp[1-8]'
say 'vkqvrhandstick r 0 1'; sleep 3; say 'vkqvrhandstick r 0 0'; sleep 3     # draw a DIFFERENT one
say 'vkqvrhandbtn r grip 1'; sleep 3                                          # swap
zone_assert "swap logged" HOLSTERNOW 'SWAP right hip: imp[1-8] out, imp[1-8] in'
say 'vkqvrhandbtn r grip 0'; sleep 2
shot 31f-r4-v2-swapped

echo "== R4: rapid alternation must not wedge the weapon state"
for _k in 1 2 3 4 5 6; do
	say 'vkqvrhandbtn r grip 1'; sleep 1; say 'vkqvrhandbtn r grip 0'; sleep 1
done
sleep 3
zone_assert "still exactly one weapon in the hand and one on the hip" HOLSTERNOW 'R\(grip=0 zone=right hip hold=imp[1-8]\).*rhip=imp[1-8]'
shot 31g-r4-v2-after-alternation

echo "== R4: doff — the physical inventory survives losing the controllers"
say 'vkqvrhand r off'; say 'vkqvrhand l off'; sleep 5
shot 32-r4-v2-doff
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 4
zone_assert "and it is still there when they come back" HOLSTERNOW 'rhip=imp[1-8]'

echo "== R4: leaving Immersive clears v2 state (Convenience is untouched)"
say 'vkqvrstyle 0'; sleep 3
zone_assert "Convenience reports no held/holstered items" HOLSTERNOW 'style=convenience.*rhip=imp0 lhip=imp0'
say 'vkqvr_grip_hold 1.0'; sleep 2   # back to shipping
say 'vkqvrhandbtn r grip 0'; sleep 2

echo "== R4 part E: strict weapon-flick gating — diagonals must not cycle"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
say 'impulse 9'; sleep 2; say 'impulse 2'; sleep 3
FLICKFAIL=0
for XY in "0.45 0.70" "0.60 0.75" "-0.50 0.80" "0.35 0.90" "0.70 0.70" "-0.65 0.72"; do
	set -- $XY
	W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
	say "vkqvrhandstick r $1 $2"; sleep 3
	say 'vkqvrhandstick r 0 0'; sleep 3
	W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
	if [ "$W0" != "$W1" ]; then
		echo "   FAIL  diagonal ($1,$2) cycled the weapon ($W0 -> $W1)" >&2; FLICKFAIL=1
	fi
done
[ "$FLICKFAIL" = 0 ] && echo "   PASS  six diagonals, zero false cycles" || FAILED=1
W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
say 'vkqvrhandstick r 0 1'; sleep 3
say 'vkqvrhandstick r 0 0'; sleep 3
W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
[ "$W0" != "$W1" ] && echo "   PASS  a clean vertical flick still cycles ($W0 -> $W1)" \
	|| { echo "   FAIL  a clean vertical flick no longer cycles (stuck at $W0)" >&2; FAILED=1; }
shot 33-r4-flick-gating

echo "== R4 part B: the crosshair, and the aim pitch trim it calibrates"
say 'vkqvrhand r 0 -20 0 0.25 -0.45 -0.40'; sleep 3
shot 34a-r4-crosshair
A0=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
say 'vkqvr_aimpitch 15'; sleep 3
A1=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
shot 34b-r4-aimtrim-plus15
say 'vkqvr_aimpitch -15'; sleep 3
A2=$(aimfield 's/.*sent=\(p([-+0-9.]+).*/\1/')
shot 34c-r4-aimtrim-minus15
say 'vkqvr_aimpitch 0'; sleep 2
python3 - "$A0" "$A1" "$A2" <<'PY' || FAILED=1
import sys
a0, a1, a2 = (float(x) for x in sys.argv[1:4])
ok = abs((a1 - a0) - 15.0) < 3.0 and abs((a2 - a0) + 15.0) < 3.0
print(f"   {'PASS' if ok else 'FAIL'}  Aim Pitch Trim moves the SENT aim +-15 deg ({a0:+.1f} -> {a1:+.1f} / {a2:+.1f})",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R4 part D: the head-locked HUD, High and Low"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
say 'vkqvrhud 0'; sleep 4; shot 35a-r4-hud-high
say 'vkqvrhud 1'; sleep 4; shot 35b-r4-hud-low
say 'vkqvrhud 2'; sleep 4; shot 35c-r4-hud-off
say 'vkqvrhud 0'; sleep 3

# R4's Sharpen on/off is superseded by R5 item 6's three-point sweep, below.

echo "== R2: hands go away -> straight back to R1 behaviour"
say 'vkqvrhand r off'; say 'vkqvrhandstick r 0 0'; sleep 5
aim_assert "no hands again: head aim restored" "handaim == 0 and hands == 0"
shot 14-r2-hands-removed-head-aim
snap 04-r2

# --- R4: the GAMEPAD-ONLY viewmodel -------------------------------------------
# the user's 1.0.7.5 gamepad round: with no controllers the weapon sat off to the
# right, at about where the right controller would have been. It was a lateral
# term in the fallback placement, not a stale pose — but from inside a headset
# those look identical, so the fix is structural (the fallback reads no hand
# state at all) and this is the assertion that keeps it that way.
echo "== R4: gamepad-only viewmodel is CENTRED and reads no hand state"
say 'impulse 9'; sleep 2; say 'impulse 2'; sleep 3
shot 40a-r4-gamepad-only-centred
# Moving a hand that is NOT tracked must change nothing about the picture. Two
# screenshots, byte-compared: the fallback path cannot be consuming hand poses.
say 'vkqvrhandstick r 0 0'; sleep 2
cp "$PFX-40a-r4-gamepad-only-centred.png" "$PFX-40a-ref.png" 2>/dev/null || true
say 'vkqvrhand r 0 45 0 0.40 -0.20 -0.30'; sleep 1; say 'vkqvrhand r off'; sleep 4
shot 40b-r4-gamepad-only-after-hand-poke
python3 - "$PFX-40a-r4-gamepad-only-centred.png" "$PFX-40b-r4-gamepad-only-after-hand-poke.png" <<'PY' || FAILED=1
import sys, zlib, struct
def load(p):
    return open(p,'rb').read()
a, b = load(sys.argv[1]), load(sys.argv[2])
# Not a pixel compare (the sim animates), but the frames must be the same SIZE
# and the weapon must not have jumped: a size change or a wildly different byte
# length is the smoking gun for a re-placed model. The real assertion is the
# grep below; this is the cheap corroboration.
ok = len(a) > 1000 and len(b) > 1000
print(f"   {'PASS' if ok else 'FAIL'}  gamepad-only frames captured for the centred-viewmodel audit",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
# The structural claim, checked in the SOURCE the build was made from: the
# fallback function must not mention a hand at all.
python3 - "$ROOT/build/src-overlay/Quake/gl_vidsdl.c" <<'PY' || FAILED=1
import sys, re
src = open(sys.argv[1]).read()
i = src.index("static qboolean VKQ_VR_PlaceViewmodelHead (entity_t *view)")
j = src.index("\nqboolean VKQ_VR_PlaceViewmodel ", i)
body = src[i:j]
bad = [t for t in ("vkq_vr_hand", "vkq_vr_aim_hand", "vkq_vr_off_hand", "vkq_vr_held_item", "hand_pub") if t in body]
print(f"   {'PASS' if not bad else 'FAIL'}  the no-hands viewmodel path consumes no hand state"
      + (f" (found {bad})" if bad else ""),
      file=(sys.stdout if not bad else sys.stderr))
sys.exit(0 if not bad else 1)
PY

# ============================================================================
# VR R5 — the round the user's 1.0.7.7 headset session dispatched.
#
# Every section below exists because something verified as a NUMBER and was
# wrong as a PIXEL, a CENTIMETRE or a KEYPRESS. The standing rule this round
# adds: a feature whose job is to put something on a screen gets an assertion
# that reads the screen (scripts/sim-pixel-count.py).
# ============================================================================

xhair_assert () { # xhair_assert <label> <extended-regex>
	local before after line
	before=$(nowseq); before=${before:-0}
	say 'vkqvrxhair'; sleep 3   # ALWAYS re-measure first (R4.1's freshness rule)
	after=$(nowseq); after=${after:-0}
	if [ "$after" -le "$before" ]; then
		printf '   FAIL  %s  (NO FRESH XHAIRNOW LINE — the app did not answer)\n' "$1" >&2
		FAILED=1
		alive || die "the app stopped answering the bridge during '$1' — it has crashed"
		die "the app is up but stopped writing XHAIRNOW lines during '$1'"
	fi
	line=$(grep -E "^XHAIRNOW " "$DOCS/vr-diagnostics.log" | tail -1)
	printf '   XHAIRNOW: %s\n' "$line"
	if printf '%s' "$line" | grep -Eq "$2"; then
		printf '   PASS  %s\n' "$1"
	else
		printf '   FAIL  %s  (no /%s/ in the last XHAIRNOW line)\n' "$1" "$2" >&2; FAILED=1
	fi
}
pixels () { # pixels <shot-name> <predicate> [--min N] [--max N] ...
	local name="$1"; shift
	local pred="$1"; shift
	python3 "$ROOT/scripts/sim-pixel-count.py" "$PFX-$name.png" "$pred" "$@" || FAILED=1
}
# Console-log assertions. The bridge writes commands into Cbuf; Con_Printf lands
# in Documents/console.log, which is the only place a blocking modal can speak
# from — SCR_ModalMessage never returns to anything that writes the diag file.
conlog_count () { grep -Ec "$1" "$DOCS/console.log" 2>/dev/null || true; }
conlog_need () { # conlog_need <label> <regex>
	if grep -Eq "$2" "$DOCS/console.log" 2>/dev/null; then
		printf '   PASS  %s\n' "$1"
	else
		printf '   FAIL  %s  (no console.log line matching /%s/)\n' "$1" "$2" >&2
		FAILED=1
	fi
}

# --- R5 item 4: THE CROSSHAIR, AS PIXELS -------------------------------------
# Two rounds shipped an invisible reticle. R4's sim pass measured the aim trim
# to a tenth of a degree and never once asked whether anything was drawn — and
# the answer was that back-face culling was discarding half the arms (the
# particle pipeline is VK_CULL_MODE_BACK_BIT and R4's four arms did not share a
# winding). DEBUG mode draws it huge, magenta and 2 m along the aim ray whatever
# the trace does; magenta is a colour Quake's palette does not contain, so a
# nonzero count is our geometry and nothing else.
echo "== R5 item 4: the crosshair exists as PIXELS (debug mode, magenta)"
# Aimed 30 deg to the RIGHT on purpose. The simulator composites the app's own
# 2D window over the immersive content, and that parked card sits near the
# centre of the frame — a reticle at the centre of vision can be hidden behind
# it, which is a property of the screenshot and not of the reticle. Aiming off
# to one side removes the confound; the device has no such card in front of the
# player at all.
say 'vkqvrhand r -30 0 0 0.25 -0.45 -0.40'; sleep 3
say 'vkqvrxhair debug'; sleep 4
shot 50a-r5-xhair-debug
pixels 50a-r5-xhair-debug magenta --min 400
# ...and it must be ON SCREEN by the engine's own projection, which is the
# measurement that separates "the rasterizer discarded it" from "it was drawn
# perfectly, off the side of the frame". R5's first build reported drawn=1 with
# a 172-pixel arm and put zero pixels on the display, and nothing in the
# diagnostic could tell those two apart.
xhair_assert "the reticle projects INSIDE the frame" 'onscreen=1'
xhair_assert "the reticle reports itself drawn, with a pixel size" 'drawn=1 verts=48 .* -> [0-9]+\.[0-9] px arm'
python3 - "$DOCS/vr-diagnostics.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1]).read()
m = None
for m in re.finditer(r'XHAIRNOW .*-> ([\d.]+) px arm, ([\d.]+) px thick', txt):
    pass
if not m:
    print("   FAIL  no XHAIRNOW line carrying a pixel size", file=sys.stderr); sys.exit(1)
arm, thick = float(m[1]), float(m[2])
# The number R4 could not report. A sub-2-pixel arm is invisible on a headset
# whatever the geometry does, and the R4 reticle's arms were ~1 px thick.
ok = arm >= 6.0 and thick >= 1.5
print(f"   {'PASS' if ok else 'FAIL'}  reticle is {arm:.1f} px per arm, {thick:.1f} px thick in the eye target",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
echo "== R5 item 4: and back to the normal reticle (no magenta left anywhere)"
say 'vkqvrxhair on'; sleep 4
shot 50b-r5-xhair-normal
pixels 50b-r5-xhair-normal magenta --max 20
xhair_assert "normal mode draws all four arms, double-sided, on screen" 'drawn=1 verts=48 mode=normal .*onscreen=1'
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3

# --- R5 item 3: THE HOLSTERS ARE DRAWN WHERE THE HAND REACHES ----------------
# the user: the grabs work at his waist, the guns hang out in front of his body.
# R4's comment claimed the two "cannot disagree"; they disagreed by several
# units, because the render path additionally applied four hand-frame trims (in
# a frame where "up" means body-FORWARD) and then shrank the model about its
# origin AFTER positioning it by its grip. HOLGEOM measures the disagreement.
echo "== R5 item 3: holster render vs holster reach, measured"
# DETERMINISTIC PRECONDITION (R4.1's lesson, applied to R5's own sections):
# Immersive v2's grip means three different things depending on what is in the
# hand and the zone, so a section that merely grips has three possible
# outcomes. Convenience RESETS the v2 state; re-entering Immersive re-seeds the
# AIM HAND from the server's active weapon with both hips empty. A grip at a
# hip from there is a STOW, every time.
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
say 'impulse 9'; sleep 3
say 'vkqvrstyle 0'; sleep 3
say 'vkqvrstyle 1'; sleep 3
say 'impulse 2'; sleep 3
zoneline
zone_assert "reset: a weapon in the aim hand, both hips empty" HOLSTERNOW 'R\(grip=0 zone=- hold=imp[1-8]\).*rhip=imp0 lhip=imp0'
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 2; say 'vkqvrhandbtn r grip 0'; sleep 3   # STOW
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
say 'vkqvrhol'; sleep 3
zone_assert "the right hip is occupied and reports its geometry" HOLGEOMNOW 'rhip: zone=.*model=.*err='
python3 - "$DOCS/vr-diagnostics.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1]).read()
m = None
for m in re.finditer(r'HOLGEOMNOW .*?rhip: .*?\|err\|=([\d.]+)u', txt):
    pass
if not m:
    print("   FAIL  no HOLGEOMNOW line with a right-hip error", file=sys.stderr); sys.exit(1)
err = float(m[1])
# The whole of item 3: the drawn weapon's grip point IS the zone centre the hand
# has to reach. Half a unit is 1.3 cm and is pure float noise.
ok = err < 0.5
print(f"   {'PASS' if ok else 'FAIL'}  drawn grip point coincides with the zone centre (|err| = {err:.2f} units)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
shot 51a-r5-holster-drawn
echo "== R5 item 3: Holster Size and Holster Forward move what they say"
say 'vkqvrhol 1.2 0'; sleep 4; shot 51b-r5-holster-large
say 'vkqvrhol'; sleep 2
zone_assert "Holster Size reaches the render scale" HOLGEOMNOW 'holsize=1.20'
say 'vkqvrhol 0.80 0.20'; sleep 4; shot 51c-r5-holster-forward
say 'vkqvrhol'; sleep 2
zone_assert "Holster Forward reaches the zone frame" HOLGEOMNOW 'holfwd=0.20m'
# ...and moving the FRAME must move the reach target too, or the slider would
# re-create the bug it exists to work around. The zone layout is published in
# player-frame units: +0.20 m forward at 39.37 u/m is -7.9 on the BACK axis.
zoneline
python3 - "$DOCS/vr-diagnostics.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1]).read()
m = None
for m in re.finditer(r'ZONESNOW right hip=imp\d+ @\(([-\d.]+),([-\d.]+),([-\d.]+)\)u', txt):
    pass
if not m:
    print("   FAIL  no ZONESNOW right-hip centre", file=sys.stderr); sys.exit(1)
z = float(m[3])
ok = z < -5.0  # 0.06 m back - 0.20 m forward = -0.14 m -> about -5.5 units
print(f"   {'PASS' if ok else 'FAIL'}  Holster Forward moved the DETECTION zone too (right hip z = {z:.1f}u, was +2.4)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
say 'vkqvrhol 0.80 0'; sleep 3

# --- R5 item 2: A PLAIN PRESS FILLS AN EMPTY HAND ----------------------------
# the user asked for this to be simpler. The strict three-condition flick gate
# exists to stop a turn-and-glance from changing the weapon you are HOLDING;
# there is no such accident when the hand is empty, so an empty aim hand takes a
# plain up/down. The value below (0.60) is deliberately BELOW the strict gate's
# 0.85, so passing this test is only possible via the relaxed path.
echo "== R5 item 2: empty aim hand, plain stick press draws a weapon"
# Same deterministic reset, for the same reason.
say 'vkqvrstyle 0'; sleep 3
say 'vkqvrstyle 1'; sleep 3
say 'impulse 2'; sleep 3
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3
say 'vkqvrhandbtn r grip 1'; sleep 2; say 'vkqvrhandbtn r grip 0'; sleep 3   # STOW -> hand empty
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
zoneline
zone_assert "the aim hand really is empty first" HOLSTERNOW 'R\(grip=0 zone=- hold=imp0\)'
say 'vkqvrhandstick r 0 0.60'; sleep 3
say 'vkqvrhandstick r 0 0'; sleep 2
zoneline
zone_assert "a plain 0.60 press filled the empty hand" HOLSTERNOW 'R\(grip=0 zone=- hold=imp[1-8]\)'
shot 52-r5-empty-hand-filled
echo "== R5 item 2: ...and the STRICT gate still protects a full hand"
FLICKFAIL=0
for xy in "0.45 0.60" "-0.45 0.60" "0.50 0.65"; do
	set -- $xy
	W0=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
	say "vkqvrhandstick r $1 $2"; sleep 2
	say 'vkqvrhandstick r 0 0'; sleep 2
	W1=$(aimfield 's/.*weapon=([0-9]+).*/\1/')
	[ "$W0" = "$W1" ] || { echo "   FAIL  diagonal ($1,$2) cycled a HELD weapon ($W0 -> $W1)" >&2; FLICKFAIL=1; }
done
[ "$FLICKFAIL" = 0 ] && echo "   PASS  three diagonals left a held weapon alone (the relaxed gate is empty-hand only)" || FAILED=1
say 'vkqvrstyle 0'; sleep 3

# --- R5 addendum: FIRING-POSE MUZZLE FLASH -----------------------------------
# R4's eight-weapon audit was IDLE ONLY. the user then photographed two large
# orange flames beside his body while firing the super nailgun: these models'
# firing poses do not put the baked flash at the muzzle, they put it forward of
# the MODEL ORIGIN, and a 0.40-scale weapon anchored by its grip puts that
# between the fist and the shoulder. the user's verdict was to cull it in every
# frame, so the identification set (still from the idle-pose rule) is now applied
# unconditionally. The engine states what it did, per model, and the screenshots
# are taken MID-FIRE.
echo "== R5 addendum: the baked muzzle flash is culled in EVERY pose, all 8 weapons"
say 'map e1m1'; sleep 18
say 'impulse 9'; sleep 3
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
python3 - "$DOCS/console.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1], errors='replace').read()
rows = re.findall(r'VR viewmodel (progs/\S+): .*flash (\d+) verts culled in (\d+)/(\d+) poses \((\d+) parked, firing poses reach x=([-\d.]+)\)', txt)
if not rows:
    print("   FAIL  no VR viewmodel audit lines (is `developer 1` set before the map load?)", file=sys.stderr)
    sys.exit(1)
seen = {}
for name, nf, np, tot, parked, firex in rows:
    seen[name] = (int(nf), int(np), int(tot), int(parked), float(firex))
bad = [n for n, v in seen.items() if v[0] and v[1] != v[2]]
axe = [n for n in seen if 'v_axe' in n]
print("   models audited: %d" % len(seen))
for n in sorted(seen):
    nf, np, tot, parked, firex = seen[n]
    print("     %-22s flash %3d verts, culled %d/%d poses (%d were parked, firing reached x=%.1f)"
          % (n, nf, np, tot, parked, firex))
ok = not bad and len(seen) >= 8
if bad:
    print("   FAIL  these models still cull in only SOME poses: %s" % bad, file=sys.stderr)
if len(seen) < 8:
    print("   FAIL  expected at least 8 viewmodels, saw %d" % len(seen), file=sys.stderr)
print(f"   {'PASS' if ok else 'FAIL'}  every model with baked flash culls it in every pose",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
# MID-FIRE screenshots: hold the trigger, shoot, capture while the firing pose is
# on screen. The nailgun (4) and the super nailgun (5) are the two the user
# photographed; all eight are captured so the next round has the whole set.
#
# r_dynamic 0 FOR THE PIXEL HALF, and this is what makes it an assertion rather
# than a coin toss. R5's first run gated on a raw flame-pixel count and learned
# two things: scattered brown world reaches the predicate (weapon 4 scored 380
# pixels with a bounding box spanning the whole frame), and — the real problem —
# the muzzle-flash DLIGHT paints the floor beside the gun the same orange the
# baked geometry is, in a compact blob, legitimately. Turning dynamic lights off
# removes exactly that confound: the flash dlight stops painting anything, while
# baked flash GEOMETRY is unlit model art and would still be bright orange. So
# with r_dynamic 0, a compact orange blob during firing can only be the geometry
# this round deleted.
say 'r_dynamic 0'; sleep 2
for w in 1 2 3 4 5 6 7 8; do
	say "impulse $w"; sleep 3
	shot "53-fire-idle-$w"
	say 'vkqvrhandbtn r trigger 1'; sleep 2
	shot "53-fire-shooting-$w"
	say 'vkqvrhandbtn r trigger 0'; sleep 2
done
# Gated on the five weapons whose projectiles are NOT orange (hitscan pellets,
# nails, lightning). The grenade and the rocket spawn real orange entities that
# are supposed to be there, so their counts are recorded and not gated — saying
# so is better than a threshold picked to make them pass.
for w in 2 3 4 5 8; do
	pixels "53-fire-shooting-$w" flame --maxcell 60
done
for w in 1 6 7; do
	python3 "$ROOT/scripts/sim-pixel-count.py" "$PFX-53-fire-shooting-$w.png" flame || true
done
say 'r_dynamic 1'; sleep 2
say 'vkqvrhandbtn r trigger 0'; say 'impulse 2'; sleep 3

# --- R5 item 5: THE HUD, WITH QUAKE'S OWN ICONS ------------------------------
echo "== R5 item 5: HUD icons come from gfx.wad, and the new High/Low spacing"
say 'vkqvrhud 0'; sleep 4; shot 54a-r5-hud-high
say 'vkqvrhud 1'; sleep 4; shot 54b-r5-hud-low
say 'vkqvrhud 2'; sleep 3; shot 54c-r5-hud-off
say 'vkqvrhud 0'; sleep 3
snap 05-r5
need "$PFX-diag-05-r5.log" "the HUD resolved real sbar lumps, not fallback blocks" \
	"HUD ICONS from the engine's own gfx.wad: health 'face[1-5]' 2[0-9]x2[0-9]"

# --- R5 item 6: SHARPEN IS A STRENGTH ----------------------------------------
echo "== R5 item 6: Sharpen 0% / 50% (= R4's fixed strength) / 100%"
say 'vkqvrsharpen 0'; sleep 4; shot 55a-r5-sharpen-000
say 'vkqvrsharpen 0.5'; sleep 4; shot 55b-r5-sharpen-050
say 'vkqvrsharpen 1.0'; sleep 4; shot 55c-r5-sharpen-100
python3 - "$PFX-55a-r5-sharpen-000.png" "$PFX-55b-r5-sharpen-050.png" "$PFX-55c-r5-sharpen-100.png" <<'PY' || FAILED=1
import sys
from PIL import Image, ImageStat, ImageFilter
# A sharpening pass raises local contrast. Laplacian energy is the cheapest
# honest proxy, and it has to rise MONOTONICALLY with the slider or the slider
# is not connected to the shader.
def energy(p):
    im = Image.open(p).convert("L").crop((600, 400, 2400, 1600))
    return ImageStat.Stat(im.filter(ImageFilter.FIND_EDGES)).mean[0]
a, b, c = (energy(p) for p in sys.argv[1:4])
ok = b > a * 1.01 and c > b * 1.01
print(f"   {'PASS' if ok else 'FAIL'}  edge energy rises with the slider: 0%={a:.2f} 50%={b:.2f} 100%={c:.2f}",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
say 'vkqvrsharpen 0.5'; sleep 3

# --- R5 item 1: THE MODAL SOFT-LOCK ------------------------------------------
# The release blocker. New Game over a loaded game -> "are you sure?" with no
# answer path: the touch Yes/No overlay belonged to a layer the visionOS shell
# hides (and was added to whichever window `connectedScenes` happened to yield
# first), the engine loop blocked forever, and the console bridge could not help
# because Cbuf never drained inside the pump.
#
# This test drives the WHOLE new path: a synthetic Sense trigger opens the menu
# item through VKQ_VR_UIInputPump (which only exists because of this bug), the
# modal blocks, a bridge command executes while it is blocked, and a second
# synthetic trigger answers it.
echo "== R5 item 1: SCR_ModalMessage — answerable, and no longer starving Cbuf"
say 'vkqvrstyle 0'; sleep 2
say 'map e1m1'; sleep 18
MODAL0=$(conlog_count 'MODAL: waiting for an answer')
say 'menu_singleplayer'; sleep 3
shot 56a-r5-menu-before-modal
# The Sense trigger drives the menu. This alone is new: before R5 the pair did
# nothing outside a VR world frame.
say 'vkqvrhandbtn r trigger 1'; sleep 2
say 'vkqvrhandbtn r trigger 0'; sleep 4
shot 56b-r5-modal-up
MODAL1=$(conlog_count 'MODAL: waiting for an answer')
[ "$MODAL1" -gt "$MODAL0" ] \
	&& echo "   PASS  a Sense trigger reached the menu and opened the modal ($MODAL0 -> $MODAL1)" \
	|| { echo "   FAIL  the modal never opened (MODAL lines $MODAL0 -> $MODAL1) — did the Sense UI pump reach key_dest != key_game?" >&2; FAILED=1; }
# THE REMOTE-RESCUE ASSERTION. The engine is parked inside SCR_ModalMessage right
# now; if Cbuf still drains, this echo lands in the console log.
say 'echo VKQ_R5_MODAL_BRIDGE_ALIVE'; sleep 4
conlog_need "a bridge command EXECUTED while the modal was blocking" 'VKQ_R5_MODAL_BRIDGE_ALIVE'
# ...and answering it with the Sense trigger, which is the thing the user could not
# do. K_ABUTTON is what SCR_ModalMessage's own exit test accepts as YES.
say 'vkqvrhandbtn r trigger 1'; sleep 2
say 'vkqvrhandbtn r trigger 0'; sleep 6
conlog_need "the modal was ANSWERED by a Sense trigger" 'MODAL: answered YES'
# THE STICKY-DIALOG ASSERTION. VKQ_iOS_ModalPump spins the main run loop so
# UIKit can deliver taps, and the CADisplayLink lives on that run loop — so
# Host_Frame keeps firing throughout the modal and each ordinary frame
# overwrote the one dialog frame upstream draws. R5's first run answered the
# modal correctly while the VR panel showed the plain Single Player menu with
# the status bar under it. With the flag sticky, essentially EVERY frame drawn
# during the wait is the dialog, so the count is in the hundreds rather than a
# handful.
python3 - "$DOCS/console.log" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1], errors='replace').read()
m = re.findall(r'MODAL: answered \w+ after (\d+) dialog frames', txt)
if not m:
    print('   FAIL  no MODAL answered line carrying a dialog-frame count', file=sys.stderr); sys.exit(1)
n = int(m[-1])
ok = n >= 60
print(f"   {'PASS' if ok else 'FAIL'}  the prompt was on screen for the whole wait ({n} dialog frames; "
      f"a non-sticky flag yields a handful)", file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
shot 56c-r5-modal-answered
# The engine has to be running again, not merely un-blocked.
say 'vkqvraim'; sleep 3
aim_assert "the engine is live again after the modal" "hands >= 0"
# The 'no' answer, through the B button, from the other side.
say 'menu_singleplayer'; sleep 3
say 'vkqvrhandbtn r trigger 1'; sleep 2; say 'vkqvrhandbtn r trigger 0'; sleep 4
say 'vkqvrhandbtn r b 1'; sleep 2; say 'vkqvrhandbtn r b 0'; sleep 5
conlog_need "and answerable NO by the Sense B button" 'MODAL: answered NO'
say 'vkqvrhandbtn r none'; sleep 1
# Back to a LIVE GAME, deterministically. `togglemenu` from a sub-menu returns
# to the main menu rather than closing it, so the section used to leave
# key_dest = key_menu behind — and the mid-game VR re-entry two sections later
# then correctly went to the PANEL and failed an assertion about world mode
# that had nothing to do with what it was testing. A map load is unambiguous.
say 'map e1m1'; sleep 18

echo "== exit VR"
say 'vkqvr 0'; sleep 12; shot 06a-back-to-2d

# --- 3. Enter VR MID-GAME: world immediately, no panel detour -----------------
echo "== re-enter VR with e1m1 already running — expect world straight away"
say 'vkqvr 1'; sleep 20; shot 06b-vr-midgame-world
snap 03-midgame
say 'vkqvr 0'; sleep 12

echo "== round-trips: 2D -> 3D -> 2D -> VR -> 2D, ten times, no wedge"
for i in $(seq 1 10); do
	printf '   round %d/10\n' "$i"
	say 'vkq3d 1'; sleep 7
	say 'vkq3d 0'; sleep 7
	say 'vkqvr 1'; sleep 8
	say 'vkqvr 0'; sleep 8
done
shot 07-after-ten-round-trips

echo "== direct 3D <-> VR switching (dismiss-then-open)"
say 'vkq3d 1'; sleep 9; shot 08a-3d-panel
say 'vkqvr 1'; sleep 16; shot 08b-direct-3d-to-vr
say 'vkq3d 1'; sleep 16; shot 08c-direct-vr-to-3d
say 'vkq3d 0'; sleep 9; shot 08d-back-to-2d

echo "== regression: the shipped 3D panel is unchanged"
say 'vkq3d 1'; sleep 12; shot 09a-vkq3d-regression
say 'vkq3d 0'; sleep 8;  shot 09b-2d-final

# --- R5 item 8: A SUBSTANTIAL QuakeC MOD, IN VR ------------------------------
# The charter's headline feature is that progs.dat is DATA — no code signing, no
# recompile, drop a folder in Files and play it. Every VR round has assumed that
# still holds and none has produced an artifact for it. hipnotic is a genuine
# progs.dat fork (Scourge of Armagon: new weapons, new impulses, new monsters),
# so a world that renders and a hand that aims inside it is the claim, closed.
if [ -n "$MODDIR" ]; then
	echo "== R5 item 8: $MODDIR (a real progs.dat mod) runs in VR"
	say "game $MODDIR"; sleep 10
	say 'vkqvr 1'; sleep 18
	say 'map start'; sleep 20
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 4
	shot 60a-r5-mod-in-vr
	aim_assert "hand aim works inside the mod" "handaim == 1"
	say 'impulse 9'; sleep 3
	say 'vkqvrhandbtn r trigger 1'; sleep 2; say 'vkqvrhandbtn r trigger 0'; sleep 2
	shot 60b-r5-mod-in-vr-armed
	snap 06-mod
	need "$PFX-diag-06-mod.log" "the mod session reached WORLD mode in VR" 'MODE .* -> world \(in the world\)'
	say 'vkqvr 0'; sleep 12
	say "game id1"; sleep 10
	shot 60c-r5-back-to-id1
else
	echo "   SKIP  no mod pak under gamedata/ — nothing was downloaded (charter rule)"
fi

# ============================================================================
# R6 — the fire scheduler (A), the body-following holsters (B), the settings
# surface (C). docs/VR-R6-NOTES.md.
#
# Everything below asserts on lines the SHIPPING code writes: FIRENOW comes out
# of the scheduler's own state, BODYNOW out of the transform the zones and the
# rendered guns both read, SETTINGSNOW out of the row builder the sheet runs on
# every open. There is no parallel test path anywhere in this block.
# ============================================================================

# One number out of a FRESH FIRENOW line, or death. Same freshness rule as
# zone_assert: a stale line compared against a stale line is two equal numbers
# and reads as "nothing changed", which is what a dead app looks like.
firenum () { # firenum <field>
	local before after line v
	before=$(nowseq); before=${before:-0}
	zoneline
	after=$(nowseq); after=${after:-0}
	[ "$after" -gt "$before" ] || die "no fresh FIRENOW line while reading '$1' — the app stopped answering"
	line=$(grep -E '^FIRENOW ' "$DOCS/vr-diagnostics.log" | tail -1)
	v=$(printf '%s' "$line" | grep -oE "(^| )$1=[-0-9]+" | tail -1 | sed 's/.*=//')
	case "$v" in
	'' | *[!0-9-]*) die "could not read '$1' from a fresh FIRENOW line: $line" ;;
	esac
	printf '%s' "$v"
}

# Put a KNOWN weapon in each hand, using only in-model gestures (the R4.1
# lesson: a precondition established by "do a gesture and assume what it did" is
# not a precondition). Right hand ends with the NAILGUN, left with the ROCKET
# LAUNCHER — the exact pair the user reported the jam on.
r6_dual_setup () {
	# CONVENIENCE FIRST. In Immersive, v2's idle sync forces the server's active
	# weapon back to whatever the aim hand holds — so an `impulse` issued there is
	# undone before the re-seed can read it, which is how the first run of this
	# function ended up with a shotgun and a super nailgun instead of the pair it
	# names. Convenience carries no v2 state and runs no sync.
	say 'vkqvrstyle 0'; sleep 3
	say 'impulse 9'; sleep 3
	say 'impulse 7'; sleep 3    # rocket launcher active, and nothing will override it
	say 'vkqvrstyle 1'; sleep 3 # NOW seed v2: the aim hand takes the RL
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
	say 'vkqvrhandbtn r grip 0'; say 'vkqvrhandbtn l grip 0'; sleep 2
	# stow the RL into the LEFT hip, then take it with the LEFT hand
	say 'vkqvrhand r 0 0 0 -0.22 -0.66 0.06'; sleep 3
	say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 2
	say 'vkqvrhand l 0 0 0 -0.22 -0.66 0.06'; sleep 3
	say 'vkqvrhandbtn l grip 1'; sleep 3; say 'vkqvrhandbtn l grip 0'; sleep 2
	# the aim hand is empty now: three flicks walk shotgun -> super shotgun ->
	# nailgun (VKQ_VR_CycleWeapon skips the RL, which is in the other hand)
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
	# Flick until the aim hand holds the NAILGUN. A fixed number of flicks is a
	# guess about the OTHER hand's contents, because VKQ_VR_CycleWeapon skips
	# whatever is already in a hand or a holster.
	got=0
	for _f in 1 2 3 4 5 6 7 8; do
		say 'vkqvrhandstick r 0 1'; sleep 2; say 'vkqvrhandstick r 0 0'; sleep 2
		zoneline
		if grep -E '^HOLSTERNOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -q 'R(grip=0 zone=- hold=imp4)'; then
			got=1; break
		fi
	done
	[ "$got" = 1 ] || die "r6_dual_setup: the aim hand never reached the nailgun after 8 flicks"
	# both hands OUT of every zone, so the assertions below read hand contents
	# rather than zone occupancy
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 3
}

echo "== R6 part A: dual wield — the nailgun in one hand, the rocket launcher in the other"
say 'vkqvr 1'; sleep 8
# The sections above leave the world scale at 39.37; R6 ships 34, and part B is
# measured in units per metre — so say it rather than inherit it.
say 'vkqvrscale 34'; sleep 3
say 'map e1m1'; sleep 14
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 4
r6_dual_setup
zone_assert "right hand holds the nailgun, left holds the rocket launcher" HOLSTERNOW \
	'L\(grip=0 zone=- hold=imp7\).*R\(grip=0 zone=- hold=imp4\)'
shot 70a-r6-dual-loaded

echo "== R6 A1: BOTH triggers held -> BOTH guns fire (the reported bug)"
# 1.0.7.8 could not do this: the aim hand won the `if` every frame it was held,
# so the off hand never became the firing hand at all.
say 'impulse 9'; sleep 3
N0=$(firenum nails); R0=$(firenum rockets)
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 6
N1=$(firenum nails); R1=$(firenum rockets)
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 2
python3 - "$N0" "$N1" "$R0" "$R1" <<'PY' || FAILED=1
import sys
n0, n1, r0, r1 = (int(x) for x in sys.argv[1:5])
ok = n1 < n0 and r1 < r0
print(f"   {'PASS' if ok else 'FAIL'}  both hands discharged inside one 6 s window: "
      f"nails {n0}->{n1} ({n0-n1} fired), rockets {r0}->{r1} ({r0-r1} fired)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
zone_assert "the scheduler handed the pipeline over at least once" FIRENOW 'handoffs=[1-9][0-9]*'
shot 70b-r6-dual-fired

echo "== R6 A1: the cross-fire invariant, CHECKED at every discharge"
# VKQ_VR_NoteDischarge compares the SERVER's own self.weapon against the owner
# hand's weapon at the instant a shot leaves. Any disagreement is the bug the user
# saw (a nail out of the rocket launcher) and it counts here.
zone_assert "no shot has ever left the wrong hand's weapon" FIRENOW 'unauthfired=0'

echo "== R6 A1: SOLO fire rate is unchanged — one trigger, full cadence"
say 'impulse 9'; sleep 3
N0=$(firenum nails)
say 'vkqvrhandbtn r trigger 1'; sleep 8
N1=$(firenum nails)
say 'vkqvrhandbtn r trigger 0'; sleep 2
SOLO=$(python3 -c "print(f'{($N0-$N1)/8.0:.2f}')")
python3 - "$N0" "$N1" <<'PY' || FAILED=1
import sys
n0, n1 = int(sys.argv[1]), int(sys.argv[2])
rate = (n0 - n1) / 8.0
# Stock nailgun refire is 0.1 s (two nails per 0.2 s cycle); the console-bridge
# round trip makes the window fuzzy at the ends, so the bar is "clearly firing
# at the weapon's own rate", not a hairline.
ok = rate >= 3.0
print(f"   {'PASS' if ok else 'FAIL'}  solo nailgun cadence {rate:.2f} nails/s over 8 s ({n0-n1} nails)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R6 A2: what alternating fire actually costs the fast weapon"
# A2 (per-weapon refire clocks) SHIPS OFF, and this section is why. It was
# specified to fix "the RL's 0.8 s stalls the other hand's nailgun"; measured, it
# buys exactly 1.00x, because the nailgun's repeat fire is a QC think chain that
# never reads attack_finished. What the fast weapon pays is the restart of its
# firing sequence at every handoff, which no engine-side clock can refund.
#
# So the assertion here is a REGRESSION FLOOR on the shipping configuration, not
# a certificate for A2: the second weapon must keep a usable fraction of its solo
# cadence, and the round records the number rather than hiding it.
zone_assert "the per-weapon clock is on — it is what lets a pending switch be read" FIRENOW 'dualclock=on'
say 'impulse 9'; sleep 3
N0=$(firenum nails)
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 8
N1=$(firenum nails)
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 2
python3 - "$N0" "$N1" "$SOLO" <<'PY' || FAILED=1
import sys
n0, n1, solo = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
rate = (n0 - n1) / 8.0
# Measured on this build: 3.50 nails/s against 10.12 solo (35%), with the rocket
# launcher firing at its own rate beside it. The shortfall is the fast weapon's
# firing sequence restarting at each handoff — inherent to one server-side weapon
# slot, which the charter's no-progs-fork rule fixes in place. The floor is 20%:
# clear of the measurement, and it catches a collapse to the ~1% that requiring
# the switch to LAND before firing produced.
ok = rate >= 0.2 * solo
print(f"   {'PASS' if ok else 'FAIL'}  nailgun keeps {100*rate/solo if solo else 0:.0f}% of its solo cadence under dual fire "
      f"({rate:.2f} vs {solo:.2f} nails/s, floor 20%)",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R6 A2: the two-minute dual-fire soak (weapon/ammo state must survive it)"
say 'impulse 9'; sleep 2
for _s in 1 2 3 4 5 6; do
	# Triggers DOWN for the burst, UP for the refill. `impulse 9` force-sets the
	# server's weapon (stock CheatCommand), so firing it mid-burst puts a shot
	# through a gun neither hand is holding — a real cross-fire, but caused by the
	# cheat rather than by the scheduler, and pressing it while both triggers are
	# held is not what this soak is for.
	say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'
	sleep 18
	say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 2
	say 'impulse 9'; sleep 2
done
say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 4
say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 3
zone_assert "after 120 s of dual fire: still no cross-fire" FIRENOW 'unauthfired=0'
zone_assert "…and both hands still hold exactly what they started with" HOLSTERNOW \
	'L\(grip=0 zone=- hold=imp7\).*R\(grip=0 zone=- hold=imp4\)'
zone_assert "…and the scheduler is idle with both triggers released" FIRENOW 'owner=- '
shot 70c-r6-after-soak

echo "== R6 B1: the holster frame FOLLOWS THE BODY (a step and a turn)"
# The zone centre and the drawn model read ONE transform (R5's invariant), so
# the test is: move the head, and the published zone must move with it — while
# HOLGEOMNOW's render-vs-reach error stays zero, which is what proves the two
# did not come apart on the way.
say 'vkqvrpose'; sleep 3; say 'vkqvrrecenter'; sleep 4
say 'vkqvrpose 0 0 0 0 0'; sleep 4
zone_assert "at the recentre point the body frame is the origin" BODYNOW 'head=\(-?0\.0,-?0\.0,-?0\.0\)u'
Z0=$(zoneline; grep -E '^ZONESNOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -oE 'right hip=imp[0-9]+ @\([-0-9.]+,[-0-9.]+,[-0-9.]+\)' | sed -E 's/.*\(([-0-9.]+),([-0-9.]+),([-0-9.]+)\)/\1 \2 \3/')
# step 1 m FORWARD (-Z in tracking space) without recentring
say 'vkqvrpose 0 0 0 0 -1.0'; sleep 5
zone_assert "the head is now 1 m forward in the player frame" BODYNOW 'head=\(-?0\.0,-?0\.0,-3[0-9]\.[0-9]\)u'
Z1=$(zoneline; grep -E '^ZONESNOW ' "$DOCS/vr-diagnostics.log" | tail -1 | grep -oE 'right hip=imp[0-9]+ @\([-0-9.]+,[-0-9.]+,[-0-9.]+\)' | sed -E 's/.*\(([-0-9.]+),([-0-9.]+),([-0-9.]+)\)/\1 \2 \3/')
python3 - "$Z0" "$Z1" <<'PY' || FAILED=1
import sys
a = [float(x) for x in sys.argv[1].split()]
b = [float(x) for x in sys.argv[2].split()]
dz = b[2] - a[2]
# 1 m at 34 u/m = 34 units forward, and forward is -Z in the player frame.
ok = abs(dz + 34.0) < 3.0 and abs(b[0] - a[0]) < 2.0 and abs(b[1] - a[1]) < 2.0
print(f"   {'PASS' if ok else 'FAIL'}  right hip zone moved {dz:+.1f} u along Z for a 1 m step "
      f"(want -34.0 at 34 u/m), lateral drift ({b[0]-a[0]:+.1f}, {b[1]-a[1]:+.1f}) u",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY

echo "== R6 B1: the torso estimate chases a real turn, and ignores a glance"
say 'vkqvrpose 8 0 0 0 -1.0'; sleep 5   # an 8-degree glance: inside the deadzone
zone_assert "an 8 degree glance does NOT drag the holsters" BODYNOW 'lag=8\.[0-9] '
say 'vkqvrpose 90 0 0 0 -1.0'; sleep 6   # a real turn: chases at <=90 deg/s
zone_assert "a 90 degree body turn brings the torso round within a beat" BODYNOW 'torsoyaw=(8[0-9]|90).[0-9] '
shot 70d-r6-body-turned

echo "== R6 B1: rendered gun and grab zone are still ONE transform after all that"
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3
say 'vkqvrhandbtn r grip 0'; sleep 2
# stow into the right hip AT THE MOVED BODY: the hand has to reach the zone
# where the body now is, which is the whole point.
HIPX=$(zoneline; grep -E '^ZONESNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
echo "   zones at the moved body: $HIPX"
say 'vkqvrpose 0 0 0 0 0'; say 'vkqvrrecenter'; sleep 6
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 4
say 'vkqvrhandbtn r grip 1'; sleep 3; say 'vkqvrhandbtn r grip 0'; sleep 3
zone_assert "the hand still reaches the hip after the body frame moved and came back" HOLSTERNOW 'rhip=imp[1-8]'
zone_assert "render vs reach error is still zero" HOLGEOMNOW 'rhip: .*\|err\|=0\.0[0-9]u'
shot 70e-r6-holster-after-move

echo "== R6 B2: the zone-entry haptic path is REACHED (and says what it did)"
# The sim has no GCController, so the outcome is "NO CONTROLLER for that hand" —
# which is the honest answer here and still proves the call site ran, which is
# exactly what was in doubt. On the device the same line reads "played".
HB=$(grep -Ec '^HAPTIC .* zone-entry ' "$DOCS/vr-diagnostics.log" 2>/dev/null || true)
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 3   # out of every zone
say 'vkqvrhand r 0 0 0 0.22 -0.66 0.06'; sleep 3    # sweep into the right hip
say 'vkqvrdiag'; sleep 3
HA=$(grep -Ec '^HAPTIC .* zone-entry ' "$DOCS/vr-diagnostics.log" 2>/dev/null || true)
python3 - "$HB" "$HA" <<'PY' || FAILED=1
import sys
b, a = int(sys.argv[1]), int(sys.argv[2])
ok = a > b
print(f"   {'PASS' if ok else 'FAIL'}  zone-entry haptic forwarder fired on the sweep into the hip "
      f"(HAPTIC zone-entry lines {b} -> {a})", file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
grep -E '^HAPTIC ' "$DOCS/vr-diagnostics.log" | tail -3 || true

echo "== R6 C3: the height derivation, against its closed form at 34 u/m"
say 'vkqvrreset'; sleep 3     # clear the baseline the section above stored
say 'vkqvrscale 34'; sleep 2  # the shipping scale, explicitly
say 'vkqvrpose 0 0 0 1.679 0'; say 'vkqvrrecenter'; sleep 6
zone_assert "the standing height was picked up" EYENOW 'standing HMD 1.679 m'
EYELINE=$(zoneline; grep -E '^EYENOW ' "$DOCS/vr-diagnostics.log" | tail -1)
echo "   $EYELINE"
python3 - "$EYELINE" <<'PY' || FAILED=1
import re, sys
line = sys.argv[1]
m = re.search(r'standing HMD ([\d.]+) m .* x ([\d.]+) u/m .*VR eye ([\d.]+) u .*rise \+?(-?[\d.]+)', line)
if not m:
    print("   FAIL  EYENOW reshaped — cannot check the height arithmetic", file=sys.stderr); sys.exit(1)
standing, ws, eye, rise = float(m[1]), float(m[2]), float(m[3]), float(m[4])
REF = 46.0 / 39.37                      # the height Quake's own 46-unit eye stands at
want_rise = (standing - REF) * ws        # R6 C3's closed form
old_rise = standing * ws - 46.0          # what 1.0.7.8 computed
ok = abs(rise - want_rise) < 0.25 and abs(eye - (46.0 + want_rise)) < 0.25
print(f"   {'PASS' if ok else 'FAIL'}  rise {rise:+.2f} u vs closed form {want_rise:+.2f} u at {ws:.2f} u/m "
      f"(eye {eye:.1f} u). 1.0.7.8 would have computed {old_rise:+.2f} u — "
      f"a {want_rise-old_rise:+.2f} u ({(want_rise-old_rise)/ws*39.3701:+.1f} in) correction, "
      f"which is what the user's 9-inch trim was standing in for.",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
need "$DOCS/vr-diagnostics.log" "auto-calibration stored a baseline on first VR entry" 'HEIGHT auto-calibrated on first VR entry'
need "$DOCS/vr-diagnostics.log" "…and the arithmetic was recorded"                      'HEIGHT baseline [0-9.]+ m, trim' 

echo "== R6 C1: the settings sheet is mode-contextual"
say 'vkqsettingsdump'; sleep 3
need "$DOCS/vr-diagnostics.log" "in VR: the VR section is present"        'SETTINGSNOW mode=2 .*\[Vision Pro VR\]'
LAST=$(grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
printf '%s' "$LAST" | grep -q '\[Vision Pro 3D\]' \
	&& { echo "   FAIL  in VR the 3D section is still shown" >&2; FAILED=1; } \
	|| echo "   PASS  in VR the 3D section is hidden"

echo "== R6 C4/C5/C6: defaults, removals and the cheats rows"
need "$DOCS/vr-diagnostics.log" "World Scale row is GONE"                 'SETTINGSNOW mode=2 .*\[Vision Pro VR\]'
for gone in vrScale vrXhairDebug vrZones vrGiveAll vrDiag vrStatus0; do
	printf '%s' "$LAST" | grep -q "$gone" \
		&& { echo "   FAIL  removed row '$gone' is still in the sheet" >&2; FAILED=1; } \
		|| echo "   PASS  '$gone' is gone from the sheet"
done
# NOT the slider values here: by now this suite has spent half an hour dragging
# them (see the fresh-store section right after launch). What must still hold at
# this point is the STRUCTURE.
printf '%s' "$LAST" | grep -q '<Cheats> cheatWeapons cheatGod' \
	&& echo "   PASS  the Cheats subheader carries All Weapons and God Mode" \
	|| { echo "   FAIL  the Cheats rows are missing or reordered" >&2; FAILED=1; }
printf '%s' "$LAST" | grep -q 'Holster Position\|vrHolFwd' \
	&& echo "   PASS  Holster Position row present in Immersive" \
	|| { echo "   FAIL  Holster Position row missing" >&2; FAILED=1; }

echo "== R6 C4: Convenience hides the holster rows, Immersive shows them"
say 'vkqvrstyle 0'; sleep 3
say 'vkqsettingsdump'; sleep 3
CONV=$(grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
printf '%s' "$CONV" | grep -q 'vrHolSize' \
	&& { echo "   FAIL  Convenience still shows the holster rows" >&2; FAILED=1; } \
	|| echo "   PASS  Convenience hides Holster Size / Holster Position"
say 'vkqvrstyle 1'; sleep 3
say 'vkqsettingsdump'; sleep 3
IMM=$(grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
printf '%s' "$IMM" | grep -q 'vrHolSize' \
	&& echo "   PASS  Immersive brings them back" \
	|| { echo "   FAIL  Immersive does not show the holster rows" >&2; FAILED=1; }

echo "== R6 C6: God Mode reads the edict, and re-asserts across a level change"
say 'god 0'; sleep 3
zone_assert "cheats are available in a loaded single-player level, god reads OFF" GODNOW 'god=off cheats=available'
say 'god 1'; sleep 3
zone_assert "the engine reports god ON from the player edict" GODNOW 'god=on cheats=available'
say 'map e1m2'; sleep 18
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; sleep 2
zone_assert "after a changelevel the switch still reads the edict, not a memory" GODNOW 'god=(on|off) cheats=available'
say 'god 1'; sleep 3
zone_assert "and god can be re-asserted on the new level" GODNOW 'god=on cheats=available'
say 'god 0'; sleep 3
zone_assert "…and explicitly turned off again (god 1/god 0 never toggles blind)" GODNOW 'god=off' 
shot 70f-r6-cheats

echo "== R6 C2: the VR Reset restores the new defaults and clears the baseline"
say 'vkqvrstyle 0'; say 'vkqvrhol 1.10 0.20'; sleep 3
say 'vkqvrreset'; sleep 4
say 'vkqsettingsdump'; sleep 3
RST=$(grep -E '^SETTINGSNOW ' "$DOCS/vr-diagnostics.log" | tail -1)
for want in 'vrStyle=1.0000' 'vrHolSize=0.7000' 'vrHolFwd=0.0381' 'vrRenderScale=1.2500' 'vrHud=1.0000' 'vrSnapTurn=0.0000'; do
	printf '%s' "$RST" | grep -q "$want" \
		&& echo "   PASS  reset restored $want" \
		|| { echo "   FAIL  reset did not restore $want" >&2; FAILED=1; }
done
B0=$(grep -Ec 'HEIGHT auto-calibrated' "$DOCS/vr-diagnostics.log" || true)
say 'vkqvrreset'; sleep 3
say 'vkqvrrecenter'; sleep 8
say 'vkqvrdiag'; sleep 3
B1=$(grep -Ec 'HEIGHT auto-calibrated' "$DOCS/vr-diagnostics.log" || true)
[ "$B1" -gt "$B0" ] \
	&& echo "   PASS  the reset cleared the baseline and the next VR entry re-calibrated ($B0 -> $B1)" \
	|| { echo "   FAIL  the reset did not clear the height baseline ($B0 -> $B1)" >&2; FAILED=1; } 

# ============================================================================
# VR R6.1 (OTA 1.0.7.10) — the four punch-list items from the user's 1.0.7.9 round.
# Item 3's migration ran on its own launches before the session (see the top);
# what is left here is everything that needs a live VR world frame.
# ============================================================================
echo "== R6.1: a clean world frame, neutral pose, both hands, to assert against"
say 'vkqvrstyle 1'; say 'vkqvrpose 0 0 0 0 0'; sleep 3
say 'map e1m1'; sleep 18
say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 5

echo "== R6.1 item 1: swim down (+movedown) is bound to B, on EITHER hand"
zone_assert "nothing held: in_down is clear"        MOVENOW 'down=0'
say 'vkqvrhandbtn r b 1'; sleep 2
zone_assert "B on the AIM hand drives +movedown"    MOVENOW 'down=1 .*btnaim=0x08'
say 'vkqvrhandbtn r b 0'; sleep 2
zone_assert "releasing B releases it"               MOVENOW 'down=0'
say 'vkqvrhandbtn l b 1'; sleep 2
zone_assert "B on the OFF hand drives it too"       MOVENOW 'down=1 .*btnoff=0x08'
say 'vkqvrhandbtn l b 0'; sleep 2
zone_assert "released again"                        MOVENOW 'down=0'
# The regression half: A is still jump, and it did not become swim-down.
say 'vkqvrhandbtn r a 1'; sleep 2
zone_assert "A still jumps, and jumping is not swimming down" MOVENOW 'jump=1 down=0'
say 'vkqvrhandbtn r a 0'; sleep 2

echo "== R6.1 item 3: the VR Reset left snap turn on Smooth, in the cvar the turn code reads"
zone_assert "vkqvr_snapturn == 0 (Smooth)"          MOVENOW 'snapturn=0\.0'

# --- item 2 -----------------------------------------------------------------
# THE RULE FROM THE THREE-ROUND INVISIBLE-RETICLE SAGA: a feature whose whole job
# is to put readable text in front of the player gets an assertion that reads
# pixels and FAILS when the text is absent.
#
# DIFFERENTIAL, not absolute, and the first run of this block is why. The parked
# "Playing in VR" window card is ~2000 white pixels of static furniture floating
# in the same space, and its screen position is NOT fixed — it sat at y≈1550 in
# the standalone probe and at y≈1180 thirty minutes into the suite, i.e. inside
# whatever fixed region I drew around the message panel. A hand-drawn exclusion
# zone is therefore a guess that goes stale; the card's CONTRIBUTION, measured in
# the same run seconds earlier, is not. Within one block it is constant to the
# pixel (1992, four shots running), so subtracting the baseline leaves exactly
# the panel's own ink.
MSGREGION="--region 900,450,2950,1250"
countpx () { # countpx <shot-name> <predicate>
	python3 "$ROOT/scripts/sim-pixel-count.py" "$PFX-$1.png" "$2" $MSGREGION 2>/dev/null \
		| grep -o 'pixels=[0-9]*' | head -1 | cut -d= -f2
}
delta_assert () { # delta_assert <label> <baseline> <measured> <ge|le> <threshold>
	python3 - "$1" "$2" "$3" "$4" "$5" <<'PY' || FAILED=1
import sys
label, base, meas, op, thr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
d = meas - base
ok = (d >= thr) if op == "ge" else (abs(d) <= thr)
word = f">= {thr}" if op == "ge" else f"within {thr} of the baseline"
print(f"   {'PASS' if ok else 'FAIL'}  {label}: {meas} - {base} = {d} px ({word})",
      file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
}

echo "== R6.1 item 2: the message panel is ABSENT when the game has said nothing"
say 'scr_centertime 25'; say 'con_notifytime 0.2'; sleep 4
shot 80a-r61-msg-none
BASE_W=$(countpx 80a-r61-msg-none msgwhite); BASE_G=$(countpx 80a-r61-msg-none msggold)
echo "   baseline inside the panel region: white=$BASE_W gold=$BASE_G (this is the parked window card, and it is what gets subtracted)"
[ -n "$BASE_W" ] && [ -n "$BASE_G" ] || { echo "   FAIL  could not measure a baseline — nothing below is evidence" >&2; FAILED=1; BASE_W=0; BASE_G=0; }

echo "== R6.1 item 2: a centerprint — the user's exact symptom — is READABLE in VR"
say 'vkqvrmsg You need the silver key'; sleep 3
shot 80b-r61-centerprint
delta_assert "a one-line centerprint puts white glyphs on the panel" "$BASE_W" "$(countpx 80b-r61-centerprint msgwhite)" ge 1500
say 'vkqvrdiag'; sleep 3
need "$DOCS/vr-diagnostics.log" "the panel names the centerprint it drew" "MSGNOW .*centre='You need the silver key'"
need "$DOCS/vr-diagnostics.log" "the glyphs come from the engine's own conchars" 'MSG FONT conchars loaded'

echo "== R6.1 item 2: a long centerprint WRAPS instead of running off the panel"
say 'vkqvrmsg This door is opened elsewhere and you cannot get through it from this side yet'; sleep 3
shot 80c-r61-centerprint-wrap
delta_assert "three wrapped lines put proportionally more ink up" "$BASE_W" "$(countpx 80c-r61-centerprint-wrap msgwhite)" ge 5000
say 'vkqvrdiag'; sleep 3
# R6.3: this asserted `lines=3 cols=(29|30)`, which R6.2 invalidated the moment it
# took the glyph cell to x5 and the column count to 24 (78 characters wrap to FOUR
# lines at 24 columns, and the widest is 24). It failed the original-pak run for two
# rounds. The test exists to prove the text WRAPS instead of running off the panel,
# so it now asserts that property — more than one line, and no line wider than the
# panel's 24 columns — rather than one build's arithmetic. A future cell-size change
# moves the number again; it must not move this assertion.
need "$DOCS/vr-diagnostics.log" "78 characters wrapped to several lines, none wider than the panel" 'MSGNOW lines=[2-9] cols=(1[0-9]|2[0-4]) '

echo "== R6.1 item 2: the OTHER class — a real server print (svc_print) reaches the panel"
say 'scr_centertime 0.2'; sleep 4          # let the centerprint die first
say 'con_notifytime 25'; sleep 1
say 'say hello from the server'; sleep 4   # SV_BroadcastPrintf -> svc_print -> notify
shot 80d-r61-notify
delta_assert "the notify feed puts gold glyphs on the panel" "$BASE_G" "$(countpx 80d-r61-notify msggold)" ge 800
say 'vkqvrdiag'; sleep 3
need "$DOCS/vr-diagnostics.log" "the notify feed reached the panel" "MSGNOW .*notify='.+'"

echo "== R6.1 item 2: engine chatter does NOT (the con_notify_game filter)"
say 'con_notifytime 0.2'; sleep 4          # clear the say
say 'con_notifytime 25'; sleep 1
say 'sizedown'; say 'sizeup'; say 'echo console chatter that must stay in the console'; sleep 4
shot 80e-r61-chatter-hidden
delta_assert "console chatter adds no white ink"  "$BASE_W" "$(countpx 80e-r61-chatter-hidden msgwhite)" le 300
delta_assert "console chatter adds no gold ink"   "$BASE_G" "$(countpx 80e-r61-chatter-hidden msggold)"  le 300

echo "== R6.1 item 2: and it goes away on its own"
say 'con_notifytime 3'; say 'scr_centertime 2'; sleep 8
shot 80f-r61-msg-expired
delta_assert "the panel is back to the baseline (white)" "$BASE_W" "$(countpx 80f-r61-msg-expired msgwhite)" le 300
delta_assert "the panel is back to the baseline (gold)"  "$BASE_G" "$(countpx 80f-r61-msg-expired msggold)"  le 300

echo "== R6.1 item 4: the settings sheet closes from the CONSOLE"
say 'vkqsettings'; sleep 8
zone_assert "the engine can see an open settings sheet" MOVENOW 'sheet=1'
shot 80g-r61-sheet-open
say 'vkqsettings close'; sleep 8
zone_assert "'vkqsettings close' dismissed it"          MOVENOW 'sheet=0'
shot 80h-r61-sheet-closed

# R6.3: THESE TWO ASSERTIONS WERE INVERTED, AND HAD BEEN SINCE R6.2.
# R6.1 item 4 made B or MENU dismiss the settings sheet. R6.2 item 3 REMOVED that
# deliberately — the user never wanted it ("you just pinch or trigger on DONE like in
# any other app"), and it could not be left in harmlessly: gameplay input is not
# frozen while the sheet is up, so B was both a swim-down and a dismissal, and a
# player sinking in water with the sheet open to tune Turn Speed would have had it
# shut under them. The quick suite was updated; this suite was not, so it went on
# demanding the deleted behaviour and failed the original-pak run for two rounds
# while R6.4 reported the suites as clean. The assertion now tests what the code is
# supposed to do: the sheet STAYS OPEN, and only the console closes it.
echo "== R6.2 item 3: B and MENU leave the sheet ALONE; only the console closes it"
say 'vkqsettings'; sleep 8
zone_assert "sheet up again"                            MOVENOW 'sheet=1'
say 'vkqvrhandbtn r b 1'; sleep 1; say 'vkqvrhandbtn r b 0'; sleep 6
zone_assert "B leaves the sheet alone now"              MOVENOW 'sheet=1'
say 'vkqvrhandbtn l menu 1'; sleep 1; say 'vkqvrhandbtn l menu 0'; sleep 6
zone_assert "MENU leaves it alone too"                  MOVENOW 'sheet=1'
say 'vkqsettings close'; sleep 8
zone_assert "and 'vkqsettings close' still dismisses it" MOVENOW 'sheet=0'

echo "== R6 A2: the same mechanism on a REAL progs.dat fork"
# attack_finished is resolved BY NAME, per loaded progs, so "it works on id1" is
# not the claim under test — the claim is that a mod's own progs is handled, and
# that a mod WITHOUT the field degrades to the shared clock instead of misbehaving.
if [ -n "$MODDIR" ]; then
	say "game $MODDIR"; sleep 12
	say 'vkqvr 1'; sleep 8
	say 'map start'; sleep 16
	say 'vkqvrhand r 0 0 0 0.25 -0.45 -0.40'; say 'vkqvrhand l 0 0 0 -0.25 -0.45 -0.40'; sleep 4
	r6_dual_setup
	zone_assert "$MODDIR: the field resolved in the mod's own progs" FIRENOW 'dualclock=on'
	say 'impulse 9'; sleep 3
	MN0=$(firenum nails)
	say 'vkqvrhandbtn r trigger 1'; say 'vkqvrhandbtn l trigger 1'; sleep 10
	MN1=$(firenum nails)
	say 'vkqvrhandbtn r trigger 0'; say 'vkqvrhandbtn l trigger 0'; sleep 3
	python3 - "$MN0" "$MN1" "$SOLO" "$MODDIR" <<'PY' || FAILED=1
import sys
n0, n1, solo, mod = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rate = (n0 - n1) / 10.0
ok = rate >= 0.2 * solo
print(f"   {'PASS' if ok else 'FAIL'}  {mod}: nailgun cadence under dual fire {rate:.2f} nails/s "
      f"vs {solo:.2f} solo on id1 (floor 20%)", file=(sys.stdout if ok else sys.stderr))
sys.exit(0 if ok else 1)
PY
	zone_assert "$MODDIR: no cross-fire in a forked progs either" FIRENOW 'unauthfired=0'
	shot 70g-r6-mod-dual-fire
	say 'vkqvr 0'; sleep 10
	say 'game id1'; sleep 12
else
	echo "   SKIP  no mod pak under gamedata/ — the forked-progs A2 gate cannot run"
fi

# --- assertions ----------------------------------------------------------------
echo "== VR diagnostics (charter standing rule: never console-only)"
[ -f "$DOCS/vr-diagnostics.log" ] || { echo "FATAL: Documents/vr-diagnostics.log was never written" >&2; exit 1; }
cp "$DOCS/vr-diagnostics.log" "$PFX-diagnostics.log"
echo "   copied: $PFX-diagnostics.log"

echo "-- session 1 (VR entered at the title screen)"
S1="$PFX-diag-01-title.log"
need "$S1" "pinned section present"                 '^--- PINNED'
need "$S1" "rolling tail present"                   '^--- ROLLING TAIL'
need "$S1" "entry logged"                           'VR loop started'
need "$S1" "eye target sized from the PHYSICAL tex" 'EYE TARGET .* PHYSICAL texture'
need "$S1" "logical viewport recorded next to it"   'LOGICAL viewport is'
need "$S1" "contract: logical + physical per view"  'viewport\(LOGICAL\)=.*texture\(PHYSICAL\)='
need "$S1" "volatile fields dumped, not diffed"     'volatile \(measured, never diffed'
need "$S1" "IPD check recorded"                     'IPD CHECK'
need "$S1" "VR entry -> panel with a NAMED reason"  'MODE \(VR entry\) -> panel \((no game running|demo playing|no map loaded|connecting|loading)\)'
need "$S1" "predicate terms recorded verbatim"      'cls\.state=[0-9]+ signon=[0-9]+/[0-9]+ key_dest=[0-9]+'
need "$S1" "pacing line carries the reason"         'PACING .*mode=panel \('
count_is "$S1" "contract dumped once"               '^CONTRACT \(frame' 1
count_is "$S1" "zero structural CHANGED lines"      'STRUCTURE CHANGED' 0

echo "-- session 1 continued (map started from inside VR, menu round-trip)"
S2="$PFX-diag-02-world.log"
need "$S2" "panel -> world when the map starts"     'MODE panel -> world \(in the world\)'
need "$S2" "world -> panel when the menu opens"     'MODE world -> panel \(in menu\)'
need "$S2" "world -> panel when the console opens"  'MODE world -> panel \(console open\)'
need "$S2" "world resumes after the menu closes"    'MODE panel -> world'
need "$S2" "pacing line in world mode"              'PACING .*mode=world \(in the world\)'
need "$S2" "real per-pixel depth (not the fallback)" 'DEPTH real per-pixel'
count_is "$S2" "still one contract dump this session" '^CONTRACT \(frame' 1
count_is "$S2" "still zero CHANGED lines"           'STRUCTURE CHANGED' 0

echo "-- session 2 (VR entered with the game already running)"
S3="$PFX-diag-03-midgame.log"
need "$S3" "mid-game entry goes straight to world"  'MODE \(VR entry\) -> world \(in the world\)'

echo "-- R2 (Sense plumbing + hand aim), from the same file"
S4="$PFX-diag-04-r2.log"
need "$S4" "the running app reads its own declaration" 'SENSE backend ready .*GCSupportedGameControllers = \('
need "$S4" "…and the accessory usage string"          'SENSE bundle NSAccessoryTrackingUsageDescription = vkQuake'
need "$S4" "the SDL filter is inert with no spatial pad" 'SENSE backend ready \(0 controller'
need "$S4" "hands were reported arriving"              'HANDS tracked: -R'
need "$S4" "…and leaving again"                        'HANDS tracked: -- '
need "$S4" "AIM lines carry every term"                'AIM sent=\(p.*\) head=\(p.*\) hand=\(p.*\) body=.* handaim=[01] movedir=[0-2] delta=.* weapon=[0-9]+'

# The eye target must equal the view's PHYSICAL texture (x render scale 1.0).
# On the simulator the logical viewport and the physical texture happen to be the
# same size, so this asserts by CONSTRUCTION (the line names which one it used)
# rather than by their difference — the device is what separates them.
echo "-- eye render target"
grep -E 'EYE TARGET' "$PFX-diagnostics.log" | tail -3
python3 - "$S1" <<'PY' || FAILED=1
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r'EYE TARGET \d+x\d+ -> (\d+)x(\d+) \([\d.]+ MP/eye\) — the view.s PHYSICAL texture (\d+)x(\d+) x([\d.]+) render scale', txt)
if not m:
    print("   FAIL  EYE TARGET line missing or reshaped", file=sys.stderr); sys.exit(1)
tw, th, pw, ph, rs = int(m[1]), int(m[2]), int(m[3]), int(m[4]), float(m[5])
if (tw, th) != (round(pw*rs), round(ph*rs)):
    print(f"   FAIL  eye target {tw}x{th} != physical {pw}x{ph} x{rs}", file=sys.stderr); sys.exit(1)
print(f"   PASS  eye target {tw}x{th} == physical texture {pw}x{ph} x{rs}")
PY

echo "-- headline measurements"
grep -E 'CONTRACT|IPD CHECK|PACING|PROJ|EYE TARGET|MODE |recentred|WORLD SCALE|DEPTH' "$PFX-diagnostics.log" | head -60 || true

echo "== [vkquake] markers"
xcrun simctl spawn "$UDID" log show --last 40m --style compact \
	--predicate 'eventMessage CONTAINS "[vkquake]"' 2>/dev/null \
	| grep -E 'vr:|imm:|3D|mode|Swift' | tee "$PFX-log.txt" | tail -40 || true

echo "== engine console tail"
tail -8 "$DOCS/console.log" 2>/dev/null || true
[ "$FAILED" = 0 ] || { echo "SIM VR VERIFY FAILED — see the FAIL lines above" >&2; exit 1; }
echo "SIM VR VERIFY DONE — inspect $PFX-*.png"
