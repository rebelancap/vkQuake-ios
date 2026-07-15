#!/usr/bin/env bash
# fetch-moltenvk.sh — provision the MoltenVK static xcframework with ALL platform
# slices (incl. xros-arm64 for the visionOS build) into vendor/moltenvk (gitignored).
# Idempotent. The iOS build uses the ios-arm64 slice from build-ios-deps.sh; this
# is only needed for the visionOS target, which links the xros-arm64 slice.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
MVK_VER=1.4.1
DEST="$ROOT/vendor/moltenvk/MoltenVK.xcframework"

if [ -f "$DEST/xros-arm64/libMoltenVK.a" ]; then
	echo "MoltenVK xros slice already present: $DEST"
	exit 0
fi

TMP="$ROOT/build/moltenvk-dl"
rm -rf "$TMP"; mkdir -p "$TMP"
echo "== downloading MoltenVK $MVK_VER (all platforms)"
curl -L --fail -o "$TMP/mvk.tar" \
	"https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VER/MoltenVK-all.tar"
tar xf "$TMP/mvk.tar" -C "$TMP"
XC=$(find "$TMP" -iname MoltenVK.xcframework -path "*static*" | head -1)
[ -d "$XC" ] || { echo "FATAL: static MoltenVK.xcframework not found in archive" >&2; exit 1; }
mkdir -p "$ROOT/vendor/moltenvk"
rm -rf "$DEST"; cp -R "$XC" "$DEST"
rm -rf "$TMP"
[ -f "$DEST/xros-arm64/libMoltenVK.a" ] || { echo "FATAL: xros slice missing after fetch" >&2; exit 1; }
echo "MOLTENVK OK: $DEST (xros-arm64 present)"
