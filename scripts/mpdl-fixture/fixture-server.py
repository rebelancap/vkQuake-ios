#!/usr/bin/env python3
"""fixture-server.py — the two MP-DL1 download sources, locally, on one port.

Stands in for both real hosts so the simulator run is deterministic and offline:

  GET/HEAD /all/<map>.bsp   -> the bare-BSP mirror (maps.quakeworld.nu).
                               Only the maps actually staged under www/all are
                               served; everything else 404s, which is what drives
                               the client onto the package archive.
  GET      /api/?q=*        -> the Quaddicted ?q=* dump. SimpleHTTPRequestHandler
                               strips the query and would then serve a directory
                               listing, so /api is mapped explicitly to the JSON.
  GET/HEAD /pkg/<name>.zip  -> a package.

Port 18777 by argument. 8765-8769 are reserved by other sessions' console
bridges and must never be used here.
"""
import functools
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tmp", "mpdl-fixture", "www")


class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean.rstrip("/") == "/api":
            return os.path.join(ROOT, "api", "index.json")
        return super().translate_path(clean)

    def log_message(self, fmt, *args):
        sys.stderr.write("fixture %s %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18777
    handler = functools.partial(Handler, directory=ROOT)
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler)
    sys.stderr.write("fixture: serving %s on 127.0.0.1:%d\n" % (ROOT, port))
    sys.stderr.flush()
    srv.serve_forever()
