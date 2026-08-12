#!/usr/bin/env bash
# ios-syntax-check.sh — the sibling of vr-syntax-check.sh for the PLAIN iOS
# target (VKQ_IOS without VKQ_VISIONOS). R5 touches gl_screen.c, which is shared
# by both apps, so "the visionOS build is green" is not the same claim as "the
# iPhone build still compiles" — and the iPhone app is the shipping one.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
O="$ROOT/build/src-overlay"; D="$ROOT/build/ios-deps"
DEFS="-DUSE_SDL3 -DVKQ_IOS=1 -DTASK_AFFINITY_NOT_AVAILABLE -D_FILE_OFFSET_BITS=64 -DUSE_CODEC_VORBIS"
INCS="-I$O/Quake -I$O/Quake/mimalloc -I$D/sdl-prefix/include -I$D/moltenvk/include -I$D/codec-prefix/include"
fail=0
for f in "$@"; do
	out=$($CC -isysroot "$SDK" -target arm64-apple-ios16.0 -O1 -fsyntax-only \
		-Werror=implicit-function-declaration -Wall $DEFS $INCS "$O/Quake/$f.c" 2>&1 | head -30)
	if [ -n "$out" ]; then
		echo "=== $f ==="; echo "$out"; fail=1
	else
		echo "OK  $f (iOS)"
	fi
done
exit $fail
