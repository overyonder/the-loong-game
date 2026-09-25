"""Draw six versions that each beat the one before, going round rock, paper, scissors.

    python3 tools/cycle_diagram.py blog/images/version-cycle.svg
"""

import sys

PAPER, INK, MUTED = "#ede5d5", "#20251f", "#66675e"
SIGNAL, FOREST, FOREST_TEXT = "#b53b13", "#263d31", "#c7c1b2"

MOVES = ["Rock", "Paper", "Scissors"] * 2
WIDTH, HEIGHT = 800, 330
CARD_WIDTH, CARD_HEIGHT, GAP = 94, 110, 38
LEFT = (WIDTH - 6 * CARD_WIDTH - 5 * GAP) / 2
CARD_Y = 96


def text(x, y, value, size=13, colour=INK, anchor="middle", weight="normal", style="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{colour}" text-anchor="{anchor}"'
            f' font-weight="{weight}" font-style="{style}">{value}</text>')


def icon(move, cx, cy):
    """A simple line drawing of each hand, in the paper colour on the dark card."""
    stroke = f'stroke="{PAPER}" stroke-width="2.4" fill="none" stroke-linecap="round"'
    if move == "Rock":
        return (f'<path d="M{cx - 20} {cy + 4} Q{cx - 22} {cy - 16} {cx - 4} {cy - 18} Q{cx + 16} {cy - 22} {cx + 20} {cy - 4}'
                f' Q{cx + 24} {cy + 16} {cx + 2} {cy + 17} Q{cx - 18} {cy + 20} {cx - 20} {cy + 4}Z" {stroke}/>')
    if move == "Paper":
        lines = f'stroke="{PAPER}" stroke-width="1.6" stroke-linecap="round"'
        return "\n".join([f'<rect x="{cx - 16}" y="{cy - 20}" width="32" height="40" rx="2" {stroke}/>']
                         + [f'<path d="M{cx - 9} {cy - 10 + 8 * row} H{cx + 9}" {lines}/>' for row in range(4)])
    return "\n".join([
        f'<circle cx="{cx - 11}" cy="{cy + 13}" r="6" {stroke}/>',
        f'<circle cx="{cx + 11}" cy="{cy + 13}" r="6" {stroke}/>',
        f'<path d="M{cx - 7} {cy + 8} L{cx + 12} {cy - 20}" {stroke}/>',
        f'<path d="M{cx + 7} {cy + 8} L{cx - 12} {cy - 20}" {stroke}/>',
    ])


def main():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t d">',
        '<title id="t">Six versions, each beating the last</title>',
        '<desc id="d">Rock, paper, scissors, rock, paper, scissors, labelled v1 to v6. Each beats the one before it,'
        ' so the labels look like steady progress, but v4 plays exactly like v1 and the sequence goes round in a circle.</desc>',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{MUTED}"/></marker>'
        f'<marker id="signal-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{SIGNAL}"/></marker></defs>',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{PAPER}"/>',
    ]

    centres = [LEFT + index * (CARD_WIDTH + GAP) + CARD_WIDTH / 2 for index in range(6)]

    # The loop that the labels hide: the fourth version is the first one again.
    first, fourth = centres[0], centres[3]
    parts.append(f'<path d="M{fourth} {CARD_Y - 6} C{fourth} {CARD_Y - 62} {first} {CARD_Y - 62} {first} {CARD_Y - 6}"'
                 f' stroke="{SIGNAL}" stroke-width="1.8" fill="none" stroke-dasharray="6 4" marker-end="url(#signal-arrow)"/>')
    parts.append(text((first + fourth) / 2, CARD_Y - 58, "v4 plays exactly like v1", 13, SIGNAL, weight="bold"))

    for index, (move, cx) in enumerate(zip(MOVES, centres)):
        x = cx - CARD_WIDTH / 2
        parts += [
            f'<rect x="{x}" y="{CARD_Y}" width="{CARD_WIDTH}" height="{CARD_HEIGHT}" rx="8" fill="{FOREST}"/>',
            icon(move, cx, CARD_Y + 42),
            text(cx, CARD_Y + 94, move, 14, PAPER, weight="bold"),
            text(cx, CARD_Y + CARD_HEIGHT + 34, f"v{index + 1}", 20, SIGNAL, weight="bold"),
        ]
        if index:
            gap_left = cx - CARD_WIDTH / 2 - GAP
            # Each newer version points back at the one it beats.
            parts.append(f'<path d="M{gap_left + GAP - 4} {CARD_Y + CARD_HEIGHT / 2} H{gap_left + 4}" stroke="{MUTED}"'
                         ' stroke-width="1.5" marker-end="url(#arrow)"/>')
            parts.append(text(gap_left + GAP / 2, CARD_Y + CARD_HEIGHT / 2 - 8, "beats", 10.5, MUTED))

    # The version labels suggest a straight line of progress.
    label_y = CARD_Y + CARD_HEIGHT + 62
    parts.append(f'<path d="M{centres[0] - 20} {label_y} H{centres[-1] + 20}" stroke="{MUTED}" stroke-width="1.5"'
                 ' marker-end="url(#arrow)"/>')
    parts.append(text(WIDTH / 2, label_y + 24, "Each version beat the one before it, so the numbers look like steady progress.", 12.5, MUTED, style="italic"))
    parts.append("</svg>")
    with open(sys.argv[1], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
