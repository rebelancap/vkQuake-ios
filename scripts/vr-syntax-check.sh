#!/usr/bin/env bash
# vr-syntax-check.sh — fast -fsyntax-only pass over the overlay files this round
# touches, with the visionOS target's exact defines. Turns a 4-minute full build
# into a 10-second answer while iterating on an overlay patch.
#
# R6 — THIS SCRIPT WAS INVERTED FOR HARD ERRORS, from the day it was written.
# It ran the compiler in a pipeline (`$CC … 2>&1 | head -30 | grep -q .`) under
# `set -o pipefail`, and pipefail makes a pipeline's status the LAST non-zero
# one — so a compile that failed (clang exit 1) made the whole pipeline non-zero
# no matter what grep found, the `if` took the else branch, and the script
# printed "OK". It reported failure only for files that compiled with WARNINGS
# (clang exit 0, output present) and success for files that did not compile at
# all. Caught in R6 by a genuinely missing declaration that it waved through.
#
# The shape below cannot invert: capture the output, keep the compiler's own
# status, and fail on either.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK=$(xcrun --sdk xros --show-sdk-path)
CC=$(xcrun --sdk xros -f clang)
O="$ROOT/build/src-overlay"; D="$ROOT/build/ios-deps"; V="$ROOT/build/visionos-deps"
DEFS="-DUSE_SDL3 -DVKQ_IOS=1 -DVKQ_VISIONOS=1 -DVKQ_SWIFT_MAIN=1 -DTASK_AFFINITY_NOT_AVAILABLE -D_FILE_OFFSET_BITS=64 -DUSE_CODEC_VORBIS"
INCS="-I$O/Quake -I$O/Quake/mimalloc -I$V/sdl-prefix/include -I$D/moltenvk/include -I$V/codec-prefix/include"
fail=0
for f in "$@"; do
	out=$($CC -isysroot "$SDK" -target arm64-apple-xros2.0 -O1 -fsyntax-only \
		-Werror=implicit-function-declaration -Wall $DEFS $INCS "$O/Quake/$f.c" 2>&1)
	rc=$?
	if [ $rc -ne 0 ] || [ -n "$out" ]; then
		echo "=== $f (clang exit $rc) ==="
		printf '%s\n' "$out" | head -40
		fail=1
	else
		echo "OK  $f"
	fi
done
exit $fail
