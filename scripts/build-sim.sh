#!/usr/bin/env bash
#
# build-sim.sh <ios|visionos> — SIMULATOR build lane (verification only, never
# shipped): deps + engine + app for iphonesimulator / xrsimulator, arm64.
#
# Exists because REMOTE OPERATIONS makes simulator validation mandatory before
# any user-facing OTA build (CLAUDE.md). Mirrors build-ios.sh / build-visionos.sh
# exactly (same oracle-derived source list, same DEFS) with three deltas:
#   - sim SDK/-target triples (arm64-apple-ios16.0-simulator / xros1.0-simulator)
#   - sim static deps in build/<plat>-sim-deps (SDL3 + ogg/vorbis; MoltenVK sim
#     slices come straight from vendor/moltenvk/MoltenVK.xcframework)
#   - unsigned app (CODE_SIGNING_ALLOWED=NO — simctl install accepts it)
# Headers are reused from the DEVICE dep prefixes (same SDL/vorbis versions;
# only the .a binaries differ per SDK).
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/build/src-overlay"
ORACLE="$ROOT/build/oracle"
IDEPS="$ROOT/build/ios-deps"          # device prefixes — header source of truth
SDL_SRC="$ROOT/vendor/SDL"
MVKX="$ROOT/vendor/moltenvk/MoltenVK.xcframework"

PLAT="${1:-}"
case "$PLAT" in
ios)
	SDKNAME=iphonesimulator
	TRIPLE=arm64-apple-ios16.0-simulator
	CM_SYS=iOS; CM_MIN=16.0
	RELDIR=Release-iphonesimulator
	MVK_SLICE="$MVKX/ios-arm64_x86_64-simulator"
	XCTARGET=vkQuake
	ENGLIB=libvkquake.a
	PLAT_DEFS=""
	;;
visionos)
	SDKNAME=xrsimulator
	TRIPLE=arm64-apple-xros2.0-simulator
	CM_SYS=visionOS; CM_MIN=2.0
	RELDIR=Release-xrsimulator
	MVK_SLICE="$MVKX/xros-arm64_x86_64-simulator"
	XCTARGET=vkQuake-visionOS
	ENGLIB=libvkquake-xros.a
	# stereo 3D hooks + SwiftUI app entry (same as the device build)
	PLAT_DEFS="-DVKQ_VISIONOS=1 -DVKQ_SWIFT_MAIN=1"
	;;
*)
	echo "usage: $0 <ios|visionos>" >&2; exit 2 ;;
esac

DEPS="$ROOT/build/$PLAT-sim-deps"
OBJ="$ROOT/build/$PLAT-sim/obj"
LIB="$ROOT/build/$PLAT-sim/$ENGLIB"

[ -d "$OVERLAY/Quake" ]    || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh" >&2; exit 1; }
[ -d "$ORACLE/vkquake.p" ] || { echo "FATAL: oracle build missing — build it first" >&2; exit 1; }
[ -f "$MVK_SLICE/libMoltenVK.a" ] || { echo "FATAL: MoltenVK sim slice missing: $MVK_SLICE (run scripts/fetch-moltenvk.sh)" >&2; exit 1; }
[ -f "$IDEPS/sdl-prefix/include/SDL3/SDL.h" ] || { echo "FATAL: SDL3 headers missing — run scripts/build-ios-deps.sh" >&2; exit 1; }
[ -f "$IDEPS/moltenvk/include/vulkan/vulkan.h" ] || { echo "FATAL: Vulkan headers missing — run scripts/build-ios-deps.sh" >&2; exit 1; }
mkdir -p "$DEPS"

# --- SDL3 (sim static) — same release-3.4.10 checkout, sim SDK ---
if [ ! -f "$DEPS/sdl-prefix/lib/libSDL3.a" ]; then
	[ -d "$SDL_SRC" ] || { echo "FATAL: SDL source missing at $SDL_SRC" >&2; exit 1; }
	echo "== building SDL3 static for $SDKNAME/arm64"
	cmake -S "$SDL_SRC" -B "$DEPS/sdl-build" -GXcode \
		-DCMAKE_SYSTEM_NAME=$CM_SYS -DCMAKE_OSX_SYSROOT=$SDKNAME \
		-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$CM_MIN \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DCMAKE_INSTALL_PREFIX="$DEPS/sdl-prefix" \
		> "$DEPS/sdl-cmake-config.log" 2>&1 || { echo "FATAL: SDL cmake configure failed"; tail -20 "$DEPS/sdl-cmake-config.log"; exit 1; }
	cmake --build "$DEPS/sdl-build" --config Release --target SDL3-static > "$DEPS/sdl-build.log" 2>&1 \
		|| { echo "FATAL: SDL build failed"; tail -25 "$DEPS/sdl-build.log"; exit 1; }
	mkdir -p "$DEPS/sdl-prefix/lib"
	cp "$DEPS/sdl-build/$RELDIR/libSDL3.a" "$DEPS/sdl-prefix/lib/"
fi
lipo -info "$DEPS/sdl-prefix/lib/libSDL3.a"

# --- libogg + libvorbis (sim static) ---
if [ ! -f "$DEPS/codec-prefix/lib/libvorbisfile.a" ]; then
	echo "== building libogg + libvorbis static for $SDKNAME/arm64"
	CODEC="$DEPS/codec-prefix"
	SIMF=(-DCMAKE_SYSTEM_NAME=$CM_SYS -DCMAKE_OSX_SYSROOT=$SDKNAME
		-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$CM_MIN
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DBUILD_SHARED_LIBS=OFF
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX="$CODEC")
	cmake -S "$ROOT/vendor/ogg" -B "$DEPS/ogg-build" -GXcode "${SIMF[@]}" > "$DEPS/ogg-cmake.log" 2>&1 \
		|| { echo "FATAL: libogg configure failed"; tail -20 "$DEPS/ogg-cmake.log"; exit 1; }
	cmake --build "$DEPS/ogg-build" --config Release --target install > "$DEPS/ogg-build.log" 2>&1 \
		|| { echo "FATAL: libogg build failed"; tail -25 "$DEPS/ogg-build.log"; exit 1; }
	cmake -S "$ROOT/vendor/vorbis" -B "$DEPS/vorbis-build" -GXcode "${SIMF[@]}" \
		-DOGG_INCLUDE_DIR="$CODEC/include" -DOGG_LIBRARY="$CODEC/lib/libogg.a" > "$DEPS/vorbis-cmake.log" 2>&1 \
		|| { echo "FATAL: libvorbis configure failed"; tail -20 "$DEPS/vorbis-cmake.log"; exit 1; }
	cmake --build "$DEPS/vorbis-build" --config Release --target install > "$DEPS/vorbis-build.log" 2>&1 \
		|| { echo "FATAL: libvorbis build failed"; tail -25 "$DEPS/vorbis-build.log"; exit 1; }
fi
lipo -info "$DEPS/codec-prefix/lib/libvorbisfile.a"

# --- engine (same source list as the device builds) ---
SDK=$(xcrun --sdk $SDKNAME --show-sdk-path)
CC=$(xcrun --sdk $SDKNAME -f clang)
CFLAGS="-isysroot $SDK -target $TRIPLE -O2 -DNDEBUG -fno-omit-frame-pointer -pipe -Wno-implicit-function-declaration"
DEFS="-DUSE_SDL3 -DVKQ_IOS=1 -DTASK_AFFINITY_NOT_AVAILABLE -D_FILE_OFFSET_BITS=64 -DUSE_CODEC_VORBIS $PLAT_DEFS"
INCS="-I$OVERLAY/Quake -I$OVERLAY/Quake/mimalloc -I$IDEPS/sdl-prefix/include -I$IDEPS/moltenvk/include -I$IDEPS/codec-prefix/include"
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

echo "== compiling ${#srcs[@]} sources for $SDKNAME/arm64"
mkdir -p "$OBJ"; rm -f "$OBJ"/*.o

STAMP="$(grep '^commit' "$ROOT/upstream.pin" | cut -d= -f2 | cut -c1-8)+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ')-$SDKNAME $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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
echo "SIM ENGINE OK: $LIB ($(du -h "$LIB" | cut -f1), $n objects)"

# --- app (unsigned, sim SDK) ---
IOSDIR="$ROOT/ios"
command -v xcodegen >/dev/null || { echo "FATAL: xcodegen not installed" >&2; exit 1; }
xcodegen generate --spec "$IOSDIR/project.yml" --project "$IOSDIR" --quiet
APPOUT="$ROOT/build/$PLAT-sim/xcode/$RELDIR/vkQuake.app"
rm -f "$APPOUT/vkQuake" # force relink against the freshly built .a (not dep-tracked)
echo "== xcodebuild (Release, $SDKNAME, unsigned)"
xcodebuild -project "$IOSDIR/vkQuake.xcodeproj" -target "$XCTARGET" -configuration Release \
	-sdk $SDKNAME ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
	CODE_SIGNING_ALLOWED=NO \
	`# VKQ_DEV_BUILD gates debugging-only features (the Remote Console switch, which` \
	`# opens an unauthenticated engine command port). Always on for the simulator —` \
	`# this lane is verification-only and never shipped. Release builds derive it` \
	`# from the version number and ship without it.` \
	GCC_PREPROCESSOR_DEFINITIONS='$(inherited) VKQ_DEV_BUILD=1' \
	SYMROOT="$ROOT/build/$PLAT-sim/xcode" \
	LIBRARY_SEARCH_PATHS="$ROOT/build/$PLAT-sim $DEPS/sdl-prefix/lib $DEPS/codec-prefix/lib $MVK_SLICE" \
	OTHER_LDFLAGS="-ObjC -force_load $LIB -lSDL3 -lMoltenVK -lc++ -lz -liconv -lvorbisfile -lvorbis -logg" \
	build > "$ROOT/build/$PLAT-sim/xcodebuild.log" 2>&1 \
	|| { echo "FATAL: xcodebuild failed — tail:" >&2; tail -45 "$ROOT/build/$PLAT-sim/xcodebuild.log" >&2; exit 1; }
grep -q "BUILD SUCCEEDED" "$ROOT/build/$PLAT-sim/xcodebuild.log" \
	|| { echo "FATAL: no BUILD SUCCEEDED — tail:" >&2; tail -30 "$ROOT/build/$PLAT-sim/xcodebuild.log" >&2; exit 1; }
[ -d "$APPOUT" ] || { echo "FATAL: app bundle not produced at $APPOUT" >&2; exit 1; }
echo "SIM APP OK: $APPOUT"
