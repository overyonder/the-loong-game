"""Draw the banners for the sonar post and the machine post, in the style of the map banners.

    python3 tools/banner.py sonar blog/images/banner-sonar.svg
    python3 tools/banner.py machine blog/images/banner-the-machine-inside-the-judge.svg
    python3 tools/banner.py cloud blog/images/banner-games-in-the-cloud.svg
    python3 tools/banner.py pearls blog/images/banner-pearls-from-the-seed.svg
    python3 tools/banner.py lines blog/images/banner-three-lines.svg
    python3 tools/banner.py gpu blog/images/banner-an-engine-on-the-gpu.svg

They use the map banners' board: a 24-pixel grid, kelp in green, pearls in yellow, our dragons
in orange and the enemy's in white. The sonar banner adds dashed rays, and the machine banner
lays the board out as a chip: register banks, cache lines and the wires between them.
"""

import random
import sys

from figure_palette import BOARD, KELP, OURS, PEARL, THEIRS
from figure_palette import BOARD_GRID as GRID

WIDTH, HEIGHT, CELL = 1440, 960, 24


def centre(column, row):
    return column * CELL + CELL / 2, row * CELL + CELL / 2


def board():
    lines = "".join(f"M{x} 0V{HEIGHT}" for x in range(CELL, WIDTH, CELL))
    lines += "".join(f"M0 {y}H{WIDTH}" for y in range(CELL, HEIGHT, CELL))
    return [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}">',
            f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{BOARD}"/>',
            f'<path d="{lines}" stroke="{GRID}" stroke-width="1"/>']


def dragon(cells, colour):
    points = " ".join("{:.0f},{:.0f}".format(*centre(*cell)) for cell in cells)
    x, y = centre(*cells[0])
    return (f'<polyline points="{points}" fill="none" stroke="{colour}" stroke-width="12"'
            f' stroke-linecap="round" stroke-linejoin="round" opacity=".85"/>'
            f'<circle cx="{x:.0f}" cy="{y:.0f}" r="8.64" fill="{colour}"/>')


def walk(rng, start, length, blocked):
    cells = [start]
    for _ in range(length - 1):
        column, row = cells[-1]
        options = [(column + dx, row + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
        options = [cell for cell in options if cell not in cells and cell not in blocked
                   and 0 <= cell[0] < WIDTH // CELL and 0 <= cell[1] < HEIGHT // CELL]
        if not options:
            break
        cells.append(rng.choice(options))
    blocked.update(cells)
    return cells


def kelp_room(column, row, width, height, gap_side):
    """A kelp wall round a rectangle of tiles, open for two tiles in the middle of one side."""
    x0, y0, x1, y1 = column * CELL, row * CELL, (column + width) * CELL, (row + height) * CELL
    mx, my = (x0 + x1) // 2, (y0 + y1) // 2
    sides = {
        "north": f"M{x0} {y0}H{mx - CELL}M{mx + CELL} {y0}H{x1}",
        "south": f"M{x0} {y1}H{mx - CELL}M{mx + CELL} {y1}H{x1}",
        "west": f"M{x0} {y0}V{my - CELL}M{x0} {my + CELL}V{y1}",
        "east": f"M{x1} {y0}V{my - CELL}M{x1} {my + CELL}V{y1}",
    }
    full = {"north": f"M{x0} {y0}H{x1}", "south": f"M{x0} {y1}H{x1}", "west": f"M{x0} {y0}V{y1}", "east": f"M{x1} {y0}V{y1}"}
    return "".join(sides[side] if side == gap_side else full[side] for side in full)


def pearls(rng, count, blocked):
    parts = []
    for _ in range(count):
        column, row = rng.randrange(WIDTH // CELL), rng.randrange(HEIGHT // CELL)
        if (column, row) not in blocked:
            x, y = centre(column, row)
            parts.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="3.2" fill="{PEARL}"/>')
    return parts


def sonar():
    rng = random.Random(14)
    parts = board()
    walls = [kelp_room(6, 5, 8, 6, "east"), kelp_room(44, 24, 8, 6, "west"), kelp_room(26, 15, 8, 8, "south"),
             kelp_room(8, 28, 6, 6, "north"), kelp_room(46, 4, 6, 6, "south")]
    parts.append(f'<path d="{"".join(walls)}" stroke="{KELP}" stroke-width="3" fill="none" stroke-linecap="square"/>')
    blocked = set()
    rays = []
    speakers = [((20, 12), OURS, (9, 13, 12, 11)), ((38, 30), THEIRS, (8, 10, 9, 14)),
                ((58, 16), OURS, (7, 9, 10, 12)), ((18, 34), THEIRS, (6, 12, 5, 9))]
    bodies = [walk(rng, head, 6, blocked) for head, _, _ in speakers]
    for _ in range(8):
        start = (rng.randrange(WIDTH // CELL), rng.randrange(HEIGHT // CELL))
        if start not in blocked:
            parts.append(dragon(walk(rng, start, rng.randrange(3, 7), blocked), rng.choice((OURS, THEIRS))))
    # Each speaker sends up to four rays, which stop at the first wall or dragon in their way.
    for (head, colour, reach), body in zip(speakers, bodies):
        parts.append(dragon(body, colour))
        x, y = centre(*head)
        behind = (body[1][0] - head[0], body[1][1] - head[1]) if len(body) > 1 else None
        for (dx, dy), length in zip(((0, -1), (1, 0), (0, 1), (-1, 0)), reach):
            if (dx, dy) == behind:
                continue  # that ray would leave from the tail, not the head
            steps = 1
            while steps < length and (head[0] + dx * steps, head[1] + dy * steps) not in blocked:
                steps += 1  # a ray stops at the first dragon segment in its way
            end_x, end_y = x + dx * steps * CELL, y + dy * steps * CELL
            rays.append(f'<path d="M{x + dx * 14:.0f} {y + dy * 14:.0f}L{end_x:.0f} {end_y:.0f}" stroke="{colour}"'
                        f' stroke-width="3" stroke-dasharray="9 7" opacity=".7"/>'
                        f'<circle cx="{end_x:.0f}" cy="{end_y:.0f}" r="10" fill="none" stroke="{colour}" stroke-width="2" opacity=".55"/>'
                        f'<circle cx="{end_x:.0f}" cy="{end_y:.0f}" r="18" fill="none" stroke="{colour}" stroke-width="1.5" opacity=".3"/>')
    parts += rays + pearls(rng, 70, blocked)
    return parts


def machine():
    rng = random.Random(16)
    parts = board()
    blocked = set()
    shapes = []
    # Register banks: rows of small cells, one v128 register to a row, sixteen lanes across.
    for bank_column, bank_row in ((4, 6), (4, 24)):
        for register in range(4):
            y = (bank_row + register * 2) * CELL
            shapes.append(f"M{bank_column * CELL} {y}h{16 * CELL}v{CELL}h{-16 * CELL}z")
            shapes.append("".join(f"M{(bank_column + lane) * CELL} {y}v{CELL}" for lane in range(1, 16)))
    # Cache: a block of lines, each eight tiles wide.
    for line in range(10):
        y = (8 + line * 2) * CELL
        shapes.append(f"M{36 * CELL} {y}h{8 * CELL}v{CELL}h{-8 * CELL}z")
        shapes.append(f"M{46 * CELL} {y}h{8 * CELL}v{CELL}h{-8 * CELL}z")
    # A clock: a square wave along the bottom edge.
    wave = "".join(f"v{-CELL}h{2 * CELL}v{CELL}h{2 * CELL}" for _ in range(14))
    shapes.append(f"M{2 * CELL} {37 * CELL}{wave}")
    parts.append(f'<path d="{"".join(shapes)}" stroke="{KELP}" stroke-width="2.5" fill="none"/>')
    for register_row in (6, 8, 10, 12, 24, 26, 28, 30):
        for lane in rng.sample(range(16), rng.randrange(4, 12)):
            x, y = centre(4 + lane, register_row)
            parts.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="3.2" fill="{PEARL}"/>')
            blocked.add((4 + lane, register_row))
    # Wires between the banks and the cache, drawn as dragons carrying data.
    routes = [[(21, 7), (24, 7), (24, 9), (30, 9), (30, 11), (35, 11)],
              [(35, 17), (29, 17), (29, 25), (21, 25)],
              [(45, 13), (45, 21)],
              [(21, 29), (27, 29), (27, 33), (40, 33), (40, 28)],
              [(55, 9), (57, 9), (57, 21), (55, 21)]]
    for index, route in enumerate(routes):
        cells = [route[0]]
        for target in route[1:]:
            while cells[-1] != target:
                column, row = cells[-1]
                column += (target[0] > column) - (target[0] < column)
                if column == cells[-1][0]:
                    row += (target[1] > row) - (target[1] < row)
                cells.append((column, row))
        parts.append(dragon(list(reversed(cells)), OURS if index % 2 == 0 else THEIRS))
    for _ in range(6):
        start = (rng.randrange(WIDTH // CELL), rng.randrange(HEIGHT // CELL))
        if start not in blocked:
            parts.append(dragon(walk(rng, start, rng.randrange(3, 6), blocked), OURS))
    parts += pearls(rng, 40, blocked)
    return parts


def cloud():
    """Two regions of worker instances, each a small board with a dragon on it, fed by one queue of games."""
    rng = random.Random(21)
    parts = board()
    blocked = set()
    shapes = []
    for room_column in (3, 36):
        shapes.append(kelp_room(room_column, 4, 21, 31, "east" if room_column == 3 else "west"))
        for row in range(3):
            for column in range(3):
                x0, y0 = room_column + 1 + column * 7, 6 + row * 10
                shapes.append(f"M{x0 * CELL} {y0 * CELL}h{5 * CELL}v{7 * CELL}h{-5 * CELL}z")
                start = (x0 + rng.randrange(1, 4), y0 + rng.randrange(1, 6))
                body = [start]
                for _ in range(rng.randrange(2, 5)):
                    options = [(body[-1][0] + dx, body[-1][1] + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
                    options = [cell for cell in options if x0 <= cell[0] < x0 + 5 and y0 <= cell[1] < y0 + 7 and cell not in body]
                    if not options:
                        break
                    body.append(rng.choice(options))
                parts.append(dragon(body, OURS if (row + column) % 3 else THEIRS))
                blocked.update(body)
    parts.insert(3, f'<path d="{"".join(shapes)}" stroke="{KELP}" stroke-width="2.5" fill="none"/>')
    # The queue: one pearl per game, down the middle between the regions.
    for row in range(5, 35):
        x, y = centre(29 + row % 2, row)
        parts.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="4" fill="{PEARL}"/>')
    parts += pearls(rng, 30, blocked | {(column, row) for column in range(3, 58) for row in range(4, 36)})
    return parts


def pearl_seed():
    """The same board and seed unfolding into a stream of pearl attempts."""
    rng = random.Random(10)
    parts = board()
    blocked = set()
    walls = [kelp_room(5, 5, 18, 28, "east"), kelp_room(37, 7, 18, 26, "west")]
    parts.append(f'<path d="{"".join(walls)}" stroke="{KELP}" stroke-width="3" fill="none"/>')
    for start, colour, length in [((13, 18), OURS, 8), ((46, 21), THEIRS, 7), ((29, 8), OURS, 5)]:
        parts.append(dragon(walk(rng, start, length, blocked), colour))
    for index in range(90):
        column = rng.randrange(WIDTH // CELL)
        row = rng.randrange(HEIGHT // CELL)
        if (column, row) in blocked:
            continue
        x, y = centre(column, row)
        radius = 2.4 + (index % 4) * 0.8
        opacity = 0.35 + (index % 5) * 0.12
        parts.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{radius:.1f}" fill="{PEARL}" opacity="{opacity:.2f}"/>')
    return parts


def three_lines():
    """Three separate bot lineages crossing the same board."""
    rng = random.Random(14)
    parts = board()
    blocked = set()
    walls = [kelp_room(4, 4, 52, 8, "east"), kelp_room(4, 16, 52, 8, "west"), kelp_room(4, 28, 52, 8, "east")]
    parts.append(f'<path d="{"".join(walls)}" stroke="{KELP}" stroke-width="3" fill="none"/>')
    for row, colour in ((8, OURS), (20, THEIRS), (32, PEARL)):
        cells = [(column, row + (column // 8) % 2) for column in range(8, 52)]
        parts.append(dragon(cells, colour))
        blocked.update(cells)
    parts += pearls(rng, 35, blocked)
    return parts


def gpu():
    """Independent little game boards across a GPU-like grid."""
    rng = random.Random(20)
    parts = board()
    blocked = set()
    shapes = []
    for row in range(4):
        for column in range(6):
            x0, y0 = 3 + column * 9, 4 + row * 8
            shapes.append(f"M{x0 * CELL} {y0 * CELL}h{7 * CELL}v{6 * CELL}h{-7 * CELL}z")
            body = [(x0 + 2, y0 + 2), (x0 + 2, y0 + 3), (x0 + 3, y0 + 3), (x0 + 4, y0 + 3)]
            if (row + column) % 2:
                body.reverse()
            parts.append(dragon(body, OURS if column % 3 else THEIRS))
            blocked.update(body)
            for dx, dy in ((1, 4), (5, 1), (5, 4)):
                x, y = centre(x0 + dx, y0 + dy)
                parts.append(f'<circle cx="{x}" cy="{y}" r="3.2" fill="{PEARL}"/>')
    parts.insert(3, f'<path d="{"".join(shapes)}" stroke="{KELP}" stroke-width="2.5" fill="none"/>')
    parts += pearls(rng, 25, blocked)
    return parts


def main():
    parts = {"sonar": sonar, "machine": machine, "cloud": cloud,
             "pearls": pearl_seed, "lines": three_lines, "gpu": gpu}[sys.argv[1]]()
    parts.append("</svg>")
    with open(sys.argv[2], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
