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
	# -N: a file new in this patch (no build/src-base copy) diffs against empty, so
	# `patch` creates it; a path missing from the overlay is a typo -- fail loudly.
	[ -f "$ROOT/build/src-overlay/$f" ] || { echo "FATAL: build/src-overlay/$f does not exist" >&2; rm -f "$tmp"; exit 1; }
	if ! diff -uN "$ROOT/build/src-base/$f" "$ROOT/build/src-overlay/$f" \
		| sed -e "1s|.*|--- a/$f|" -e "2s|.*|+++ b/$f|" >> "$tmp"; then
		: # diff exits 1 when files differ; that is the normal case
	fi
done
mv "$tmp" "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
