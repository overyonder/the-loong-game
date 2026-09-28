"""Generate symmetric maps that look like the official ones, for held-out evaluation.

    just mapgen --count 20 --seed 2026            # maps-generated/
    just mapgen --count 4 --style labyrinth --output DIR
    just mapgen --check maps-generated

Inputs: a seed and optional world settings. Outputs: `gen_<seed>_<nn>.map` files
in `--output`, one summary per map on stdout. `--check DIR` writes nothing and
reports each map in DIR that falls outside the official envelope. The envelope
is read from `maps/`, the organiser's maps as `unswbc maps` installs them.

The generator is xCirno's layered world generator
(https://gist.github.com/xCirno1/ffdaac4236c1f1085c351af4fdfc1600), posted as
[Stockfish]xCirno in the competition Discord. It builds each map in stages that
read what the earlier ones decided:

  1. canvas     size, symmetry and a closed or wrapping border, picked from
                the shapes the official maps use (32x16, 48x24, 25x35, 63x27...)
  2. climate    two periodic fBm noise fields, elevation and fertility,
                symmetrised so both teams get the same world
  3. districts  camps (spawn points) and a heart on the symmetry axis are
                seeded first. Poisson-disk seeds fill the rest, and each tile
                joins its nearest seed under domain warping, giving organic
                regions
  4. biomes     each district's role (camp / heart / frontier / home) and
                climate pick its biome: open sea, meadow, reef, ruins, caves
                (cellular automata), maze (braided DFS), vault
  5. landmark   one map-scale structure, planned before the camps so they
                settle round it: a citadel (concentric curtain walls), a
                great labyrinth or 1-wide warren, a palace, a walled city,
                a serpent hall (diagonal lanes, as Slithery Fight), a great
                wall, parallel lanes (Devil), line-art effigies with crowns
                and words (Schooltime, Queen of Spades, Help) or a portal
                lattice (Portals)
     borders    walls between districts depend on both biomes, with gates
                in them
  6. structures the heart vault (room / keep / cross / garden), spiral and
                zig-zag nests the first dragon starts coiled in, buildings
                by biome (rooms, BSP complexes, cloisters, stalls,
                colonnades, 2-wide or 1-wide labyrinths, ramparts,
                stockades), elevation ridges, portal shrines (sealed boxes
                reached only by portal, like Portals), wormholes across the
                axis, pearl groves on fertility peaks, food near the camps
  7. repair     every pocket gets a door into the main component, so no
                dragon is born into a sealed hole and no pearl is wasted
  8. economy    one gap palette per map (hot / rich / fair / background,
                like the official maps' few gap classes), scaled to a pearl
                supply per round that suits the dragon count
  9. spawns     dragons coil out of each camp, heads pointing at the enemy,
                with exits checked and enemy heads kept apart
 10. judge      N candidates are scored on contested supply, meeting
                distance, detours, dead ends, early food and portal use.
                The best one is written

Every write goes through a symmetric setter, so the map is exactly symmetric
by construction, and a final self-check verifies it.

Our additions widen it to the official maps' variety and bound it by them:
the 11x11, 16x8 and 64x64 shapes and a quarter of sizes drawn freely, a
pearl supply from a third of a pearl to twelve per dragon per round,
background spawns on every live tile in some worlds, palettes folded to one
or two gap classes, an open style with no buildings (as Big Empty, Help and
Colosseum), and the envelope: a candidate is kept only if every
measure in `ENVELOPE_MEASURES` lies within the range the official maps span.
"""

import math
import random
import statistics
from collections import deque
from dataclasses import dataclass, fields
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = Path("maps-generated")
# The organiser's maps, as `unswbc maps` installs them beside the article bots.
OFFICIAL_MAPS = Path("maps")

DIRS = "NESW"
DX = {"N": 0, "E": 1, "S": 0, "W": -1}
DY = {"N": -1, "E": 0, "S": 1, "W": 0}
OPP = {"N": "S", "S": "N", "E": "W", "W": "E"}

# ------------------------------------------------------------------ canvas


class Canvas:
    """Tiles, edges and portals of one map. Every mutation is symmetric.

    Edges: ('h', x, y) is the north side of tile (x, y); ('v', x, y) the
    west side. Kinds: 0 open, 1 kelp, 2 portal (engine convention)."""

    def __init__(self, w, h, sym, closed):
        self.w, self.h, self.sym, self.closed = w, h, sym, closed
        self.kind = {}
        self.pid = {}
        self.partner = {}
        self.npid = 0
        self.solid = set()
        self.tiles = [(x, y) for y in range(h) for x in range(w)]
        if closed:
            for x in range(w):
                self.put(("h", x, 0), 1, force=True)
            for y in range(h):
                self.put(("v", 0, y), 1, force=True)

    # --- symmetry
    def m(self, t):
        x, y = t
        if self.sym == "y":
            return (self.w - 1 - x, y)
        if self.sym == "x":
            return (x, self.h - 1 - y)
        return (self.w - 1 - x, self.h - 1 - y)

    def mf(self, p):
        """Mirror of a float point (district seeds may sit on the axis)."""
        x, y = p
        if self.sym == "y":
            return (self.w - 1 - x, y)
        if self.sym == "x":
            return (x, self.h - 1 - y)
        return (self.w - 1 - x, self.h - 1 - y)

    def me(self, e):
        o, x, y = e
        w, h = self.w, self.h
        if o == "h":
            if self.sym == "y":
                return ("h", w - 1 - x, y)
            if self.sym == "x":
                return ("h", x, (h - y) % h)
            return ("h", w - 1 - x, (h - y) % h)
        if self.sym == "y":
            return ("v", (w - x) % w, y)
        if self.sym == "x":
            return ("v", x, h - 1 - y)
        return ("v", (w - x) % w, h - 1 - y)

    def is_canon(self, t):
        return t <= self.m(t)

    # --- geometry
    def nb(self, t, d):
        return ((t[0] + DX[d]) % self.w, (t[1] + DY[d]) % self.h)

    def edge(self, t, d):
        x, y = t
        if d == "N":
            return ("h", x, y)
        if d == "S":
            return ("h", x, (y + 1) % self.h)
        if d == "W":
            return ("v", x, y)
        return ("v", (x + 1) % self.w, y)

    def sides(self, e):
        o, x, y = e
        if o == "h":
            return (x, (y - 1) % self.h), (x, y)
        return ((x - 1) % self.w, y), (x, y)

    def is_border(self, e):
        return self.closed and (
            (e[0] == "h" and e[2] == 0) or (e[0] == "v" and e[1] == 0)
        )

    def dist(self, a, b):
        dx, dy = abs(a[0] - b[0]), abs(a[1] - b[1])
        if not self.closed:
            dx, dy = min(dx, self.w - dx), min(dy, self.h - dy)
        return math.hypot(dx, dy)

    # --- mutation (always symmetric)
    def put(self, e, k, force=False):
        me = self.me(e)
        for x in (e,) if me == e else (e, me):  # ordered: a set of str tuples is not
            if self.kind.get(x, 0) == 2:
                continue  # never overwrite a portal
            if not force and self.is_border(x):
                continue  # the border stays shut
            if k:
                self.kind[x] = k
            else:
                self.kind.pop(x, None)

    def link(self, e1, e2):
        """Portal pair e1<->e2 plus its mirror pair. False if illegal."""
        if e1[0] != e2[0] or e1 == e2:
            return False
        m1, m2 = self.me(e1), self.me(e2)
        if m1 == e1 or m2 == e2:
            return False  # never on the symmetry line
        pairs = [(e1, e2)] if {m1, m2} == {e1, e2} else [(e1, e2), (m1, m2)]
        used = {e for p in pairs for e in p}
        if len(used) != 2 * len(pairs) or any(
            self.kind.get(e, 0) == 2 or self.is_border(e) for e in used
        ):
            return False
        for a, b in pairs:
            for e in (a, b):
                self.kind[e] = 2
                self.pid[e] = self.npid
            self.partner[a], self.partner[b] = b, a
            self.npid += 1
        return True

    def make_solid(self, t):
        for s in {t, self.m(t)}:
            self.solid.add(s)
        for s in {t, self.m(t)}:
            for d in DIRS:
                if self.nb(s, d) not in self.solid:
                    self.put(self.edge(s, d), 1)

    def post(self, v, arm=1):
        """A pillar: a cross of kelp round the vertex v (the north-west corner
        of tile v). It blocks the way between the four tiles round it and
        encloses none of them, so it never reads as a sealed room."""
        x, y = v
        for k in range(arm):
            for e in (
                ("h", (x - 1 - k) % self.w, y),
                ("h", (x + k) % self.w, y),
                ("v", x, (y - 1 - k) % self.h),
                ("v", x, (y + k) % self.h),
            ):
                self.put(e, 1)

    def verts(self, e):
        o, x, y = e
        if o == "h":
            return ((x, y), ((x + 1) % self.w, y))
        return ((x, y), (x, (y + 1) % self.h))

    def chains(self, edges):
        """Split edges into runs that touch end to end, each in walking order,
        so a wall can be drawn along its length with gates in it."""
        byv = {}
        for e in edges:
            for v in self.verts(e):
                byv.setdefault(v, []).append(e)
        left = set(edges)
        out = []
        while left:
            start = min(
                left, key=lambda e: (sum(len(byv[v]) for v in self.verts(e)), e)
            )
            chain, stack = [], [start]
            while stack:
                e = stack.pop()
                if e not in left:
                    continue
                left.discard(e)
                chain.append(e)
                stack.extend(
                    sorted(f for v in self.verts(e) for f in byv[v] if f in left)
                )
            out.append(chain)
        return out

    def tidy(self):
        """Kelp between two rock tiles is invisible and meaningless: drop it."""
        for e in list(self.kind):
            a, b = self.sides(e)
            if (
                self.kind[e] == 1
                and a in self.solid
                and b in self.solid
                and not self.is_border(e)
            ):
                del self.kind[e]

    def enclose(self, tiles):
        ts = set(tiles)
        for t in ts:
            for d in DIRS:
                if self.nb(t, d) not in ts:
                    self.put(self.edge(t, d), 1)

    # --- movement (mirrors engine.resolve)
    def step(self, t, d):
        e = self.edge(t, d)
        k = self.kind.get(e, 0)
        if k == 1:
            return None
        if k == 2:
            o, px, py = self.partner[e]
            if o == "h":
                n = (px, py) if d == "S" else (px, (py - 1) % self.h)
            else:
                n = (px, py) if d == "E" else ((px - 1) % self.w, py)
        else:
            n = self.nb(t, d)
        return None if n in self.solid else n

    def bfs(self, sources, portals=True, block=()):
        dist = {}
        dq = deque()
        for s in sources:
            if s not in dist:
                dist[s] = 0
                dq.append(s)
        while dq:
            t = dq.popleft()
            for d in DIRS:
                if not portals and self.kind.get(self.edge(t, d), 0) == 2:
                    n = self.nb(t, d)
                    if n in self.solid:
                        continue
                else:
                    n = self.step(t, d)
                if n is None or n in dist or n in block:
                    continue
                dist[n] = dist[t] + 1
                dq.append(n)
        return dist

    def exits(self, t, block=()):
        return sum(
            1 for d in DIRS if (n := self.step(t, d)) is not None and n not in block
        )


# ------------------------------------------------------------------ noise


class ValueNoise:
    """Periodic value noise: tiles the torus exactly, so wrap maps have no seam."""

    def __init__(self, rng, w, h, cell):
        self.gx = max(1, round(w / cell))
        self.gy = max(1, round(h / cell))
        self.w, self.h = w, h
        self.v = [[rng.random() for _ in range(self.gx)] for _ in range(self.gy)]

    def at(self, x, y):
        u = x / self.w * self.gx
        v = y / self.h * self.gy
        i, j = math.floor(u), math.floor(v)
        fu, fv = u - i, v - j
        fu, fv = fu * fu * (3 - 2 * fu), fv * fv * (3 - 2 * fv)
        i0, i1 = i % self.gx, (i + 1) % self.gx
        j0, j1 = j % self.gy, (j + 1) % self.gy
        a = self.v[j0][i0] + (self.v[j0][i1] - self.v[j0][i0]) * fu
        b = self.v[j1][i0] + (self.v[j1][i1] - self.v[j1][i0]) * fu
        return a + (b - a) * fv


def field(cv, rng, cell, octaves=3):
    """Symmetric fBm field over the tiles, equalised to ranks in [0, 1]."""
    layers = [
        ValueNoise(rng, cv.w, cv.h, max(2.0, cell / (2**o))) for o in range(octaves)
    ]

    def raw(t):
        return sum(layer.at(*t) * 0.5**o for o, layer in enumerate(layers))

    vals = {t: raw(t) + raw(cv.m(t)) for t in cv.tiles}
    order = sorted(cv.tiles, key=lambda t: (vals[t], min(t, cv.m(t))))
    n = max(1, len(order) - 1)
    return {t: i / n for i, t in enumerate(order)}


# ------------------------------------------------------------------ styles & biomes

# biome: climate centre (elevation, fertility), fertility multiplier, and the
# buildings it raises (weights; None = leave the ground open). Caves are an
# enclosure in their own right; a maze district raises one labyrinth.
BIOMES = {
    "sea": dict(
        ef=(0.15, 0.25), fert=0.5, build=[("rampart", 3), ("room", 1.5), (None, 4)]
    ),
    "meadow": dict(
        ef=(0.25, 0.75),
        fert=0.9,
        build=[("room", 3), ("stalls", 3), ("complex", 2), (None, 1.5)],
    ),
    "reef": dict(
        ef=(0.50, 0.80),
        fert=1.3,
        build=[("colonnade", 3), ("room", 2), ("stalls", 2), ("complex", 2)],
    ),
    "ruins": dict(
        ef=(0.55, 0.35),
        fert=0.9,
        build=[("complex", 4), ("cloister", 3), ("colonnade", 2)],
    ),
    "caves": dict(ef=(0.85, 0.65), fert=1.0, build=[]),
    "maze": dict(ef=(0.85, 0.25), fert=0.7, build=[("labyrinth", 1)]),
    "camp": dict(ef=(0.30, 0.50), fert=0.8, build=[]),
    "vault": dict(ef=(0.50, 0.50), fert=1.5, build=[]),
    "garden": dict(ef=(0.30, 0.90), fert=1.6, build=[("colonnade", 3), ("stalls", 2)]),
    "landmark": dict(ef=(0.50, 0.50), fert=1.0, build=[]),
}

# Map-scale landmarks, one per world at most. The central ones sit on the
# symmetry axis and are planned before the camps, which settle round them;
# the great wall is a mirrored pair of fortified lines, one before each side.
LANDMARKS = (
    "citadel",
    "labyrinth",
    "palace",
    "city",
    "serpent",
    "wall",
    "lanes",
    "effigy",
    "lattice",
)
LANDMARK_MIN = {"citadel": 9, "labyrinth": 9, "palace": 9, "city": 11, "serpent": 13}
# the share of the map a central landmark aims to cover
LANDMARK_SHARE = {"serpent": (0.45, 0.65)}

# bw: biome weight multipliers; build: building weight multipliers;
# stockade: chance each camp is walled in; front: chance a home/frontier
# district border becomes a gated wall; darea: tiles per district;
# worm/shrine: portal feature counts; closed: chance of a sealed border;
# vault: chance the heart is a vault; ridges: chance of elevation ridges;
# detour: the path/straight-line ratio the judge aims for; landmark: weights
# of the map-scale landmark (see LANDMARKS); nest: chance the first dragon
# starts coiled in a spiral nest
STYLES = {
    # Open water with no buildings, as Big Empty, Help and Colosseum: only the
    # border, portals and the odd grove break it up.
    "open": dict(
        bw={"caves": 0, "maze": 0, "ruins": 0.3},
        build={},
        stockade=0,
        front=0,
        darea=160,
        worm=(0, 2),
        shrine=(0, 1),
        closed=0.3,
        vault=0,
        ridges=0,
        detour=1.05,
        landmark={"none": 1},
        nest=0,
        open=True,
    ),
    "wilds": dict(
        bw={},
        build={},
        stockade=0.35,
        front=0.2,
        darea=110,
        worm=(0, 1),
        shrine=(0, 2),
        closed=0.5,
        vault=0.6,
        ridges=0.6,
        detour=1.3,
        landmark={
            "citadel": 1,
            "labyrinth": 1,
            "palace": 1,
            "city": 1,
            "wall": 1,
            "serpent": 1,
            "effigy": 1,
            "lattice": 0.7,
            "lanes": 1,
            "none": 0.8,
        },
        nest=0.3,
    ),
    "archipelago": dict(
        bw={"sea": 3, "reef": 2, "meadow": 1.5, "maze": 0.3, "ruins": 0.5},
        build={"colonnade": 2, "rampart": 1.5},
        stockade=0.2,
        front=0.0,
        darea=130,
        worm=(1, 2),
        shrine=(0, 2),
        closed=0.3,
        vault=0.4,
        ridges=0.3,
        detour=1.15,
        landmark={
            "city": 1,
            "wall": 1.5,
            "citadel": 0.5,
            "palace": 0.5,
            "effigy": 2,
            "lattice": 1,
            "none": 1.2,
        },
        nest=0.2,
    ),
    "labyrinth": dict(
        bw={"maze": 3.5, "ruins": 1.5, "sea": 0.4, "meadow": 0.5},
        build={"complex": 2},
        stockade=0.4,
        front=0.3,
        darea=110,
        worm=(0, 1),
        shrine=(0, 1),
        closed=0.7,
        vault=0.7,
        ridges=0.2,
        detour=1.6,
        landmark={
            "labyrinth": 4,
            "palace": 1,
            "citadel": 1,
            "serpent": 2,
            "lanes": 1,
            "none": 0.4,
        },
        nest=0.3,
    ),
    "caverns": dict(
        bw={"caves": 3.5, "reef": 1.2, "sea": 0.5},
        build={"colonnade": 1.5},
        stockade=0.3,
        front=0.1,
        darea=120,
        worm=(0, 1),
        shrine=(0, 1),
        closed=0.6,
        vault=0.5,
        ridges=0.8,
        detour=1.4,
        landmark={
            "palace": 1,
            "labyrinth": 1,
            "wall": 1,
            "citadel": 0.5,
            "effigy": 1.5,
            "serpent": 1,
            "none": 1.0,
        },
        nest=0.3,
    ),
    "fortress": dict(
        bw={"ruins": 2.5, "maze": 1.2, "meadow": 1.0},
        build={"complex": 2.5, "cloister": 2.5, "room": 1.5},
        stockade=0.85,
        front=0.6,
        darea=100,
        worm=(0, 1),
        shrine=(0, 1),
        closed=0.9,
        vault=1.0,
        ridges=0.3,
        detour=1.4,
        landmark={
            "citadel": 4,
            "wall": 2,
            "palace": 1,
            "city": 0.5,
            "serpent": 1,
            "lanes": 1.5,
            "none": 0.2,
        },
        nest=0.15,
    ),
    "shrines": dict(
        bw={"meadow": 2, "sea": 1.5, "ruins": 1.2},
        build={"stalls": 3},
        stockade=0.3,
        front=0.1,
        darea=110,
        worm=(0, 1),
        shrine=(3, 6),
        closed=0.8,
        vault=0.3,
        ridges=0.4,
        detour=1.25,
        landmark={"city": 2, "palace": 2, "citadel": 1, "lattice": 3, "none": 0.5},
        nest=0.2,
    ),
}

# the shapes the official maps come in
SHAPES = [
    (32, 16),
    (48, 24),
    (25, 35),
    (32, 32),
    (16, 16),
    (54, 18),
    (63, 27),
    (60, 40),
    (25, 25),
    (40, 20),
    (36, 24),
    (24, 24),
    (44, 22),
    (30, 30),
    (11, 11),
    (16, 8),
    (64, 64),
]
# The share of worlds whose size is drawn freely instead of from SHAPES, since
# tournament maps are unseen and need not share the official shapes.
FREE_SIZE_SHARE = 0.25

TIER_RANK = {"dead": 0, "bg": 1, "fair": 2, "rich": 3, "hot": 4}


# ------------------------------------------------------------------ world


def macro(
    seed,
    w=None,
    h=None,
    sym=None,
    style=None,
    closed=None,
    per_side=None,
    supply=None,
    landmark=None,
    supply_per_100_tiles=(0.0, math.inf),
):
    """The world's skeleton, fixed by the seed: shape, style, symmetry, border,
    dragon count. Candidates of one seed differ only in the details."""
    rng = random.Random(seed)
    if w is None:
        w, h = rng.choice(SHAPES)
        if rng.random() < FREE_SIZE_SHARE:
            w = rng.randint(11, 64)
            h = max(8, min(64, round(w / rng.uniform(1.0, 3.0))))
        if rng.random() < 0.3:
            w, h = h, w
    style = style or rng.choice(sorted(STYLES))
    if sym is None:
        sym = "xy" if rng.random() < 0.55 else ("y" if w >= h else "x")
    if closed is None:
        closed = rng.random() < STYLES[style]["closed"]
    if per_side is None:
        per_side = max(1, min(7, round(w * h / 260 + rng.uniform(-1.0, 1.5))))
    if supply is None:
        # Official maps give each dragon from a third of a pearl a round
        # (Small) to dozens (Help); the envelope check trims the extremes.
        supply = per_side * math.exp(rng.uniform(math.log(0.3), math.log(12.0)))
        low, high = supply_per_100_tiles
        supply = min(max(supply, 1.1 * low * w * h / 100), 0.9 * high * w * h / 100)
    if landmark is None:
        wt = STYLES[style]["landmark"]
        landmark = rng.choices(sorted(wt), [wt[k] for k in sorted(wt)])[0]
    return dict(
        w=w,
        h=h,
        sym=sym,
        style=style,
        closed=closed,
        per_side=per_side,
        supply=supply,
        landmark=landmark,
    )


class World:
    def __init__(
        self, seed, w, h, sym, style, closed, per_side, supply, landmark="none"
    ):
        self.seed = seed
        self.landmark_kind = landmark
        self.rng = random.Random(seed)
        self.style_name = style
        self.style = STYLES[style]
        self.cv = Canvas(w, h, sym, closed)
        self.area = w * h
        self.req_per_side = per_side
        self.req_supply = supply
        self.tier = {}
        self.notes = []
        self.occupied = set()
        self.lm, self.reserved, self.lm_built, self.lm_area = None, set(), False, 0
        self.nest_bias, self.nest_path = 0.0, None
        self.why = None

    def log(self, msg):
        self.notes.append(msg)

    # ---------------------------------------------------------- stage 2
    def climate(self):
        cv, rng = self.cv, self.rng
        base = max(6.0, math.sqrt(self.area) / 2.5)
        self.elev = field(cv, rng, base * 1.4)
        self.fert = field(cv, rng, base * 0.8)
        self.wx = ValueNoise(rng, cv.w, cv.h, base * 0.7)
        self.wy = ValueNoise(rng, cv.w, cv.h, base * 0.7)

    # ---------------------------------------------------------- stage 3
    def axis_points(self):
        cv, rng = self.cv, self.rng
        cx, cy = (cv.w - 1) / 2, (cv.h - 1) / 2
        if self.lm:
            L = self.lm
            cx = (L["x0"] + (L["fw"] - 1) / 2) % cv.w
            cy = (L["y0"] + (L["fh"] - 1) / 2) % cv.h
            if cv.sym == "y":
                return [(cx, cy)]
            if cv.sym == "x":
                return [(cx, cy)]
        if cv.sym == "xy":
            pts = [(cx, cy)]
            if not cv.closed and rng.random() < 0.5:
                pts.append(((cx + cv.w / 2) % cv.w, (cy + cv.h / 2) % cv.h))
            return pts
        if cv.sym == "y":
            return [(cx, rng.uniform(cv.h * 0.3, cv.h * 0.7))]
        return [(rng.uniform(cv.w * 0.3, cv.w * 0.7), cy)]

    def camps_and_districts(self):
        cv, rng = self.cv, self.rng
        w, h = cv.w, cv.h
        n = self.per_side = self.req_per_side
        ncamps = 1 if n <= 2 else rng.randint(1, min(3, n))
        margin = 2 if cv.closed else 0
        camps = []
        for _ in range(ncamps):
            best, bs = None, -1e9
            for _try in range(60):
                for _draw in range(
                    30
                ):  # camps are drawn from the ground the landmark leaves open
                    p = (
                        rng.uniform(margin + 1, w - 2 - margin),
                        rng.uniform(margin + 1, h - 2 - margin),
                    )
                    if not self.lm or self.rect_dist(p, self.lm_rect()) >= 3.5:
                        break
                t = (int(p[0]), int(p[1]))
                if not cv.is_canon(t):
                    p = cv.mf(p)
                sep = cv.dist(p, cv.mf(p))
                spread = min([cv.dist(p, c) for c in camps] + [99])
                s = sep * rng.uniform(0.8, 1.2) + min(spread, 12) * 1.5
                if sep < 6:
                    s -= 100
                if self.lm and self.rect_dist(p, self.lm_rect()) < 3.5:
                    s -= 1000  # a camp needs open ground outside the landmark
                if s > bs:
                    best, bs = p, s
            camps.append((round(best[0]), round(best[1])))
        self.camps = camps
        if self.lm and any(self.rect_dist(c, self.lm_rect()) < 3.5 for c in camps):
            self.log("no room for the {} beside the camps".format(self.lm["kind"]))
            self.lm, self.reserved, self.landmark_kind = None, set(), "wall"

        seeds, roles = [], []

        def add(p, role):
            q = cv.mf(p)
            if cv.dist(p, q) < 0.01:
                seeds.append(p)
                roles.append(role)
                return [len(seeds) - 1]
            seeds.extend([p, q])
            roles.extend([role, role])
            return [len(seeds) - 2, len(seeds) - 1]

        for c in camps:
            add(c, "camp")
        for p in self.axis_points():
            add(p, "heart")
        # ordinary districts are counted on their own: camps are small clearings
        # and must not use up the district budget of the map
        target = max(
            6, min(44, round(self.area / (self.style["darea"] * rng.uniform(0.7, 1.3))))
        )
        r = math.sqrt(self.area / target) * 0.85
        tries = land = 0
        while land < target and tries < 4000:
            tries += 1
            p = (rng.uniform(0, w - 1), rng.uniform(0, h - 1))
            if (
                min(
                    cv.dist(p, s) * (1.5 if roles[k] == "camp" else 1.0)
                    for k, s in enumerate(seeds)
                )
                < r * 0.9
            ):
                continue
            if cv.dist(p, cv.mf(p)) < r * 0.9:
                continue
            if (int(p[0]), int(p[1])) in self.reserved:
                continue
            land += len(add(p, "land"))
        self.seeds, self.roles = seeds, roles
        self.smir = [
            min(range(len(seeds)), key=lambda j: cv.dist(seeds[j], cv.mf(seeds[i])))
            for i in range(len(seeds))
        ]
        # assign tiles by warped nearest seed, canonical side first, mirror copies
        amp = r * 0.45
        camp_r = 4.5 + 0.5 * min(3, n)
        assign = {}
        for t in cv.tiles:
            if not cv.is_canon(t):
                continue
            q = (
                t[0] + (self.wx.at(*t) - 0.5) * 2 * amp,
                t[1] + (self.wy.at(*t) - 0.5) * 2 * amp,
            )

            # camps are clearings, not provinces: weaker pull and a hard radius
            def pull(j, q=q):
                dd = cv.dist(q, seeds[j])
                if roles[j] == "camp":
                    return dd * 1.5 if dd <= camp_r else 1e9
                return dd

            i = min(range(len(seeds)), key=pull)
            assign[t] = i
            mt = cv.m(t)
            if mt != t:
                assign[mt] = self.smir[i]
        self.assign = assign
        self.members = {i: [] for i in range(len(seeds))}
        for t, i in assign.items():
            self.members[i].append(t)
        # role of each land district: frontier (contested) or home
        ca = [c for c in camps]
        cb = [cv.m(c) for c in camps]
        for i, s in enumerate(seeds):
            if roles[i] != "land":
                continue
            da = min(cv.dist(s, c) for c in ca)
            db = min(cv.dist(s, c) for c in cb)
            roles[i] = "frontier" if abs(da - db) / max(1.0, da + db) < 0.2 else "home"

    # ---------------------------------------------------------- stage 4
    def pick_biomes(self):
        rng, cv = self.rng, self.cv
        bw = self.style["bw"]
        self.biome = {}
        for i, s in enumerate(self.seeds):
            if i in self.biome:
                continue
            role = self.roles[i]
            mem = self.members[i]
            if role == "camp":
                b = "camp"
            elif role == "heart":
                inside = (
                    int(round(s[0])) % cv.w,
                    int(round(s[1])) % cv.h,
                ) in self.reserved
                inside = (
                    inside or self.landmark_kind == "effigy"
                )  # the centrepiece figure is the heart
                b = (
                    "vault"
                    if rng.random() < self.style["vault"]
                    and len(mem) >= 16
                    and not inside
                    else rng.choice(["garden", "reef", "ruins"])
                )
            else:
                if mem:
                    e = sum(self.elev[t] for t in mem) / len(mem)
                    f = sum(self.fert[t] for t in mem) / len(mem)
                else:
                    e = f = 0.5
                best, bs = "sea", -1
                for name, spec in BIOMES.items():
                    if name in ("camp", "vault", "garden", "landmark"):
                        continue
                    ce, cf = spec["ef"]
                    a = math.exp(-((e - ce) ** 2 + (f - cf) ** 2) / 0.2)
                    a *= bw.get(name, 1.0)
                    if role == "frontier":
                        a *= {"reef": 1.5, "ruins": 1.5, "maze": 0.7, "sea": 0.8}.get(
                            name, 1
                        )
                    else:
                        a *= {"sea": 1.3, "caves": 1.2, "meadow": 1.3}.get(name, 1)
                    a *= rng.uniform(0.6, 1.4)
                    if a > bs:
                        best, bs = name, a
                b = best
                if b == "maze" and len(mem) < 14:
                    b = "ruins"
            self.biome[i] = b
            self.biome[self.smir[i]] = b
        self.tbiome = {t: self.biome[i] for t, i in self.assign.items()}

    # ---------------------------------------------------------- stage 5
    def wall_chain(self, chain, spacing, ruined=False):
        """Kelp along an ordered chain with gates every ~spacing edges (1-2
        wide). A ruined wall also loses whole runs, never single edges."""
        cv, rng = self.cv, self.rng
        if len(chain) < 3:
            return  # a one- or two-edge wall is a stub, not a structure
        n = len(chain)
        walled = [True] * n
        pos = rng.randint(0, max(0, min(n - 1, spacing // 2)))
        while pos < n:
            for j in range(pos, min(n, pos + rng.choice([1, 1, 2]))):
                walled[j] = False
            pos += max(3, int(spacing * rng.uniform(0.6, 1.4)))
        if ruined:
            j = rng.randint(0, 4)
            while j < n:
                gap = rng.randint(1, 3)
                for k in range(j, min(n, j + gap)):
                    walled[k] = False
                j += gap + rng.randint(3, 7)
        for e, wl in zip(chain, walled, strict=False):
            if wl:
                cv.put(e, 1)

    def fresh(self, chain, done):
        """True once per mirrored pair of chains (the mirror would redraw it)."""
        if all(e in done for e in chain):
            return False
        for e in chain:
            done.add(e)
            done.add(self.cv.me(e))
        return True

    def ridges(self):
        """Long organic walls along elevation contour lines, with fords."""
        cv, rng = self.cv, self.rng
        if rng.random() >= self.style["ridges"]:
            return
        levels = sorted(rng.sample([0.3, 0.45, 0.6, 0.75], rng.randint(1, 2)))
        edges = []
        for t in cv.tiles:
            if self.tbiome[t] in ("camp", "vault") or t in self.occupied:
                continue
            for d in ("E", "S"):
                n = cv.nb(t, d)
                if self.tbiome[n] in ("camp", "vault") or n in self.occupied:
                    continue
                a, b = self.elev[t], self.elev[n]
                if any(min(a, b) < lv <= max(a, b) for lv in levels):
                    edges.append(cv.edge(t, d))
        done = set()
        count = 0
        for ch in cv.chains(edges):
            if len(ch) >= 6 and self.fresh(ch, done):
                self.wall_chain(ch, rng.randint(6, 11))
                count += 1
        if count:
            self.log(f"{count} ridge(s)")

    def borders(self):
        cv, rng = self.cv, self.rng
        bounds = {}
        for t in cv.tiles:
            for d in ("E", "S"):
                n = cv.nb(t, d)
                if t in self.reserved or n in self.reserved:
                    continue
                a, b = self.assign[t], self.assign[n]
                if a != b:
                    key = (min(a, b), max(a, b))
                    bounds.setdefault(key, []).append(cv.edge(t, d))
        done = set()
        for (a, b), edges in sorted(bounds.items()):
            if (a, b) in done:
                continue
            ma, mb = self.smir[a], self.smir[b]
            done.add((a, b))
            done.add((min(ma, mb), max(ma, mb)))
            ba, bb = self.biome[a], self.biome[b]
            # A border wall has a job: the outer wall of an enclosure (maze,
            # caves), or a gated front line between home ground and the
            # contested frontier. Anything else stays open ground.
            enclosure = (
                ba != bb and "caves" in (ba, bb) and not ({"vault", "camp"} & {ba, bb})
            )
            front = {self.roles[a], self.roles[b]} == {
                "home",
                "frontier",
            } and rng.random() < self.style["front"]
            if not (enclosure or front):
                continue
            for ch in cv.chains(edges):
                self.wall_chain(ch, rng.randint(6, 10))

    # ---------------------------------------------------------- stage 6: interiors
    def canon_districts(self, biome):
        return [
            i
            for i in range(len(self.seeds))
            if self.biome[i] == biome and i <= self.smir[i]
        ]

    def interiors(self):
        self.caves([i for i in range(len(self.seeds)) if self.biome[i] == "caves"])

    def caves(self, districts):
        cv, rng = self.cv, self.rng
        mem = set(t for i in districts for t in self.members[i]) - self.reserved
        if not mem:
            return
        rock = {}
        for t in sorted(mem):
            if cv.is_canon(t):
                v = rng.random() < 0.45
                rock[t] = rock[cv.m(t)] = v
        for _ in range(4):
            nxt = {}
            for t in mem:
                c = 0
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        if dx or dy:
                            c += rock.get(
                                ((t[0] + dx) % cv.w, (t[1] + dy) % cv.h), False
                            )
                nxt[t] = c >= 5 or (rock[t] and c >= 4)
            rock = nxt
        solid = {t for t in mem if rock[t]}
        if len(solid) > 0.55 * len(mem):
            return
        # each blob of rock becomes a grotto: its outline is the cave wall,
        # with openings, and the hollow inside holds pearls. (Solid rock drew
        # as sealed, empty rooms, and the game has no rock.)
        left = set(solid)
        blobs = []
        while left:
            t0 = min(left)
            blob, stack = {t0}, [t0]
            left.discard(t0)
            while stack:
                t = stack.pop()
                for d in DIRS:
                    n = cv.nb(t, d)
                    if n in left:
                        left.discard(n)
                        blob.add(n)
                        stack.append(n)
            blobs.append(blob)
        for blob in blobs:
            mirror = {cv.m(t) for t in blob}
            if min(mirror) < min(blob):
                continue  # its mirror image draws it
            if len(blob) < 4:
                cv.post(min(blob))
                continue
            self.draw(self.outline(blob), rng.randint(5, 8))
            for t in blob:
                if rng.random() < (0.6 if len(blob) <= 12 else 0.3):
                    self.tag(t, "rich" if len(blob) <= 12 else "fair")

    # ---------------------------------------------------------- stage 5: landmark
    def plan_landmark(self):
        """Fix the central landmark's footprint before the camps exist, so the
        camps and districts settle round it rather than the other way round."""
        cv, rng = self.cv, self.rng
        kind = self.landmark_kind
        if kind not in LANDMARK_MIN:
            return
        w, h = cv.w, cv.h
        road = 2 if cv.closed else 1
        # the camps need a strip of open ground on both ends of the axis
        caps = []
        strip = 2 * max(
            8, 5 + self.req_per_side
        )  # room for each side's camps and dragons
        if cv.sym in ("y", "xy"):
            caps.append((w - strip, h - 2 * road - 2))
        if cv.sym in ("x", "xy"):
            caps.append((w - 2 * road - 2, h - strip))
        lo = LANDMARK_MIN[kind]
        caps = [c for c in caps if min(c) >= lo]
        if caps:
            cw, ch = max(caps, key=lambda c: c[0] * c[1])
            want = self.area * rng.uniform(*LANDMARK_SHARE.get(kind, (0.28, 0.5)))
            fw = min(cw, max(lo, round(math.sqrt(want * cw / ch))))
            fh = min(ch, max(lo, round(want / fw)))
            # a footprint that is its own mirror image: centred on the axis
            if cv.sym in ("y", "xy") and (w - fw) % 2:
                fw -= 1
            if cv.sym in ("x", "xy") and (h - fh) % 2:
                fh -= 1

            def free(n, f):
                return (
                    rng.randint(road, n - road - f) if cv.closed else rng.randrange(n)
                )

            if min(fw, fh) >= lo:
                x0 = (w - fw) // 2 if cv.sym in ("y", "xy") else free(w, fw)
                y0 = (h - fh) // 2 if cv.sym in ("x", "xy") else free(h, fh)
                self.lm = dict(kind=kind, x0=x0, y0=y0, fw=fw, fh=fh)
                self.reserved = set(self.rect(x0 - 1, y0 - 1, fw + 2, fh + 2))
                return
        self.landmark_kind = "wall"  # no room on the axis: fortify the fronts instead

    def lm_rect(self):
        L = self.lm
        return L["x0"], L["y0"], L["fw"], L["fh"]

    def rect_dist(self, p, r):
        """Distance from a point to a rectangle of tiles (on the torus if it wraps)."""
        cv = self.cv
        x0, y0, fw, fh = r

        def d1(a, lo, n, size):
            return min(
                max(0.0, lo - (a + sh), (a + sh) - (lo + n - 1))
                for sh in ((0,) if cv.closed else (-size, 0, size))
            )

        return math.hypot(d1(p[0], x0, fw, cv.w), d1(p[1], y0, fh, cv.h))

    def landmark(self):
        kind = self.landmark_kind
        if self.lm:
            x0, y0, fw, fh = self.lm_rect()
            self.frame(x0, y0, fw, fh)
            getattr(self, "lm_" + kind)()
            for t in self.rect(x0, y0, fw, fh):
                self.tbiome[t] = "landmark"
            self.occupied |= self.reserved
            self.lm_built, self.lm_area = True, fw * fh
            title = {
                "labyrinth": "great labyrinth",
                "city": "walled city",
                "serpent": "serpent hall",
            }.get(kind, kind)
            self.log(f"{title} {fw}x{fh}")
        elif kind in ("wall", "lanes", "effigy", "lattice"):
            self.lm_built = getattr(self, "lm_" + kind)()

    # The central landmarks are drawn in a local frame: u runs across the
    # symmetry axis (u = 0 is the outer wall facing one side's camps), v runs
    # along it. Anything random is drawn on the near half only, u < fu/2;
    # every write is mirrored, so the far half is its exact image.
    TMAP = {"N": "W", "S": "E", "E": "S", "W": "N"}

    def frame(self, x0, y0, fw, fh):
        self.fx = (x0, y0)
        self.ft = self.cv.sym == "x"
        self.fu, self.fv = (fh, fw) if self.ft else (fw, fh)

    def T(self, u, v):
        x0, y0 = self.fx
        return self.R(x0, y0, v, u) if self.ft else self.R(x0, y0, u, v)

    def le(self, u, v, d):
        return self.cv.edge(self.T(u, v), self.TMAP[d] if self.ft else d)

    def lrect(self, u0, v0, uw, vh):
        return [self.T(u0 + du, v0 + dv) for du in range(uw) for dv in range(vh)]

    def lside(self, u0, v0, uw, vh, d):
        if d == "N":
            return [self.le(u0 + k, v0, "N") for k in range(uw)]
        if d == "S":
            return [self.le(u0 + k, v0 + vh - 1, "S") for k in range(uw)]
        if d == "W":
            return [self.le(u0, v0 + k, "W") for k in range(vh)]
        return [self.le(u0 + uw - 1, v0 + k, "E") for k in range(vh)]

    def lwall(self, edges, k=1):
        for e in edges:
            self.cv.put(e, k)

    def lbox(self, u0, v0, uw, vh):
        self.cv.enclose(self.lrect(u0, v0, uw, vh))

    def ltag(self, tiles, tier, p=1.0):
        for t in tiles:
            if self.rng.random() < p:
                self.tag(t, tier)

    def near_run(self, run, uw):
        """The part of a wall run that lies on the near half (for N/S walls
        that cross the axis), so a gate there is mirrored, not doubled."""
        k = max(2, uw // 2 - 1)
        return run[:k] if len(run) > k + 1 else run

    def depth_from_outside(self):
        """Steps from the road round the landmark to every tile inside it."""
        x0, y0, fw, fh = self.lm_rect()
        inside = set(self.rect(x0, y0, fw, fh))
        ring = [t for t in self.reserved if t not in inside]
        return self.cv.bfs(
            ring, block={t for t in self.cv.tiles if t not in self.reserved}
        )

    def lm_citadel(self):
        """Concentric curtain walls with staggered gates, radial walls cutting
        the baileys into wards, corner towers, and a keep with the treasure."""
        rng = self.rng
        U, V = self.fu, self.fv
        g = 3 if min(U, V) < 19 else rng.choice([3, 4])
        rings = [(0, 0, U, V)]
        while len(rings) < 3 and min(rings[-1][2], rings[-1][3]) - 2 * g >= 7:
            u0, v0, uw, vh = rings[-1]
            rings.append((u0 + g, v0 + g, uw - 2 * g, vh - 2 * g))

        def keep_dim(n):
            k = n - 4  # a ward at least two wide all round
            while k > 6:
                k -= 2
            return k

        u0, v0, uw, vh = rings[-1]
        ku, kv = keep_dim(uw), keep_dim(vh)
        if min(ku, kv) >= 3:
            rings.append((u0 + (uw - ku) // 2, v0 + (vh - kv) // 2, ku, kv))
        for r in rings:
            self.lbox(*r)
        if min(U, V) >= 13:  # corner towers
            for v in (1, V - 1):
                self.cv.post(self.T(1, v))
        # radial walls: each bailey is cut into wards, one door in each cut
        for k in range(len(rings) - 1):
            ou, ov, ow, oh = rings[k]
            iu, iv, iw, ih = rings[k + 1]
            for _ in range(rng.randint(1, 2)):
                if rng.random() < 0.5 and U // 2 - 1 > iu + 1:
                    c = rng.randint(iu + 1, U // 2 - 1)
                    run = [self.le(c, v, "W") for v in range(ov, iv)]
                else:
                    if ih < 4:
                        continue
                    c = rng.randint(iv + 1, iv + ih - 2)
                    run = [self.le(u, c, "N") for u in range(ou, iu)]
                if any(p in self.cv.solid for e in run for p in self.cv.sides(e)):
                    continue
                self.lwall(run)
                self.door(run)
        # gates, staggered ring by ring so the way in winds round each bailey
        prev = None
        for k, r in enumerate(rings):
            if k == 0:
                d = "W"
            elif prev == "W":
                d = rng.choice("NS")
            else:
                d = "W"
            run = self.lside(*r, d)
            if d != "W":
                run = self.near_run(run, r[2])
            keep = k == len(rings) - 1 and k > 0
            self.door(run, 1 if keep else 2)
            if k == 0 and rng.random() < 0.5:  # a postern on the far side
                self.door(self.near_run(self.lside(*r, rng.choice("NS")), r[2]))
            prev = d
        # treasure: the keep, then the inner ward, then the baileys
        for k, r in enumerate(rings):
            tiles = self.lrect(*r)
            if k == len(rings) - 1 and k > 0:
                self.ltag(tiles, "hot")
            elif k == len(rings) - 2:
                self.ltag(tiles, "rich", 0.45)
            elif k > 0:
                self.ltag(tiles, "fair", 0.35)

    def maze(self, nc, nr, loops=0.07):
        """A perfect maze on an nc x nr grid of cells (depth-first), braided
        with a few loops. Returns the set of linked cell pairs."""
        rng = self.rng
        start = (rng.randrange(nc), rng.randrange(nr))
        seen, stack, links = {start}, [start], set()
        while stack:
            c = stack[-1]
            nxt = [(c[0] + DX[d], c[1] + DY[d]) for d in DIRS]
            nxt = [
                n for n in nxt if 0 <= n[0] < nc and 0 <= n[1] < nr and n not in seen
            ]
            if not nxt:
                stack.pop()
                continue
            n = rng.choice(nxt)
            links.add(frozenset((c, n)))
            seen.add(n)
            stack.append(n)
        for i in range(nc):
            for j in range(nr):
                if i + 1 < nc and rng.random() < loops:
                    links.add(frozenset(((i, j), (i + 1, j))))
                if j + 1 < nr and rng.random() < loops:
                    links.add(frozenset(((i, j), (i, j + 1))))
        return links

    @staticmethod
    def bounds(n, c):
        """Cell boundaries for n tiles cut into cells of c (a short last cell
        joins the one before it)."""
        b = list(range(0, n + 1, c))
        if b[-1] != n:
            b[-1] = n
        return b

    def draw_maze(self, cb, rb, links, E):
        """Walls between unlinked neighbour cells; E(u, v, d) gives the edge."""
        nc, nr = len(cb) - 1, len(rb) - 1
        for i in range(nc):
            for j in range(nr):
                if i + 1 < nc and frozenset(((i, j), (i + 1, j))) not in links:
                    self.lwall([E(cb[i + 1], v, "W") for v in range(rb[j], rb[j + 1])])
                if j + 1 < nr and frozenset(((i, j), (i, j + 1))) not in links:
                    self.lwall([E(u, rb[j + 1], "N") for u in range(cb[i], cb[i + 1])])

    def lm_labyrinth(self):
        """A great labyrinth on each side of a processional way along the axis:
        2-wide corridors, or 1-wide warrens with chambers carved into them
        (as Stronghold and Trauma). The way holds the sanctum and is reached
        only through the maze; the pearls wait in the dead ends."""
        rng = self.rng
        U, V = self.fu, self.fv
        c = 1 if rng.random() < 0.45 else 2
        s = (U % 4 or 4) if c == 2 else (1 if U % 2 else 2)
        hu = (U - s) // 2
        if hu < 2 * c or V < 6:
            return self.lm_citadel()
        cb, rb = self.bounds(hu, c), self.bounds(V, c)
        nc, nr = len(cb) - 1, len(rb) - 1
        links = self.maze(nc, nr, 0.07 if c == 2 else 0.1)
        self.lbox(0, 0, U, V)
        self.lwall(
            [self.le(hu, v, "W") for v in range(V)]
        )  # the processional way's wall
        self.draw_maze(cb, rb, links, self.le)
        # openings: into the way, and gates in the outer wall
        for j in rng.sample(range(nr), min(nr, 2 if nr < 6 else 3)):
            self.cv.put(self.le(hu, rng.randrange(rb[j], rb[j + 1]), "W"), 0)
        for j in rng.sample(range(nr), min(nr, 2)):
            self.lwall([self.le(0, v, "W") for v in range(rb[j], rb[j + 1])][:2], 0)
        if rng.random() < 0.5:
            i = rng.randrange(nc)
            self.lwall([self.le(u, 0, "N") for u in range(cb[i], cb[i + 1])][:2], 0)
        degree = {}
        for pr in links:
            for cell in pr:
                degree[cell] = degree.get(cell, 0) + 1
        for (i, j), dg in sorted(degree.items()):
            if dg == 1 and (c == 2 or rng.random() < 0.5):
                self.ltag(
                    self.lrect(cb[i], rb[j], cb[i + 1] - cb[i], rb[j + 1] - rb[j]),
                    "rich",
                )
        if c == 1:
            # chambers: clear the maze inside a few rectangles; their walls are
            # the maze's own, so every way through the chamber survives
            for _ in range(max(1, hu * V // 45)):
                cw, ch = rng.randint(2, 4), rng.randint(2, 3)
                if cw >= hu - 1 or ch >= V - 1:
                    continue
                u0, v0 = rng.randint(0, hu - cw), rng.randint(0, V - ch)
                for u in range(u0, u0 + cw):
                    for v in range(v0, v0 + ch):
                        if u + 1 < u0 + cw:
                            self.cv.put(self.le(u, v, "E"), 0)
                        if v + 1 < v0 + ch:
                            self.cv.put(self.le(u, v, "S"), 0)
                self.ltag(self.lrect(u0, v0, cw, ch), "rich", 0.7)
        mid = V // 2
        self.ltag(self.lrect(hu, mid - 1, U - 2 * hu, 2), "hot")

    def lm_palace(self):
        """A great hall along the axis, wings of rooms either side split by
        binary partition, courtyards among them, the treasury deepest in."""
        cv, rng = self.cv, self.rng
        U, V = self.fu, self.fv
        s = rng.choice([3, 5]) if U % 2 else rng.choice([2, 4])
        while (U - s) // 2 < 3 and s > 2:
            s -= 2
        hu = (U - s) // 2
        self.lbox(0, 0, U, V)
        self.lwall([self.le(hu, v, "W") for v in range(V)])
        leaves, splits = [], []

        def split(u, v, uw, vh, depth):
            can_u, can_v = uw >= 6, vh >= 6
            if (
                not (can_u or can_v)
                or (depth >= 2 and uw * vh <= 20)
                or (depth >= 3 and rng.random() < 0.35)
            ):
                leaves.append((u, v, uw, vh))
                return
            if can_u and (not can_v or uw > vh * 1.2 or rng.random() < 0.3):
                c = rng.randint(3, uw - 3)
                splits.append([self.le(u + c, v + k, "W") for k in range(vh)])
                split(u, v, c, vh, depth + 1)
                split(u + c, v, uw - c, vh, depth + 1)
            else:
                c = rng.randint(3, vh - 3)
                splits.append([self.le(u + k, v + c, "N") for k in range(uw)])
                split(u, v, uw, c, depth + 1)
                split(u, v + c, uw, vh - c, depth + 1)

        split(0, 0, hu, V, 0)
        for run in splits:
            self.lwall(run)
        for run in splits:
            self.door(run, 2 if len(run) >= 7 and rng.random() < 0.3 else 1)
        # rooms on the hall open into it (at least two do)
        hall_side = [lf for lf in leaves if lf[0] + lf[2] == hu]
        forced = set(rng.sample(range(len(hall_side)), min(2, len(hall_side))))
        for k, lf in enumerate(hall_side):
            if k in forced or rng.random() < 0.5:
                self.door(self.lside(*lf, "E"))
        # the hall's great doors at both ends, and a side door into a wing
        mid = [self.le(u, 0, "N") for u in range(hu, U - hu)]
        cut = 1 if s >= 4 else 0
        self.lwall(mid[cut : len(mid) - cut], 0)
        self.lwall(
            [self.le(u, V - 1, "S") for u in range(hu, U - hu)][cut : len(mid) - cut], 0
        )
        outer = [lf for lf in leaves if lf[0] == 0]
        if outer:
            self.door(self.lside(*rng.choice(outer), "W"))
        if s == 5:  # colonnaded hall
            for v in range(2, V - 1, 3):
                cv.post(self.T(hu + 1, v))
        # courtyards and treasure
        depth = self.depth_from_outside()
        rooms = []
        for lf in leaves:
            tiles = self.lrect(*lf)
            if lf[2] * lf[3] >= 20 and rng.random() < 0.35:
                cv.post(self.T(lf[0] + lf[2] // 2, lf[1] + lf[3] // 2))  # a fountain
                self.ltag(tiles, "fair", 0.6)
                continue
            rooms.append((max(depth.get(t, 0) for t in tiles), tiles))
        rooms.sort(key=lambda r: -r[0])
        for k, (_, tiles) in enumerate(rooms):
            if k == 0:
                self.ltag(tiles, "hot" if len(tiles) <= 12 else "rich")
            elif k <= 2:
                self.ltag(tiles, "rich")
            else:
                self.ltag(tiles, "fair", 0.5)
        self.ltag(self.lrect(hu, V // 2 - 1, U - 2 * hu, 2), "rich")  # the throne

    def parts(self, n, lo=4, hi=9, gap=2):
        """Blocks lo..hi long with gap-wide streets between them, filling a run
        of n tiles; any remainder widens the last street."""
        out, pos = [], 0
        while n - pos >= lo:
            rest = n - pos
            if rest <= hi:
                out.append((pos, rest))
                break
            b = self.rng.randint(lo, min(7, rest - gap - lo))
            out.append((pos, b))
            pos += b + gap
        return out

    def lm_city(self):
        """A walled city: a ring road inside the wall, blocks of houses,
        temples, markets and parks between two-wide streets, and an avenue
        along the axis with a fountain square."""
        cv, rng = self.cv, self.rng
        U, V = self.fu, self.fv
        s = 3 if U % 2 else rng.choice([2, 4])
        hu = (U - s) // 2
        self.lbox(0, 0, U, V)
        ub = [(1 + a, n) for a, n in self.parts(hu - 1)]
        vb = [(1 + a, n) for a, n in self.parts(V - 2)]
        doors = []
        for bu, bw in ub:
            for bv, bh in vb:
                kinds = [("house", 5), ("park", 1.2)]
                if min(bw, bh) >= 5:
                    kinds += [("temple", 1.5), ("market", 1.2)]
                if bu + bw >= hu - 1 and bv <= V // 2 < bv + bh:
                    kinds = [("park", 1)]  # the square by the avenue
                kind = rng.choices([k for k, _ in kinds], [wt for _, wt in kinds])[0]
                doors += self.city_block(kind, bu, bv, bw, bh)
        for run, width in doors:
            self.door(run, width)
        # gates: the avenue's ends, and where streets meet the wall
        av = [self.le(u, 0, "N") for u in range(hu, U - hu)]
        cut = 1 if s == 4 else 0
        self.lwall(av[cut : len(av) - cut], 0)
        self.lwall(
            [self.le(u, V - 1, "S") for u in range(hu, U - hu)][cut : len(av) - cut], 0
        )
        streets = [bv + bh for bv, bh in vb[:-1]]
        for k, v in enumerate(rng.sample(streets, len(streets))):
            if k == 0 or rng.random() < 0.4:
                self.lwall([self.le(0, v, "W"), self.le(0, v + 1, "W")], 0)
        cross = [bu + bw for bu, bw in ub[:-1]]
        if cross and rng.random() < 0.6:
            u = rng.choice(cross)
            self.lwall([self.le(u, 0, "N"), self.le(u + 1, 0, "N")], 0)
        # the square: a fountain on the axis, pearls round it
        mv = V // 2
        if s == 3:
            cv.post(self.T(hu + 1, mv))
        self.ltag(self.lrect(hu - 2, mv - 2, s + 4, 4), "rich", 0.7)

    def city_block(self, kind, bu, bv, bw, bh):
        """Build one city block; return the doors to open once all walls stand."""
        cv, rng = self.cv, self.rng
        doors = []
        if kind == "park":
            if min(bw, bh) >= 5 and rng.random() < 0.6:
                cv.post(self.T(bu + bw // 2, bv + bh // 2))  # an old tree
            self.ltag(self.lrect(bu, bv, bw, bh), "fair", 0.5)
            return doors
        if kind == "temple":
            self.lbox(bu, bv, bw, bh)
            self.lbox(bu + 1, bv + 1, bw - 2, bh - 2)
            d = rng.choice(DIRS)
            doors.append((self.lside(bu, bv, bw, bh, d), 2 if min(bw, bh) >= 6 else 1))
            doors.append((self.lside(bu + 1, bv + 1, bw - 2, bh - 2, OPP[d]), 1))
            self.ltag(self.lrect(bu + 1, bv + 1, bw - 2, bh - 2), "rich")
            return doors
        if kind == "market":
            # stalls along the two long sides, facing the aisle between them
            along_v = bh >= bw
            n = (bh if along_v else bw) // 2
            for k in range(n):
                for row in (0, 1):
                    if along_v:
                        su, sv = (bu if row == 0 else bu + bw - 2), bv + 2 * k
                        front = "E" if row == 0 else "W"
                    else:
                        su, sv = bu + 2 * k, (bv if row == 0 else bv + bh - 2)
                        front = "S" if row == 0 else "N"
                    self.lbox(su, sv, 2, 2)
                    doors.append((self.lside(su, sv, 2, 2, front), 1))
                    self.ltag(
                        self.lrect(su, sv, 2, 2),
                        "rich" if rng.random() < 0.35 else "fair",
                    )
            return doors
        # houses: one, or two back to back
        houses = [(bu, bv, bw, bh)]
        if bw * bh >= 20 and rng.random() < 0.7:
            if bw >= bh and bw >= 6:
                c = rng.randint(3, bw - 3)
                houses = [(bu, bv, c, bh), (bu + c, bv, bw - c, bh)]
            elif bh >= 6:
                c = rng.randint(3, bh - 3)
                houses = [(bu, bv, bw, c), (bu, bv + c, bw, bh - c)]
        for hs in houses:
            self.lbox(*hs)
            u0, v0, uw, vh = hs
            street = [
                d
                for d in DIRS
                if (d == "W" and u0 == bu)
                or (d == "E" and u0 + uw == bu + bw)
                or (d == "N" and v0 == bv)
                or (d == "S" and v0 + vh == bv + bh)
            ]
            n = 1 if rng.random() < 0.55 else 2
            for d in rng.sample(street, min(n, len(street))):
                doors.append((self.lside(*hs, d), 1))
            self.ltag(self.lrect(*hs), "rich" if n == 1 else "fair", 0.7)
        return doors

    def lm_wall(self):
        """A great wall before each side: a fortified line across the whole map
        between the camps and the axis, gates flanked by towers, barracks
        behind it. Mirrored, so each side has its own."""
        cv, rng = self.cv, self.rng
        orients = [
            o
            for o, ok in (("v", cv.sym in ("y", "xy")), ("h", cv.sym in ("x", "xy")))
            if ok
        ]
        for o in rng.sample(orients, len(orients)):
            W, Lh = (cv.w, cv.h) if o == "v" else (cv.h, cv.w)
            ax = (W - 1) / 2
            cs = [c[0] if o == "v" else c[1] for c in self.camps]
            if all(c < ax - 4 for c in cs):
                pass
            elif all(c > ax + 4 for c in cs):
                cs = [
                    W - 1 - c for c in cs
                ]  # the mirror side's camps sit on the low side
            else:
                continue
            lo, hi = max(cs) + 4, (W - 5) // 2
            if lo > hi:
                continue
            p = rng.randint(lo, hi)

            def E(a, b, d, o=o):  # edge at (across, along) in this orientation
                return cv.edge(
                    (a % cv.w, b % cv.h) if o == "v" else (b % cv.w, a % cv.h),
                    d if o == "v" else self.TMAP[d],
                )

            def tile(a, b, o=o):
                return (a % cv.w, b % cv.h) if o == "v" else (b % cv.w, a % cv.h)

            line = [E(p, b, "W") for b in range(Lh)]
            if any(
                tile(a, b) in self.occupied or tile(a, b) in cv.solid
                for a in range(p - 4, p + 3)
                for b in range(Lh)
            ):
                continue
            self.lwall(line)
            # gates every 6-10 tiles, each flanked by towers on the outer face
            gates, b = [], rng.randint(2, 5)
            while b + 1 < Lh - (2 if cv.closed else 0):
                gates.append(b)
                b += rng.randint(7, 11)
            if len(gates) < 2:
                gates = [Lh // 3, 2 * Lh // 3]
            for g in gates:
                # a gatehouse: the passage runs two tiles deep through the
                # wall's outer face, walled along both sides
                self.lwall([line[g], line[(g + 1) % Lh]], 0)
                for bb in (g, g + 2):
                    if cv.closed and not (0 < bb < Lh):
                        continue
                    self.lwall([E(a, bb, "N") for a in (p, p + 1)])
            # barracks behind the wall, between the gates
            made = 0
            for g0, g1 in zip(gates, gates[1:], strict=False):
                if g1 - g0 >= 7 and made < 2 and rng.random() < 0.7:
                    b0 = g0 + 3
                    room = [
                        tile(a, bb) for a in range(p - 3, p) for bb in range(b0, b0 + 3)
                    ]
                    if any(min(cv.dist(t, c) for c in self.camps) < 3 for t in room):
                        continue
                    cv.enclose(room)
                    run = [E(p - 3, bb, "W") for bb in range(b0, b0 + 3)]
                    self.door(run)
                    for t in room:
                        self.tag(t, "rich")
                    made += 1
            band = {tile(a, b) for a in range(p - 4, p + 3) for b in range(Lh)}
            self.occupied |= band | {cv.m(t) for t in band}
            self.log(
                f"great wall, {len(gates)} gates"
                + (f", {made} barracks" if made else "")
            )
            return True
        self.log("no room for a great wall")
        return False

    # ---------------------------------------------------------- line art
    # Shapes as regions of tiles; their outlines are the walls. Curves come
    # out as stair-stepped kelp, as on Schooltime and Slithery Fight. Every
    # drawing is symmetrised first and drawn from its canonical half, so a
    # gate left in a wall is mirrored as a gate, never closed by the mirror.
    def blob(self, cx, cy, rx, ry, p=2.0):
        """Tiles of a superellipse |dx/rx|^p + |dy/ry|^p <= 1 (p=2 an ellipse,
        p=1 a diamond, large p a rounded box)."""
        cv = self.cv
        out = set()
        for y in range(math.floor(cy - ry) - 1, math.ceil(cy + ry) + 2):
            for x in range(math.floor(cx - rx) - 1, math.ceil(cx + rx) + 2):
                if cv.closed and not (0 <= x < cv.w and 0 <= y < cv.h):
                    continue
                if abs((x - cx) / rx) ** p + abs((y - cy) / ry) ** p <= 1.0:
                    out.add((x % cv.w, y % cv.h))
        return out

    def outline(self, region):
        cv = self.cv
        reg = set(region) | {cv.m(t) for t in region}
        return {cv.edge(t, d) for t in reg for d in DIRS if cv.nb(t, d) not in reg}

    def draw(self, edges, spacing=None):
        """Wall along a set of edges: gated every ~spacing, one gate if spacing
        is large, none if spacing is None."""
        cv = self.cv
        es = set(edges) | {cv.me(e) for e in edges}
        es = sorted(e for e in es if e <= cv.me(e) and not cv.is_border(e))
        for ch in cv.chains(es):
            if spacing is None:
                for e in ch:
                    cv.put(e, 1)
            else:
                self.wall_chain(ch, spacing)

    def clear_of(self, region, gap=1, camps=3.5):
        """A region is free to draw on: off rock, other structures and the camps."""
        cv = self.cv
        allc = self.camps + [cv.m(c) for c in self.camps]
        for t in region:
            if t in cv.solid or t in self.occupied or self.tbiome.get(t) == "vault":
                return False
            if any(cv.dist(t, c) < camps for c in allc):
                return False
        return True

    def claim(self, region, ring=1):
        cv = self.cv
        grow = set(region)
        for _ in range(ring):
            grow |= {cv.nb(t, d) for t in grow for d in DIRS}
        grow |= {cv.m(t) for t in grow}
        self.occupied |= grow
        self.reserved |= grow

    def lm_effigy(self):
        """Line-art figures across the whole map, Rorschach-mirrored: a head
        outline with gates, ringed eyes holding the treasure, a mouth arc,
        and small rings scattered round them like bubbles."""
        cv, rng = self.cv, self.rng
        w, h = cv.w, cv.h
        figs = 0
        want = 1 + (self.area > 800) + (self.area > 1600)
        tries = 0
        while figs < want and tries < 60:
            tries += 1
            rx = max(
                3.5,
                min(w, h)
                * rng.uniform(0.16, 0.26)
                * (1.3 if figs == 0 else 1.0)
                * (1 - tries / 90),
            )
            ry = rx * rng.uniform(0.8, 1.35)
            if figs == 0 and rng.random() < 0.6:  # the centrepiece sits on the axis
                cx, cy = self.axis_points()[0]
            else:
                cx, cy = rng.uniform(0, w - 1), rng.uniform(0, h - 1)
                if cv.dist((cx, cy), cv.mf((cx, cy))) < 2 * max(rx, ry) + 2:
                    continue
            if cv.closed and not (
                rx + 1 <= cx <= w - 2 - rx and ry + 1 <= cy <= h - 2 - ry
            ):
                continue
            head = self.blob(cx, cy, rx, ry, rng.choice([1.6, 2.0, 2.0, 2.6, 4.0]))
            if not self.clear_of(head):
                continue
            self.draw(self.outline(head), rng.randint(11, 17))
            er = max(1.0, min(rx, ry) * rng.uniform(0.14, 0.22))
            ex, ey = rx * rng.uniform(0.3, 0.45), ry * rng.uniform(0.12, 0.32)
            for sx in (-1, 1):
                eye = self.blob(
                    cx + sx * ex, cy - ey, er + 0.5, (er + 0.5) * rng.uniform(0.8, 1.3)
                )
                if len(eye) >= 2:
                    self.draw(self.outline(eye), 99)
                    for t in eye:
                        self.tag(t, "hot" if len(eye) <= 6 else "rich")
            mx, my = rx * rng.uniform(0.3, 0.55), ry * rng.uniform(0.3, 0.5)
            mouth = self.blob(cx, cy + my - 1.5, mx, 2.0)
            arc = [
                e
                for e in self.outline(mouth)
                if all(
                    t[1] >= (cy + my - 1.5) % h - 0.01 or not cv.closed
                    for t in cv.sides(e)
                )
                and all(t in head for t in cv.sides(e))
            ]
            if len(arc) >= 3:
                self.draw(arc, None)
            for t in head:
                if rng.random() < 0.25:
                    self.tag(t, "fair")
            if rng.random() < 0.5:
                # a crown on the head, teeth along its top (Queen of Spades)
                cw, ch = max(2, int(rx * 0.6)), rng.randint(2, 3)
                top = int(math.floor(cy - ry)) + 1
                crown = {
                    (int(round(cx)) + dx, top - ch + dy)
                    for dx in range(-cw, cw + 1)
                    for dy in range(ch)
                    if not (dy == 0 and (dx + cw) % 2 == 1)
                }
                crown = {
                    (x % w, y % h)
                    for x, y in crown
                    if not cv.closed or (0 <= x < w and 1 <= y < h)
                }
                if crown and self.clear_of(crown, camps=3):
                    self.draw(self.outline(crown), 99)
                    for t in crown:
                        self.tag(t, "rich")
                    self.claim(crown)
            self.claim(head)
            figs += 1
        if rng.random() < 0.6:
            self.inscription()
        bubbles = 0
        for _ in range(self.area // 40):
            if bubbles >= self.area // 110:
                break
            x, y = rng.randrange(w), rng.randrange(h)
            r = rng.choice([1.0, 1.0, 1.5, 2.0])
            ring = self.blob(x, y, r + 0.5, r + 0.5)
            if (
                not ring
                or {cv.m(t) for t in ring} & ring
                or not self.clear_of(ring | {cv.nb(t, d) for t in ring for d in DIRS})
            ):
                continue
            self.draw(self.outline(ring), 99)
            for t in ring:
                self.tag(t, "rich" if len(ring) <= 4 else "fair")
            self.claim(ring)
            bubbles += 1
        if figs:
            self.log(f"{figs} effigies, {bubbles} rings")
        return figs > 0

    def lm_lattice(self):
        """A lattice of sealed pearl boxes over the whole map, reached only by
        portals from box to box (the Portals map), with a pearl zipper
        down the symmetry axis."""
        cv, rng = self.cv, self.rng
        w, h = cv.w, cv.h
        px, py = rng.choice([4, 5, 5, 6]), rng.choice([3, 4, 4, 5])
        ox, oy = rng.randrange(px), rng.randrange(py)
        boxes = []
        for gx in range(ox, w - 1, px):
            for gy in range(oy, h - 1, py):
                box = self.rect(gx, gy, 2, 2)
                if not all(cv.is_canon(t) for t in box):
                    continue
                if cv.closed and not (
                    1 <= gx and gx + 2 <= w - 1 and 1 <= gy and gy + 2 <= h - 1
                ):
                    continue
                ring = set(self.rect(gx - 1, gy - 1, 4, 4))
                if {cv.m(t) for t in ring} & ring or not self.clear_of(ring):
                    continue
                boxes.append(box)
        rng.shuffle(boxes)
        made, linked = [], 0
        boxes = boxes[: max(4, self.area // 30)]
        for box in boxes:
            cv.enclose(box)
            self.claim(box)
            made.append(box)
        # portals: box to box, same side of each, so the outside of one leads
        # into the other; an odd box out opens onto far open ground
        order = list(made)
        while len(order) >= 2:
            b1 = order.pop()
            far = sorted(
                order, key=lambda b: -cv.dist(b[0], b1[0]) * rng.uniform(0.6, 1.0)
            )
            for b2 in far[:6]:
                d = rng.choice(DIRS)
                s1, s2 = set(b1), set(b2)
                o1 = [cv.edge(t, d) for t in b1 if cv.nb(t, d) not in s1]
                o2 = [cv.edge(t, d) for t in b2 if cv.nb(t, d) not in s2]
                if cv.link(rng.choice(o1), rng.choice(o2)):
                    order.remove(b2)
                    linked += 1
                    break
            # a box left without a partner stays sealed until repair opens a door
        for box in made:
            self.ltag(box, "hot" if rng.random() < 0.3 else "rich")
        # the zipper: a pearl lane on the axis between toothed walls
        if cv.sym in ("y", "xy"):
            ax = (w - 1) // 2
            lane = [(ax, y) for y in range(h)]
            teeth = [
                cv.edge((ax, y), "W")
                for y in range(h)
                if y % 2 == rng.randint(0, 1) or y % 3 == 0
            ]
        else:
            ay = (h - 1) // 2
            lane = [(x, ay) for x in range(w)]
            teeth = [
                cv.edge((x, ay), "N")
                for x in range(w)
                if x % 2 == rng.randint(0, 1) or x % 3 == 0
            ]
        lane = [t for t in lane if self.clear_of([t], camps=3.5)]
        keep = {t for t in lane}
        teeth = [e for e in teeth if any(t in keep for t in cv.sides(e))]
        for e in teeth:
            if not cv.kind.get(e):
                cv.put(e, 1)
        for t in keep:
            self.tag(t, "rich")
        self.claim(keep, ring=0)
        self.log(f"pearl lattice: {2 * len(made)} boxes, {linked} portal pairs")
        return len(made) >= 4

    def lm_serpent(self):
        """Slithery Fight's heart: a field of diagonal lanes between stepped
        walls, great halls on either side, and treasure galleries along the
        border. The lanes run one way on each side of the axis."""
        cv, rng = self.cv, self.rng
        x0, y0, fw, fh = self.lm_rect()
        U, V = self.fu, self.fv
        # halls on the near half; the lane field in the middle
        hw = max(4, int(U * rng.uniform(0.2, 0.26)))
        a = max(1, int(V * rng.uniform(0.08, 0.2)))
        hall = (0, a, hw, V - 2 * a)
        self.lbox(*hall)
        for d in ("W", "N", "S"):
            run = self.lside(*hall, d)
            if d != "W" or rng.random() < 0.6:
                self.door(run, 2)
        self.door(self.lside(*hall, "E"), 2)
        core = self.lrect(1, a + 1, hw - 2, V - 2 * a - 2)
        self.ltag(core, "fair", 0.8)
        cu, cv_ = (U - 1) / 2, (V - 1) / 2
        rx, ry = U / 2 - hw - 0.5, V / 2 - 0.3
        field = set()
        for u in range(hw + 1, U - hw - 1):
            for v in range(V):
                if abs((u - cu) / rx) ** 1.6 + abs((v - cv_) / ry) ** 1.6 <= 1.0:
                    field.add((u, v))
        W = rng.choice([2, 2, 3])
        sgn = rng.choice([-1, 1])

        def lane(t):
            return (t[0] + sgn * t[1]) // W

        walls = []
        for u, v in field:
            for d in ("E", "S"):
                n = (u + (d == "E"), v + (d == "S"))
                if n in field and lane((u, v)) != lane(n) and u < U // 2:
                    walls.append(self.le(u, v, d))
        self.draw(walls, rng.randint(5, 8))
        edge_field = [
            self.le(u, v, d)
            for (u, v) in field
            for d in DIRS
            if (u + DX[d], v + DY[d]) not in field and u < U // 2
        ]
        self.draw(edge_field, rng.randint(6, 9))
        for u, v in field:
            if lane((u, v)) % 4 == 0 and rng.random() < 0.5:
                self.tag(self.T(u, v), "rich")
        self.ltag(self.lrect(int(cu) - 1, int(cv_) - 1, 3 - U % 2 + 1, 2), "hot")
        # treasure galleries: pearl cells along the border, one door each
        if cv.closed:
            cells = (
                [(0, y) for y in range(y0, y0 + fh)]
                if self.ft
                else [(x, 0) for x in range(x0, x0 + fw)]
            )
            if self.clear_of(cells, camps=4):
                inward = "E" if self.ft else "S"
                step = "N" if self.ft else "W"
                far = cv.sym == (
                    "x" if self.ft else "y"
                )  # the far border is not a mirror image here
                for t in cells:
                    cv.put(cv.edge(t, inward), 1)
                k = 0
                while k < len(cells):
                    n = rng.randint(3, 4)
                    cell = cells[k : k + n]
                    if len(cell) >= 2:
                        cv.put(cv.edge(cell[0], step), 1)
                        cv.put(cv.edge(rng.choice(cell), inward), 0)
                    k += n
                if far:
                    for t in cells:
                        f = (t[0], cv.h - 1) if not self.ft else (cv.w - 1, t[1])
                        cv.put(cv.edge(f, "N" if not self.ft else "W"), 1)
                    k = 0
                    while k < len(cells):
                        n = rng.randint(3, 4)
                        cell = [
                            (t[0], cv.h - 1) if not self.ft else (cv.w - 1, t[1])
                            for t in cells[k : k + n]
                        ]
                        if len(cell) >= 2:
                            cv.put(cv.edge(cell[0], step), 1)
                            cv.put(
                                cv.edge(rng.choice(cell), "N" if not self.ft else "W"),
                                0,
                            )
                        k += n
                for t in cells:
                    self.tag(t, "hot" if rng.random() < 0.4 else "rich")
                    if far:
                        self.tag(
                            (t[0], cv.h - 1) if not self.ft else (cv.w - 1, t[1]),
                            "rich",
                        )
                self.claim(cells, ring=1)
                if far:
                    self.claim(
                        [
                            (t[0], cv.h - 1) if not self.ft else (cv.w - 1, t[1])
                            for t in cells
                        ],
                        ring=1,
                    )
        self.nest_bias = 0.9

    def lm_lanes(self):
        """Devil's parallel lanes: full-length walls along the axis between the
        camps and the middle, a few gates in each, gold cells at the lane
        ends, alternate lanes rich."""
        cv, rng = self.cv, self.rng
        orients = [
            o
            for o, ok in (("v", cv.sym in ("y", "xy")), ("h", cv.sym in ("x", "xy")))
            if ok
        ]
        for o in rng.sample(orients, len(orients)):
            W, Lh = (cv.w, cv.h) if o == "v" else (cv.h, cv.w)
            ax = (W - 1) / 2
            cs = [c[0] if o == "v" else c[1] for c in self.camps]
            if all(c < ax for c in cs):
                pass
            elif all(c > ax for c in cs):
                cs = [W - 1 - c for c in cs]
            else:
                continue
            start, stop = (
                max(cs) + 4,
                W // 2,
            )  # walls at a in [start, stop]: the W edge of column a
            if stop - start < 3:
                continue

            def tile(a, b, o=o):
                return (a % cv.w, b % cv.h) if o == "v" else (b % cv.w, a % cv.h)

            def E(a, b, d, o=o):
                return cv.edge(tile(a, b), d if o == "v" else self.TMAP[d])

            walls, a = [], start
            while a <= stop:
                walls.append(a)
                a += rng.choice([1, 2, 2, 3])
            if len(walls) < 2 or any(
                tile(a, b) in self.occupied or tile(a, b) in cv.solid
                for a in range(start - 1, stop + 1)
                for b in range(Lh)
            ):
                continue
            end = 1 if cv.closed else 0
            for a in walls:
                if a == W - a:  # on the axis itself: drawn by its mirror
                    continue
                line = [E(a, b, "W") for b in range(Lh)]
                self.lwall(line)
                for _ in range(rng.randint(1, 3)):  # gates
                    g = rng.randint(end + 1, Lh - end - 3)
                    self.lwall(line[g : g + rng.choice([1, 2])], 0)
            # lanes: alternate rich; gold cells shut off at the lane ends
            for k, (a0, a1) in enumerate(zip(walls, walls[1:], strict=False)):
                lane = [tile(a, b) for a in range(a0, a1) for b in range(Lh)]
                if k % 2 == 0:
                    self.ltag(lane, "fair", 0.6)
                if cv.closed and a1 - a0 <= 2:
                    for b in (0, Lh - 1):
                        cap = [tile(a, b) for a in range(a0, a1)]
                        for t in cap:
                            cv.put(
                                cv.edge(t, "S" if b == 0 else "N")
                                if o == "v"
                                else cv.edge(t, "E" if b == 0 else "W"),
                                1,
                            )
                        door = rng.choice(cap)
                        cv.put(
                            cv.edge(door, "S" if b == 0 else "N")
                            if o == "v"
                            else cv.edge(door, "E" if b == 0 else "W"),
                            0,
                        )
                        self.ltag(cap, "hot")
            band = {tile(a, b) for a in range(start - 1, stop + 1) for b in range(Lh)}
            self.claim(band, ring=0)
            self.log(f"{2 * (len(walls) - 1)} lanes")
            return True
        self.log("no room for lanes")
        return False

    # a stroke font on a vertex grid, x right, y down (Help writes with it)
    GLYPHS = {
        "A": [(0, 0, 0, 4), (3, 0, 3, 4), (0, 0, 3, 0), (0, 2, 3, 2)],
        "E": [(0, 0, 0, 4), (0, 0, 3, 0), (0, 2, 2, 2), (0, 4, 3, 4)],
        "G": [(0, 0, 3, 0), (0, 0, 0, 4), (0, 4, 3, 4), (3, 2, 3, 4), (2, 2, 3, 2)],
        "H": [(0, 0, 0, 4), (3, 0, 3, 4), (0, 2, 3, 2)],
        "L": [(0, 0, 0, 4), (0, 4, 3, 4)],
        "N": [
            (0, 0, 0, 4),
            (3, 0, 3, 4),
            (0, 0, 1, 0),
            (1, 0, 1, 2),
            (1, 2, 2, 2),
            (2, 2, 2, 4),
            (2, 4, 3, 4),
        ],
        "O": [(0, 0, 3, 0), (0, 4, 3, 4), (0, 0, 0, 4), (3, 0, 3, 4)],
        "P": [(0, 0, 0, 4), (0, 0, 3, 0), (3, 0, 3, 2), (0, 2, 3, 2)],
        "S": [(0, 0, 3, 0), (0, 0, 0, 2), (0, 2, 3, 2), (3, 2, 3, 4), (0, 4, 3, 4)],
        "T": [(0, 0, 4, 0), (2, 0, 2, 4)],
        "U": [(0, 0, 0, 4), (3, 0, 3, 4), (0, 4, 3, 4)],
    }
    WORDS = [
        "HELP",
        "GO",
        "EAT",
        "NEST",
        "LOOP",
        "HOLE",
        "GATE",
        "SEAL",
        "STOP",
        "SLOT",
        "PLAN",
        "GLUE",
        "TUNNEL",
        "PEN",
        "TOP",
        "HUNT",
        "SNAP",
        "GULP",
        "SPOT",
    ]

    def inscription(self, word=None):
        """A word in kelp strokes on open ground; the mirror writes it again
        the other way round, as on Help."""
        cv, rng = self.cv, self.rng

        def width(wd):
            return sum(
                max(x for s in self.GLYPHS[ch] for x in (s[0], s[2])) for ch in wd
            ) + 2 * (len(wd) - 1)

        room = (cv.w if cv.sym == "x" else cv.w // 2) - 4
        fits = [wd for wd in self.WORDS if width(wd) <= room]
        if not word:
            if not fits:
                return False
            word = rng.choice(fits)
        widths = [max(x for s in self.GLYPHS[ch] for x in (s[0], s[2])) for ch in word]
        tw, th = width(word), 4
        for _ in range(80):
            x0, y0 = rng.randrange(cv.w), rng.randrange(cv.h)
            if cv.closed and not (
                1 <= x0 and x0 + tw <= cv.w - 1 and 1 <= y0 and y0 + th <= cv.h - 1
            ):
                continue
            area = set(self.rect(x0 - 1, y0 - 1, tw + 2, th + 2))
            if {cv.m(t) for t in area} & area or not self.clear_of(area, camps=3):
                continue
            x = x0
            for ch, wd in zip(word, widths, strict=False):
                for a, b, c, d in self.GLYPHS[ch]:
                    if b == d:
                        for k in range(min(a, c), max(a, c)):
                            cv.put(("h", (x + k) % cv.w, (y0 + b) % cv.h), 1)
                    else:
                        for k in range(min(b, d), max(b, d)):
                            cv.put(("v", (x + a) % cv.w, (y0 + k) % cv.h), 1)
                x += wd + 2
            self.claim(area, ring=0)
            self.log(f"the word {word}")
            return True
        return False

    # ---------------------------------------------------------- spiral nests
    def nest(self, camp, L):
        """A square spiral round a camp, as the coiled starts of Slithery
        Fight: one corridor winding in, walls between its turns. The first
        dragon lies coiled in it, head at the mouth."""
        cv, rng = self.cv, self.rng
        if rng.random() < 0.6:
            k = 3
            while k * k < L + 2:
                k += 1
            path = [camp]
            x, y = camp
            dirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]
            seg, di = 1, rng.randrange(4)
            turn = rng.choice([1, -1])
            while len(path) < k * k:
                for _ in range(2):
                    dx, dy = dirs[di % 4]
                    for _s in range(seg):
                        if len(path) >= k * k:
                            break
                        x, y = x + dx, y + dy
                        path.append((x, y))
                    di += turn
                seg += 1
        else:
            # a zig-zag channel instead, rows back and forth (community1)
            bw = rng.randint(3, 6)
            rows = max(2, -(-(L + 2) // bw))
            sx, sy = rng.choice([1, -1]), rng.choice([1, -1])
            path = []
            for r in range(rows):
                xs = range(bw) if r % 2 == 0 else range(bw - 1, -1, -1)
                path += [(camp[0] + sx * x, camp[1] + sy * r) for x in xs]
            if rng.random() < 0.5:
                path = [
                    (camp[0] + (y - camp[1]), camp[1] + (x - camp[0])) for x, y in path
                ]
        if cv.closed and any(
            not (1 <= px < cv.w - 1 and 1 <= py < cv.h - 1) for px, py in path
        ):
            return None
        path = [(px % cv.w, py % cv.h) for px, py in path]
        sq = set(path)
        ring = sq | {cv.nb(t, d) for t in sq for d in DIRS}
        if {cv.m(t) for t in ring} & ring:
            return None
        if any(t in cv.solid or t in self.occupied for t in ring):
            return None
        if any(cv.kind.get(cv.edge(t, d), 0) for t in sq for d in DIRS):
            return None
        idx = {t: i for i, t in enumerate(path)}
        for t in path:
            for d in DIRS:
                n = cv.nb(t, d)
                if n not in sq or abs(idx[n] - idx[t]) != 1:
                    cv.put(cv.edge(t, d), 1)
        mouth = path[-1]
        hx, hy = (cv.w - 1) / 2, (cv.h - 1) / 2
        outs = [d for d in DIRS if cv.nb(mouth, d) not in sq]
        d = max(outs, key=lambda d: DX[d] * (hx - mouth[0]) + DY[d] * (hy - mouth[1]))
        cv.put(cv.edge(mouth, d), 0)
        self.occupied |= ring | {cv.m(t) for t in ring}
        return path[::-1]

    # ---------------------------------------------------------- stage 6: architecture
    def R(self, x0, y0, dx, dy):
        return ((x0 + dx) % self.cv.w, (y0 + dy) % self.cv.h)

    def rect(self, x0, y0, bw, bh):
        return [self.R(x0, y0, dx, dy) for dy in range(bh) for dx in range(bw)]

    def side(self, x0, y0, bw, bh, d):
        """The perimeter edges of a rectangle on one side, in order."""
        cv = self.cv
        if d == "N":
            return [cv.edge(self.R(x0, y0, dx, 0), "N") for dx in range(bw)]
        if d == "S":
            return [cv.edge(self.R(x0, y0, dx, bh - 1), "S") for dx in range(bw)]
        if d == "W":
            return [cv.edge(self.R(x0, y0, 0, dy), "W") for dy in range(bh)]
        return [cv.edge(self.R(x0, y0, bw - 1, dy), "E") for dy in range(bh)]

    def door(self, edges, width=1):
        """Open a doorway in a run of wall, away from the corners."""
        n = len(edges)
        width = min(width, max(1, n - 2))
        lo, hi = (1, n - 1 - width) if n >= 3 else (0, n - width)
        pos = self.rng.randint(lo, max(lo, hi))
        for e in edges[pos : pos + width]:
            self.cv.put(e, 0)

    def facing(self, x0, y0, bw, bh):
        """Sides of a footprint, the one facing the heart of the map first."""
        cv = self.cv
        hx, hy = (cv.w - 1) / 2, (cv.h - 1) / 2
        cx, cy = x0 + (bw - 1) / 2, y0 + (bh - 1) / 2
        dx, dy = hx - cx, hy - cy
        order = sorted(DIRS, key=lambda d: -(DX[d] * dx + DY[d] * dy))
        return order

    def site(self, i, bw, bh, allow=()):
        """A clean footprint near district i's seed: mostly inside the district, off
        other structures (with a one-tile walkway round it), clear of rock and
        kelp, and clear of its own mirror image."""
        cv, rng = self.cv, self.rng
        memset = self.memset[i]
        sx, sy = self.seeds[i]
        best, bs = None, 1e9
        mem = self.members[i]
        if not mem:
            return None  # a district swallowed whole by its neighbours
        for _ in range(120):
            cx, cy = rng.choice(mem)
            x0, y0 = cx - bw // 2, cy - bh // 2
            if cv.closed and (
                x0 < 1 or y0 < 1 or x0 + bw > cv.w - 1 or y0 + bh > cv.h - 1
            ):
                continue
            if not cv.closed and (bw > cv.w - 2 or bh > cv.h - 2):
                continue
            tiles = self.rect(x0, y0, bw, bh)
            if sum(t in memset for t in tiles) < 0.5 * len(tiles):
                continue  # a building may straddle a district line, not live across it
            ring = set(self.rect(x0 - 1, y0 - 1, bw + 2, bh + 2))
            if ring & self.occupied or any(t in cv.solid for t in ring):
                continue
            if any(
                self.tbiome[t] in ("camp", "vault") and self.tbiome[t] not in allow
                for t in tiles
            ):
                continue
            if any(cv.kind.get(cv.edge(t, d), 0) for t in tiles for d in DIRS):
                continue
            mring = {cv.m(t) for t in ring}
            if mring & ring:
                continue
            sc = cv.dist((x0 + bw / 2, y0 + bh / 2), (sx, sy)) + rng.random()
            if sc < bs:
                best, bs = (x0, y0), sc
        if best:
            ring = set(self.rect(best[0] - 1, best[1] - 1, bw + 2, bh + 2))
            self.occupied |= ring | {cv.m(t) for t in ring}
        return best

    def fit(self, lo, hi):
        """A building dimension in [lo, hi], capped by what the map can hold
        beside its own mirror image; None when even lo does not fit."""
        cap = max(3, min(self.cv.w, self.cv.h) // 2 - 2)
        return self.rng.randint(lo, min(hi, cap)) if cap >= lo else None

    def architecture(self):
        """Buildings, chosen by biome and style, placed where they fit."""
        rng = self.rng
        self.memset = {i: set(m) for i, m in self.members.items()}
        self.nest_path = None
        if self.style.get("open"):
            self.buildings = self.want_buildings = 0
            return
        built = {}
        # camps first: the first may hold a spiral nest, the rest a stockade
        if rng.random() < max(self.style["nest"], self.nest_bias):
            L = rng.randint(5, 12)
            self.nest_path = self.nest(self.camps[0], L)
            if self.nest_path:
                self.nest_len = L
                built["nest"] = 1
        for c in self.camps:
            if self.nest_path and c == self.camps[0]:
                continue
            if rng.random() < self.style["stockade"] and self.stockade(c):
                built["stockade"] = built.get("stockade", 0) + 1
        mult = self.style["build"]
        for i in sorted(
            range(len(self.seeds)), key=lambda j: (self.roles[j] != "frontier", j)
        ):
            if i > self.smir[i]:
                continue
            options = BIOMES[self.biome[i]]["build"]
            if not options:
                continue
            size = len(self.members[i])
            count = min(4, 1 + size // 70)
            for _ in range(count):
                kinds = [k for k, _ in options]
                weights = [wt * mult.get(k, 1.0) for k, wt in options]
                kind = rng.choices(kinds, weights)[0]
                if kind and getattr(self, "b_" + kind)(i):
                    built[kind] = built.get(kind, 0) + 1
        # every world has architecture: open styles leave ground empty by
        # choice, but never the whole map
        want = max(1 if self.lm_built else 2, round((self.area - self.lm_area) / 280))
        candidates = [
            i
            for i in range(len(self.seeds))
            if i <= self.smir[i] and any(k for k, _ in BIOMES[self.biome[i]]["build"])
        ]
        for _ in range(40):
            if sum(built.values()) - built.get("stockade", 0) >= want or not candidates:
                break
            i = rng.choice(candidates)
            options = [
                (k, wt * mult.get(k, 1.0))
                for k, wt in BIOMES[self.biome[i]]["build"]
                if k
            ]
            kind = rng.choices([k for k, _ in options], [wt for _, wt in options])[0]
            if getattr(self, "b_" + kind)(i):
                built[kind] = built.get(kind, 0) + 1
        self.buildings = sum(built.values())
        self.want_buildings = want
        if built:
            self.log(
                ", ".join(
                    f"{n} {k}" + ("s" if n > 1 and not k.endswith("s") else "")
                    for k, n in sorted(built.items())
                )
            )

    def b_room(self, i):
        rng = self.rng
        bw, bh = self.fit(3, 6), self.fit(3, 5)
        if rng.random() < 0.5:
            bw, bh = bh, bw
        at = self.site(i, bw, bh)
        if not at:
            return False
        x0, y0 = at
        tiles = self.rect(x0, y0, bw, bh)
        self.cv.enclose(tiles)
        sides = self.facing(x0, y0, bw, bh)
        self.door(self.side(x0, y0, bw, bh, sides[0]), rng.choice([1, 1, 2]))
        one_door = rng.random() < 0.4
        if not one_door:
            self.door(self.side(x0, y0, bw, bh, rng.choice(sides[1:])))
        # a one-door room is a pocket: worth more, and a trap
        tier = "rich" if one_door else "fair"
        for t in tiles:
            self.tag(t, tier)
        return True

    def b_complex(self, i):
        """A building of several rooms: binary space partition, one door per
        inner wall, two ways in. The deepest room holds the treasure."""
        cv, rng = self.cv, self.rng
        cap = max(6, int(math.sqrt(len(self.members[i]))) + 1)
        bw, bh = self.fit(6, min(10, cap + 2)), self.fit(5, min(8, cap))
        if bw is None or bh is None:
            return self.b_room(i)
        if rng.random() < 0.5:
            bw, bh = bh, bw
        at = self.site(i, bw, bh)
        if not at:
            return False
        x0, y0 = at
        leaves = []

        def split(x, y, ww, hh, depth):
            can_v, can_h = ww >= 6, hh >= 6
            if (
                not (can_v or can_h)
                or ww * hh <= 12
                or (depth >= 2 and rng.random() < 0.4)
            ):
                leaves.append((x, y, ww, hh))
                return
            vertical = can_v and (
                not can_h or ww > hh or (ww == hh and rng.random() < 0.5)
            )
            if vertical:
                c = rng.randint(3, ww - 3)
                wall = [cv.edge(self.R(x0, y0, x + c, y + dy), "W") for dy in range(hh)]
                split(x, y, c, hh, depth + 1)
                split(x + c, y, ww - c, hh, depth + 1)
            else:
                c = rng.randint(3, hh - 3)
                wall = [cv.edge(self.R(x0, y0, x + dx, y + c), "N") for dx in range(ww)]
                split(x, y, ww, c, depth + 1)
                split(x, y + c, ww, hh - c, depth + 1)
            for e in wall:
                cv.put(e, 1)
            self.door(wall, 2 if len(wall) >= 6 and rng.random() < 0.3 else 1)

        tiles = self.rect(x0, y0, bw, bh)
        cv.enclose(tiles)
        split(0, 0, bw, bh, 0)
        sides = self.facing(x0, y0, bw, bh)
        entry = []
        for d in (sides[0], rng.choice(sides[2:])):
            run = self.side(x0, y0, bw, bh, d)
            self.door(run, rng.choice([1, 2]))
            entry += [
                t
                for e in run
                if cv.kind.get(e, 0) == 0
                for t in cv.sides(e)
                if t in set(tiles)
            ]
        inside = set(tiles)
        depth = cv.bfs(entry, block={t for t in cv.tiles if t not in inside})
        rooms = []
        for x, y, ww, hh in leaves:
            rt = self.rect(x0 + x, y0 + y, ww, hh)
            rooms.append((min(depth.get(t, 99) for t in rt), rt))
        rooms.sort(key=lambda r: -r[0])
        for k, (_, rt) in enumerate(rooms):
            tier = (
                ("hot" if len(rt) <= 9 else "rich")
                if k == 0
                else "fair"
                if k == 1
                else None
            )
            if tier:
                for t in rt:
                    self.tag(t, tier)
        return True

    def b_labyrinth(self, i):
        """A walled labyrinth: 2x2 cells, or a dense 1-wide warren; a perfect
        maze with a few loops, two or three gates, pearls in its dead ends."""
        cv, rng = self.cv, self.rng
        side = int(math.sqrt(len(self.members[i])))
        c = rng.choice([1, 2])
        lim = max(3, min(cv.w, cv.h) // 2 - 2) // c
        if lim < 3:
            return self.b_room(i)
        at = None
        top = 8 if c == 2 else 14
        for cw, chh in sorted(
            {
                (
                    max(3, min(top, lim, side // c + a)),
                    max(3, min(top - 1, lim, side // c + b)),
                )
                for a in (0, -1, -2, -4)
                for b in (0, -1, -2, -4)
            },
            key=lambda p: -p[0] * p[1],
        ):
            if rng.random() < 0.5:
                cw, chh = chh, cw
            at = self.site(i, c * cw, c * chh)
            if at:
                break
        if not at:
            return False
        x0, y0 = at
        bw, bh = c * cw, c * chh
        cv.enclose(self.rect(x0, y0, bw, bh))
        links = self.maze(cw, chh, 0.08)

        def E(u, v, d):
            return cv.edge(self.R(x0, y0, u, v), d)

        self.draw_maze(self.bounds(bw, c), self.bounds(bh, c), links, E)
        sides = self.facing(x0, y0, bw, bh)
        for dside in [sides[0], OPP[sides[0]]] + (
            [rng.choice(sides[1:3])] if rng.random() < 0.6 else []
        ):
            run = self.side(x0, y0, bw, bh, dside)
            k = rng.randrange(len(run) // c)
            for e in run[c * k : c * k + c]:
                cv.put(e, 0)
        degree = {}
        for pr in links:
            for cell in pr:
                degree[cell] = degree.get(cell, 0) + 1
        for (a, b), dg in degree.items():
            if dg == 1 and (c == 2 or rng.random() < 0.5):
                for t in self.rect(x0 + c * a, y0 + c * b, c, c):
                    self.tag(t, "rich")
        return True

    def b_cloister(self, i):
        """A walled ring round an inner sanctum; the two doors never line up."""
        rng = self.rng
        bw, bh = self.fit(7, 9), self.fit(7, 8)
        if bw is None or bh is None:
            return self.b_complex(i)
        at = self.site(i, bw, bh)
        if not at:
            return False
        x0, y0 = at
        cv = self.cv
        cv.enclose(self.rect(x0, y0, bw, bh))
        inner = self.rect(x0 + 2, y0 + 2, bw - 4, bh - 4)
        cv.enclose(inner)
        sides = self.facing(x0, y0, bw, bh)
        self.door(self.side(x0, y0, bw, bh, sides[0]), rng.choice([1, 2]))
        self.door(self.side(x0 + 2, y0 + 2, bw - 4, bh - 4, OPP[sides[0]]))
        for t in inner:
            self.tag(t, "rich")
        return True

    def b_stalls(self, i):
        """Two rows of 2x2 stalls facing a two-wide aisle, one door each,
        like the pearl boxes of the official Portals map."""
        rng = self.rng
        cv = self.cv
        k = self.fit(4, 8)
        if k is None or self.fit(6, 6) is None:
            return self.b_room(i)
        k //= 2
        horiz = rng.random() < 0.5
        bw, bh = (2 * k, 6) if horiz else (6, 2 * k)
        at = self.site(i, bw, bh)
        if not at:
            return False
        x0, y0 = at
        for j in range(k):
            for row in (0, 4):
                sx, sy = (x0 + 2 * j, y0 + row) if horiz else (x0 + row, y0 + 2 * j)
                cell = self.rect(sx, sy, 2, 2)
                cv.enclose(cell)
                front = (
                    ("S" if row == 0 else "N") if horiz else ("E" if row == 0 else "W")
                )
                run = self.side(sx, sy, 2, 2, front)
                cv.put(run[rng.randrange(2)], 0)
                tier = "rich" if rng.random() < 0.35 else "fair"
                for t in cell:
                    self.tag(t, tier)
        return True

    def b_colonnade(self, i):
        """A plaza of pillars three apart: cover to weave through, pearls between."""
        rng = self.rng
        bw, bh = self.fit(5, 10), self.fit(5, 9)
        if bw is None or bh is None:
            return self.b_room(i)
        at = self.site(i, bw, bh)
        if not at:
            return False
        x0, y0 = at
        ox, oy = rng.randint(1, 2), rng.randint(1, 2)
        for dy in range(oy, bh, 3):
            for dx in range(ox, bw, 3):
                self.cv.post(self.R(x0, y0, dx, dy))
        for t in self.rect(x0, y0, bw, bh):
            if rng.random() < 0.6:
                self.tag(t, "fair")
        return True

    def b_rampart(self, i):
        """A breakwater: one long straight wall across open water, with gates."""
        cv, rng = self.cv, self.rng
        memset = self.memset[i]
        sx, sy = (
            int(round(self.seeds[i][0])) % cv.w,
            int(round(self.seeds[i][1])) % cv.h,
        )
        horiz = rng.random() < 0.5
        run = [(sx, sy)]
        for sgn in (-1, 1):
            t = (sx, sy)
            while True:
                t = cv.nb(
                    t, ("E" if sgn > 0 else "W") if horiz else ("S" if sgn > 0 else "N")
                )
                if (
                    t not in memset
                    or t in self.occupied
                    or t in cv.solid
                    or t in run
                    or len(run) > 30
                ):
                    break
                run.append(t)
        run.sort()
        if len(run) < 8:
            return False
        chain = [cv.edge(t, "N" if horiz else "W") for t in run]
        if any(cv.kind.get(e, 0) or cv.me(e) in chain for e in chain):
            return False
        self.wall_chain(chain, rng.randint(5, 8))
        band = set()
        for t in run:
            band |= {t, cv.nb(t, "N" if horiz else "W")}
        self.occupied |= band | {cv.m(t) for t in band}
        return True

    def stockade(self, camp):
        """A gated palisade round a spawn clearing."""
        cv, rng = self.cv, self.rng
        r = rng.choice([3, 3, 4])
        x0, y0 = camp[0] - r, camp[1] - r
        n = 2 * r + 1
        if cv.closed and (x0 < 1 or y0 < 1 or x0 + n > cv.w - 1 or y0 + n > cv.h - 1):
            return False
        tiles = self.rect(x0, y0, n, n)
        ring = set(self.rect(x0 - 1, y0 - 1, n + 2, n + 2))
        if (
            ring & self.occupied
            or any(t in cv.solid for t in ring)
            or {cv.m(t) for t in ring} & ring
        ):
            return False
        if any(cv.kind.get(cv.edge(t, d), 0) for t in tiles for d in DIRS):
            return False
        chain = (
            self.side(x0, y0, n, n, "N")
            + self.side(x0, y0, n, n, "E")
            + self.side(x0, y0, n, n, "S")[::-1]
            + self.side(x0, y0, n, n, "W")[::-1]
        )
        self.wall_chain(chain, rng.randint(5, 7))
        self.occupied |= ring | {cv.m(t) for t in ring}
        return True

    # ---------------------------------------------------------- stage 6: structures
    def tag(self, t, tier):
        for s in {t, self.cv.m(t)}:
            if TIER_RANK[tier] > TIER_RANK.get(self.tier.get(s, "dead"), 0):
                self.tier[s] = tier

    def vault(self):
        cv, rng = self.cv, self.rng
        hearts = [
            i
            for i in range(len(self.seeds))
            if self.biome[i] == "vault" and i <= self.smir[i]
        ]
        for i in hearts:
            sx, sy = self.seeds[i]
            mem = set(self.members[i])
            size = len(mem)
            cap = max(1, min(3, int(math.sqrt(self.area * 0.04) / 2)))
            hw = max(1, min(cap, int(math.sqrt(size) / 3) + rng.randint(0, 1)))
            hh = max(1, min(cap, int(math.sqrt(size) / 3) + rng.randint(0, 1)))
            x0, y0 = math.floor(sx - hw + 0.5), math.floor(sy - hh + 0.5)
            x1 = (
                cv.w - 1 - x0
                if cv.sym in ("y", "xy") and self.smir[i] == i
                else x0 + 2 * hw - 1
            )
            y1 = (
                cv.h - 1 - y0
                if cv.sym in ("x", "xy") and self.smir[i] == i
                else y0 + 2 * hh - 1
            )
            if x1 < x0 or y1 < y0:
                continue
            room = [
                (x % cv.w, y % cv.h)
                for x in range(x0, x1 + 1)
                for y in range(y0, y1 + 1)
            ]
            kind = rng.choice(["room", "keep", "cross", "room"])
            if kind == "keep" and (x1 - x0 < 3 or y1 - y0 < 3):
                kind = "room"
            cv.enclose(room)
            rs = set(room)
            for t in room:
                for d in list(DIRS) + [None]:
                    u = cv.nb(t, d) if d else t
                    self.occupied |= {u, cv.m(u)}
                    for d2 in DIRS:
                        self.occupied.add(cv.nb(u, d2))
                        self.occupied.add(cv.m(cv.nb(u, d2)))
            perim = sorted(
                {cv.edge(t, d) for t in room for d in DIRS if cv.nb(t, d) not in rs}
            )
            if kind == "cross":
                # doors in the middle of every side
                cxm, cym = (x0 + x1) / 2, (y0 + y1) / 2
                for e in perim:
                    a, b = cv.sides(e)
                    t = a if a in rs else b
                    if abs(t[0] - cxm) < 0.6 or abs(t[1] - cym) < 0.6:
                        cv.put(e, 0)
            else:
                for _ in range(rng.randint(1, 2)):
                    cv.put(rng.choice(perim), 0)
            inner = room
            if kind == "keep":
                inner = [
                    (x % cv.w, y % cv.h)
                    for x in range(x0 + 1, x1)
                    for y in range(y0 + 1, y1)
                ]
                cv.enclose(inner)
                ins = set(inner)
                ip = sorted(
                    {
                        cv.edge(t, d)
                        for t in inner
                        for d in DIRS
                        if cv.nb(t, d) not in ins
                    }
                )
                cv.put(rng.choice(ip), 0)
            for t in room:
                self.tag(t, "rich")
            core = sorted(inner, key=lambda t: cv.dist(t, (sx, sy)))[
                : max(1, len(inner) // 3)
            ]
            for t in core:
                self.tag(t, "hot")
            self.log(f"vault {kind} {x1 - x0 + 1}x{y1 - y0 + 1}")

    def free_box(self, x, y, bw, bh):
        cv = self.cv
        box = [
            ((x + dx) % cv.w, (y + dy) % cv.h) for dx in range(bw) for dy in range(bh)
        ]
        mb = {cv.m(t) for t in box}
        if mb & set(box):
            return None
        ring = set()
        for t in box:
            for d in DIRS:
                ring.add(cv.nb(t, d))
                if cv.kind.get(cv.edge(t, d), 0):
                    return None
        if ring & mb:
            return None
        for t in list(ring) + box:
            if (
                t in cv.solid
                or t in self.occupied
                or self.tbiome.get(t) in ("camp", "vault")
            ):
                return None
        return box

    def shrines(self):
        cv, rng = self.cv, self.rng
        lo, hi = self.style["shrine"]
        want = rng.randint(lo, hi)
        made = 0
        for _ in range(want * 30):
            if made >= want:
                break
            bw, bh = rng.choice([(1, 1), (2, 1), (1, 2), (2, 2), (2, 2)])
            x, y = rng.randrange(cv.w), rng.randrange(cv.h)
            if not cv.is_canon((x, y)):
                continue
            box = self.free_box(x, y, bw, bh)
            if not box:
                continue
            bs = set(box)
            perim = [cv.edge(t, d) for t in box for d in DIRS if cv.nb(t, d) not in bs]
            e1 = rng.choice(perim)
            # the anchor: a door in an existing wall far from the shrine,
            # else open ground
            reach = cv.bfs([cv.nb(box[0], "N")])
            cands = []
            for e, k in sorted(cv.kind.items()) + [
                (cv.edge(t, rng.choice(DIRS)), 0)
                for t in rng.sample(cv.tiles, min(200, len(cv.tiles)))
            ]:
                if e[0] != e1[0] or k == 2 or cv.is_border(e):
                    continue
                a, b = cv.sides(e)
                if a in cv.solid or b in cv.solid or a in bs or b in bs:
                    continue
                if a not in reach and b not in reach:
                    continue
                far = cv.dist(a, box[0])
                if far < 6:
                    continue
                cands.append((far * rng.uniform(0.5, 1.5) + (4 if k == 1 else 0), e))
            if not cands:
                continue
            cands.sort(reverse=True)
            e2 = cands[0][1]
            snapshot = dict(cv.kind)
            cv.enclose(box)
            if not cv.link(e1, e2):
                cv.kind = snapshot
                continue
            for t in box:
                self.occupied |= {t, cv.m(t)}
            for t in box:
                self.tag(t, "rich" if len(box) > 1 else "hot")
            made += 1
        if made:
            self.log(f"{made} portal shrine pair(s)")

    def wormholes(self):
        cv, rng = self.cv, self.rng
        lo, hi = self.style["worm"]
        want = rng.randint(lo, hi)
        made = 0
        for _ in range(want * 40):
            if made >= want:
                break
            t = rng.choice(cv.tiles)
            if (
                not cv.is_canon(t)
                or t in cv.solid
                or self.tbiome.get(t) in ("camp", "vault")
            ):
                continue
            e = cv.edge(t, rng.choice(DIRS))
            if cv.kind.get(e, 0) == 2 or cv.is_border(e):
                continue
            a, b = cv.sides(e)
            if (
                a in cv.solid
                or b in cv.solid
                or a in self.occupied
                or b in self.occupied
            ):
                continue
            me = cv.me(e)
            if cv.dist(a, cv.sides(me)[0]) < min(cv.w, cv.h) * 0.4:
                continue
            if cv.link(e, me):
                made += 1
        if made:
            self.log(f"{made} wormhole(s)")

    def groves(self):
        cv, rng = self.cv, self.rng
        n = max(1, round(self.area / 350 * rng.uniform(0.5, 1.5)))

        def shelter(t):
            k = 0
            for dx in range(-2, 3):
                for dy in range(-2, 3):
                    u = ((t[0] + dx) % cv.w, (t[1] + dy) % cv.h)
                    k += sum(1 for d in "NW" if cv.kind.get(cv.edge(u, d), 0) == 1)
            return min(1.0, k / 12)

        peaks = sorted(
            (
                t
                for t in cv.tiles
                if cv.is_canon(t)
                and t not in cv.solid
                and t not in self.occupied
                and self.tbiome.get(t) not in ("vault", "camp")
            ),
            key=lambda t: (
                -(
                    self.fert[t] * BIOMES[self.tbiome[t]]["fert"]
                    + 0.6 * shelter(t)
                    + 0.2 * rng.random()
                )
            ),
        )
        used = []
        for t in peaks:
            if len(used) >= n:
                break
            if any(cv.dist(t, u) < 7 for u in used) or cv.dist(t, cv.m(t)) < 3:
                continue
            used.append(t)
            size = rng.randint(3, 9)
            blob, frontier = {t}, [t]
            while frontier and len(blob) < size:
                c = frontier.pop(rng.randrange(len(frontier)))
                for d in DIRS:
                    n2 = cv.step(c, d)
                    if (
                        n2
                        and n2 not in blob
                        and cv.m(n2) not in blob
                        and n2 not in self.occupied
                    ):
                        blob.add(n2)
                        frontier.append(n2)
            tier = "rich" if rng.random() < 0.5 else "fair"
            for b in blob:
                self.tag(b, tier)
        self.log(f"{len(used)} grove(s)")

    # ---------------------------------------------------------- stage 7
    def repair(self):
        cv, rng = self.cv, self.rng
        for _round in range(400):
            left = [t for t in cv.tiles if t not in cv.solid]
            comp, sizes = {}, []
            for t in left:
                if t in comp:
                    continue
                d = cv.bfs([t])
                cid = len(sizes)
                for u in d:
                    comp[u] = cid
                sizes.append(len(d))
            if len(sizes) <= 1:
                return True
            main = max(range(len(sizes)), key=lambda c: sizes[c])
            small = sorted(
                (c for c in range(len(sizes)) if c != main), key=lambda c: sizes[c]
            )
            c = small[0]
            tiles = sorted(t for t in comp if comp[t] == c)
            doors_main, doors_any = [], []
            for t in tiles:
                for d in DIRS:
                    e = cv.edge(t, d)
                    if cv.kind.get(e, 0) != 1 or cv.is_border(e):
                        continue
                    n = cv.nb(t, d)
                    if n in cv.solid or comp.get(n) == c:
                        continue
                    (doors_main if comp.get(n) == main else doors_any).append(e)
            doors = doors_main or doors_any
            if not doors:
                for t in tiles:
                    cv.make_solid(t)
                    self.tier.pop(t, None)
                    self.tier.pop(cv.m(t), None)
                continue
            cv.put(rng.choice(doors), 0)
        return False

    # ---------------------------------------------------------- stage 8
    def economy(self):
        cv, rng = self.cv, self.rng
        # camp food: a little early income inside each camp
        for c in self.camps:
            near = cv.bfs([c]) if c not in cv.solid else {}
            for t, dd in near.items():
                if 2 <= dd <= 5 and rng.random() < 0.35:
                    self.tag(t, "fair")
        cover = rng.choice([0.0, 0.05, 0.15, 0.3, 1.0])
        blanket = rng.random() < 0.3  # every live tile spawns, as on Big Empty or Help
        for t in cv.tiles:
            if not cv.is_canon(t) or t in cv.solid:
                continue
            b = self.tbiome[t]
            v = self.fert[t] * BIOMES[b]["fert"]
            if v > 1.2:
                self.tag(t, "fair")
            elif blanket or rng.random() < cover * min(1.0, v * 1.5):
                self.tag(t, "bg")
        pal = {
            "hot": [1, rng.choice([1, 1, 2, 3, 5])],
            "rich": [rng.randint(1, 5), rng.randint(10, 60)],
            "fair": [rng.randint(1, 20), rng.randint(80, 300)],
            "bg": [1, rng.choice([500, 1000, 1500, 2559, 3849])],
        }
        target = self.req_supply
        live = [
            t
            for t in cv.tiles
            if self.tier.get(t, "dead") != "dead" and t not in cv.solid
        ]
        # hot tiles at most ~60% of the budget: demote the outer ones to rich
        hot = sorted(
            (t for t in live if self.tier[t] == "hot"), key=lambda t: rng.random()
        )
        per_hot = 2 / (pal["hot"][0] + pal["hot"][1])
        keep = int(target * 0.6 / per_hot)
        keep -= keep % 2 if cv.sym else 0
        for t in hot[keep:]:
            self.tier[t] = "rich"
        for t in cv.tiles:  # restore symmetry after the shuffle
            if cv.is_canon(t):
                a, b = self.tier.get(t, "dead"), self.tier.get(cv.m(t), "dead")
                if a != b:
                    top = a if TIER_RANK[a] < TIER_RANK[b] else b
                    self.tier[t] = self.tier[cv.m(t)] = top
        # Most official maps use one or two gap classes: fold the tiers together.
        classes = rng.choice([1, 2, 2, None, None])
        fold = {
            1: {"hot": "fair", "rich": "fair", "bg": "fair"},
            2: {"hot": "rich", "fair": "bg"},
        }.get(classes, {})
        for t in live:
            self.tier[t] = fold.get(self.tier[t], self.tier[t])
        hot_supply = sum(per_hot for t in live if self.tier[t] == "hot")
        rest = [t for t in live if self.tier[t] in ("rich", "fair", "bg")]

        def supply(k):
            s = 0.0
            for t in rest:
                lo, hi = pal[self.tier[t]]
                s += 2 / (lo + max(lo, round(hi * k)))
            return s

        goal = max(0.3, target - hot_supply)
        lo_k, hi_k = 0.05, 60.0
        for _ in range(40):
            mid = math.sqrt(lo_k * hi_k)
            if supply(mid) > goal:
                lo_k = mid
            else:
                hi_k = mid
        k = math.sqrt(lo_k * hi_k)
        for tier in ("rich", "fair", "bg"):
            pal[tier][1] = max(pal[tier][0], round(pal[tier][1] * k))
        self.palette = pal
        self.gap = {}
        for t in cv.tiles:
            tier = self.tier.get(t, "dead")
            self.gap[t] = (
                (0, 0) if tier == "dead" or t in cv.solid else tuple(pal[tier])
            )
        self.supply = sum(2 / (a + b) for a, b in self.gap.values() if b > 0)
        self.target = target

    # ---------------------------------------------------------- stage 9
    def spawns(self):
        cv, rng = self.cv, self.rng
        n = self.per_side
        lengths = [rng.choice([2, 3, 3, 4, 4, 5]) for _ in range(n)]
        # A flagship, as Dilemma (11), Autarky and Help (14) and Slithery
        # Fight (25) start with; the organisers promise more such maps.
        if rng.random() < 0.25:
            lengths[0] = rng.randint(6, 16)
        if rng.random() < 0.08 and self.area > 500:
            lengths[0] = rng.randint(17, 25)
        taken = set()
        dragons = []
        enemy_anchor = [cv.m(c) for c in self.camps]
        away = cv.bfs([a for a in enemy_anchor if a not in cv.solid])
        anchor = {c: c for c in self.camps}
        if self.nest_path:
            # the first dragon lies coiled in the nest, head at the mouth; the
            # nest's other tiles stay empty, and its camp's other dragons
            # start outside the mouth
            lengths[0] = min(self.nest_len, len(self.nest_path))
            taken |= set(self.nest_path)
            mouth = self.nest_path[0]
            outside = [cv.step(mouth, d) for d in DIRS]
            outside = [t for t in outside if t and t not in taken]
            if not outside:
                self.why = "no way out of the nest"
                return False
            anchor[self.camps[0]] = outside[0]
            taken.add(outside[0])  # the mouth stays clear
        for i, L in enumerate(lengths):
            camp = anchor[self.camps[i % len(self.camps)]]
            if i == 0 and self.nest_path:
                dragons.append(self.nest_path[:L])
                continue
            if camp in cv.solid:
                self.why = "camp blocked"
                return False
            ring = cv.bfs([camp], block=taken | {cv.m(t) for t in taken})
            cand = sorted(
                (
                    t
                    for t in ring
                    if t not in taken and cv.m(t) not in taken and cv.m(t) != t
                ),
                key=lambda t: ring[t] + rng.random() * 2,
            )
            placed = None
            for head in cand[:40]:
                body = self.grow(head, L, taken, away)
                if body:
                    placed = body
                    break
            if not placed:
                self.why = "no room to coil a dragon"
                return False
            taken |= set(placed)
            dragons.append(placed)
        taken = {t for d in dragons for t in d}
        mt = {cv.m(t) for t in taken}
        if mt & taken:
            self.why = "bodies overlap their mirror"
            return False
        self.dragons = dragons
        heads_b = [cv.m(d[0]) for d in dragons]
        da = cv.bfs([d[0] for d in dragons], block=taken | mt)
        meet = min((da.get(hb, 999) for hb in heads_b), default=999)
        if meet < 6:
            self.why = f"first contact {meet} steps"
            return False
        for d in dragons:
            if cv.exits(d[0], block=taken | mt) < 1:
                self.why = "a head with no exit"
                return False
        return True

    def grow(self, head, L, taken, away):
        """Self-avoiding body from the head backwards, away from the enemy."""
        cv, rng = self.cv, self.rng
        bad = taken | {cv.m(t) for t in taken}
        for _try in range(30):
            body = [head]
            prev = None
            ok = True
            while len(body) < L:
                t = body[-1]
                opts = []
                for d in DIRS:
                    e = cv.edge(t, d)
                    if cv.kind.get(e, 0):
                        continue  # bodies never straddle kelp or portals
                    n = cv.nb(t, d)
                    if (
                        n in cv.solid
                        or n in bad
                        or n in body
                        or cv.m(n) in body
                        or cv.m(n) == n
                    ):
                        continue
                    s = (
                        away.get(n, 0)
                        - away.get(t, 0)
                        + (1.5 if d == prev else 0)
                        + rng.random() * 1.2
                    )
                    opts.append((s, d, n))
                if not opts:
                    ok = False
                    break
                opts.sort(reverse=True)
                _, prev, n = opts[0]
                body.append(n)
            if (
                ok
                and cv.exits(head, block=bad | set(body) | {cv.m(t) for t in body}) >= 2
            ):
                return body
        return None

    # ---------------------------------------------------------- stage 10
    def judge(self):
        cv = self.cv
        allb = {t for d in self.dragons for t in d}
        allb |= {cv.m(t) for t in allb}
        ha = [d[0] for d in self.dragons]
        hb = [cv.m(h) for h in ha]
        da, db = cv.bfs(ha), cv.bfs(hb)
        live = [t for t in cv.tiles if t not in cv.solid]
        if any(t not in da for t in live):
            return None
        sup = {t: 2 / (a + b) for t, (a, b) in self.gap.items() if b > 0}
        total = sum(sup.values()) or 1
        contested = sum(v for t, v in sup.items() if abs(da[t] - db[t]) <= 2) / total
        early = sum(v for t, v in sup.items() if da[t] <= 8) / total
        meet = min(db[h] for h in ha)
        span = (cv.w + cv.h) / 2
        rng = random.Random(self.seed ^ 0x5EED)
        srcs = rng.sample(live, min(16, len(live)))
        det = []
        for s in srcs:
            dd = cv.bfs([s], portals=False)
            for t in rng.sample(live, min(40, len(live))):
                g = abs(t[0] - s[0]) + abs(t[1] - s[1])
                if not cv.closed:
                    g = min(abs(t[0] - s[0]), cv.w - abs(t[0] - s[0])) + min(
                        abs(t[1] - s[1]), cv.h - abs(t[1] - s[1])
                    )
                if g >= 4 and t in dd:
                    det.append(dd[t] / g)
        detour = sum(det) / len(det) if det else 1.0
        dead_ends = sum(1 for t in live if cv.exits(t) <= 1) / max(1, len(live))
        noport = cv.bfs(ha, portals=False)
        pgain = sum(1 for t in live if da[t] < noport.get(t, 10**6)) / max(1, len(live))
        biomes = len({b for b in self.biome.values()})
        s = 0.0
        s -= ((contested - 0.25) / 0.15) ** 2
        s -= ((meet / span - 0.8) / 0.4) ** 2
        s -= ((detour - self.style["detour"]) / 0.25) ** 2
        s -= max(0.0, dead_ends - 0.06) * 30
        s -= 0 if early > 0.04 else 2
        s += min(pgain, 0.3) * 3
        s += min(biomes, 5) * 0.3
        # architecture: a world with its buildings beats a bare one
        structure = min(1.0, self.buildings / max(1, self.want_buildings))
        s += 1.5 * structure
        s += 1.5 if self.lm_built else 0.0
        self.metrics = dict(
            contested=contested,
            early=early,
            meet=meet,
            detour=detour,
            dead_ends=dead_ends,
            portal_gain=pgain,
            biomes=biomes,
            structure=structure,
            landmark=1.0 if self.lm_built else 0.0,
        )
        self.score = s
        return s

    # ---------------------------------------------------------- pipeline
    def build(self):
        self.climate()
        self.plan_landmark()
        self.camps_and_districts()
        self.pick_biomes()
        self.landmark()
        self.borders()
        self.interiors()
        self.vault()
        self.architecture()
        self.ridges()
        self.shrines()
        self.wormholes()
        if not self.repair():
            self.why = "repair did not converge"
            return False
        self.cv.tidy()
        # camps must stay open ground
        if any(c in self.cv.solid for c in self.camps):
            self.why = "a camp was filled in"
            return False
        self.groves()
        self.economy()
        if not self.spawns():
            return False
        if self.judge() is None:
            self.why = "unreachable tiles"
            return False
        self.check()
        self.name = make_name(self)
        return True

    def check(self):
        cv = self.cv
        for t in cv.tiles:
            assert self.gap[t] == self.gap[cv.m(t)], ("gap asym", t)
            assert (t in cv.solid) == (cv.m(t) in cv.solid)
        for e, k in cv.kind.items():
            assert cv.kind.get(cv.me(e), 0) == k, ("edge asym", e)
        byp = {}
        for e, p in cv.pid.items():
            byp.setdefault(p, []).append(e)
        for p, es in byp.items():
            assert len(es) == 2 and es[0][0] == es[1][0], ("portal", p, es)
            assert cv.me(es[0]) != es[0]

    # ---------------------------------------------------------- output
    def text(self):
        return map_text(self.cv, self.name, self.gap, self.dragons)

    def summary(self):
        cv, m = self.cv, self.metrics
        share = {}
        for b in self.tbiome.values():
            share[b] = share.get(b, 0) + 1
        biomes = ", ".join(
            f"{b} {100 * c // len(cv.tiles)}%"
            for b, c in sorted(share.items(), key=lambda kv: -kv[1])
        )
        used = set(self.tier.values())
        palette = ", ".join(
            f"{k} [{lo},{hi}]" for k, (lo, hi) in self.palette.items() if k in used
        )
        kelp = sum(1 for k in cv.kind.values() if k == 1)
        spawning = sum(1 for g in self.gap.values() if g[1] > 0)
        seed, candidate = self.origin
        border = "closed" if cv.closed else "wrapping"
        lengths = ",".join(str(len(d)) for d in self.dragons)
        return "\n".join(
            [
                f"{self.name}  (seed {seed}#{candidate}, style {self.style_name})",
                f"  {cv.w}x{cv.h}  symmetry {cv.sym}  {border} border  "
                f"{len(self.dragons)} dragons/side (lengths {lengths})",
                f"  biomes: {biomes}",
                "  features: " + "; ".join(self.notes),
                f"  kelp edges {kelp}, portal pairs {cv.npid}, "
                f"rock tiles {len(cv.solid)}",
                f"  pearls: {self.supply:.1f}/round (target {self.target:.1f}), "
                f"{spawning} spawning tiles; palette {palette}",
                f"  judge {self.score:.2f}: contested {100 * m['contested']:.0f}%, "
                f"early food {100 * m['early']:.0f}%, first contact {m['meet']} steps, "
                f"detour x{m['detour']:.2f}, dead ends {100 * m['dead_ends']:.1f}%, "
                f"portal shortcut {100 * m['portal_gain']:.0f}% of tiles",
            ]
        )


# ------------------------------------------------------------------ names

ADJ = [
    "Sunken",
    "Drowned",
    "Tidal",
    "Abyssal",
    "Brackish",
    "Gilded",
    "Broken",
    "Whispering",
    "Silent",
    "Coral",
    "Moonlit",
    "Hollow",
    "Salt",
    "Siren",
    "Pale",
    "Twisting",
    "Forgotten",
]
NOUN = {
    "sea": ["Shallows", "Expanse", "Deep", "Straits"],
    "meadow": ["Beds", "Flats", "Lagoon"],
    "reef": ["Reef", "Shoals", "Gardens"],
    "ruins": ["Ruins", "Colonnade", "Atrium"],
    "caves": ["Grottoes", "Caverns", "Hollows"],
    "maze": ["Labyrinth", "Warrens", "Coils"],
    "vault": ["Vault", "Sanctum", "Crown"],
    "garden": ["Orchard", "Gardens"],
    "camp": ["Nests"],
}
NOUN_LANDMARK = {
    "citadel": ["Citadel", "Bastion", "Stronghold"],
    "labyrinth": ["Labyrinth", "Maze", "Warren"],
    "palace": ["Palace", "Halls", "Court"],
    "city": ["City", "Market", "Town"],
    "wall": ["Wall", "Ramparts", "Bulwark"],
    "serpent": ["Coils", "Serpentarium", "Slither"],
    "effigy": ["Faces", "Effigies", "Idols"],
    "lattice": ["Lattice", "Gates", "Mirrors"],
    "lanes": ["Lanes", "Furrows", "Pews"],
}


def make_name(wd):
    rng = random.Random(wd.seed * 7 + 1)
    counts = {}
    for b in wd.tbiome.values():
        if b not in ("camp", "landmark"):
            counts[b] = counts.get(b, 0) + 1
    top = max(counts, key=counts.get) if counts else "sea"
    if wd.lm_built:
        name = f"{rng.choice(ADJ)} {rng.choice(NOUN_LANDMARK[wd.landmark_kind])}"
        return name + (" of Gates" if wd.cv.npid >= 4 and rng.random() < 0.6 else "")
    name = f"{rng.choice(ADJ)} {rng.choice(NOUN[top])}"
    if wd.cv.npid >= 4 and rng.random() < 0.6:
        name += " of Gates"
    elif any(b == "vault" for b in wd.biome.values()) and rng.random() < 0.5:
        name += f" of the {rng.choice(NOUN['vault'])}"
    return name


# ------------------------------------------------------------------ driver


def generate(seed, envelope, candidates=8, **kw):
    """Build worlds from sub-seeds of `seed` until `candidates` are valid and
    inside `envelope`; keep the best."""
    skel = macro(seed, supply_per_100_tiles=envelope.ranges["supply"], **kw)
    best, valid = None, 0
    for i in range(candidates * 6):
        if valid >= candidates:
            break
        wd = World(seed * 1009 + i, **skel)
        wd.origin = (seed, i)
        if not wd.build():
            continue
        if envelope.outside(map_profile(wd.text(), wd.name)):
            continue
        valid += 1
        if best is None or wd.score > best.score:
            best = wd
    if best is None:
        raise RuntimeError(f"no valid world for seed {seed}; try another seed or size")
    return best


def map_text(cv, name, gap, dragons):
    """The .map file for a canvas, its spawn gaps and team A's bodies (team B
    is their mirror image), in the official files' line order."""
    lines = [
        f"MAP {cv.w} {cv.h}",
        f"SYMMETRY {cv.sym}",
        f"MAP_NAME {name}",
        f"TILE_COUNT {len(cv.tiles)}",
    ]
    for y in range(cv.h):
        for x in range(cv.w):
            lo, hi = gap[(x, y)]
            lines.append(f"TILE {x} {y} {lo} {hi}")
    edges = []
    for (o, x, y), k in cv.kind.items():
        row = 2 * y + (0 if o == "h" else 1)
        edges.append((row * (cv.w + 1) + x, k, cv.pid.get((o, x, y), -1)))
    edges.sort()
    lines.append(f"EDGE_COUNT {len(edges)}")
    lines += [f"EDGE {index} {kind} {pid}" for index, kind, pid in edges]
    lines.append(f"DRAGON_COUNT {2 * len(dragons)}")
    for d in dragons:  # alternate A, B like the official maps
        for team, body in ((0, d), (1, [cv.m(t) for t in d])):
            coordinates = " ".join(f"{x} {y}" for x, y in body)
            lines.append(f"DRAGON {team} {len(body)} {coordinates}")
    lines.append("END")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ envelope


@dataclass(frozen=True)
class MapProfile:
    """What a map file shows about its size, economy, walls and forces."""

    name: str
    tiles: int
    aspect: float  # long side over short side
    supply: float  # pearl spawn attempts per round per 100 tiles
    spawning: float  # share of tiles that can spawn
    gap_classes: int  # distinct (min, max) spawn ranges
    kelp: float  # kelp edges per tile
    portal_pairs: int
    per_side: int
    longest: int  # a side's longest starting dragon
    force: int  # a side's total starting length
    closed: bool  # the wrap edges are all kelp
    dead_ends: float  # share of reachable tiles with at most one exit
    detour: float  # walking distance over wrapped Manhattan, portals ignored


def map_profile(text, name):
    """Measure a .map file's text; a replay carries the same text."""
    w = h = 0
    sym = "xy"
    gaps, pairs, sides = {}, {}, {}
    kelp = []
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "MAP":
            w, h = int(f[1]), int(f[2])
        elif f[0] == "SYMMETRY":
            sym = f[1]
        elif f[0] == "TILE":
            gaps[(int(f[1]), int(f[2]))] = (int(f[3]), int(f[4]))
        elif f[0] == "EDGE":
            # Official maps also list open edges, as kind 0.
            row, x = divmod(int(f[1]), w + 1)
            e = ("h" if row % 2 == 0 else "v", x, row // 2)
            if f[2] == "1":
                kelp.append(e)
            elif f[2] == "2":
                pairs.setdefault(int(f[3]), []).append(e)
        elif f[0] == "DRAGON":
            n = int(f[2])
            body = [(int(f[3 + 2 * i]), int(f[4 + 2 * i])) for i in range(n)]
            sides.setdefault(int(f[1]), []).append(body)
    cv = Canvas(w, h, sym, closed=False)
    for e in kelp:
        cv.kind[e] = 1
    for pid, ends in pairs.items():
        for e in ends:
            cv.kind[e] = 2
            cv.pid[e] = pid
        if len(ends) == 2:
            cv.partner[ends[0]], cv.partner[ends[1]] = ends[1], ends[0]
    tiles = w * h
    spawning = [g for g in gaps.values() if g[1] > 0]
    team = sides[min(sides)]
    reach = cv.bfs([body[0] for body in team])
    rng = random.Random(0)
    live = sorted(reach)
    ratios = []
    for s in rng.sample(live, min(16, len(live))):
        dd = cv.bfs([s], portals=False)
        for t in rng.sample(live, min(40, len(live))):
            dx, dy = abs(t[0] - s[0]), abs(t[1] - s[1])
            g = min(dx, w - dx) + min(dy, h - dy)
            if g >= 4 and t in dd:
                ratios.append(dd[t] / g)
    lengths = [len(body) for body in team]
    return MapProfile(
        name=name,
        tiles=tiles,
        aspect=max(w, h) / min(w, h),
        supply=100 * sum(2 / (lo + hi) for lo, hi in spawning) / tiles,
        spawning=len(spawning) / tiles,
        gap_classes=len(set(spawning)),
        kelp=len(kelp) / tiles,
        portal_pairs=sum(len(ends) for ends in pairs.values()) // 2,
        per_side=len(team),
        longest=max(lengths),
        force=sum(lengths),
        closed=all(cv.kind.get(("h", x, 0)) == 1 for x in range(w))
        and all(cv.kind.get(("v", 0, y)) == 1 for y in range(h)),
        dead_ends=sum(cv.exits(t) <= 1 for t in reach) / max(1, len(reach)),
        detour=statistics.fmean(ratios) if ratios else 1.0,
    )


# The measures a generated map must keep within the official maps' range:
# size, shape, food, walls, portals and the starting forces.
ENVELOPE_MEASURES = (
    "tiles",
    "aspect",
    "supply",
    "kelp",
    "portal_pairs",
    "per_side",
    "longest",
    "force",
    "dead_ends",
)


@dataclass(frozen=True)
class Envelope:
    """The smallest and largest value of each measure over the official maps.

    It bounds the generator without shaping its spread: tournament maps are
    unseen, so a map anywhere inside the range is as plausible as the
    official maps' own values."""

    ranges: dict

    def outside(self, profile):
        """The measures on which `profile` falls outside, with its values."""
        return {
            m: getattr(profile, m)
            for m in ENVELOPE_MEASURES
            if not self.ranges[m][0] <= getattr(profile, m) <= self.ranges[m][1]
        }


def map_profiles(directory):
    return [
        map_profile(p.read_text(), p.name)
        for p in sorted(Path(directory).glob("*.map"))
    ]


def official_envelope():
    profiles = map_profiles(OFFICIAL_MAPS)
    return Envelope(
        {
            m: (
                min(getattr(p, m) for p in profiles),
                max(getattr(p, m) for p in profiles),
            )
            for m in ENVELOPE_MEASURES
        }
    )


def profile_table(groups):
    """Quartiles of every measure for each named group of profiles, as Markdown."""
    names = [f.name for f in fields(MapProfile) if f.name != "name"]
    lines = [
        "| Measure | "
        + " | ".join(f"{g} (min / q1 / median / q3 / max)" for g in groups)
        + " |",
        "| --- |" + " ---: |" * len(groups),
    ]
    for m in names:
        cells = []
        for profiles in groups.values():
            xs = sorted(float(getattr(p, m)) for p in profiles)
            q1, q2, q3 = statistics.quantiles(xs, n=4) if len(xs) > 1 else (xs[0],) * 3
            cells.append(" / ".join(f"{v:.2f}" for v in (xs[0], q1, q2, q3, xs[-1])))
        lines.append(f"| {m} | " + " | ".join(cells) + " |")
    return "\n".join(lines)
