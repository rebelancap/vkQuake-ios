#!/usr/bin/env bash
#
# build-visionos-deps.sh — static dependencies for the visionOS (xrOS) build,
# mirror of build-ios-deps.sh for the xrOS SDK. Outputs:
#   vendor/moltenvk/MoltenVK.xcframework/xros-arm64/libMoltenVK.a  (fetch-moltenvk.sh)
#   build/visionos-deps/sdl-prefix/{lib/libSDL3.a, include/SDL3}   (SDL3 3.4.10)
#   build/visionos-deps/codec-prefix/lib/{libogg,libvorbis,libvorbisfile}.a
#
# One command; idempotent (skips anything already built — rm -rf build/visionos-deps
# to force a rebuild). SDL local patches (patches/sdl/*.patch) are applied the same
# way as the iOS build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/visionos-deps"
SDL_SRC="$ROOT/vendor/SDL"
mkdir -p "$DEPS"

# --- MoltenVK (all-platform xcframework incl. xros-arm64) ---
"$ROOT/scripts/fetch-moltenvk.sh"

# --- SDL3 (xrOS static) ---
# Apply local downstream SDL patches (same set as iOS; harmless on visionOS).
if [ -d "$SDL_SRC/.git" ]; then
	sdl_patched=0
	for p in "$ROOT"/patches/sdl/*.patch; do
		[ -e "$p" ] || continue
		if git -C "$SDL_SRC" apply --reverse --check "$p" 2>/dev/null; then :; else
			echo "== applying SDL patch: $(basename "$p")"
			git -C "$SDL_SRC" apply "$p" || { echo "FATAL: SDL patch failed: $p" >&2; exit 1; }
			sdl_patched=1
		fi
	done
	[ "$sdl_patched" = "1" ] && rm -rf "$DEPS/sdl-prefix" "$DEPS/sdl-build"
fi

if [ ! -f "$DEPS/sdl-prefix/lib/libSDL3.a" ]; then
	[ -d "$SDL_SRC" ] || { echo "FATAL: SDL source missing — git clone --depth 1 --branch release-3.4.10 https://github.com/libsdl-org/SDL.git $SDL_SRC" >&2; exit 1; }
	echo "== building SDL3 static for xros/arm64"
	cmake -S "$SDL_SRC" -B "$DEPS/sdl-build" -GXcode \
		-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=1.0 \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DCMAKE_INSTALL_PREFIX="$DEPS/sdl-prefix" \
		> "$DEPS/sdl-cmake-config.log" 2>&1 || { echo "FATAL: SDL cmake configure failed"; tail -20 "$DEPS/sdl-cmake-config.log"; exit 1; }
	cmake --build "$DEPS/sdl-build" --config Release --target SDL3-static > "$DEPS/sdl-build.log" 2>&1 \
		|| { echo "FATAL: SDL build failed"; tail -25 "$DEPS/sdl-build.log"; exit 1; }
	mkdir -p "$DEPS/sdl-prefix/lib" "$DEPS/sdl-prefix/include/SDL3"
	cp "$DEPS/sdl-build/Release-xros/libSDL3.a" "$DEPS/sdl-prefix/lib/"
	cp "$SDL_SRC/include/SDL3/"*.h "$DEPS/sdl-prefix/include/SDL3/"
	cp "$(find "$DEPS/sdl-build" -name SDL_revision.h | head -1)" "$DEPS/sdl-prefix/include/SDL3/"
fi
lipo -info "$DEPS/sdl-prefix/lib/libSDL3.a"

# --- libogg + libvorbis (xrOS static, for external ogg music tracks) ---
if [ ! -f "$DEPS/codec-prefix/lib/libvorbisfile.a" ]; then
	echo "== building libogg + libvorbis static for xros/arm64"
	CODEC="$DEPS/codec-prefix"
	XRF=(-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=1.0
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DBUILD_SHARED_LIBS=OFF
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX="$CODEC")
	cmake -S "$ROOT/vendor/ogg" -B "$DEPS/ogg-build" -GXcode "${XRF[@]}" > "$DEPS/ogg-cmake.log" 2>&1 \
		|| { echo "FATAL: libogg configure failed"; tail -20 "$DEPS/ogg-cmake.log"; exit 1; }
	cmake --build "$DEPS/ogg-build" --config Release --target install > "$DEPS/ogg-build.log" 2>&1 \
		|| { echo "FATAL: libogg build failed"; tail -25 "$DEPS/ogg-build.log"; exit 1; }
	cmake -S "$ROOT/vendor/vorbis" -B "$DEPS/vorbis-build" -GXcode "${XRF[@]}" \
		-DOGG_INCLUDE_DIR="$CODEC/include" -DOGG_LIBRARY="$CODEC/lib/libogg.a" > "$DEPS/vorbis-cmake.log" 2>&1 \
		|| { echo "FATAL: libvorbis configure failed"; tail -20 "$DEPS/vorbis-cmake.log"; exit 1; }
	cmake --build "$DEPS/vorbis-build" --config Release --target install > "$DEPS/vorbis-build.log" 2>&1 \
		|| { echo "FATAL: libvorbis build failed"; tail -25 "$DEPS/vorbis-build.log"; exit 1; }
fi
lipo -info "$DEPS/codec-prefix/lib/libvorbisfile.a"

echo "VISIONOS DEPS OK: $DEPS"
