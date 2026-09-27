"""Draw the explanatory diagrams in the series: small card-and-arrow figures in the
over|yonder palette that illustrate one idea each.

    python3 tools/concept_figures.py blog/images [NAME...]

Each figure is a function below, registered in FIGURES under the file name it writes.
"""

import html
import sys
from pathlib import Path

PAPER, CARD, INK, MUTED, RULE = "#ede5d5", "#f6f1e7", "#20251f", "#66675e", "#b9ad99"
FOREST, SIGNAL, HOT, PALE = "#263d31", "#b53b13", "#ff7a3d", "#dcd0bb"


def svg(width, height, title, parts):
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
        ' font-family="Helvetica, Arial, sans-serif" role="img" aria-labelledby="t">',
        f'<title id="t">{html.escape(title)}</title>',
        f'<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{MUTED}"/></marker>'
        f'<marker id="s" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{SIGNAL}"/></marker></defs>',
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        *parts, "</svg>", ""])


def text(x, y, value, size=14, fill=INK, anchor="start", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" text-anchor="{anchor}"'
            f' font-weight="{weight}">{html.escape(str(value))}</text>')


def card(x, y, w, h, title, lines=(), dark=False, accent=RULE, centre=False):
    """A rounded card: a bold title, which may run to two lines with \n, then body lines."""
    fill, title_fill, line_fill = (FOREST, PAPER, "#d9d2c3") if dark else (CARD, INK, MUTED)
    tx, anchor = (x + w / 2, "middle") if centre else (x + 14, "start")
    titles = title.split("\n")
    parts = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{accent}" stroke-width="1.6"/>']
    parts += [text(tx, y + 25 + 19 * i, t, 15, title_fill, anchor, "bold") for i, t in enumerate(titles)]
    top = y + 46 + 19 * (len(titles) - 1)
    parts += [text(tx, top + 18 * index, line, 12.5, line_fill, anchor) for index, line in enumerate(lines)]
    return "".join(parts)


def arrow(points, colour=MUTED, dashed=False):
    path = " ".join(f"{'M' if i == 0 else 'L'}{x} {y}" for i, (x, y) in enumerate(points))
    dash = ' stroke-dasharray="6 5"' if dashed else ""
    marker = "s" if colour == SIGNAL else "a"
    return (f'<path d="{path}" fill="none" stroke="{colour}" stroke-width="1.8"{dash}'
            f' stroke-linejoin="round" marker-end="url(#{marker})"/>')


def bars(title, rows, unit, width=1000, log=True, note=None):
    """Horizontal bars, one per (label, value, colour) row, on a log or linear scale."""
    import math
    left, right, top, gap = 260, 150, 60, 44
    top_value = max(value for _, value, _ in rows)
    bottom = min(value for _, value, _ in rows)
    lo = 10 ** math.floor(math.log10(bottom)) if log else 0
    scale = (lambda v: (math.log10(v) - math.log10(lo)) / (math.log10(top_value) - math.log10(lo))) if log \
        else (lambda v: v / top_value)
    span = width - left - right
    parts = [text(20, 34, title, 17, INK, weight="bold")]
    for index, (label, value, colour) in enumerate(rows):
        y = top + index * gap
        length = max(4, span * scale(value))
        parts.append(text(left - 12, y + 19, label, 14, INK, "end"))
        parts.append(f'<rect x="{left}" y="{y}" width="{length:.1f}" height="26" rx="4" fill="{colour}"/>')
        parts.append(text(left + length + 10, y + 19, f"{value:,.0f} {unit}", 13.5, MUTED))
    height = top + len(rows) * gap + (36 if note else 12)
    if note:
        parts.append(text(20, height - 14, note, 12.5, MUTED))
    return svg(width, height, title, parts)


# ---- 00: the series -----------------------------------------------------------------------

def series_stages():
    stages = [
        ("1. Understanding\nthe problem", ["the tournament", "the wishlist", "the language"]),
        ("2. Building\nour tooling", ["harness, statistics, maps", "ladder, replays, viewer", "profiling"]),
        ("3. Grand\nstrategy", ["architecture", "roles"]),
        ("4. Tactical ideas\nand espionage", ["tactics", "sonar"]),
        ("5. Performance", ["faster kernels", "our own judge"]),
    ]
    parts = []
    for index, (title, lines) in enumerate(stages):
        x = 20 + index * 212
        parts.append(card(x, 20, 196, 130, title, lines, dark=index == 0))
        if index:
            parts.append(arrow([(x - 14, 85), (x - 2, 85)]))
    return svg(1080, 170, "The series in five stages", parts)


def toolkit_and_gaps():
    parts = [card(20, 20, 470, 150, "What the toolkit gives you", [
        "unswbc init: a starter bot in C, C++ or Python",
        "unswbc run --sandbox: a game, as the judge plays it",
        "--seed: the same game again, exactly",
        "unswbc submit: an upload to the ladder",
        "the website: docs, a replay visualiser,",
        "and every public ladder game"]),
        card(530, 20, 470, 150, "What it doesn't tell you", [
        "whether a change made the bot better",
        "why a dragon died, and what it could see",
        "how other teams' bots actually play",
        "where the CPU budget went",
        "", "These are what the tools posts build."], accent=SIGNAL)]
    return svg(1020, 190, "What the toolkit gives you, and what it doesn't tell you", parts)


def strategy_cost():
    return bars("CPU points per turn for the strategy alone, idle cost removed", [
        ("C", 43_000, FOREST), ("Python", 19_700_000, SIGNAL)],
        "points", note="Log scale. The same flood-fill strategy, making the same moves; each language's idle bot cost subtracted.")


def language_options():
    parts = [
        card(20, 20, 310, 120, "Python", ["quick to write", "the strategy costs 450 times", "as much as in C"], accent=SIGNAL),
        card(350, 20, 310, 120, "C and C++", ["fast: the same clang, the same", "WebAssembly", "verbose while ideas change"]),
        card(680, 20, 310, 120, "Nim", ["reads like Python", "compiles to C, which the", "judge accepts"], dark=True),
    ]
    return svg(1010, 160, "Three ways to write a bot for the judge", parts)


def nim_build():
    parts = [
        card(20, 20, 220, 96, "strategy.nim", ["the strategy, in Nim", "changed constantly"], dark=True),
        card(20, 136, 220, 96, "kernels.c", ["hot kernels, hand-written C", "where every point counts"]),
        arrow([(240, 68), (300, 68)]),
        card(300, 20, 220, 96, "nim c", ["compileOnly, wasm32", "writes C into gen/"]),
        arrow([(520, 68), (560, 68), (560, 110), (590, 110)]),
        arrow([(240, 184), (560, 184), (560, 140), (590, 140)]),
        card(590, 76, 200, 96, "The judge's clang", ["compiles every .c file", "to WebAssembly"]),
        arrow([(790, 124), (830, 124)]),
        card(830, 76, 160, 96, "bot.wasm", ["metered, run per", "dragon, per turn"]),
    ]
    return svg(1010, 252, "How a Nim bot reaches the judge", parts)


def round_robin_schedule():
    """Every pair, both sides, on every map, with the map's seeds shared by all pairings."""
    parts = [text(20, 30, "One map, two seeds: the same seeds for every pairing and both sides", 15, INK, weight="bold")]
    pairs = [("room-c", "starter-c"), ("starter-c", "room-c"), ("room-c", "room-py"), ("room-py", "room-c")]
    seeds = ["crc32(\"arena.map:0\")", "crc32(\"arena.map:1\")"]
    for column, seed in enumerate(seeds):
        x = 250 + column * 360
        parts.append(f'<rect x="{x}" y="46" width="340" height="30" rx="6" fill="{FOREST}"/>')
        parts.append(text(x + 170, 66, f"seed {seed}", 13, PAPER, "middle", "bold"))
    for row, (a, b) in enumerate(pairs):
        y = 92 + row * 42
        parts.append(text(230, y + 20, f"{a} (A)  vs  {b} (B)", 13.5, INK, "end"))
        for column in range(2):
            x = 250 + column * 360
            parts.append(f'<rect x="{x}" y="{y}" width="340" height="32" rx="6" fill="{CARD}" stroke="{RULE}"/>')
            parts.append(text(x + 170, y + 21, "same pearls, same random numbers", 12.5, MUTED, "middle"))
    parts.append(text(20, 280, "…then the same again on every other map. Rerunning the schedule replays exactly the same games.", 13, MUTED))
    return svg(990, 300, "A round robin schedule on one map", parts)


def game_outcomes():
    parts = [card(20, 20, 380, 110, "Counted", ["a win, a loss or a draw,", "read from the engine's result line"], dark=True),
             card(440, 20, 540, 110, "Errors, in their own column", [
                 "Match exceeded the harness timeout",
                 "Battlecode exited with code N",
                 "Bot execution failure: out of time, exited, a limit, no valid action",
                 "No engine result found  ·  Replay was not written"], accent=SIGNAL)]
    return svg(1000, 150, "How the harness sorts a finished game", parts)


def coin_flips():
    """How often an even match of 100 games gives one side at least k wins."""
    from math import comb
    left, top, width, height = 70, 50, 880, 220
    parts = [text(20, 30, "Out of 100 games between equal bots, how often does one side win at least this many?", 15, INK, weight="bold")]
    at_least = {k: sum(comb(100, j) for j in range(k, 101)) / 2 ** 100 for k in range(40, 71)}
    for k in range(40, 71):
        x = left + (k - 40) * width / 31
        h = height * at_least[k]
        colour = SIGNAL if k in (55, 60) else FOREST
        parts.append(f'<rect x="{x:.1f}" y="{top + height - h:.1f}" width="{width / 31 - 4:.1f}" height="{h:.1f}" fill="{colour}" opacity="{1 if k in (55, 60) else .75}"/>')
        if k % 5 == 0:
            parts.append(text(x + width / 62, top + height + 20, k, 12.5, MUTED, "middle"))
    for k, label in ((55, "55 or more: 18%, could easily be luck"), (60, "60 or more: 3%, strong evidence")):
        x = left + (k - 40) * width / 31 + width / 62
        y = top + height - height * at_least[k] - 10
        parts.append(text(x + 8, y, label, 13, SIGNAL, "start", "bold"))
    parts.append(text(left, top + height + 42, "wins out of 100", 12.5, MUTED))
    return svg(990, 320, "How often coin flips win at least this many of 100 games", parts)


def verdict_games():
    parts = [
        card(20, 20, 300, 80, "The candidate plays…", ["on every map, side and seed"], dark=True),
        card(20, 120, 300, 80, "…and so does the baseline", ["in the candidate's seat"]),
        card(400, 20, 250, 56, "the baseline itself", [], centre=True),
        card(400, 88, 250, 56, "starter-c", [], centre=True),
        card(400, 156, 250, 56, "starter-py", [], centre=True),
        arrow([(320, 60), (398, 48)]), arrow([(320, 60), (398, 116)]), arrow([(320, 60), (398, 184)]),
        arrow([(320, 160), (398, 48)], dashed=True), arrow([(320, 160), (398, 116)], dashed=True), arrow([(320, 160), (398, 184)], dashed=True),
        card(720, 20, 270, 90, "Head to head", ["paired game by game; judged", "by weighted sign flips"]),
        card(720, 122, 270, 90, "Against weak bots", ["a candidate that loses more of", "these is never called better"], accent=SIGNAL),
        arrow([(650, 48), (718, 64)]), arrow([(650, 116), (718, 166)]), arrow([(650, 184), (718, 166)]),
    ]
    return svg(1010, 232, "The games a verdict plays", parts)


def rating_odds():
    """The chance the higher-rated bot wins, against the rating gap."""
    left, top, width, height = 90, 50, 820, 240
    parts = [text(20, 30, "Chance the stronger bot wins, by rating gap", 16, INK, weight="bold")]
    points = []
    for gap in range(0, 801, 10):
        p = 1 / (1 + 10 ** (-gap / 400))
        points.append(f"{left + width * gap / 800:.1f},{top + height * (1 - (p - 0.5) / 0.5):.1f}")
    parts.append(f'<path d="M{left} {top}V{top + height}H{left + width}" stroke="{RULE}" fill="none"/>')
    parts.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{FOREST}" stroke-width="3"/>')
    for gap, label in ((0, "even"), (200, "about 3 to 1"), (400, "10 to 1"), (800, "100 to 1")):
        p = 1 / (1 + 10 ** (-gap / 400))
        x, y = left + width * gap / 800, top + height * (1 - (p - 0.5) / 0.5)
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{SIGNAL}"/>')
        parts.append(text(x + (8 if gap < 800 else -8), y - 10, f"{label}, {p:.0%}", 13, SIGNAL, "start" if gap < 800 else "end", "bold"))
    for gap in range(0, 801, 200):
        parts.append(text(left + width * gap / 800, top + height + 20, gap, 12.5, MUTED, "middle"))
    for p in (0.5, 0.75, 1.0):
        parts.append(text(left - 10, top + height * (1 - (p - 0.5) / 0.5) + 4, f"{p:.0%}", 12.5, MUTED, "end"))
    parts.append(text(left + width / 2, top + height + 44, "rating gap, points", 12.5, MUTED, "middle"))
    return svg(960, 350, "Chance the stronger bot wins, by rating gap", parts)


def pearls_weak_bots():
    return bars("Games against the starters that changed, room-pearls in place of room-c", [
        ("lost that room-c won", 51, SIGNAL), ("won that room-c lost", 3, FOREST)],
        "games", log=False)


FIGURES = {
    "pearls-weak-bots": pearls_weak_bots,
    "rating-odds": rating_odds,
    "coin-flips": coin_flips,
    "verdict-games": verdict_games,
    "round-robin-schedule": round_robin_schedule,
    "game-outcomes": game_outcomes,
    "language-options": language_options,
    "nim-build": nim_build,
    "strategy-cost": strategy_cost,
    "series-stages": series_stages,
    "toolkit-gaps": toolkit_and_gaps,
}


if __name__ == "__main__":
    output = Path(sys.argv[1])
    names = sys.argv[2:] or list(FIGURES)
    for name in names:
        (output / f"{name}.svg").write_text(FIGURES[name]())
