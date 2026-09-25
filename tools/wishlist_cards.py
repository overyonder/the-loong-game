"""Draw the wishlist card shown at the end of each section of post 1.

Card N fills the first N slots, highlights the newest item and leaves the rest
as empty dashed slots.

    python3 tools/wishlist_cards.py blog/images
"""

import sys
from pathlib import Path

WISHLIST_ITEMS = ["Evaluation harness", "Statistics", "Offline Elo ladder", "Map generator",
                  "Replay sampler", "Replay decoder", "Debug viewer", "Profiling"]
PAPER         = "#ede5d5"
CARD          = "#f6f1e7"
INK           = "#20251f"
MUTED         = "#66675e"
RULE          = "#b9ad99"
SIGNAL        = "#b53b13"
COLUMNS       = 4
SLOT_WIDTH    = 162
SLOT_HEIGHT   = 46
GAP           = 12
MARGIN        = 20
HEADER_HEIGHT = 34


def render_wishlist_card_svg(filled_count):
    width = 2 * MARGIN + COLUMNS * SLOT_WIDTH + (COLUMNS - 1) * GAP
    rows = (len(WISHLIST_ITEMS) + COLUMNS - 1) // COLUMNS
    height = 2 * MARGIN + HEADER_HEIGHT + rows * SLOT_HEIGHT + (rows - 1) * GAP
    listed = ", ".join(WISHLIST_ITEMS[:filled_count])
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
        ' font-family="Helvetica, Arial, sans-serif" role="img" aria-labelledby="t">',
        f'<title id="t">Wishlist so far: {listed}</title>',
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        f'<text x="{MARGIN}" y="{MARGIN + 16}" font-size="14" font-weight="700"'
        f' fill="{MUTED}">Wishlist</text>',
        f'<text x="{width - MARGIN}" y="{MARGIN + 16}" font-size="13" fill="{MUTED}"'
        f' text-anchor="end">{filled_count} of {len(WISHLIST_ITEMS)}</text>',
    ]
    for index, item in enumerate(WISHLIST_ITEMS):
        x = MARGIN + (index % COLUMNS) * (SLOT_WIDTH + GAP)
        y = MARGIN + HEADER_HEIGHT + (index // COLUMNS) * (SLOT_HEIGHT + GAP)
        if index >= filled_count:
            parts.append(f'<rect x="{x}" y="{y}" width="{SLOT_WIDTH}" height="{SLOT_HEIGHT}" rx="6"'
                         f' fill="none" stroke="{RULE}" stroke-dasharray="4 4"/>')
            continue
        newest = index == filled_count - 1
        parts.append(f'<rect x="{x}" y="{y}" width="{SLOT_WIDTH}" height="{SLOT_HEIGHT}" rx="6"'
                     f' fill="{SIGNAL if newest else CARD}" stroke="{SIGNAL if newest else RULE}"/>')
        parts.append(f'<text x="{x + SLOT_WIDTH / 2}" y="{y + SLOT_HEIGHT / 2 + 5}" font-size="14"'
                     f' fill="{PAPER if newest else INK}" text-anchor="middle">{item}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    output_directory = Path(sys.argv[1])
    for filled_count in range(1, len(WISHLIST_ITEMS) + 1):
        (output_directory / f"wishlist-{filled_count}.svg").write_text(render_wishlist_card_svg(filled_count))


if __name__ == "__main__":
    main()
