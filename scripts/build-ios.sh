#!/usr/bin/env bash
#
# build-ios.sh — compile the vkQuake engine for iphoneos/arm64 into
# build/ios/libvkquake.a (linked into the Xcode app shell later).
#
# The engine source set is derived from the object files of the PROVEN macOS
# oracle build (build/oracle), so the two cannot silently diverge in coverage.
# The 60 generated shader/pak .c files (SPIR-V byte arrays + embedded pak) are
# platform-independent DATA — reused verbatim from the oracle, no re-run of
# glslang. iOS masquerades as PLATFORM_OSX (arch_def.h), so it reuses the
# unix/OSX code paths. Codecs + curl excluded for the substrate spike.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/build/src-overlay"
ORACLE="$ROOT/build/oracle"
DEPS="$ROOT/build/ios-deps"
OBJ="$ROOT/build/ios/obj"
LIB="$ROOT/build/ios/libvkquake.a"

[ -d "$OVERLAY/Quake" ]       || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh" >&2; exit 1; }
[ -d "$ORACLE/vkquake.p" ]    || { echo "FATAL: oracle build missing — build it first" >&2; exit 1; }
[ -f "$DEPS/sdl-prefix/include/SDL3/SDL.h" ] || { echo "FATAL: SDL3 iOS headers missing" >&2; exit 1; }
[ -f "$DEPS/moltenvk/include/vulkan/vulkan.h" ] || { echo "FATAL: Vulkan headers missing" >&2; exit 1; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
CFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=16.0 -O2 -DNDEBUG -fno-omit-frame-pointer -pipe -Wno-implicit-function-declaration"
# NOTE: no DO_USERDIRS on iOS — it computes a non-sandboxed userdir
# (/var/mobile/Library/...) that the app can't create. Without it userdir==basedir,
# so writes go to com_basedir/id1 = the injected Documents/id1 (container-writable).
DEFS="-DUSE_SDL3 -DVKQ_IOS=1 -DTASK_AFFINITY_NOT_AVAILABLE -D_FILE_OFFSET_BITS=64 -DUSE_CODEC_VORBIS"
INCS="-I$OVERLAY/Quake -I$OVERLAY/Quake/mimalloc -I$DEPS/sdl-prefix/include -I$DEPS/moltenvk/include -I$DEPS/codec-prefix/include"

# codec sources excluded for the spike (no music libs linked)
EXCLUDE="snd_flac snd_mpg123 snd_opus snd_mp3tag snd_mp3"

srcs=()
for o in "$ORACLE"/vkquake.p/Quake_*.c.o; do
  b=$(basename "$o" .c.o); b=${b#Quake_}
  case " $EXCLUDE " in *" $b "*) continue ;; esac
  s="$OVERLAY/Quake/$b.c"
  [ -f "$s" ] || { echo "FATAL: source missing: $s" >&2; exit 1; }
  srcs+=("$s")
done
shopt -s nullglob
for s in "$ORACLE"/*.frag.c "$ORACLE"/*.vert.c "$ORACLE"/*.comp.c "$ORACLE"/embedded_pak.c; do
  srcs+=("$s")
done

echo "== compiling ${#srcs[@]} sources for iphoneos/arm64"
mkdir -p "$OBJ"; rm -f "$OBJ"/*.o

STAMP="$(grep '^commit' "$ROOT/upstream.pin" | cut -d= -f2 | cut -c1-8)+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ') $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'const char *vkq_ios_stamp = "%s";\n' "$STAMP" > "$OBJ/vkq_ios_stamp.c"
srcs+=("$OBJ/vkq_ios_stamp.c")
echo "== stamp: $STAMP"

fail=0
for s in "${srcs[@]}"; do
  b=$(basename "$s" .c)
  if ! $CC $CFLAGS $DEFS $INCS -c "$s" -o "$OBJ/$b.o" 2>"$OBJ/$b.err"; then
    echo "FATAL: compile failed: $s" >&2
    head -25 "$OBJ/$b.err" >&2
    fail=1; break
  fi
done
[ "$fail" = 0 ] || exit 1

n=$(ls "$OBJ"/*.o | wc -l | tr -d ' ')
mkdir -p "$(dirname "$LIB")"
libtool -static -o "$LIB" "$OBJ"/*.o
echo "IOS ENGINE OK: $LIB ($(du -h "$LIB" | cut -f1), $n objects)"
lipo -info "$LIB"

# --- assemble + sign the app (xcodegen + xcodebuild) ---
IOSDIR="$ROOT/ios"
[ -f "$IOSDIR/project.yml" ] || { echo "FATAL: ios/project.yml missing" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "FATAL: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
# app icon: compiled asset catalog (Assets.car). The OLD loose-PNG +
# CFBundleIconFiles setup rendered on the Home Screen but left a BLANK tile in
# SideStore/AltStore's "My Apps" list, which resolves the installed icon via
# CFBundleIconName -> Assets.car. A MULTI-size AppIcon.appiconset compiles
# cleanly on Xcode 26 actool (the "actool rejects single-size catalogs"
# q2repro fact is about SINGLE-size only — verified: this multi-size set builds
# and bakes AppIcon into the car). Sizes generated from the 512px master; the
# 1024 marketing slot is an upscale (only used in large/store contexts).
ICON_SRC="$IOSDIR/icon/vkq_icon.png"; ICONSET="$IOSDIR/Assets.xcassets/AppIcon.appiconset"
if [ -f "$ICON_SRC" ]; then
	mkdir -p "$ICONSET"
	sips -z 120 120   "$ICON_SRC" --out "$ICONSET/AppIcon60x60@2x.png"     >/dev/null 2>&1
	sips -z 180 180   "$ICON_SRC" --out "$ICONSET/AppIcon60x60@3x.png"     >/dev/null 2>&1
	sips -z 152 152   "$ICON_SRC" --out "$ICONSET/AppIcon76x76@2x.png"     >/dev/null 2>&1
	sips -z 167 167   "$ICON_SRC" --out "$ICONSET/AppIcon83.5x83.5@2x.png" >/dev/null 2>&1
	sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/AppIcon1024.png"         >/dev/null 2>&1
	echo "== icon catalog refreshed from $ICON_SRC"
else
	echo "== WARNING: $ICON_SRC missing — app will build with no icon" >&2
fi
echo "== generating Xcode project"
xcodegen generate --spec "$IOSDIR/project.yml" --project "$IOSDIR" --quiet
echo "== xcodebuild (Release, iphoneos, signed)"
xcodebuild -project "$IOSDIR/vkQuake.xcodeproj" -target vkQuake -configuration Release \
	-sdk iphoneos -allowProvisioningUpdates ONLY_ACTIVE_ARCH=NO \
	SYMROOT="$ROOT/build/ios/xcode" build > "$ROOT/build/ios/xcodebuild.log" 2>&1 \
	|| { echo "FATAL: xcodebuild failed — tail:" >&2; tail -45 "$ROOT/build/ios/xcodebuild.log" >&2; exit 1; }
APP="$ROOT/build/ios/xcode/Release-iphoneos/vkQuake.app"
[ -d "$APP" ] || { echo "FATAL: app bundle not produced" >&2; exit 1; }
echo "IOS APP OK: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true
