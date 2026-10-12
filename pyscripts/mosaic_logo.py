#!/usr/bin/env python3
"""
mosaic_logo.py  -  old-fashioned marble-mosaic letter logo generator (v2)

    python mosaic_logo.py F
    python mosaic_logo.py F --size 700            # one quick preview
    python mosaic_logo.py F --svg --seed 3
    python mosaic_logo.py F --circle              # round frame, transparent corners
    python mosaic_logo.py F --font /path/to/Font.ttf

Install:   pip install pillow shapely fonttools numpy

How it works (the "tiler's" way, not a picture-to-pixels trick):
  1. The letter is read as a real vector outline from the font.
  2. The outline is cleaned up (corners kept sharp, thin strokes thickened).
  3. Tiles are laid in courses that FOLLOW the outline: a light halo row,
     a black row and a charcoal row. Each straight side gets a whole number
     of tiles, stretched evenly, with mitred corners.
  4. The gold middle is a grid whose joints are lined up with the letter's
     straight edges, with edge tiles cut to fit and tiny slivers merged.
  5. The background is a "seigaiha" fan pattern: concentric rows of cut
     tiles in each scale, scales overlapping like roof shingles.
  6. A mitred frame (white / black / gold / black / grey) goes around it.
"""

import argparse
import math
import os
import random
import sys
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from shapely import affinity
from shapely.geometry import Point, Polygon, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.prepared import prep
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen

# ======================================================================
#  1. WHAT TO MAKE  -  edit this block
# ======================================================================

# One entry per logo file you want:  (name, width_px, height_px)
# Optional 4th item = per-file overrides, e.g.
#     ("floorpaper_icon", 512, 512, {"round": 0.18})   # rounded corners
#     ("floorpaper_icon", 96, 96,  {"detail": 2.0})    # chunkier tiles
OUTPUT_SPECS = [
    ("floorpaper_icon", 1024, 1024),
    ("floorpaper_icon", 512, 512),
    ("floorpaper_icon", 192, 192),
]

LETTER = "F"          # used when you don't type a letter on the command line
SEED = 7              # change it to get a different (but equally neat) shading
OUT_DIR = "mosaic_out"
EMIT_SVG = False      # also write .svg files

# Font: set FONT_PATH to any bold slab/serif .ttf/.otf you like.
# If None the script tries a cached download of "Bevan" (Clarendon-style, very
# 'old floor'), then common system serif fonts.
FONT_PATH = None
FONT_DOWNLOADS = [
    ("Bevan-Regular.ttf",
     "https://raw.githubusercontent.com/google/fonts/main/ofl/bevan/Bevan-Regular.ttf"),
    ("AlfaSlabOne-Regular.ttf",
     "https://raw.githubusercontent.com/google/fonts/main/ofl/alfaslabone/AlfaSlabOne-Regular.ttf"),
]
FONT_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mosaic_fonts")
FONT_SYSTEM = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
    "/System/Library/Fonts/Supplemental/Rockwell Bold.ttf",
    "C:/Windows/Fonts/georgiab.ttf",
    "C:/Windows/Fonts/rockb.ttf",
    "C:/Windows/Fonts/timesbd.ttf",
]

# ======================================================================
#  2. LOOK  -  all sizes are fractions of the SHORT side of the image
# ======================================================================
STYLE = dict(
    # ---- letter
    letter_height=0.74,     # letter height as a fraction of the inner field
    letter_max_width=0.80,  # ...but never wider than this fraction of the field
    letter_tracking=0.0,
    gold_tile=0.075,        # wanted gold tile size (snapped to fit the strokes)
    outline_black=0.0165,   # black outline row thickness
    outline_inner=0.0095,   # charcoal row inside the black one (0 = off)
    halo=0.0125,            # light row of tiles hugging the letter (0 = off)
    min_stroke_gold=0.032,  # thinnest allowed gold width (thickens skinny fonts)

    # ---- background fans
    fan_rings=6,            # tile rows in each scale
    fan_tile=0.0135,        # size of a background tile
    fan_row_step=0.5,       # vertical step between scale rows (x scale radius)

    # ---- frame (outside -> in)
    frame_outer=0.040,      # white/grey square ring
    frame_black=0.0145,     # black square ring
    frame_gold=0.0225,      # gold band
    frame_gold_len=0.075,   # gold tile length
    frame_black2=0.0105,    # thin black ring
    frame_line=0.0065,      # dark grey line

    # ---- general
    grout=0.0022,           # joint width
    min_tile_px=4.0,        # tiny icons automatically get chunkier tiles
    detail=1.0,             # manual multiplier on all tile sizes (>1 = chunkier)
    circle_rim=1.45,        # circle only: how much thicker the rim rings are
    shape="square",         # "square" or "circle" (circle: round frame, transparent corners)
    round=0.0,              # rounded image corners for the square shape (0.2 = very round)
    bevel=0.07,             # tile edge lighting, 0 = flat vector look
    ss=4,                   # anti-aliasing: draw at N x size and shrink
)

# ---- palette
GROUT = "#d9d6cf"
GOLD_DEEP = ("#e1a40f", "#dc9f0c", "#e4a81a")
GOLD_PALE = ("#ecc872", "#e8c064", "#efd084")
BLACKS = ("#111111", "#1a1a1a", "#262626", "#3a3a3a")
CHARCOAL = ("#3b3b3b", "#464646", "#2d2d2d", "#585858")
FIELD_LIGHT = ("#fbfbf9", "#f4f4f2", "#ececea", "#e3e3e0")
FIELD_GREY = ("#d4d4d1", "#c5c5c2", "#b4b4b1", "#a2a2a0")
FRAME_WHITES = ("#fcfcfb", "#f1f1ef", "#e4e4e2", "#d2d2d0", "#bcbcba", "#9f9f9d")
FRAME_WHITE_W = (34, 28, 20, 12, 4, 0)
FRAME_BLACKS = ("#0f0f0f", "#1b1b1b", "#333333", "#6a6a6a")
FRAME_BLACK_W = (50, 25, 15, 10)
FRAME_LINE = ("#555555", "#6b6b6b", "#444444")


# ======================================================================
#  small helpers
# ======================================================================
def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def shade(hexcol, rng, amt=0.03):
    r, g, b = hex2rgb(hexcol)
    f = 1.0 + rng.uniform(-amt, amt)
    return tuple(max(0, min(255, int(round(c * f)))) for c in (r, g, b))


def parts(geom):
    """Polygons inside any shapely geometry."""
    if geom is None or geom.is_empty:
        return []
    if geom.geom_type == "Polygon":
        return [geom]
    out = []
    for g in getattr(geom, "geoms", []):
        out += parts(g)
    return out


def mitre(g, d, limit=4.0):
    return g.buffer(d, join_style=2, mitre_limit=limit)


def add_poly(polys, geom, color, gw=0.0):
    """Shrink by half a grout joint and append every resulting piece."""
    for p in parts(geom):
        if gw > 0:
            p = p.buffer(-gw / 2.0, join_style=2, mitre_limit=2.5)
        for q in parts(p):
            if q.area > 0.05:
                polys.append((list(q.exterior.coords), color))


# ======================================================================
#  font -> shapely outline
# ======================================================================
class _FlatPen(BasePen):
    def __init__(self, glyphset):
        super().__init__(glyphset)
        self.contours, self._cur = [], None

    def _moveTo(self, p):
        self._cur = [p]

    def _lineTo(self, p):
        self._cur.append(p)

    def _curveToOne(self, p1, p2, p3):
        p0 = self._cur[-1]
        n = 16
        for i in range(1, n + 1):
            t = i / n
            a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
            self._cur.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                              a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))

    def _closePath(self):
        if self._cur and len(self._cur) > 2:
            self.contours.append(self._cur)
        self._cur = None

    _endPath = _closePath


def resolve_font(explicit):
    """Your font -> cached download -> fresh download -> common system fonts."""
    if explicit and os.path.exists(explicit):
        return explicit
    for fname, url in FONT_DOWNLOADS:
        path = os.path.join(FONT_CACHE, fname)
        if os.path.exists(path):
            return path
    for fname, url in FONT_DOWNLOADS:
        path = os.path.join(FONT_CACHE, fname)
        try:
            os.makedirs(FONT_CACHE, exist_ok=True)
            urllib.request.urlretrieve(url, path)
            return path
        except Exception:
            pass
    for p in FONT_SYSTEM:
        if os.path.exists(p):
            return p
    sys.exit("No usable font. Set FONT_PATH (or pass --font) to a bold serif .ttf.")


def glyph_geometry(text, font_path, tracking):
    """Vector outline of `text` in image coordinates (y down), units = font units."""
    font = TTFont(font_path, fontNumber=0)
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    upm = font["head"].unitsPerEm
    shapes, x = [], 0.0
    for ch in text:
        gname = cmap.get(ord(ch))
        if gname is None:
            sys.exit(f"Font has no glyph for {ch!r}")
        pen = _FlatPen(gs)
        gs[gname].draw(pen)
        rings = []
        for c in pen.contours:
            pts = [(px + x, -py) for px, py in c]
            rings.append(Polygon(pts).buffer(0))
        if rings:
            signed = []
            for c in pen.contours:
                a = 0.0
                for i in range(len(c)):
                    x0, y0 = c[i]
                    x1, y1 = c[(i + 1) % len(c)]
                    a += x0 * y1 - x1 * y0
                signed.append(a)
            big = signed[int(np.argmax(np.abs(signed)))]
            outers = [r for r, a in zip(rings, signed) if a * big > 0]
            holes = [r for r, a in zip(rings, signed) if a * big < 0]
            g = unary_union(outers)
            if holes:
                g = g.difference(unary_union(holes))
            shapes.append(g)
        x += gs[gname].width + tracking * upm * 0.7
    return unary_union(shapes), upm


def opening_radius(g, keep, hi):
    """Largest r so that opening the shape by r still keeps `keep` of its area."""
    lo, A = 0.0, g.area
    for _ in range(9):
        mid = (lo + hi) / 2
        op = mitre(mitre(g, -mid), mid)
        if op.area >= keep * A:
            lo = mid
        else:
            hi = mid
    return lo


def prepare_letter(text, font_path, field, S, k, m, fit_radius=None):
    """Fit the glyph in the field and tidy it so it can be tiled well."""
    g, upm = glyph_geometry(text, font_path, S["letter_tracking"])
    fx0, fy0, fx1, fy1 = field
    fw, fh = fx1 - fx0, fy1 - fy0
    minx, miny, maxx, maxy = g.bounds
    h0 = (maxy - miny)
    target_h = min(S["letter_height"] * fh, S["letter_max_width"] * fw * h0 / (maxx - minx))
    g = affinity.scale(g, target_h / h0, target_h / h0, origin=(minx, miny))

    bw, cw = S["outline_black"] * m * k, S["outline_inner"] * m * k
    halo = S["halo"] * m * k

    # tidy: close notches too narrow for the halo row, drop tiny jaggies,
    # keep corners sharp
    rc = max(0.004 * m, 0.9 * halo)
    g = mitre(mitre(g, rc), -rc).simplify(0.0007 * m)
    g = blunt_counters(g, 1.15 * (bw + cw))

    # thicken skinny strokes so there is room for the outline rows + gold
    w_min = 2 * (bw + cw) + S["min_stroke_gold"] * m * k
    r_thin = opening_radius(g, 0.93, 0.12 * m)
    need = w_min / 2 - r_thin
    if need > 0:
        g = mitre(g, min(need, 0.03 * m))

    # re-fit (emboldening grew it a little) and centre
    minx, miny, maxx, maxy = g.bounds
    s = min(target_h / (maxy - miny), S["letter_max_width"] * fw / (maxx - minx))
    g = affinity.scale(g, s, s, origin=((minx + maxx) / 2, (miny + maxy) / 2))
    minx, miny, maxx, maxy = g.bounds
    # optical centring: balance the bounding box against where the ink really is
    cx = 0.6 * (minx + maxx) / 2 + 0.4 * g.centroid.x
    g = affinity.translate(g, (fx0 + fx1) / 2 - cx,
                           (fy0 + fy1) / 2 - (miny + maxy) / 2 + 0.004 * fh)
    if fit_radius:      # round field: keep every corner of the letter inside the circle
        ccx, ccy = (fx0 + fx1) / 2, (fy0 + fy1) / 2
        far = max(math.hypot(x - ccx, y - ccy)
                  for p in parts(g) for x, y in p.exterior.coords)
        if far > fit_radius:
            f = fit_radius / far
            g = affinity.scale(g, f, f, origin=(ccx, ccy))
    return orient_all(g)


def blunt_counters(g, r):
    """Round off pointed counters (the hole in A, R, B...) so the necks stay thick
    enough to hold the outline rows. Counters that are too small simply close up."""
    out = []
    for p in parts(g):
        holes = []
        for h in p.interiors:
            hp = mitre(mitre(Polygon(h), -r), r)
            holes += [q for q in parts(hp) if q.area > 0.0]
        shell = Polygon(p.exterior)
        for q in holes:
            shell = shell.difference(q)
        out.append(shell)
    return unary_union(out)


def orient_all(g):
    return unary_union([orient(p, 1.0) for p in parts(g)])


# ======================================================================
#  contour-following courses (rows of tiles that hug an outline)
# ======================================================================
def course(ring_coords, d0, d1, tile_len, gw, pick, polys, corner_deg=32):
    """
    Lay one row of tiles along a ring between distance d0 and d1 from the edge.
    d > 0 is toward the inside of the letter, d < 0 outside.
    Tiles are spaced along the row's own centre-line, so each straight side gets
    a whole number of evenly stretched tiles. Dividers are square to the edge;
    only the corner tiles are mitred.
    """
    pts = np.array(ring_coords[:-1], dtype=float)
    keep = np.hypot(*(pts - np.roll(pts, 1, axis=0)).T) > 1e-7
    pts = pts[keep]
    n = len(pts)
    if n < 3:
        return
    dm = (d0 + d1) / 2.0
    e = np.roll(pts, -1, axis=0) - pts
    ln = np.hypot(e[:, 0], e[:, 1])
    t = e / ln[:, None]
    nr = np.stack([-t[:, 1], t[:, 0]], axis=1)       # left normal (= material side)
    pn = np.roll(nr, 1, axis=0)
    dot = (pn * nr).sum(1)
    turn = np.degrees(np.arccos(np.clip(dot, -1, 1)))
    mv = (pn + nr) / np.maximum(1 + dot, 0.05)[:, None]   # mitre vector
    A = pts + mv * d0
    B = pts + mv * d1
    Mid = (A + B) / 2
    corners = list(np.where(turn > corner_deg)[0]) or [0]
    runs = []
    for i, c in enumerate(corners):
        c2 = corners[(i + 1) % len(corners)]
        ids, j = [c], c
        while True:
            j = (j + 1) % n
            ids.append(j)
            if j == c2:
                break
        runs.append(ids)

    idx = 0
    for ids in runs:
        Mp = Mid[ids]
        seg = np.hypot(*(Mp[1:] - Mp[:-1]).T)
        # a run whose centre-line runs backwards has vanished at this offset
        fwd = np.einsum("ij,ij->i", Mp[1:] - Mp[:-1], t[ids[:-1]])
        if (fwd <= 0).any():
            continue
        cum = np.concatenate([[0], np.cumsum(seg)])
        L = cum[-1]
        if L < tile_len * 0.25:
            continue
        N = max(1, int(round(L / tile_len)))
        step = L / N
        Aa, Bb = A[ids], B[ids]
        eid = ids[:-1]

        def at(s):
            kk = int(np.clip(np.searchsorted(cum, s, side="right") - 1, 0, len(seg) - 1))
            tt = (s - cum[kk]) / max(seg[kk], 1e-9)
            if tt < 1e-6:
                return Aa[kk], Bb[kk]
            if tt > 1 - 1e-6:
                return Aa[kk + 1], Bb[kk + 1]
            pos = Mp[kk] + (Mp[kk + 1] - Mp[kk]) * tt
            nn = nr[eid[kk]]                       # square to the edge, not sheared
            return pos + nn * (d0 - dm), pos + nn * (d1 - dm)

        for q in range(N):
            sa, sb = q * step, (q + 1) * step
            a0, b0 = at(sa)
            a1, b1 = at(sb)
            mid = [kk for kk in range(len(cum)) if sa + 1e-6 < cum[kk] < sb - 1e-6]
            ach = [a0] + [Aa[kk] for kk in mid] + [a1]
            bch = [b0] + [Bb[kk] for kk in mid] + [b1]
            poly = Polygon([tuple(p) for p in ach] + [tuple(p) for p in bch[::-1]])
            if not poly.is_valid:
                poly = poly.buffer(0)
            add_poly(polys, poly, pick(idx), gw)
            idx += 1


def all_rings(geom):
    out = []
    for p in parts(geom):
        out.append(list(p.exterior.coords))
        for r in p.interiors:
            out.append(list(r.coords))
    return out


# ======================================================================
#  gold fill: a grid lined up with the letter's straight edges
# ======================================================================
def axis_edges(P, vertical, minlen):
    out = []
    for p in parts(P):
        for ring in [p.exterior] + list(p.interiors):
            c = np.array(ring.coords)
            d = c[1:] - c[:-1]
            ln = np.hypot(d[:, 0], d[:, 1])
            if vertical:
                ok = (np.abs(d[:, 0]) < 0.04 * ln) & (ln >= minlen)
                pos = (c[:-1, 0] + c[1:, 0]) / 2
            else:
                ok = (np.abs(d[:, 1]) < 0.04 * ln) & (ln >= minlen)
                pos = (c[:-1, 1] + c[1:, 1]) / 2
            out += list(zip(pos[ok], ln[ok]))
    return out


def grid_lines(edges, lo, hi, tile):
    """
    Grid lines for one axis. Every long straight edge of the shape becomes a
    grid line; between neighbouring ones the space is divided into a whole
    number of equal rows, so each stroke gets evenly sized tiles.
    """
    cl = []
    for pos, ln in sorted(edges):
        if cl and pos - cl[-1][0] / cl[-1][1] < 0.14 * tile:
            cl[-1][0] += pos * ln
            cl[-1][1] += ln
        else:
            cl.append([pos * ln, ln])
    keys = [(p / w, w) for p, w in cl if w >= 0.9 * tile]
    keys = [(lo, 1e9)] + [k for k in keys if lo + 0.3 * tile < k[0] < hi - 0.3 * tile] + [(hi, 1e9)]
    # keys that sit too close together: keep the one backed by more edge length
    out = [keys[0]]
    for kpos, w in keys[1:]:
        if kpos - out[-1][0] < 0.6 * tile:
            if w > out[-1][1] and len(out) > 1:
                out[-1] = (kpos, w)
            elif w >= 1e9:
                out[-1] = (kpos, w)
            continue
        out.append((kpos, w))
    xs = [out[0][0]]
    for (a, _), (b, _) in zip(out[:-1], out[1:]):
        r = (b - a) / tile
        lo_n = max(1, int(math.floor(r)))
        nn = lo_n if abs(math.log(r / lo_n)) <= abs(math.log(r / (lo_n + 1))) else lo_n + 1
        xs += [a + (b - a) * i / nn for i in range(1, nn + 1)]
    return xs


def gold_fill(P, tile, gw, rng, polys):
    if P.is_empty:
        return
    minx, miny, maxx, maxy = P.bounds
    minlen = 0.7 * tile
    xs = grid_lines(axis_edges(P, True, minlen), minx, maxx, tile)
    ys = grid_lines(axis_edges(P, False, minlen), miny, maxy, tile)
    pp = prep(P)
    pieces = {}
    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cell = box(xs[i], ys[j], xs[i + 1], ys[j + 1])
            if not pp.intersects(cell):
                continue
            nom = (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
            for n, g in enumerate(parts(cell.intersection(P))):
                if g.area > 0.01 * nom:
                    pieces[(i, j, n)] = (g, nom)

    # merge slivers into a neighbour, drop crumbs
    eps = 0.01 * tile
    for key in sorted(pieces, key=lambda q: pieces[q][0].area / pieces[q][1]):
        if key not in pieces:
            continue
        g, nom = pieces[key]
        if g.area >= 0.40 * nom:
            continue
        i, j, _ = key
        best, bs = None, 0.0
        for nk, (o, onom) in pieces.items():
            if nk == key or abs(nk[0] - i) + abs(nk[1] - j) != 1:
                continue
            sc = g.buffer(eps).intersection(o.buffer(eps)).area
            if sc > bs and g.area + o.area < 1.6 * onom:
                best, bs = nk, sc
        if best is not None and bs > eps * eps * 10:
            o, onom = pieces[best]
            merged = unary_union([g.buffer(eps), o.buffer(eps)]).buffer(-eps)
            if merged.geom_type == "Polygon":
                pieces[best] = (merged, onom)
                del pieces[key]
                continue
        if g.area < 0.16 * nom:
            del pieces[key]

    pale = {}
    for (i, j, n) in sorted(pieces, key=lambda q: (q[1], q[0])):
        left, up = pale.get((i - 1, j), False), pale.get((i, j - 1), False)
        is_pale = (not left and not up and rng.random() < 0.26)
        pale[(i, j)] = is_pale
        pal = GOLD_PALE if is_pale else GOLD_DEEP
        add_poly(polys, pieces[(i, j, n)][0], shade(rng.choice(pal), rng, 0.02), gw)


# ======================================================================
#  background: seigaiha fans
# ======================================================================
def fan_field(field, S, m, k, gw, allowed, rng, polys):
    fx0, fy0, fx1, fy1 = field
    fw = fx1 - fx0
    rings = S["fan_rings"]
    R0 = rings * S["fan_tile"] * m * k
    cols = max(2, int(round(fw / (2 * R0))))
    R = fw / (2 * cols)
    t = R / rings
    dy = S["fan_row_step"] * R
    nrows = int(math.ceil((fy1 - fy0) / dy)) + 6
    circles = []
    for j in range(-4, nrows):
        yc = fy0 + R + j * dy
        if j % 2 == 0:
            xs = [fx0 + R + 2 * R * i for i in range(-1, cols + 1)]
        else:
            xs = [fx0 + 2 * R * i for i in range(-1, cols + 2)]
        for x in xs:
            circles.append((j, x, yc))
    pa = prep(allowed)
    field_box = box(fx0, fy0, fx1, fy1)
    cull = {}
    for idx, (j, cx, cy) in enumerate(circles):
        cull[idx] = [(c2x, c2y) for (j2, c2x, c2y) in circles
                     if j2 > j and (c2x - cx) ** 2 + (c2y - cy) ** 2 < (2 * R) ** 2]
    for idx, (j, cx, cy) in enumerate(circles):
        if cy + R < fy0 or cy - R > fy1 or cx + R < fx0 or cx - R > fx1:
            continue
        tone = rng.choice((-1, 0, 0, 1))
        # grout backing disc hides what the scale in front overlaps
        disc = [(cx + R * math.cos(a), cy + R * math.sin(a))
                for a in np.linspace(0, 2 * math.pi, 120, endpoint=False)]
        polys.append((disc, hex2rgb(GROUT)))
        later = cull[idx]
        for ring in range(rings):
            r1, r0 = R - ring * t, R - (ring + 1) * t
            rm = (r0 + r1) / 2
            n = max(6, int(round(2 * math.pi * rm / (t * 1.08))))
            phase = 0.5 * (ring % 2) + 0.17 * ((idx * 7) % 3)
            for q in range(n):
                a0 = (q + phase) * 2 * math.pi / n
                a1 = a0 + 2 * math.pi / n
                da0 = (gw / 2) / max(rm, t * 0.5)
                aa0, aa1 = a0 + da0, a1 - da0
                ro, ri = r1 - gw / 2, max(r0 + gw / 2, 0.0)
                steps = max(2, int(math.ceil((aa1 - aa0) / 0.10)))
                outer = [(cx + ro * math.cos(a), cy + ro * math.sin(a))
                         for a in np.linspace(aa0, aa1, steps + 1)]
                if r0 <= 1e-6:
                    inner = [(cx, cy)]
                else:
                    inner = [(cx + ri * math.cos(a), cy + ri * math.sin(a))
                             for a in np.linspace(aa1, aa0, steps + 1)]
                tile = outer + inner
                # skip tiles completely hidden by later scales
                mx = sum(p[0] for p in tile) / len(tile)
                my = sum(p[1] for p in tile) / len(tile)
                rad = max(math.hypot(p[0] - mx, p[1] - my) for p in tile)
                if any(math.hypot(mx - lx, my - ly) + rad < R - gw for lx, ly in later):
                    continue
                if mx + rad < fx0 or mx - rad > fx1 or my + rad < fy0 or my - rad > fy1:
                    continue
                poly = Polygon(tile)
                if not poly.is_valid:
                    poly = poly.buffer(0)
                if not pa.contains(poly):
                    if not pa.intersects(poly):
                        continue
                    nominal = t * t
                    cut = poly.intersection(allowed)
                    cut = unary_union([g for g in parts(cut) if g.area > 0.14 * nominal])
                    if cut.is_empty:
                        continue
                    poly = cut
                # colour: every scale has a slightly greyer rim (reads as shingled
                # fans from afar); the middle stays white. A slow diagonal drift
                # makes some regions a touch greyer, like real stone batches.
                drift = 0.07 * math.sin((cx * 0.9 + cy * 1.7) / (m * 0.22))
                p_rim = (0.62, 0.22, 0.08)[min(ring, 2)] + drift + 0.06 * tone
                if rng.random() < p_rim:
                    col = FIELD_GREY[0] if rng.random() < 0.62 else FIELD_GREY[1]
                    if ring >= 2 and rng.random() < 0.15:
                        col = FIELD_GREY[2]
                else:
                    col = rng.choice(FIELD_LIGHT)
                for g in parts(poly):
                    polys.append((list(g.exterior.coords), shade(col, rng, 0.015)))


# ======================================================================
#  frame
# ======================================================================
def frame_band(polys, W, H, off, th, tile_len, pick, gw, square_corners=True):
    """One rectangular ring of tiles at `off` from the edge, `th` thick, mitred corners."""
    x0, y0, x1, y1 = off, off, W - off, H - off
    idx = [0]

    def put(rx0, ry0, rx1, ry1):
        polys.append((rect(rx0 + gw / 2, ry0 + gw / 2, rx1 - gw / 2, ry1 - gw / 2),
                      pick(idx[0])))
        idx[0] += 1

    # corners
    for cx0, cy0 in ((x0, y0), (x1 - th, y0), (x0, y1 - th), (x1 - th, y1 - th)):
        put(cx0, cy0, cx0 + th, cy0 + th)
    # sides: whole number of evenly stretched tiles
    nx = max(1, int(round((x1 - x0 - 2 * th) / tile_len)))
    sx = (x1 - x0 - 2 * th) / nx
    for q in range(nx):
        xa = x0 + th + q * sx
        put(xa, y0, xa + sx, y0 + th)
        put(xa, y1 - th, xa + sx, y1)
    ny = max(1, int(round((y1 - y0 - 2 * th) / tile_len)))
    sy = (y1 - y0 - 2 * th) / ny
    for q in range(ny):
        ya = y0 + th + q * sy
        put(x0, ya, x0 + th, ya + sy)
        put(x1 - th, ya, x1, ya + sy)


def ring_band(polys, cx, cy, r_out, th, tile_len, pick, gw):
    """One circular ring of tiles, outer radius r_out, thickness th."""
    r_in = r_out - th
    rm = (r_out + r_in) / 2
    n = max(8, int(round(2 * math.pi * rm / tile_len)))
    step = 2 * math.pi / n
    for q in range(n):
        a0 = -math.pi / 2 - step / 2 + q * step
        a1 = a0 + step
        ro, ri = r_out - gw / 2, r_in + gw / 2
        da_o, da_i = (gw / 2) / ro, (gw / 2) / max(ri, 1e-6)
        steps = max(2, int(math.ceil(step / 0.08)))
        outer = [(cx + ro * math.cos(a), cy + ro * math.sin(a))
                 for a in np.linspace(a0 + da_o, a1 - da_o, steps + 1)]
        inner = [(cx + ri * math.cos(a), cy + ri * math.sin(a))
                 for a in np.linspace(a1 - da_i, a0 + da_i, steps + 1)]
        polys.append((outer + inner, pick(q)))


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def weighted(rng, items, weights):
    return rng.choices(items, weights=weights, k=1)[0]


# ======================================================================
#  put it all together
# ======================================================================
def build_logo(text, W, H, font_path, seed, S):
    rng = random.Random(seed)
    m = min(W, H)
    # tiny icons: make every tile chunkier so they stay readable
    k = max(S["detail"], S["min_tile_px"] / (S["fan_tile"] * m), 1.0)
    gw = max(0.9, S["grout"] * m * (1 + 0.35 * (k - 1)))
    polys = []

    # ---- frame geometry
    circle = S["shape"] == "circle"
    bands = [
        ("outer", S["frame_outer"] * m * k, S["frame_outer"] * m * k),
        ("black", S["frame_black"] * m * k, S["frame_black"] * m * k),
        ("gold", S["frame_gold"] * m * k, S["frame_gold_len"] * m * k),
        ("black2", S["frame_black2"] * m * k, S["frame_black2"] * m * k),
        ("line", S["frame_line"] * m * k, 0.05 * m * k),
    ]
    if circle:      # the white square ring only makes sense on a square image
        bands = [(n_, t_ * S["circle_rim"], l_ * S["circle_rim"]) for n_, t_, l_ in bands[1:]]
    off = 0.0
    frame_jobs = []
    for name, th, tl in bands:
        frame_jobs.append((name, off, th, tl))
        off += th
    pad = gw / 2
    ccx, ccy = W / 2.0, H / 2.0
    if circle:
        Rc = m / 2.0
        Rf = Rc - off - pad
        field = (ccx - Rf, ccy - Rf, ccx + Rf, ccy + Rf)
        field_shape = Point(ccx, ccy).buffer(Rf, 128)
    else:
        field = (off + pad, off + pad, W - off - pad, H - off - pad)
        field_shape = box(*field)

    # ---- letter (outline courses + gold)
    G = prepare_letter(text, font_path, field, S, k, m, fit_radius=(0.80 * Rf if circle else None))
    halo_w = S["halo"] * m * k
    bw = S["outline_black"] * m * k
    cw_ = S["outline_inner"] * m * k
    keepout = mitre(G, halo_w + gw)
    allowed = field_shape.difference(keepout)

    # ---- background fans (first, everything else sits on top)
    fan_field(field, S, m, k, gw, allowed, rng, polys)

    # ---- frame
    def pick_outer(i):
        return shade(weighted(rng, FRAME_WHITES, FRAME_WHITE_W), rng, 0.01)

    def pick_black(i):
        return shade(weighted(rng, FRAME_BLACKS, FRAME_BLACK_W), rng, 0.02)

    def pick_gold(i):
        pal = GOLD_PALE if (i % 2 == 1 and rng.random() < 0.55) else GOLD_DEEP
        return shade(rng.choice(pal), rng, 0.02)

    def pick_line(i):
        return shade(rng.choice(FRAME_LINE), rng, 0.02)

    picks = dict(outer=pick_outer, black=pick_black, gold=pick_gold,
                 black2=pick_black, line=pick_line)
    for name, o, th, tl in frame_jobs:
        if circle:
            ring_band(polys, ccx, ccy, Rc - o, th, tl, picks[name], gw)
        else:
            frame_band(polys, W, H, o, th, tl, picks[name], gw)

    # ---- letter courses
    def pick_halo(i):
        pool = FIELD_GREY[:2] if rng.random() < 0.12 else FIELD_LIGHT[:3]
        return shade(rng.choice(pool), rng, 0.012)

    def pick_b(i):
        return shade(weighted(rng, BLACKS, (60, 20, 14, 6)), rng, 0.02)

    def pick_c(i):
        return shade(rng.choice(CHARCOAL), rng, 0.02)

    rings = all_rings(G)
    for r in rings:
        if halo_w > 0:
            course(r, -halo_w, 0.0, halo_w * 1.15, gw, pick_halo, polys)
        course(r, 0.0, bw, bw * 1.05, gw, pick_b, polys)
        if cw_ > 0:
            course(r, bw, bw + cw_, cw_ * 1.45, gw, pick_c, polys)
    inner = mitre(G, -(bw + cw_), 8.0)
    tile = S["gold_tile"] * m * k
    if not inner.is_empty:
        gold_fill(inner, tile, gw, rng, polys)
    return polys


# ======================================================================
#  output
# ======================================================================
def add_bevel(img, ss, amount):
    """Light from the top-left: lit top/left tile edges, shaded bottom/right edges."""
    a = np.asarray(img).astype(np.float32)
    g = np.array(hex2rgb(GROUT), dtype=np.float32)
    grout = (np.abs(a - g).max(axis=2) < 0.5).astype(np.float32)
    d = max(1, int(round(0.9 * ss)))

    def shifted(m, dy, dx):
        out = np.zeros_like(m)
        h, w = m.shape
        ys, yd = (slice(dy, h), slice(0, h - dy)) if dy >= 0 else (slice(0, h + dy), slice(-dy, h))
        xs, xd = (slice(dx, w), slice(0, w - dx)) if dx >= 0 else (slice(0, w + dx), slice(-dx, w))
        out[ys, xs] = m[yd, xd]
        return out

    # grout pushed down-right lights the tile pixels just below/right of it
    lit = shifted(grout, d, d) * (1 - grout)
    dark = shifted(grout, -d, -d) * (1 - grout)
    lit_img = Image.fromarray((lit * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(d * 0.6))
    dark_img = Image.fromarray((dark * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(d * 0.6))
    lit = np.asarray(lit_img).astype(np.float32)[..., None] / 255.0
    dark = np.asarray(dark_img).astype(np.float32)[..., None] / 255.0
    nongrout = (1 - grout)[..., None]
    a = a * (1 + amount * 1.4 * lit * nongrout - amount * 1.6 * dark * nongrout)
    a = np.where(a > 255, 255, a)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def render_png(polys, W, H, S, path):
    # keep memory sane: big images get less supersampling
    big = max(W, H)
    ss = S["ss"] if big <= 700 else (3 if big <= 1400 else 2)
    ss = min(ss, S["ss"])
    img = Image.new("RGB", (W * ss, H * ss), hex2rgb(GROUT))
    d = ImageDraw.Draw(img)
    for pts, col in polys:
        d.polygon([(x * ss, y * ss) for x, y in pts], fill=tuple(col))
    if S["bevel"] > 0:
        img = add_bevel(img, ss, S["bevel"])
    out = img.resize((W, H), Image.BOX)
    if S["shape"] == "circle":
        r = min(W, H) / 2.0
        mask = Image.new("L", (W * 4, H * 4), 0)
        ImageDraw.Draw(mask).ellipse(((W / 2 - r) * 4, (H / 2 - r) * 4,
                                      (W / 2 + r) * 4 - 1, (H / 2 + r) * 4 - 1), fill=255)
        out = out.convert("RGBA")
        out.putalpha(mask.resize((W, H), Image.LANCZOS))
    elif S["round"] > 0:
        r = int(S["round"] * min(W, H))
        mask = Image.new("L", (W * 4, H * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, W * 4 - 1, H * 4 - 1), r * 4, fill=255)
        out = out.convert("RGBA")
        out.putalpha(mask.resize((W, H), Image.LANCZOS))
    out.save(path)


def render_svg(polys, W, H, path, S):
    parts_ = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
              f'viewBox="0 0 {W} {H}">']
    if S["shape"] == "circle":
        parts_.append(f'<clipPath id="c"><circle cx="{W/2}" cy="{H/2}" r="{min(W, H)/2}"/></clipPath>'
                      '<g clip-path="url(#c)">')
    parts_.append(f'<rect width="{W}" height="{H}" fill="{GROUT}"/>')
    for pts, col in polys:
        s = " ".join(f"{x:.2f},{y:.2f}" for x, y in pts)
        parts_.append(f'<polygon points="{s}" fill="rgb{tuple(col)}"/>')
    if S["shape"] == "circle":
        parts_.append("</g>")
    parts_.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(parts_))


def main():
    ap = argparse.ArgumentParser(description="Mosaic letter logo generator")
    ap.add_argument("letter", nargs="?", default=LETTER)
    ap.add_argument("--outdir", default=OUT_DIR)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--font", default=FONT_PATH)
    ap.add_argument("--svg", action="store_true", default=EMIT_SVG)
    ap.add_argument("--circle", action="store_true", help="round frame instead of square")
    ap.add_argument("--size", type=int, help="render just one square preview of this size")
    a = ap.parse_args()

    if len(a.letter) > 1:
        print(f"Only one letter is supported - using {a.letter[0]!r}.")
        a.letter = a.letter[0]
    font = resolve_font(a.font)
    print("font:", font)
    os.makedirs(a.outdir, exist_ok=True)
    specs = [("preview", a.size, a.size)] if a.size else OUTPUT_SPECS
    for spec in specs:
        name, w, h = spec[:3]
        S = dict(STYLE)
        if a.circle:
            S["shape"] = "circle"
        if len(spec) > 3:
            S.update(spec[3])
        polys = build_logo(a.letter, w, h, font, a.seed, S)
        tag = "_circle" if S["shape"] == "circle" else ""
        base = os.path.join(a.outdir, f"{name}_{a.letter}{tag}_{w}x{h}")
        render_png(polys, w, h, S, base + ".png")
        print("wrote", base + ".png")
        if a.svg:
            render_svg(polys, w, h, base + ".svg", S)
            print("wrote", base + ".svg")


if __name__ == "__main__":
    main()