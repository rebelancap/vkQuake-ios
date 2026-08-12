#!/usr/bin/env python3
"""sim-pixel-count.py — count pixels matching a named colour predicate in a
simulator screenshot, and say WHERE they are.

VR R5 exists partly because two rounds verified a crosshair as NUMBERS and
shipped it invisible. The rule that came out of that round is: a feature whose
whole job is to put pixels on a screen gets an assertion that reads pixels. This
is that assertion's instrument.

    sim-pixel-count.py <png> <predicate> [--min N] [--max N] [--region x0,y0,x1,y1]

Predicates (all in 0-255 sRGB, deliberately narrow so a brown Quake wall can
never satisfy one by accident):

  magenta   R>=140, B>=140, G <= 0.45*min(R,B)   — the crosshair's debug colour.
            Quake's palette has no colour in this region at all, so a nonzero
            count means our geometry and nothing else.
  flame     R>=190, 60<=G<=190, B<=80, R-B>=140  — id's baked muzzle-flash
            orange. Quake's brown world gets close on hue but not on the R-B
            spread at this saturation.

Exit status 0 when the count is inside [--min, --max] (both optional), 1
otherwise, and the count plus its bounding box always go to stdout so a failure
report carries the evidence rather than a verdict.

`--maxcell N` is the one that matters for the flame audit, and it exists because
the first run proved a raw count cannot tell "id's baked flash hanging beside the
player" from "e1m1 has torches in it": weapon 4 scored 380 flame pixels with a
bounding box spanning the ENTIRE 3840x2160 frame, which is scattered warm-brown
world and not a flame at all. A real baked-flash blob is COMPACT — hundreds of
pixels inside one 64x64 cell — so the frame is gridded and the busiest cell is
what gets asserted on. Scattered noise cannot reach a cell threshold; a flame
cannot avoid one.
"""
import sys
from PIL import Image

PREDS = {
    "magenta": lambda r, g, b: r >= 140 and b >= 140 and g <= 0.45 * min(r, b),
    "flame": lambda r, g, b: r >= 190 and 60 <= g <= 190 and b <= 80 and (r - b) >= 140,
    # VR R6.1 item 2 — the message panel's two inks, which are chosen colours and
    # not data-set colours (VKQVR.m rasterises the glyphs itself, using the
    # engine's conchars only as a coverage mask). That is what makes them
    # assertable: Quake's own palette is brown, grey and green, so near-pure white
    # and this particular warm gold are ours and nothing else's.
    #
    # The panel also paints a near-black plate behind the ink, which pushes the
    # scene's own contribution inside the panel's rectangle to almost nothing —
    # so the count is dominated by glyph coverage, and an absent message reads as
    # a collapse rather than as a smaller number.
    # MEASURED, not intended. The drawable is an sRGB format and Metal encodes
    # what the shell writes, so the gold ink VKQVR.m rasterises as (255,202,96)
    # reaches the screen as (255,230,165) — sRGB(0.792) = 0.903, sRGB(0.376) =
    # 0.645, exactly. The first version of this predicate was written from the
    # source constant and counted zero pixels of a message that was plainly on
    # screen in the artifact beside it. White is unaffected (255 encodes to 255),
    # which is the other reason the centerprint's ink is the primary assertion.
    "msgwhite": lambda r, g, b: r >= 225 and g >= 225 and b >= 225 and (max(r, g, b) - min(r, g, b)) <= 14,
    "msggold": lambda r, g, b: r >= 246 and 216 <= g <= 244 and 142 <= b <= 192 and (r - b) >= 55 and (r - g) >= 12,
}


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, pred = argv[1], argv[2]
    lo = hi = maxcell = None
    region = None
    i = 3
    while i < len(argv):
        if argv[i] == "--min":
            lo = int(argv[i + 1]); i += 2
        elif argv[i] == "--max":
            hi = int(argv[i + 1]); i += 2
        elif argv[i] == "--maxcell":
            maxcell = int(argv[i + 1]); i += 2
        elif argv[i] == "--region":
            region = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        else:
            print("unknown argument %s" % argv[i]); return 2
    if pred not in PREDS:
        print("unknown predicate %s (have: %s)" % (pred, ", ".join(PREDS)))
        return 2
    f = PREDS[pred]

    im = Image.open(path).convert("RGB")
    if region:
        im = im.crop(region)
    w, h = im.size
    px = im.load()
    n = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    CELL = 64
    cells = {}
    # Every 2nd pixel: a 3840x2160 screenshot is 8.3 MP and the features we look
    # for are tens of pixels across, so a 2x2 stride cannot miss one and the
    # whole check stays under a second.
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            if f(r, g, b):
                n += 1
                if x < x0: x0 = x
                if y < y0: y0 = y
                if x > x1: x1 = x
                if y > y1: y1 = y
                k = (x // CELL, y // CELL)
                cells[k] = cells.get(k, 0) + 1
    box = "none" if x1 < 0 else "(%d,%d)-(%d,%d)" % (x0, y0, x1, y1)
    peak, peakcell = (0, None)
    if cells:
        peakcell, peak = max(cells.items(), key=lambda kv: kv[1])
    peaktxt = "none" if peakcell is None else "%d in cell (%d,%d)" % (peak, peakcell[0] * CELL, peakcell[1] * CELL)
    print("   %s: %s pixels=%d (sampled 1-in-4) bbox=%s busiest %dx%d cell=%s of %dx%d"
          % (path.split("/")[-1], pred, n, box, CELL, CELL, peaktxt, w, h))
    ok = True
    if lo is not None and n < lo:
        ok = False
        print("   FAIL  expected at least %d %s pixels, got %d" % (lo, pred, n), file=sys.stderr)
    if hi is not None and n > hi:
        ok = False
        print("   FAIL  expected at most %d %s pixels, got %d (bbox %s)" % (hi, pred, n, box), file=sys.stderr)
    if maxcell is not None and peak > maxcell:
        ok = False
        print("   FAIL  a COMPACT %s blob is present: %s (limit %d per cell) — scattered world colour cannot do this"
              % (pred, peaktxt, maxcell), file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
