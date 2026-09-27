"""Draw .map files as a contact sheet, in the style of the map banners.

    python3 tools/map_figure.py OUTPUT.svg "TITLE" MAP...

Each board shows its kelp in green, portal edges in orange dashes, the tiles that can
spawn pearls as faint dots, and the starting dragons in the teams' colours, with the
map's name and size beneath.
"""

import html
import sys
from pathlib import Path

from banner import BOARD, CELL, GRID, KELP, OURS, PEARL, THEIRS

SHEET, LABEL = "#263d31", "#f3ecdf"
COLUMNS, SLOT_WIDTH, SLOT_HEIGHT, GAP = 5, 200, 170, 16


def read_map(path):
    width = height = 0
    name, spawn, kelp, portals, dragons = path.stem, [], [], [], []
    for line in path.read_text().splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "MAP":
            width, height = int(fields[1]), int(fields[2])
        elif fields[0] == "MAP_NAME":
            name = " ".join(fields[1:])
        elif fields[0] == "TILE":
            spawn.append((int(fields[1]), int(fields[2])))
        elif fields[0] == "EDGE":
            row, x = divmod(int(fields[1]), width + 1)
            edge = ("N", x, row // 2) if row % 2 == 0 else ("W", x, row // 2)
            (kelp if fields[2] == "1" else portals).append(edge)
        elif fields[0] == "DRAGON":
            numbers = [int(value) for value in fields[3:]]
            dragons.append((int(fields[1]), list(zip(numbers[::2], numbers[1::2]))))
    return name, width, height, spawn, kelp, portals, dragons


def edge_path(edges):
    return "".join(f"M{x * CELL} {y * CELL}h{CELL}" if side == "N" else f"M{x * CELL} {y * CELL}v{CELL}"
                   for side, x, y in edges)


def board(path):
    name, width, height, spawn, kelp, portals, dragons = read_map(path)
    w, h = width * CELL, height * CELL
    grid = "".join(f"M{x} 0V{h}" for x in range(CELL, w, CELL)) + "".join(f"M0 {y}H{w}" for y in range(CELL, h, CELL))
    parts = [f'<rect width="{w}" height="{h}" fill="{BOARD}"/>',
             f'<path d="{grid}" stroke="{GRID}" stroke-width="1"/>']
    parts += [f'<circle cx="{x * CELL + CELL / 2}" cy="{y * CELL + CELL / 2}" r="2.5" fill="{PEARL}" opacity=".35"/>'
              for x, y in spawn]
    parts.append(f'<path d="{edge_path(kelp)}" stroke="{KELP}" stroke-width="5" stroke-linecap="round"/>')
    parts.append(f'<path d="{edge_path(portals)}" stroke="{OURS}" stroke-width="5" stroke-dasharray="6 5"/>')
    for team, body in dragons:
        colour = OURS if team == 0 else THEIRS
        points = " ".join(f"{x * CELL + CELL / 2},{y * CELL + CELL / 2}" for x, y in body)
        hx, hy = body[0]
        parts.append(f'<polyline points="{points}" fill="none" stroke="{colour}" stroke-width="12"'
                     f' stroke-linecap="round" stroke-linejoin="round" opacity=".85"/>'
                     f'<circle cx="{hx * CELL + CELL / 2}" cy="{hy * CELL + CELL / 2}" r="8.6" fill="{colour}"/>')
    return name, width, height, w, h, "".join(parts)


def sheet(title, paths):
    # A single map gets one large slot; a set gets a grid of small ones.
    columns, slot_width, slot_height = (1, 520, 470) if len(paths) == 1 else (COLUMNS, SLOT_WIDTH, SLOT_HEIGHT)
    rows = (len(paths) + columns - 1) // columns
    width = columns * (slot_width + GAP) + GAP
    height = 56 + rows * (slot_height + GAP)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-labelledby="t"'
             ' font-family="Helvetica, Arial, sans-serif">',
             f'<title id="t">{html.escape(title)}</title>',
             f'<rect width="{width}" height="{height}" fill="{SHEET}"/>',
             f'<text x="{GAP}" y="36" font-size="20" font-weight="bold" fill="{LABEL}">{html.escape(title)}</text>']
    for index, path in enumerate(paths):
        name, columns, rows_, w, h, drawing = board(path)
        x0 = GAP + (index % columns) * (slot_width + GAP)
        y0 = 56 + (index // columns) * (slot_height + GAP)
        scale = min(slot_width / w, (slot_height - 24) / h)
        dx = x0 + (slot_width - w * scale) / 2
        parts.append(f'<svg x="{dx:.1f}" y="{y0}" width="{w * scale:.1f}" height="{h * scale:.1f}" viewBox="0 0 {w} {h}">'
                     f'{drawing}</svg>')
        parts.append(f'<text x="{x0 + slot_width / 2}" y="{y0 + slot_height - 6}" font-size="12" fill="{LABEL}"'
                     f' text-anchor="middle">{html.escape(name)}, {columns}×{rows_}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


if __name__ == "__main__":
    Path(sys.argv[1]).write_text(sheet(sys.argv[2], [Path(path) for path in sys.argv[3:]]))
