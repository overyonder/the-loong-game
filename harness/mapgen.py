"""Generate plausible symmetric maps for held-out evaluation.

The generator follows the official map-file format and the conventions of the
maps seen on the public ladder: `SYMMETRY y` mirrors x, `SYMMETRY x` mirrors y,
`SYMMETRY xy` rotates 180 degrees. Some ladder maps omit the SYMMETRY line, so
their geometry is symmetric but pearl countdowns are not shared.
"""

import random
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "maps" / "generated"

# An edge is ("N", x, y), the north side of tile (x, y), or ("W", x, y), its west
# side. The south and east borders are the wrapped north and west borders.
Edge = tuple[str, int, int]
Tile = tuple[int, int]

SPAWN_RANGES_FULL = [
    (1, 100),
    (1, 200),
    (1, 250),
    (1, 385),
    (1, 600),
    (1, 750),
    (1, 1000),
    (1, 3849),
    (8, 20),
    (10, 20),
    (20, 200),
]
SPAWN_RANGES_HOTSPOT = [(1, 1), (1, 50), (5, 30), (20, 50), (1, 100)]
SPAWN_RANGES_LATE = [(240, 320), (320, 400), (150, 250), (480, 490)]
KELP_STYLES = ["segments", "rooms", "pillars", "border", "open", "maze", "divide"]
# Food layouts seen in the official 1.0.2 and community maps: spread over the
# map, almost none, a contested central strip, or a private field per side
# plus a contested centre.
FOOD_LAYOUTS = ["spread", "spread", "spread", "starving", "centre", "fields"]


@dataclass
class GeneratedMap:
    width: int
    height: int
    symmetry: str  # "x", "y" or "xy"
    declare_symmetry: bool  # write the SYMMETRY line
    name: str
    kelp: set[Edge] = field(default_factory=set)
    portals: dict[Edge, int] = field(default_factory=dict)
    spawn_ranges: dict[Tile, tuple[int, int]] = field(default_factory=dict)
    dragons: list[tuple[int, list[Tile]]] = field(default_factory=list)


def mirror_tile(layout: GeneratedMap, tile: Tile) -> Tile:
    x, y = tile
    w, h = layout.width, layout.height
    if layout.symmetry == "y":
        return (w - 1 - x, y)
    if layout.symmetry == "x":
        return (x, h - 1 - y)
    return (w - 1 - x, h - 1 - y)


def mirror_edge(layout: GeneratedMap, edge: Edge) -> Edge:
    side, x, y = edge
    w, h = layout.width, layout.height
    if side == "N":
        mirrored_x = x if layout.symmetry == "x" else w - 1 - x
        mirrored_y = y if layout.symmetry == "y" else (h - y) % h
    else:
        mirrored_x = x if layout.symmetry == "x" else (w - x) % w
        mirrored_y = y if layout.symmetry == "y" else h - 1 - y
    return (side, mirrored_x, mirrored_y)


def edge_index(layout: GeneratedMap, edge: Edge) -> int:
    side, x, y = edge
    row = 2 * y if side == "N" else 2 * y + 1
    return row * (layout.width + 1) + x


def edge_between_tile_and_direction(
    layout: GeneratedMap, tile: Tile, direction: str
) -> Edge:
    x, y = tile
    w, h = layout.width, layout.height
    return {
        "N": ("N", x, y),
        "S": ("N", x, (y + 1) % h),
        "W": ("W", x, y),
        "E": ("W", (x + 1) % w, y),
    }[direction]


def step_tile(layout: GeneratedMap, tile: Tile, direction: str) -> Tile:
    dx, dy = {"N": (0, -1), "S": (0, 1), "W": (-1, 0), "E": (1, 0)}[direction]
    return ((tile[0] + dx) % layout.width, (tile[1] + dy) % layout.height)


def destination_after_move(
    layout: GeneratedMap, tile: Tile, direction: str
) -> Tile | None:
    """Return the tile a head reaches, following portals; None for kelp."""
    edge = edge_between_tile_and_direction(layout, tile, direction)
    if edge in layout.kelp:
        return None
    if edge not in layout.portals:
        return step_tile(layout, tile, direction)
    portal_id = layout.portals[edge]
    partner = next(e for e, i in layout.portals.items() if i == portal_id and e != edge)
    # Crossing a portal leaves through the partner edge in the same direction.
    _side, x, y = partner
    if direction == "N":
        return (x, (y - 1) % layout.height)
    if direction == "S":
        return (x, y)
    if direction == "W":
        return ((x - 1) % layout.width, y)
    return (x, y)


def add_kelp_symmetrically(layout: GeneratedMap, edge: Edge) -> None:
    layout.kelp.add(edge)
    layout.kelp.add(mirror_edge(layout, edge))


def add_kelp_segments(layout: GeneratedMap, generator: random.Random) -> None:
    for _ in range(generator.randint(2, max(3, layout.width * layout.height // 40))):
        x, y = generator.randrange(layout.width), generator.randrange(layout.height)
        length = generator.randint(2, max(3, min(layout.width, layout.height) // 3))
        horizontal = generator.random() < 0.5
        for offset in range(length):
            if horizontal:
                add_kelp_symmetrically(layout, ("N", (x + offset) % layout.width, y))
            else:
                add_kelp_symmetrically(layout, ("W", x, (y + offset) % layout.height))


def add_kelp_rooms(layout: GeneratedMap, generator: random.Random) -> None:
    room_size = generator.randint(6, max(7, min(layout.width, layout.height) // 2))
    door_width = generator.randint(1, 3)
    for x in range(0, layout.width, room_size):
        for y in range(layout.height):
            if (y % room_size) >= door_width + 1:
                add_kelp_symmetrically(layout, ("W", x, y))
    for y in range(0, layout.height, room_size):
        for x in range(layout.width):
            if (x % room_size) >= door_width + 1:
                add_kelp_symmetrically(layout, ("N", x, y))


def add_kelp_pillars(layout: GeneratedMap, generator: random.Random) -> None:
    for _ in range(generator.randint(2, max(3, layout.width * layout.height // 120))):
        x, y = generator.randrange(layout.width), generator.randrange(layout.height)
        size_x, size_y = generator.randint(1, 4), generator.randint(1, 4)
        for offset in range(size_x):
            add_kelp_symmetrically(layout, ("N", (x + offset) % layout.width, y))
            add_kelp_symmetrically(
                layout, ("N", (x + offset) % layout.width, (y + size_y) % layout.height)
            )
        for offset in range(size_y):
            add_kelp_symmetrically(layout, ("W", x, (y + offset) % layout.height))
            add_kelp_symmetrically(
                layout, ("W", (x + size_x) % layout.width, (y + offset) % layout.height)
            )


def add_kelp_border(layout: GeneratedMap, generator: random.Random) -> None:
    gap_every = generator.choice([0, 0, 5, 8])
    for x in range(layout.width):
        if not gap_every or x % gap_every:
            add_kelp_symmetrically(layout, ("N", x, 0))
    for y in range(layout.height):
        if not gap_every or y % gap_every:
            add_kelp_symmetrically(layout, ("W", 0, y))


def add_portals(
    layout: GeneratedMap, generator: random.Random, pair_count: int
) -> None:
    all_edges = [
        (side, x, y)
        for side in "NW"
        for x in range(layout.width)
        for y in range(layout.height)
    ]
    next_id = 0
    for _ in range(pair_count * 50):
        if next_id >= pair_count * 2:
            break
        first, second = generator.sample(all_edges, 2)
        if first[0] != second[0]:
            continue
        group = {first, second, mirror_edge(layout, first), mirror_edge(layout, second)}
        # Both portals of a pair lie on the symmetry line or both lie off it.
        if any(mirror_edge(layout, e) == e for e in (first, second)):
            continue
        if group & (layout.kelp | layout.portals.keys()):
            continue
        layout.portals[first] = layout.portals[second] = next_id
        if mirror_edge(layout, first) != second:
            layout.portals[mirror_edge(layout, first)] = next_id + 1
            layout.portals[mirror_edge(layout, second)] = next_id + 1
            next_id += 1
        next_id += 1


def add_kelp_maze(layout: GeneratedMap, generator: random.Random) -> None:
    """Corridors of width `cell` carved by a randomised depth-first search."""
    cell = generator.choice([2, 2, 3, 4])
    columns, rows = max(2, layout.width // cell), max(2, layout.height // cell)
    walls = set()
    for cx in range(columns):
        for cy in range(rows):
            walls.add(("E", cx, cy))
            walls.add(("S", cx, cy))
    seen = {(0, 0)}
    stack = [(0, 0)]
    while stack:
        cx, cy = stack[-1]
        options = [
            (d, (cx + dx) % columns, (cy + dy) % rows)
            for d, dx, dy in (("E", 1, 0), ("W", -1, 0), ("S", 0, 1), ("N", 0, -1))
            if ((cx + dx) % columns, (cy + dy) % rows) not in seen
        ]
        if not options:
            stack.pop()
            continue
        d, nx, ny = generator.choice(options)
        wall = {
            "E": ("E", cx, cy),
            "S": ("S", cx, cy),
            "W": ("E", nx, ny),
            "N": ("S", nx, ny),
        }[d]
        walls.discard(wall)
        seen.add((nx, ny))
        stack.append((nx, ny))
    # Open some extra walls so the maze has loops, as ladder mazes do.
    for wall in generator.sample(
        sorted(walls), len(walls) // generator.choice([4, 6, 10])
    ):
        walls.discard(wall)
    for kind, cx, cy in walls:
        for offset in range(cell):
            if kind == "E":
                x, y = (cx + 1) * cell % layout.width, cy * cell + offset
                if y < layout.height:
                    add_kelp_symmetrically(layout, ("W", x, y))
            else:
                x, y = cx * cell + offset, (cy + 1) * cell % layout.height
                if x < layout.width:
                    add_kelp_symmetrically(layout, ("N", x, y))


def add_kelp_divide(layout: GeneratedMap, generator: random.Random) -> None:
    """A wall between the two halves with a few gaps, like The Great Divide."""
    gaps = generator.randint(1, 3)
    if layout.symmetry == "x":
        span, line = layout.width, layout.height // 2
        openings = set(generator.sample(range(span), min(span, gaps)))
        for x in range(span):
            if x not in openings:
                add_kelp_symmetrically(layout, ("N", x, line))
                add_kelp_symmetrically(layout, ("N", x, 0))
    else:
        span, line = layout.height, layout.width // 2
        openings = set(generator.sample(range(span), min(span, gaps)))
        for y in range(span):
            if y not in openings:
                add_kelp_symmetrically(layout, ("W", line, y))
                add_kelp_symmetrically(layout, ("W", 0, y))


def reachable_tiles(layout: GeneratedMap, start: Tile) -> set[Tile]:
    seen = {start}
    queue = deque([start])
    while queue:
        tile = queue.popleft()
        for direction in "NESW":
            destination = destination_after_move(layout, tile, direction)
            if destination is not None and destination not in seen:
                seen.add(destination)
                queue.append(destination)
    return seen


def largest_component(layout: GeneratedMap) -> set[Tile]:
    remaining = {(x, y) for x in range(layout.width) for y in range(layout.height)}
    largest: set[Tile] = set()
    while remaining:
        component = reachable_tiles(layout, next(iter(remaining)))
        remaining -= component
        if len(component) > len(largest):
            largest = component
    return largest


def in_team_a_half(layout: GeneratedMap, tile: Tile) -> bool:
    x, y = tile
    if layout.symmetry == "x":
        return 1 <= y < layout.height // 2 - 1
    return 1 <= x < layout.width // 2 - 1


def wrapped_chebyshev(layout: GeneratedMap, a: Tile, b: Tile) -> int:
    dx = abs(a[0] - b[0])
    dy = abs(a[1] - b[1])
    return max(min(dx, layout.width - dx), min(dy, layout.height - dy))


def place_dragons(
    layout: GeneratedMap,
    generator: random.Random,
    playable: set[Tile],
    per_team: int,
    lengths: list[int],
) -> bool:
    occupied: set[Tile] = set()
    candidates = [tile for tile in playable if in_team_a_half(layout, tile)]
    for length in lengths[:per_team]:
        for _ in range(400):
            head = generator.choice(candidates)
            body = [head]
            while len(body) < length:
                options = []
                for direction in "NESW":
                    edge = edge_between_tile_and_direction(layout, body[-1], direction)
                    if edge in layout.kelp or edge in layout.portals:
                        continue
                    nxt = step_tile(layout, body[-1], direction)
                    if (
                        nxt in body
                        or nxt in occupied
                        or not in_team_a_half(layout, nxt)
                    ):
                        continue
                    options.append(nxt)
                if not options:
                    break
                # Straight bodies are the common ladder layout.
                if len(body) >= 2:
                    straight = (
                        2 * body[-1][0] - body[-2][0],
                        2 * body[-1][1] - body[-2][1],
                    )
                    if straight in options and generator.random() < 0.7:
                        options = [straight]
                body.append(generator.choice(options))
            if len(body) < length:
                continue
            mirrored = [mirror_tile(layout, tile) for tile in body]
            enemy = mirrored + [mirror_tile(layout, tile) for tile in occupied]
            if any(
                wrapped_chebyshev(layout, a, b) < 4
                for a in body + list(occupied)
                for b in enemy
            ):
                continue
            if any(wrapped_chebyshev(layout, a, b) < 2 for a in body for b in occupied):
                continue
            free_exits = sum(
                1
                for direction in "NESW"
                if (d := destination_after_move(layout, head, direction)) is not None
                and d not in body
                and d not in occupied
            )
            if free_exits < 2:
                continue
            occupied.update(body)
            layout.dragons.append((0, body))
            layout.dragons.append((1, mirrored))
            break
        else:
            return False
    return True


def assign_spawn_ranges(
    layout: GeneratedMap, generator: random.Random, playable: set[Tile], food: str
) -> None:
    if food != "spread":
        assign_structured_food(layout, generator, playable, food)
        return
    base = generator.choice(SPAWN_RANGES_FULL)
    barren_fraction = generator.choice([0.0, 0.0, 0.3, 0.5, 0.75])
    tiles = sorted(playable)
    for tile in tiles:
        layout.spawn_ranges[tile] = base
    for tile in {
        (x, y) for x in range(layout.width) for y in range(layout.height)
    } - playable:
        layout.spawn_ranges[tile] = (0, 0)
    # Barren regions grow from random seeds so resources cluster, as on the ladder.
    if barren_fraction:
        barren: set[Tile] = set()
        target = int(len(tiles) * barren_fraction)
        frontier = deque(generator.sample(tiles, max(1, len(tiles) // 60)))
        while frontier and len(barren) < target:
            tile = frontier.popleft()
            if tile in barren or tile not in playable:
                continue
            barren.add(tile)
            barren.add(mirror_tile(layout, tile))
            for direction in "NESW":
                if generator.random() < 0.8:
                    frontier.append(step_tile(layout, tile, direction))
        for tile in barren:
            layout.spawn_ranges[tile] = (0, 0)
    for special_ranges in (SPAWN_RANGES_HOTSPOT, SPAWN_RANGES_LATE):
        if generator.random() < (
            0.6 if special_ranges is SPAWN_RANGES_HOTSPOT else 0.25
        ):
            spawn_range = generator.choice(special_ranges)
            for _ in range(generator.randint(1, 4)):
                x, y = generator.choice(tiles)
                size = generator.randint(1, 3)
                for tile in [
                    ((x + i) % layout.width, (y + j) % layout.height)
                    for i in range(size)
                    for j in range(size)
                ]:
                    if tile in playable:
                        layout.spawn_ranges[tile] = spawn_range
                        layout.spawn_ranges[mirror_tile(layout, tile)] = spawn_range


def assign_structured_food(
    layout: GeneratedMap, generator: random.Random, playable: set[Tile], food: str
) -> None:
    """Mostly barren maps with food concentrated where it forces a choice."""
    for x in range(layout.width):
        for y in range(layout.height):
            layout.spawn_ranges[(x, y)] = (0, 0)
    tiles = sorted(playable)
    if food == "starving":
        # A handful of scattered, slow spawns; the game turns on starting length.
        for tile in generator.sample(tiles, min(len(tiles), generator.randint(0, 6))):
            spawn = generator.choice(SPAWN_RANGES_LATE + [(1, 2559)])
            layout.spawn_ranges[tile] = layout.spawn_ranges[
                mirror_tile(layout, tile)
            ] = spawn
        return
    across = layout.symmetry == "x"
    size = layout.height if across else layout.width
    middle = size // 2
    half_width = max(1, size // generator.choice([10, 8, 6]))
    centre_spawn = generator.choice([(1, 1), (1, 5), (1, 10), (150, 250)])
    for tile in tiles:
        position = tile[1] if across else tile[0]
        if abs(position - middle) <= half_width and generator.random() < 0.6:
            layout.spawn_ranges[tile] = centre_spawn
            layout.spawn_ranges[mirror_tile(layout, tile)] = centre_spawn
    if food == "fields":
        # Each side gets a private block of slow food, like Autarky.
        field_spawn = generator.choice([(1, 1), (1, 5), (1, 10), (480, 490)])
        width = generator.randint(3, max(3, size // 6))
        start = generator.randint(1, max(1, middle - half_width - width - 1))
        for tile in tiles:
            position = tile[1] if across else tile[0]
            if start <= position < start + width and generator.random() < 0.7:
                layout.spawn_ranges[tile] = field_spawn
                layout.spawn_ranges[mirror_tile(layout, tile)] = field_spawn
    # Occasional late surprises anywhere.
    late = generator.choice(SPAWN_RANGES_LATE)
    for tile in generator.sample(tiles, min(len(tiles), generator.randint(0, 8))):
        layout.spawn_ranges[tile] = layout.spawn_ranges[mirror_tile(layout, tile)] = (
            late
        )


def starting_lengths(
    generator: random.Random, per_team: int, playable_half: int
) -> list[int]:
    """Equal escorts, sometimes with one long flagship or mixed lengths."""
    kind = generator.choices(["equal", "flagship", "mixed"], weights=[50, 35, 15])[0]
    if kind == "mixed":
        return sorted(
            (generator.choice([3, 5, 7, 8, 12, 16]) for _ in range(per_team)),
            reverse=True,
        )
    base = generator.choice([3, 3, 4, 4, 5, 6])
    if kind == "equal":
        return [base] * per_team
    # The flagship fits in a third of a team's half; very long ones are rare.
    cap = max(8, playable_half // 3)
    flagship = min(cap, generator.choice([9, 11, 14, 14, 16, 20, 30, 80]))
    return [flagship] + [3] * max(1, per_team - 1)


def generate_map(generator: random.Random, name: str) -> GeneratedMap:
    while True:
        # Ladder maps are mostly square or wide, from 11x11 to 64x64.
        low, high = generator.choices(
            [(10, 20), (21, 40), (41, 64)], weights=[35, 40, 25]
        )[0]
        width = generator.randint(low, high)
        aspect = generator.choice([1.0, 1.0, 1.0, 0.5, 0.6, 0.75, 1.4, 0.33, 0.16])
        height = max(8, min(64, round(width * aspect)))
        layout = GeneratedMap(
            width=width,
            height=height,
            symmetry=generator.choice(["x", "y", "xy", "xy"]),
            declare_symmetry=generator.random() < 0.8,
            name=name,
        )
        styles = generator.sample(KELP_STYLES, generator.choice([1, 2, 2, 3]))
        # Mazes are dense by design; other styles keep the old limits.
        dense = "maze" in styles
        for style in styles:
            {
                "segments": add_kelp_segments,
                "rooms": add_kelp_rooms,
                "pillars": add_kelp_pillars,
                "border": add_kelp_border,
                "open": lambda *_: None,
                "maze": add_kelp_maze,
                "divide": add_kelp_divide,
            }[style](layout, generator)
        if len(layout.kelp) > (0.6 if dense else 0.35) * 2 * width * height:
            continue
        add_portals(
            layout,
            generator,
            min(generator.choice([0, 0, 1, 2, 3, 4, 6]), width * height // 80),
        )
        playable = largest_component(layout)
        if len(playable) < (0.35 if dense else 0.6) * width * height:
            continue
        area = width * height
        per_team = generator.randint(1, 2 if area < 400 else 4 if area < 1600 else 6)
        lengths = starting_lengths(generator, per_team, len(playable) // 2)
        if not place_dragons(layout, generator, playable, len(lengths), lengths):
            continue
        assign_spawn_ranges(layout, generator, playable, generator.choice(FOOD_LAYOUTS))
        return layout


def serialise_map(layout: GeneratedMap) -> str:
    lines = [f"MAP {layout.width} {layout.height}"]
    if layout.declare_symmetry:
        lines.append(f"SYMMETRY {layout.symmetry}")
    lines.append(f"MAP_NAME {layout.name}")
    lines.append(f"TILE_COUNT {layout.width * layout.height}")
    for y in range(layout.height):
        for x in range(layout.width):
            minimum, maximum = layout.spawn_ranges[(x, y)]
            lines.append(f"TILE {x} {y} {minimum} {maximum}")
    edges = sorted(
        [(edge_index(layout, e), 1, -1) for e in layout.kelp]
        + [(edge_index(layout, e), 2, i) for e, i in layout.portals.items()]
    )
    lines.append(f"EDGE_COUNT {len(edges)}")
    lines.extend(f"EDGE {index} {kind} {portal}" for index, kind, portal in edges)
    lines.append(f"DRAGON_COUNT {len(layout.dragons)}")
    for team, body in layout.dragons:
        coordinates = " ".join(f"{x} {y}" for x, y in body)
        lines.append(f"DRAGON {team} {len(body)} {coordinates}")
    lines.append("END")
    return "\n".join(lines) + "\n"
