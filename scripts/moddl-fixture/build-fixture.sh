#!/usr/bin/env bash
# build-fixture.sh — assemble the MOD-DL (overlay 0034) simulator fixture under
# tmp/moddl-fixture. Called by scripts/sim-verify-moddl.sh. Nothing it produces
# is committed (tmp/ is ignored); gamedata/ is only ever read.
#
# THE FAKE MOD is "qdlmod": Copper 1.30's progs.dat + pak0.pak under a game
# directory name no table or server knows. A real mod's progs is used because
# NetQuake mod content is precached by QuakeC, and a real progs precaches real
# models the client lacks (progs/v_axe2.mdl, progs/zombienm.mdl, ...). Copper
# comes from the curated table's own pinned URL (provenance: mods/mod-sources.json,
# cached by scripts/mod-sources-verify.py under tmp/mod-sources-cache/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/tmp/moddl-fixture"
PORT="${1:-18778}"

python3 -I "$ROOT/scripts/mod-sources-verify.py" >/dev/null || { echo "FATAL: the mod table does not verify" >&2; exit 1; }
SHA=$(python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1])); print([m for m in t["mods"] if m["gamedir"]=="copper"][0]["sha256"])' "$ROOT/mods/mod-sources.json")
ZIP="$ROOT/tmp/mod-sources-cache/${SHA:0:24}"
[ -f "$ZIP" ] || { echo "FATAL: copper package not cached at $ZIP" >&2; exit 1; }

rm -rf "$FIX/www" "$FIX/server" "$FIX/server-nogd" "$FIX/serveruser"*
mkdir -p "$FIX/www/dl/qdlmod" "$FIX/www/pkg" "$FIX/www/table" "$FIX/server/id1" "$FIX/server/qdlmod" "$FIX/server-nogd/id1"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$FIX/server/id1/pak0.pak"
cp -c "$ROOT/gamedata/rerelease/id1/pak0.pak" "$FIX/server-nogd/id1/pak0.pak"

python3 -I - "$ZIP" "$FIX" <<'PY'
import io, os, struct, sys, zipfile
zpath, fix = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(zpath)
pak = z.read("copper/pak0.pak")
open(os.path.join(fix, "server/qdlmod/pak0.pak"), "wb").write(pak)
open(os.path.join(fix, "server/qdlmod/progs.dat"), "wb").write(z.read("copper/progs.dat"))
# the server's download tree, FTE layout: <url>/<gamedir>/<path>
off, ln = struct.unpack("<ii", pak[4:12])
n = 0
for i in range(ln // 64):
    e = pak[off + i * 64: off + i * 64 + 64]
    name = e[:56].split(b"\0")[0].decode("latin1")
    fo, fl = struct.unpack("<ii", e[56:64])
    if ".." in name or name.startswith("/"):
        continue
    dst = os.path.join(fix, "www/dl/qdlmod", name)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "wb").write(pak[fo:fo + fl])
    n += 1
# One OPTIONAL file served as garbage: the client must reject it by magic number
# and carry on without it (a sound is not worth failing the join over).
open(os.path.join(fix, "www/dl/qdlmod/sound/items/patch.wav"), "wb").write(b"<html>not a wav</html>\n")
print("server download tree:", n, "files")
# NO-GAMEDIR server (leg h): the same mod content as id1/pak1.pak (Copper's pak +
# its progs.dat), so the server runs the mod while reporting game "id1" — which
# the client treats as "no mod folder named".
files = []
for i in range(ln // 64):
    e = pak[off + i * 64: off + i * 64 + 64]
    name = e[:56].split(b"\0")[0]
    fo, fl = struct.unpack("<ii", e[56:64])
    if name != b"progs.dat":
        files.append((name, pak[fo:fo + fl]))
files.append((b"progs.dat", z.read("copper/progs.dat")))
body = b"".join(d for _, d in files)
out = bytearray(b"PACK" + struct.pack("<ii", 12 + len(body), 64 * len(files)) + body)
pos = 12
for name, d in files:
    out += name.ljust(56, b"\0") + struct.pack("<ii", pos, len(d))
    pos += len(d)
open(os.path.join(fix, "server-nogd/id1/pak1.pak"), "wb").write(out)
PY

cp "$ZIP" "$FIX/www/pkg/copper_v1_30.zip"
# a copy with one byte flipped: same name, same size, wrong sha256
python3 -I - "$ZIP" "$FIX/www/pkg/copper_bad.zip" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read()); d[len(d) // 2] ^= 0xFF
open(sys.argv[2], "wb").write(d)
PY

# A copy that downloads small but unpacks big (leg i): Copper plus 24 MiB of
# zeros (~24 KB deflated). With cl_mapdownload_maxpkg 6 the unpack cap is 24 MiB;
# Copper alone unpacks to 12.7 MiB, so only the padding pushes it over.
python3 -I - "$ZIP" "$FIX/www/pkg/copper_big.zip" <<'PY'
import sys, zipfile
src = zipfile.ZipFile(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as dst:
    for info in src.infolist():
        dst.writestr(info.filename, src.read(info))
    dst.writestr("copper/zzpad.bin", bytes(24 * 1024 * 1024))
PY

# Fixture tables: the REAL table with Copper's URL pointed at this fixture —
# so the run also proves the shipped files list matches what Copper's progs
# actually precaches. "bad" points at the corrupted copy (sha mismatch).
python3 -I - "$ROOT/mods/mod-sources.json" "$FIX/www/table" "$PORT" <<'PY'
import json, sys, os
t = json.load(open(sys.argv[1])); out = sys.argv[2]; port = sys.argv[3]
import hashlib
for name, pkg in (("good.json", "copper_v1_30.zip"), ("bad.json", "copper_bad.zip"), ("big.json", "copper_big.zip")):
    for m in t["mods"]:
        if m["gamedir"] == "copper":
            m["url"] = "http://127.0.0.1:%s/pkg/%s" % (port, pkg)
            if name == "big.json":  # a CORRECT pin: only the unpack cap may refuse it
                d = open(os.path.join(out, "..", "pkg", pkg), "rb").read()
                m["sha256"] = hashlib.sha256(d).hexdigest()
                m["bytes"] = len(d)
    json.dump(t, open(os.path.join(out, name), "w"), indent=1)
PY
cp "$FIX/www/table/bad.json" "$FIX/www/table/mod-sources.json"
echo "fixture built in $FIX (http port $PORT)"
