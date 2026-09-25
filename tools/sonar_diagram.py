"""Draw one dragon's four sonar rays on a small board, and the echo counts they return.

    python3 tools/sonar_diagram.py blog/images/sonar-rays.svg
"""

import sys

PAPER, CARD, INK, MUTED, RULE = "#ede5d5", "#f6f1e7", "#20251f", "#66675e", "#b9ad99"
BOARD, GRID, KELP = "#1d3027", "rgba(243,236,223,.08)", "#7fb069"
OURS, THEIRS, SIGNAL = "#ff7a3d", "#f3ecdf", "#b53b13"

SIZE, CELL = 11, 36
LEFT, TOP = 24, 24

# Our sender faces east, head at (5, 5). Its body runs west from the head.
SENDER = [(5, 5), (4, 5), (3, 5), (2, 5)]
TEAMMATE = [(0, 7), (0, 6), (0, 5)]           # head at the bottom, body just past the sender's tail
ENEMY = [(9, 5), (9, 4), (9, 3), (10, 3)]      # head facing west, towards us
KELP_EDGES = [(4, 1), (5, 1), (6, 1)]          # a wall along the north side of row 1


def centre(cell):
    return LEFT + cell[0] * CELL + CELL / 2, TOP + cell[1] * CELL + CELL / 2


def dragon(body, colour):
    points = " ".join("{:.0f},{:.0f}".format(*centre(cell)) for cell in body)
    x, y = centre(body[0])
    return (f'<polyline points="{points}" fill="none" stroke="{colour}" stroke-width="{CELL * 0.5}"'
            f' stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>'
            f'<circle cx="{x}" cy="{y}" r="{CELL * 0.34}" fill="{colour}"/>')


def ray(points, label, label_at, anchor="start"):
    path = " ".join(f"{'M' if index == 0 else 'L'}{x:.0f} {y:.0f}" for index, (x, y) in enumerate(points))
    return (f'<path d="{path}" stroke="{SIGNAL}" stroke-width="2.5" stroke-dasharray="7 5" fill="none"'
            f' marker-end="url(#arrow)"/>'
            f'<text x="{label_at[0]}" y="{label_at[1]}" font-size="13" font-weight="bold" fill="{SIGNAL}"'
            f' text-anchor="{anchor}">{label}</text>')


def main():
    board = SIZE * CELL
    width, height = LEFT + board + 300, TOP * 2 + board
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t">',
        '<title id="t">One dragon\'s four sonar rays and the echo counts they return</title>',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
        f'<path d="M0 0L10 5L0 10z" fill="{SIGNAL}"/></marker></defs>',
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        f'<rect x="{LEFT}" y="{TOP}" width="{board}" height="{board}" fill="{BOARD}"/>',
    ]
    grid = "".join(f"M{LEFT + i * CELL} {TOP}V{TOP + board}M{LEFT} {TOP + i * CELL}H{LEFT + board}" for i in range(1, SIZE))
    parts.append(f'<path d="{grid}" stroke="{GRID}" stroke-width="1"/>')
    kelp = "".join(f"M{LEFT + x * CELL} {TOP + y * CELL}h{CELL}" for x, y in KELP_EDGES)
    parts.append(f'<path d="{kelp}" stroke="{KELP}" stroke-width="5" stroke-linecap="round"/>')
    parts += [dragon(TEAMMATE, OURS), dragon(ENEMY, THEIRS), dragon(SENDER, OURS)]

    hx, hy = centre(SENDER[0])
    tx, ty = centre(SENDER[-1])
    # North: up from the head until the kelp wall on row 1.
    parts.append(ray([(hx, hy - 14), (hx, TOP + CELL + 4)], "N: kelp", (hx + 8, TOP + CELL + 22)))
    # East: straight into the enemy's head.
    ex, _ = centre(ENEMY[0])
    parts.append(ray([(hx + 14, hy), (ex - 16, hy)], "E: enemy head", (hx + 30, hy - 10)))
    # South: down and off the bottom edge, back in at the top, and into the same wall from above.
    parts.append(ray([(hx, hy + 14), (hx, TOP + board)], "", (0, 0)))
    parts.append(ray([(hx, TOP), (hx, TOP + CELL - 4)], "S: wraps round, kelp", (hx + 8, TOP + 20)))
    # West, opposite the facing: starts from the tail and heads away from the body, into a teammate.
    mx, _ = centre(TEAMMATE[0])
    parts.append(ray([(tx - 14, ty), (mx + 16, ty)], "W: from the tail, ally body", (mx + 20, ty + 32)))

    # The echo counts the sender reads next turn.
    x0 = LEFT + board + 30
    parts.append(f'<text x="{x0}" y="{TOP + 30}" font-size="16" font-weight="bold" fill="{INK}">Echoes next turn</text>')
    parts.append(f'<text x="{x0}" y="{TOP + 52}" font-size="12.5" fill="{MUTED}">totals over all four rays</text>')
    for index, (name, count) in enumerate([("kelp", 2), ("allied body", 1), ("allied head", 0),
                                           ("enemy body", 0), ("enemy head", 1)]):
        y = TOP + 88 + index * 34
        parts.append(f'<rect x="{x0}" y="{y - 20}" width="230" height="28" rx="5" fill="{CARD}" stroke="{RULE}"/>')
        parts.append(f'<text x="{x0 + 12}" y="{y - 1}" font-size="14" fill="{INK}">{name}</text>')
        parts.append(f'<text x="{x0 + 216}" y="{y - 1}" font-size="15" font-weight="bold" fill="{SIGNAL if count else MUTED}"'
                     f' text-anchor="end">{count}</text>')
    parts.append(f'<text x="{x0}" y="{TOP + 290}" font-size="12.5" fill="{MUTED}">Each ray also delivers its</text>')
    parts.append(f'<text x="{x0}" y="{TOP + 306}" font-size="12.5" fill="{MUTED}">64-bit value to the dragon it hits,</text>')
    parts.append(f'<text x="{x0}" y="{TOP + 322}" font-size="12.5" fill="{MUTED}">with no sender and no team.</text>')
    parts.append("</svg>")
    with open(sys.argv[1], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
