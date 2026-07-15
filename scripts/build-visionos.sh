#!/usr/bin/env bash
#
# build-visionos.sh — compile the vkQuake engine for visionOS (xrOS/arm64) into
# build/visionos/libvkquake-xros.a, then build+sign the native visionOS app.
#
# Mirrors build-ios.sh (SAME oracle-derived source list, so coverage can't
# silently diverge) with the xrOS SDK/target. The engine reuses the iOS code
# paths verbatim (VKQ_IOS=1 — SDL windowing, shell glue, no-mouse, etc.); the
# visionOS-specific shell deltas (no landscape gate, window aspect-lock, hidden
# touch controls) are gated by VKQ_VISIONOS=1 in the app target (project.yml).
# The iOS build path is untouched. MoltenVK's xros-arm64 slice comes from
# vendor/moltenvk (fetch-moltenvk.sh); Vulkan headers are the platform-agnostic
# set already vendored under build/ios-deps/moltenvk. Codecs excluded for the
# first-render spike (no music yet), same as the original iOS substrate spike.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/build/src-overlay"
ORACLE="$ROOT/build/oracle"
DEPS="$ROOT/build/ios-deps"
VDEPS="$ROOT/build/visionos-deps"
MVK="$ROOT/vendor/moltenvk/MoltenVK.xcframework/xros-arm64"
OBJ="$ROOT/build/visionos/obj"
LIB="$ROOT/build/visionos/libvkquake-xros.a"

[ -d "$OVERLAY/Quake" ]    || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh" >&2; exit 1; }
[ -d "$ORACLE/vkquake.p" ] || { echo "FATAL: oracle build missing — build it first" >&2; exit 1; }
[ -f "$MVK/libMoltenVK.a" ] || "$ROOT/scripts/fetch-moltenvk.sh"
[ -f "$MVK/libMoltenVK.a" ] || { echo "FATAL: MoltenVK xros slice missing after fetch" >&2; exit 1; }
[ -f "$VDEPS/sdl-prefix/include/SDL3/SDL.h" ] || { echo "FATAL: SDL3 xros headers missing — run scripts/build-visionos-deps.sh" >&2; exit 1; }
[ -f "$DEPS/moltenvk/include/vulkan/vulkan.h" ] || { echo "FATAL: Vulkan headers missing — run scripts/build-ios-deps.sh" >&2; exit 1; }

SDK=$(xcrun --sdk xros --show-sdk-path)
CC=$(xcrun --sdk xros -f clang)
CFLAGS="-isysroot $SDK -target arm64-apple-xros2.0 -O2 -DNDEBUG -fno-omit-frame-pointer -pipe -Wno-implicit-function-declaration"
# VKQ_VISIONOS: stereoscopic 3D engine hooks (overlay patch 0010 — offscreen
# present image + eye matrices). VKQ_SWIFT_MAIN: the app entry is a SwiftUI
# @main (ImmersiveSpace requirement), so the engine's main is renamed
# vkq_engine_main and called by the shell instead of SDL's UIApplicationMain.
DEFS="-DUSE_SDL3 -DVKQ_IOS=1 -DVKQ_VISIONOS=1 -DVKQ_SWIFT_MAIN=1 -DTASK_AFFINITY_NOT_AVAILABLE -D_FILE_OFFSET_BITS=64 -DUSE_CODEC_VORBIS"
INCS="-I$OVERLAY/Quake -I$OVERLAY/Quake/mimalloc -I$VDEPS/sdl-prefix/include -I$DEPS/moltenvk/include -I$VDEPS/codec-prefix/include"

# ogg/vorbis music IS linked on visionOS (build-visionos-deps.sh); other codecs excluded
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

echo "== compiling ${#srcs[@]} sources for xros/arm64"
mkdir -p "$OBJ"; rm -f "$OBJ"/*.o

STAMP="$(grep '^commit' "$ROOT/upstream.pin" | cut -d= -f2 | cut -c1-8)+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ')-xros $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'const char *vkq_ios_stamp = "%s";\n' "$STAMP" > "$OBJ/vkq_ios_stamp.c"
srcs+=("$OBJ/vkq_ios_stamp.c")
echo "== stamp: $STAMP"

fail=0
for s in "${srcs[@]}"; do
  b=$(basename "$s" .c)
  if ! $CC $CFLAGS $DEFS $INCS -c "$s" -o "$OBJ/$b.o" 2>"$OBJ/$b.err"; then
    echo "FATAL: compile failed: $s" >&2; head -25 "$OBJ/$b.err" >&2; fail=1; break
  fi
done
[ "$fail" = 0 ] || exit 1

n=$(ls "$OBJ"/*.o | wc -l | tr -d ' ')
mkdir -p "$(dirname "$LIB")"
libtool -static -o "$LIB" "$OBJ"/*.o
echo "VISIONOS ENGINE OK: $LIB ($(du -h "$LIB" | cut -f1), $n objects)"
lipo -info "$LIB"

# --- assemble + sign the app (xcodegen + xcodebuild) ---
IOSDIR="$ROOT/ios"
[ -f "$IOSDIR/project.yml" ] || { echo "FATAL: ios/project.yml missing" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "FATAL: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
echo "== generating Xcode project"
xcodegen generate --spec "$IOSDIR/project.yml" --project "$IOSDIR" --quiet
# Force a relink: xcodebuild links -lvkquake-xros from a search path and does NOT
# track the .a as a dependency, so an engine-only change would ship a stale binary.
APPOUT="$ROOT/build/visionos/xcode/Release-xros/vkQuake.app"
rm -f "$APPOUT/vkQuake"
echo "== xcodebuild (Release, xros, signed)"
xcodebuild -project "$IOSDIR/vkQuake.xcodeproj" -target vkQuake-visionOS -configuration Release \
	-sdk xros -allowProvisioningUpdates ONLY_ACTIVE_ARCH=NO \
	SYMROOT="$ROOT/build/visionos/xcode" build > "$ROOT/build/visionos/xcodebuild.log" 2>&1 \
	|| { echo "FATAL: xcodebuild failed — tail:" >&2; tail -45 "$ROOT/build/visionos/xcodebuild.log" >&2; exit 1; }
grep -q "BUILD SUCCEEDED" "$ROOT/build/visionos/xcodebuild.log" \
	|| { echo "FATAL: xcodebuild did not report BUILD SUCCEEDED — tail:" >&2; tail -30 "$ROOT/build/visionos/xcodebuild.log" >&2; exit 1; }
[ -d "$APPOUT" ] || { echo "FATAL: app bundle not produced" >&2; exit 1; }
# Staleness protection is the rm -f above (forces the final link to re-run against
# the freshly-built .a). The stamp string itself is dead-stripped (unreferenced),
# so its presence is a best-effort note, not a hard gate.
n2=$(strings "$APPOUT/vkQuake" | grep -cF "$STAMP" || true)
[ "${n2:-0}" -gt 0 ] && echo "VISIONOS APP OK: $APPOUT (stamp verified)" \
	|| echo "VISIONOS APP OK: $APPOUT (relinked; stamp dead-stripped, not asserted)"
codesign -dv "$APPOUT" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true
