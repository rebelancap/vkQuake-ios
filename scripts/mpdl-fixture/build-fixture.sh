#!/usr/bin/env bash
# build-fixture.sh — assemble the MP-DL1 simulator fixture under tmp/mpdl-fixture.
# Called by scripts/sim-verify-mpdl.sh. Everything it produces is derived from the
# user's own game data and NEVER committed (tmp/ is ignored); gamedata/ is only
# ever read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/tmp/mpdl-fixture"
PAK="$ROOT/gamedata/id1/PAK0.PAK"
SRCMAP="maps/e1m7.bsp"   # 607 KB, the smallest playable id1 map

[ -f "$PAK" ] || { echo "FATAL: $PAK missing" >&2; exit 1; }

rm -rf "$FIX/www" "$FIX/server" "$FIX/serveruser" "$FIX/stage"
mkdir -p "$FIX/www/all" "$FIX/www/pkg" "$FIX/www/api" "$FIX/server/id1/maps" "$FIX/serveruser" "$FIX/stage"

# One real BSP, renamed six ways. Inside a .bsp the map's own name appears
# nowhere — the engine loads it purely by filename — so this is a legitimate
# stand-in for six community maps the client does not have.
python3 "$ROOT/scripts/mpdl-fixture/pakread.py" "$PAK" "$SRCMAP" "$FIX/stage/base.bsp" >/dev/null
# blitzkrieg2 is the REAL map this feature exists for: the run's last leg has the
# server announce it so the client fetches the genuine 2.5 MB file from
# maps.quakeworld.nu. The server side is still this stand-in — NetQuake carries no
# map checksum, which is itself a finding the round reports.
for m in qdl_test1 qdl_test2 qdl_test3 qdl_test4 qdl_test6 qdl_test9 blitzkrieg2; do
	cp "$FIX/stage/base.bsp" "$FIX/server/id1/maps/$m.bsp"
done
# The server also needs the real game data behind those maps.
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$FIX/server/id1/pak0.pak"

# --- SOURCE A (bare-BSP mirror) — only test1 and test4 are published there.
cp "$FIX/stage/base.bsp" "$FIX/www/all/qdl_test1.bsp"
cp "$FIX/stage/base.bsp" "$FIX/www/all/qdl_test4.bsp"

# --- SOURCE B package for qdl_test2. readme_qdl.txt is deliberately something the
# client will already have, so the "skip (exists), never overwrite" guardrail has
# an entry to fire on.
mkdir -p "$FIX/stage/pkg2/maps"
cp "$FIX/stage/base.bsp" "$FIX/stage/pkg2/maps/qdl_test2.bsp"
printf 'fixture package readme — the client already has this file.\n' > "$FIX/stage/pkg2/readme_qdl.txt"
( cd "$FIX/stage/pkg2" && zip -q -r -X "$FIX/www/pkg/qdl_pkg2.zip" . )

# --- ZIP-SLIP package for qdl_test3: one escaping entry plus one legitimate map,
# so the run proves the bad entry is refused WITHOUT the whole package being
# thrown away.
mkdir -p "$FIX/stage/pkg3/maps"
cp "$FIX/stage/base.bsp" "$FIX/stage/pkg3/maps/qdl_test3.bsp"
( cd "$FIX/stage/pkg3" && zip -q -r -X "$FIX/www/pkg/qdl_evil.zip" . )
# zip refuses to store "../" paths from the command line, so the traversal entry
# is appended with a tiny writer that does not care.
python3 - "$FIX/www/pkg/qdl_evil.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'a', zipfile.ZIP_DEFLATED)
z.writestr('../../../../evil_mapdl.txt', 'if you can read this outside Documents, zip-slip won\n')
z.writestr('maps/../../evil_mapdl2.txt', 'second traversal shape\n')
z.close()
PY

SHA2=$(shasum -a 256 "$FIX/www/pkg/qdl_pkg2.zip" | cut -d' ' -f1)
SHA3=$(shasum -a 256 "$FIX/www/pkg/qdl_evil.zip" | cut -d' ' -f1)
B2=$(stat -f%z "$FIX/www/pkg/qdl_pkg2.zip")
B3=$(stat -f%z "$FIX/www/pkg/qdl_evil.zip")

# --- the ?q=* dump, in the live API v1 record shape (files as an OBJECT).
cat > "$FIX/www/api/index.json" <<JSON
[
 {"sha256":"$SHA2","timestamp":"2026-01-01T00:00:00Z",
  "metadata":{"title":"QDL Fixture Pack Two","authors":["fixture"],
   "tags":["zipbasedir=id1","startmap=qdl_test2","filename=qdl_pkg2.zip"],
   "urls":["http://127.0.0.1:18777/pkg/qdl_pkg2.zip"],
   "bytes":$B2,
   "files":{"maps/qdl_test2.bsp":{"bytes":607420,"sha256":"x","timestamp":"2026-01-01T00:00:00Z"},
            "readme_qdl.txt":{"bytes":60,"sha256":"y","timestamp":"2026-01-01T00:00:00Z"}},
   "install":{"extract":"{base}/id1/"},
   "notes":[],"description":"fixture"}},
 {"sha256":"$SHA3","timestamp":"2026-01-01T00:00:00Z",
  "metadata":{"title":"QDL Fixture Pack Three (hostile)","authors":["fixture"],
   "tags":["zipbasedir=id1"],
   "urls":["http://127.0.0.1:18777/pkg/qdl_evil.zip"],
   "bytes":$B3,
   "files":{"maps/qdl_test3.bsp":{"bytes":607420,"sha256":"x","timestamp":"2026-01-01T00:00:00Z"}},
   "install":{"extract":"{base}/id1/"},
   "notes":[],"description":"zip-slip fixture"}}
]
JSON
python3 -c "import json,sys; json.load(open(sys.argv[1])); print('index.json parses, records:', len(json.load(open(sys.argv[1]))))" "$FIX/www/api/index.json"
echo "fixture built:"
echo "  maps served bare : $(ls "$FIX/www/all" | tr '\n' ' ')"
echo "  packages         : qdl_pkg2.zip ($B2 B, $SHA2)"
echo "                     qdl_evil.zip ($B3 B, $SHA3)"
echo "  server maps      : $(ls "$FIX/server/id1/maps" | tr '\n' ' ')"
