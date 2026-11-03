#!/usr/bin/env python3
"""mod-sources-verify.py — check (and optionally regenerate) mods/mod-sources.json.

The table is what overlay 0034's mod downloader offers players, so every entry
must be TRUE: the URL answers, the bytes hash to `sha256`, the size is `bytes`,
every install rule names a file that is in the archive (a "file" entry is one
loose file whose single rule names its game path), no installed .pak
carries a .cfg/.rc, and `files` is exactly what the installed paks/files
provide (the client matches a server's missing models against `files`).

    scripts/mod-sources-verify.py                # verify every entry
    scripts/mod-sources-verify.py --write-files  # also rewrite `files`, `bytes`
                                                 # and `sha256` from the archives

Downloads are cached under tmp/mod-sources-cache/ (gitignored) and are only
ever read as data: zip and pak directories are parsed, nothing is executed.
Exit status is non-zero if any entry fails.
"""
import hashlib
import io
import json
import os
import struct
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "mods", "mod-sources.json")
CACHE = os.path.join(ROOT, "tmp", "mod-sources-cache")


def pak_entries(data):
    if data[:4] != b"PACK":
        raise ValueError("not a .pak")
    off, ln = struct.unpack("<ii", data[4:12])
    out = []
    for i in range(ln // 64):
        e = data[off + i * 64: off + i * 64 + 64]
        out.append(e[:56].split(b"\0")[0].decode("latin1"))
    return out


def fetch(url, sha):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, (sha or hashlib.sha256(url.encode()).hexdigest())[:24])
    if not os.path.exists(path):
        req = urllib.request.Request(url, headers={"User-Agent": "vkQuake-iOS mod-sources-verify"})
        with urllib.request.urlopen(req, timeout=120) as r, open(path + ".part", "wb") as f:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                f.write(b)
        os.rename(path + ".part", path)
    return open(path, "rb").read()


def installed_parts(entry, data):
    """[(rule_as, bytes)] for every file the install rules place."""
    parts = []
    if entry["type"] == "pak":
        for r in entry["install"]:
            parts.append((r["as"], data))
        return parts
    if entry["type"] == "file":
        # one loose file: the download IS the file; exactly one rule names its path
        rules = entry["install"]
        if len(rules) != 1 or rules[0].get("from", "") or rules[0]["as"] == "pak":
            raise ValueError("a file entry needs exactly one {\"as\": \"<game path>\"} rule")
        if rules[0]["as"].lower().endswith(".mdl") and data[:4] != b"IDPO":
            raise ValueError("%s is not an alias model (no IDPO magic)" % rules[0]["as"])
        return [(rules[0]["as"], data)]
    z = zipfile.ZipFile(io.BytesIO(data))
    names = {i.filename: i for i in z.infolist()}
    for r in entry["install"]:
        if r["from"] not in names:
            raise ValueError("install rule names %r, which is not in the archive" % r["from"])
        parts.append((r["as"], z.read(r["from"])))
    return parts


def main():
    write = "--write-files" in sys.argv
    table = json.load(open(TABLE))
    assert table.get("schema") == 1, "unknown schema"
    bad = 0
    for e in table["mods"]:
        name = e.get("name", e.get("gamedir"))
        try:
            data = fetch(e["url"], e.get("sha256"))
            sha = hashlib.sha256(data).hexdigest()
            if write:
                e["sha256"], e["bytes"] = sha, len(data)
            if sha != e.get("sha256"):
                raise ValueError("sha256 %s != table %s" % (sha, e.get("sha256")))
            if len(data) != e.get("bytes"):
                raise ValueError("size %d != table %s" % (len(data), e.get("bytes")))
            provides = set()
            for as_, blob in installed_parts(e, data):
                if as_ == "pak":
                    for n in pak_entries(blob):
                        if n.lower().endswith((".cfg", ".rc")):
                            raise ValueError("a .pak carries config %r (the client refuses it)" % n)
                        provides.add(n.lower())
                else:
                    provides.add(as_.lower())
            files = sorted(provides)
            if write:
                e["files"] = files
            elif files != sorted(f.lower() for f in e.get("files", [])):
                missing = set(files) ^ set(f.lower() for f in e.get("files", []))
                raise ValueError("files list differs from the archive (%d paths, e.g. %s)" % (len(missing), sorted(missing)[:3]))
            print("OK    %-40s %9d bytes  %4d files  %s" % (name, len(data), len(files), e["url"]))
        except Exception as ex:  # noqa: BLE001 — report every entry, then fail
            bad += 1
            print("FAIL  %-40s %s" % (name, ex))
    if write:
        with open(TABLE, "w") as f:
            json.dump(table, f, indent=1)
            f.write("\n")
        print("rewrote", TABLE)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
