#!/usr/bin/env bash
#
# build-ios-deps.sh — prebuilt static iOS dependencies for the vkQuake app:
#   build/ios-deps/sdl-prefix/{lib/libSDL3.a, include/SDL3}          (SDL3 3.4.10)
#   build/ios-deps/moltenvk/{lib/libMoltenVK.a, include/{vulkan,MoltenVK}}
#
# SDL3 is built at the SAME release the macOS oracle uses (release-3.4.10) so
# device and desk differ only by platform, not library version. Idempotent.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/ios-deps"
SDL_SRC="$ROOT/vendor/SDL"   # git clone --depth 1 --branch release-3.4.10 https://github.com/libsdl-org/SDL.git
# MoltenVK iOS static lib. TODO: fetch the official KhronosGroup/MoltenVK release
# into vendor/ for a true clean-machine drill; for now reuse the sibling's vendored copy.
MVK_SRC="$HOME/dev/quake3e-ios/vendor/moltenvk-ios/MoltenVK/MoltenVK"

mkdir -p "$DEPS"

# --- MoltenVK (iOS static) + platform-independent Vulkan headers ---
if [ ! -f "$DEPS/moltenvk/lib/libMoltenVK.a" ]; then
	echo "== vendoring MoltenVK ios-arm64 + Vulkan headers"
	[ -f "$MVK_SRC/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" ] || { echo "FATAL: MoltenVK iOS lib not found at $MVK_SRC" >&2; exit 1; }
	mkdir -p "$DEPS/moltenvk/lib" "$DEPS/moltenvk/include"
	cp "$MVK_SRC/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" "$DEPS/moltenvk/lib/"
	cp -R "$MVK_SRC/include/MoltenVK" "$DEPS/moltenvk/include/"
	cp -R /opt/homebrew/opt/vulkan-headers/include/vulkan "$DEPS/moltenvk/include/"
	cp -R /opt/homebrew/opt/vulkan-headers/include/vk_video "$DEPS/moltenvk/include/" 2>/dev/null || true
fi
lipo -info "$DEPS/moltenvk/lib/libMoltenVK.a"

# --- SDL3 (iOS static) ---
# Local downstream SDL patches (reproducible; each must apply cleanly or fail loud).
# These are private build fixes, NOT upstream contributions. Currently: enable the
# on-screen-keyboard backspace when SDL_HasKeyboard() is true (a game controller
# makes it true on iOS, which otherwise gates soft-keyboard Delete off entirely).
if [ -d "$SDL_SRC/.git" ]; then
	sdl_patched=0
	for p in "$ROOT"/patches/sdl/*.patch; do
		[ -e "$p" ] || continue
		if git -C "$SDL_SRC" apply --reverse --check "$p" 2>/dev/null; then
			: # already applied
		else
			echo "== applying SDL patch: $(basename "$p")"
			git -C "$SDL_SRC" apply "$p" || { echo "FATAL: SDL patch failed to apply: $p" >&2; exit 1; }
			sdl_patched=1
		fi
	done
	# a freshly-applied patch must invalidate a previously-built lib
	[ "$sdl_patched" = "1" ] && rm -rf "$DEPS/sdl-prefix" "$DEPS/sdl-build"
fi

if [ ! -f "$DEPS/sdl-prefix/lib/libSDL3.a" ]; then
	[ -d "$SDL_SRC" ] || { echo "FATAL: SDL source missing — git clone --depth 1 --branch release-3.4.10 https://github.com/libsdl-org/SDL.git $SDL_SRC" >&2; exit 1; }
	echo "== building SDL3 static for iphoneos/arm64"
	cmake -S "$SDL_SRC" -B "$DEPS/sdl-build" -GXcode \
		-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DCMAKE_INSTALL_PREFIX="$DEPS/sdl-prefix" \
		> "$DEPS/sdl-cmake-config.log" 2>&1 || { echo "FATAL: SDL cmake configure failed"; tail -20 "$DEPS/sdl-cmake-config.log"; exit 1; }
	cmake --build "$DEPS/sdl-build" --config Release --target SDL3-static > "$DEPS/sdl-build.log" 2>&1 \
		|| { echo "FATAL: SDL build failed"; tail -25 "$DEPS/sdl-build.log"; exit 1; }
	# assemble prefix: lib from build tree; headers = source SDL3/*.h + generated SDL_revision.h
	mkdir -p "$DEPS/sdl-prefix/lib" "$DEPS/sdl-prefix/include/SDL3"
	cp "$DEPS/sdl-build/Release-iphoneos/libSDL3.a" "$DEPS/sdl-prefix/lib/"
	cp "$SDL_SRC/include/SDL3/"*.h "$DEPS/sdl-prefix/include/SDL3/"
	cp "$(find "$DEPS/sdl-build" -name SDL_revision.h | head -1)" "$DEPS/sdl-prefix/include/SDL3/"
fi
lipo -info "$DEPS/sdl-prefix/lib/libSDL3.a"

# --- libogg + libvorbis (iOS static, for external ogg music tracks) ---
if [ ! -f "$DEPS/codec-prefix/lib/libvorbisfile.a" ]; then
	echo "== building libogg + libvorbis static for iphoneos/arm64"
	CODEC="$DEPS/codec-prefix"
	IOSF=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DBUILD_SHARED_LIBS=OFF
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX="$CODEC") # ogg/vorbis declare an ancient cmake minimum
	cmake -S "$ROOT/vendor/ogg" -B "$DEPS/ogg-build" -GXcode "${IOSF[@]}" > "$DEPS/ogg-cmake.log" 2>&1 \
		|| { echo "FATAL: libogg configure failed"; tail -20 "$DEPS/ogg-cmake.log"; exit 1; }
	cmake --build "$DEPS/ogg-build" --config Release --target install > "$DEPS/ogg-build.log" 2>&1 \
		|| { echo "FATAL: libogg build failed"; tail -25 "$DEPS/ogg-build.log"; exit 1; }
	cmake -S "$ROOT/vendor/vorbis" -B "$DEPS/vorbis-build" -GXcode "${IOSF[@]}" \
		-DOGG_INCLUDE_DIR="$CODEC/include" -DOGG_LIBRARY="$CODEC/lib/libogg.a" > "$DEPS/vorbis-cmake.log" 2>&1 \
		|| { echo "FATAL: libvorbis configure failed"; tail -20 "$DEPS/vorbis-cmake.log"; exit 1; }
	cmake --build "$DEPS/vorbis-build" --config Release --target install > "$DEPS/vorbis-build.log" 2>&1 \
		|| { echo "FATAL: libvorbis build failed"; tail -25 "$DEPS/vorbis-build.log"; exit 1; }
fi
lipo -info "$DEPS/codec-prefix/lib/libvorbisfile.a"

echo "IOS DEPS OK: $DEPS"
