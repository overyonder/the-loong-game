"""Copy the computing-stack chart from over-yonder.tech's homepage as a standalone, static SVG.

    python3 tools/stack_chart.py ../over-yonder.tech/index.html blog/images/computing-stack.svg

The homepage styles and animates the chart with its stylesheet. This keeps the markup, drops the
animation and mobile-only parts, and inlines the colours and fonts the chart needs.
"""

import re
import sys

STYLE = """<style>
.plot-grid path { fill: none; stroke: #596057; stroke-width: 1; }
.plot-grid .major-grid { stroke-opacity: .75; }
.plot-grid .minor-grid { stroke-opacity: .23; }
.barriers path { fill: none; stroke: #596057; stroke-width: 1.25; stroke-opacity: .75; }
.hardware-boundary path { fill: none; stroke: #ff7a3d; stroke-width: 1.5; stroke-dasharray: 7 5; }
.hardware-boundary text { fill: #ff7a3d; font: 700 11px "SFMono-Regular", Consolas, monospace; letter-spacing: .1em; text-anchor: end; }
.axis-labels, .group-labels, .stage-labels { font-family: "SFMono-Regular", Consolas, "DejaVu Sans Mono", monospace; }
.axis-labels { fill: #a5a293; font-size: 14px; text-anchor: middle; }
.axis-labels .axis-title { fill: #f3ecdf; font-size: 13px; letter-spacing: .02em; }
.group-labels { fill: #a5a293; font-size: 11px; font-weight: 700; letter-spacing: .1em; }
.stage-labels .domain { fill: #f3ecdf; font-size: 11.5px; font-weight: 500; }
.stage-labels .intervention { fill: #ff7a3d; stroke: #263d31; stroke-width: 4px; paint-order: stroke; font-size: 10.5px; font-weight: 650; }
.stage-labels .intervention-before { text-anchor: end; }
.progress-halo { fill: none; stroke: #ff7a3d; stroke-width: 15; stroke-opacity: .12; }
.progress-line { fill: none; stroke: #ff7a3d; stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; }
.plot-points circle { fill: #263d31; stroke: #ff7a3d; stroke-width: 3; }
.plot-points g:last-child circle { fill: #ff7a3d; }
</style>"""


def main() -> None:
    page = open(sys.argv[1]).read()
    svg = re.search(r'<svg viewBox="0 0 900 \d+".*?</svg>', page, re.S).group()
    height = int(re.search(r'viewBox="0 0 900 (\d+)"', svg).group(1))
    svg = re.sub(r"\s*<defs>.*?</defs>", "", svg, flags=re.S)
    svg = re.sub(r'\s*<g class="mobile-connectors".*?</g>', "", svg, flags=re.S)
    svg = svg.replace(f'<svg viewBox="0 0 900 {height}"',
                      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-24 -20 948 {height + 40}"', 1)
    svg = svg.replace(' aria-labelledby="plot-title plot-desc">',
                      f' aria-labelledby="plot-title plot-desc">\n{STYLE}\n'
                      f'<rect x="-24" y="-20" width="948" height="{height + 40}" fill="#263d31"/>', 1)
    svg = re.sub(r' style="--step:\d+"', "", svg)
    with open(sys.argv[2], "w") as output:
        output.write(svg + "\n")


if __name__ == "__main__":
    main()
