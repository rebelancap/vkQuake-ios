# STATUS — vkQuake iOS

## Current state
Engine is on upstream vkQuake **1.36.0** (`1b948e29`, 2026-08-27) with a 26-patch
overlay (0015/0016 mg3 workarounds deleted — upstream fixed both; 0016 slimmed to
a placeholder-vintage warning). Branch `upstream-1.36.0` off `release-1.1.1`.
OTA dev build **1.1.1.1** (iOS + visionOS) is live at
https://goomba.tailc8f64e.ts.net/ota/vkquake/ . Last public release: 1.1.1.

## Last round (2026-08-30)
Pin bump 8fed52d0 → 1.36.0 via git 3-way rebase of the overlay; hand-resolved
conflicts itemized in DECISIONS.md ("2026-08-30 — upstream 1.36.0 pin bump").
Oracle: mg3 map1 spawns with no MD5 warning, 1669 loc strings, id1 e1m1 ok.
iOS sim lane 1: screenshots artifacts/sim/2026-08-30-ios-1.36.0-*.png (boot,
e1m1, mg3 map1, menu, mods menu). Config migration verified: old
`<game>/config.cfg` read on first boot, writes go to `vkQuake.cfg` (global +
per-game). Sonnet review: no bugs. visionOS: builds/links only, no runtime round.

## Next steps
1. Austin tests 1.1.1.1 on iPhone (mg3, settings carried over, touch menus with
   the enlarged upstream mods menu) and in the headset (VR viewmodel: gun holds,
   muzzle flash hides — patch 0021 was re-derived for the new skinning path).
2. If good: merge `upstream-1.36.0` → main; Austin picks the release number
   (1.1.2 by the patch-bump rule) and RELEASING.md loop runs.
3. Consider adopting upstream's per-game archived cvars in the iOS settings page.

## Open questions
- Release number/timing for this bump — Austin's call. Default: stay on OTA
  1.1.1.x dev builds until told.

## Live claims
None. Simulators shut down; no agents running; tree clean on `upstream-1.36.0`.
