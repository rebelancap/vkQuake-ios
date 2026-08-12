#!/usr/bin/env bash
# vr-make-patch.sh — regenerate an overlay patch from build/src-base (the overlay
# as it stood BEFORE this round's edits) against build/src-overlay (as it stands
# now). Usage: vr-make-patch.sh <out.patch> <Quake/file.c> [...]
#
# Keeps the same `--- a/... / +++ b/...` shape the other patches use so
# sync-overlay.sh's `patch -p1 --fuzz=0` applies it identically.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; shift
[ -d "$ROOT/build/src-base" ] || { echo "FATAL: build/src-base missing (snapshot the overlay before editing)" >&2; exit 1; }
tmp="$OUT.tmp"
: > "$tmp"
for f in "$@"; do
	if ! diff -u "$ROOT/build/src-base/$f" "$ROOT/build/src-overlay/$f" \
		| sed -e "1s|.*|--- a/$f|" -e "2s|.*|+++ b/$f|" >> "$tmp"; then
		: # diff exits 1 when files differ; that is the normal case
	fi
done
mv "$tmp" "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
