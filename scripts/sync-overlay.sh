#!/usr/bin/env bash
#
# sync-overlay.sh — regenerate build/src-overlay = pristine vendor/vkQuake
# with patches/*.patch applied on top. This is the meson SOURCE tree for every
# build (oracle and, later, iOS), so instrumentation is always present and any
# patch drift fails the build loudly (charter rules 1 & 3).
#
# Checksum-based sync (rsync -c, deliberately NO -t): changed files get fresh
# mtimes so ninja never silently reuses a stale object — the false-A/B trap that
# cost the sibling ports a day (q2repro M-004 / quake3e D-004).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/vkQuake"
OVERLAY="$ROOT/build/src-overlay"

[ -d "$VENDOR/Quake" ] || { echo "FATAL: $VENDOR/Quake missing — clone vendor/vkQuake at upstream.pin first." >&2; exit 1; }

mkdir -p "$OVERLAY"

# -r recursive, -l symlinks, -p perms, -c checksum. No -t on purpose (fresh mtimes).
rsync -rlpc --delete --exclude='.git/' "$VENDOR/" "$OVERLAY/"

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
	echo "sync-overlay: overlay = pristine vendor (no patches yet)"
else
	for p in "${patches[@]}"; do
		echo "sync-overlay: applying $(basename "$p")"
		if ! patch -p1 -d "$OVERLAY" --fuzz=0 --forward < "$p"; then
			echo "FATAL: patch failed to apply cleanly: $p" >&2
			exit 1
		fi
	done
	echo "sync-overlay: applied ${#patches[@]} patch(es)"
fi

echo "sync-overlay: OK -> $OVERLAY"
