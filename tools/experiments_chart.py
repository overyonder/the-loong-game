"""Chart a set of verdicts: for each change, the share of its changed games it gained.

    python3 tools/experiments_chart.py "Each change against the first bot" blog/images/roles-experiments.svg \\
        "Roles, first try=examples/tooling/results-v2/p12-first-try" ...

Each argument after the output is a label and a verdict directory. Changed games are the paired
games whose result the change altered; unchanged games aren't plotted, since they can't tell us
anything about the change.
"""

import json
import sys
from pathlib import Path

PAPER, INK, MUTED, GRID, EVEN = "#ede5d5", "#20251f", "#66675e", "#d9d0bf", "#8a8274"
COLOURS = {"better": "#b53b13", "worse": "#8a8274", "undecided": "#b9ad99"}


def main():
    title, output, *rows = sys.argv[1:]
    verdicts = []
    for row in rows:
        label, directory = row.split("=", 1)
        verdicts.append((label, json.loads((Path(directory) / "verdict.json").read_text())))
    left, right, top, step = 290, 600, 54, 44
    width, height = 760, top + step * len(verdicts) + 34
    x = lambda share: left + share * (right - left)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="Helvetica, Arial, sans-serif"'
             ' role="img" aria-labelledby="t d">', f'<title id="t">{title}</title>']
    description = "; ".join(f"{label}: {v['gained']} changed games gained, {v['dropped']} dropped, {v['verdict']}"
                            for label, v in verdicts)
    parts.append(f'<desc id="d">{description}.</desc>')
    parts.append(f'<rect width="{width}" height="{height}" fill="{PAPER}"/>')
    bottom = top + step * len(verdicts) - 24
    for share in (0, 0.25, 0.5, 0.75, 1):
        dash = f' stroke="{EVEN}" stroke-dasharray="4 3"' if share == 0.5 else f' stroke="{GRID}"'
        parts.append(f'<line x1="{x(share)}" x2="{x(share)}" y1="32" y2="{bottom}"{dash}/>')
        parts.append(f'<text x="{x(share)}" y="{bottom + 18}" font-size="12" fill="{MUTED}" text-anchor="middle">{share:.0%}</text>')
    parts.append(f'<text x="{x(0.5)}" y="26" font-size="12" fill="{MUTED}" text-anchor="middle">share of changed games gained</text>')
    for index, (label, v) in enumerate(verdicts):
        y = top + index * step
        changed = v["gained"] + v["dropped"]
        share = v["gained"] / changed if changed else 0.5
        colour = COLOURS[v["verdict"]]
        parts.append(f'<text x="{left - 12}" y="{y + 5}" font-size="13" fill="{INK}" text-anchor="end">{label}</text>')
        parts.append(f'<line x1="{x(0.5)}" x2="{x(share):.1f}" y1="{y}" y2="{y}" stroke="{colour}" stroke-width="3"/>')
        parts.append(f'<circle cx="{x(share):.1f}" cy="{y}" r="6" fill="{colour}" stroke="{PAPER}" stroke-width="2"/>')
        summary = f"{v['gained']}–{v['dropped']} of {v['pairs']}, {v['verdict']}"
        parts.append(f'<text x="{right + 14}" y="{y + 5}" font-size="12.5" fill="{INK}">{summary}</text>')
    parts.append("</svg>")
    Path(output).write_text("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
