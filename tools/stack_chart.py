"""Copy the computing-stack chart from over-yonder.tech's homepage as a standalone, static SVG.

    python3 tools/stack_chart.py ../over-yonder.tech/index.html blog/images/computing-stack.svg

The homepage styles and animates the chart with the site's stylesheet. This keeps the markup,
drops the animation and mobile-only parts, and inlines the chart's rules from the same checkout's
styles/main.css, with its tokens resolved, since an image can't load the site's stylesheets.
"""

import re
import sys
from pathlib import Path

from figure_palette import read_tokens

PLOT = ".oy-home-plot "
# The page draws the progress line in and fades the labels in; the still image shows them drawn.
MOTION = {"animation", "opacity", "stroke-dashoffset", "vector-effect"}


def style(site):
    """The plot's rules from the site's stylesheet, outside its media queries, as static CSS."""
    tokens = read_tokens((site / "styles" / "tokens.css").resolve().as_uri())
    css = re.sub(r"@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}", "", (site / "styles" / "main.css").read_text())
    rules = []
    for selectors, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        selectors = [selector.strip() for selector in selectors.split(",")]
        # Only the chart's own parts: the page's figure frame, caption and scrolling stay behind.
        if not all(selector.startswith(PLOT + ".") for selector in selectors) or "mobile" in "".join(selectors):
            continue
        declarations = []
        for declaration in filter(None, (part.strip() for part in body.split(";"))):
            name, value = (part.strip() for part in declaration.split(":", 1))
            if name in MOTION or (name == "stroke-dasharray" and value == "900"):
                continue
            declarations.append(f"{name}: {re.sub(r'var\(--([\w-]+)\)', lambda match: tokens[match.group(1)], value)}")
        if declarations:
            rules.append(f"{', '.join(selector.removeprefix(PLOT) for selector in selectors)} {{ {'; '.join(declarations)}; }}")
    return tokens, "<style>\n" + "\n".join(rules) + "\n</style>"


def main() -> None:
    page_path = Path(sys.argv[1])
    tokens, rules = style(page_path.parent)
    page = page_path.read_text()
    svg = re.search(r'<svg viewBox="0 0 900 \d+".*?</svg>', page, re.S).group()
    height = int(re.search(r'viewBox="0 0 900 (\d+)"', svg).group(1))
    svg = re.sub(r"\s*<defs>.*?</defs>", "", svg, flags=re.S)
    svg = re.sub(r'\s*<g class="mobile-connectors".*?</g>', "", svg, flags=re.S)
    svg = svg.replace(f'<svg viewBox="0 0 900 {height}"',
                      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-24 -20 948 {height + 40}"', 1)
    svg = svg.replace(' aria-labelledby="plot-title plot-desc">',
                      f' aria-labelledby="plot-title plot-desc">\n{rules}\n'
                      f'<rect x="-24" y="-20" width="948" height="{height + 40}" fill="{tokens["forest"]}"/>', 1)
    svg = re.sub(r' style="--step:\d+"', "", svg)
    with open(sys.argv[2], "w") as output:
        output.write(svg + "\n")


if __name__ == "__main__":
    main()
