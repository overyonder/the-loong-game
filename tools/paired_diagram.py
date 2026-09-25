"""Draw how the verdict pairs games: each candidate game beside the baseline's game on the same seed.

    python3 tools/paired_diagram.py blog/images/paired-games.svg
"""

import sys

PAPER, INK, MUTED, RULE = "#ede5d5", "#20251f", "#66675e", "#b9ad99"
FOREST, SIGNAL, PALE = "#263d31", "#b53b13", "#dcd0bb"


def text(x, y, content, size=14, weight="normal", fill=INK, anchor="start"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}"'
            f' text-anchor="{anchor}">{content}</text>')


def main():
    width, height = 1040, 330
    # Twelve fixtures: the same map, side and seed for both rows. Activation is the share of the
    # candidate's turns in which the changed behaviour ran.
    fixtures = [("same", 0.0), ("same", 0.0), ("gained", 0.40), ("same", 0.10), ("dropped", 0.05), ("same", 0.0),
                ("gained", 0.30), ("same", 0.20), ("same", 0.0), ("gained", 0.15), ("same", 0.0), ("same", 0.0)]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
             'font-family="Helvetica, Arial, sans-serif" role="img" aria-labelledby="t">',
             '<title id="t">Paired games: the candidate and the baseline on the same map, side and seed</title>',
             f'<rect width="{width}" height="{height}" fill="{PAPER}"/>']
    parts.append(text(186, 72, "baseline", 21, "bold", anchor="end"))
    parts.append(text(186, 152, "candidate", 21, "bold", anchor="end"))
    parts.append(text(186, 224, "activation", 19, fill=MUTED, anchor="end"))
    for index, (result, share) in enumerate(fixtures):
        x = 210 + index * 68
        for row, won in enumerate((result != "gained", result != "dropped")):
            y = 40 + row * 80
            fill = FOREST if won else PALE
            parts.append(f'<rect x="{x}" y="{y}" width="52" height="52" rx="6" fill="{fill}" stroke="{RULE}"/>')
            parts.append(text(x + 26, y + 32, "W" if won else "L", 22, "bold", PAPER if won else MUTED, "middle"))
        parts.append(f'<rect x="{x}" y="{226 - share * 60}" width="52" height="{share * 60}" fill="{SIGNAL}" opacity=".75"/>')
        parts.append(f'<path d="M{x} 226H{x + 52}" stroke="{RULE}"/>')
        if result != "same":
            parts.append(f'<rect x="{x - 6}" y="32" width="64" height="148" rx="9" fill="none" stroke="{SIGNAL}" stroke-width="3"/>')
            parts.append(text(x + 26, 256, result, 18, "bold", SIGNAL, "middle"))
    parts.append(text(204, 306, "Only the outlined pairs count, each weighted by how much the change ran.", 21))
    parts.append("</svg>")
    with open(sys.argv[1], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
