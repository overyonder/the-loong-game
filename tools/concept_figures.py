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
    left, right, top, gap = 380, 150, 60, 44
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
        shown = f"{value:,.0f}" if value >= 1000 else f"{value:g}"
        parts.append(text(left + length + 10, y + 19, f"{shown} {unit}", 13.5, MUTED))
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


def replay_requests():
    parts = [
        card(20, 20, 220, 100, "Battles page", ["/battles?sort=at&dir=desc", "25 series a page,", "newest first"]),
        card(290, 20, 220, 100, "Series page", ["one per series", "lists its games"]),
        card(560, 20, 220, 100, "Replay API", ["/api/matches/<game>/replay", "redirects to storage"]),
        card(830, 20, 160, 100, "Replay file", ["packed binary,", "gzipped"], dark=True),
        arrow([(240, 70), (288, 70)]), arrow([(510, 70), (558, 70)]), arrow([(780, 70), (828, 70)]),
        text(20, 150, "One replay costs three requests, and the first two are shared by every game in a series. Every request waits its turn.", 13, MUTED),
    ]
    return svg(1010, 170, "The requests behind one replay", parts)


def turn_cost():
    return bars("Median CPU points per turn for the profiled bot, by part", [
        ("Output", 3_038_645, SIGNAL), ("Input", 329_448, FOREST), ("ChooseMove", 48_657, FOREST),
        ("ReadWindow", 18_444, FOREST)], "points", note="Log scale. Output is the 2.5 million write fee plus 4,000 points a byte, and the profiler's own log line.")


def moving_targets():
    parts = [
        card(20, 20, 235, 110, "Opponents change", ["teams upload new bots", "twelve times an hour"]),
        card(270, 20, 235, 110, "Maps change", ["every tournament map", "is unseen"]),
        card(520, 20, 235, 110, "Rules change", ["random pearl seeding broke", "20 teams' hardcoded", "schedules overnight"]),
        card(770, 20, 220, 110, "Views are partial", ["a 7×7 window, and", "sonar for the rest"]),
    ]
    return svg(1010, 150, "Why a bot tuned to today's ladder doesn't last", parts)


def two_rules():
    parts = [
        card(20, 20, 470, 110, "Round 500", ["If neither team is wiped out, the longest living", "dragon wins. So our longest dragon should grow", "and stay out of trouble."], dark=True),
        card(530, 20, 460, 110, "A head-on collision", ["When two heads meet, both dragons die, however", "long each was. A two-segment dragon has almost", "nothing to lose."], accent=SIGNAL),
    ]
    return svg(1010, 150, "Two rules that pull dragons in opposite directions", parts)


def strategy_tactics():
    parts = [
        card(20, 20, 470, 96, "Strategy", ["What is each dragon for?", "\"Who should be the champion?\""]),
        card(530, 20, 460, 96, "Tactics", ["How does a dragon do its job well?", "\"I'm the champion, so how do I do it well?\""], dark=True),
        arrow([(490, 68), (528, 68)]),
    ]
    return svg(1010, 136, "Strategy decides the job, tactics does it", parts)


def grid_board(x0, y0, columns, rows, cell, items):
    """A small board: items are (kind, column, row[, label]) with kind in kelp-h, kelp-v, ours, theirs, mate."""
    colours = {"ours": HOT, "theirs": "#f3ecdf", "mate": "#e0a36a"}
    parts = [f'<rect x="{x0}" y="{y0}" width="{columns * cell}" height="{rows * cell}" fill="#1d3027" rx="4"/>']
    grid = "".join(f"M{x0 + c * cell} {y0}v{rows * cell}" for c in range(1, columns))
    grid += "".join(f"M{x0} {y0 + r * cell}h{columns * cell}" for r in range(1, rows))
    parts.append(f'<path d="{grid}" stroke="rgba(243,236,223,.08)"/>')
    for item in items:
        kind, c, r = item[:3]
        cx, cy = x0 + c * cell + cell / 2, y0 + r * cell + cell / 2
        if kind == "kelp-h":
            parts.append(f'<path d="M{x0 + c * cell} {y0 + r * cell}h{cell}" stroke="#7fb069" stroke-width="5"/>')
        elif kind == "kelp-v":
            parts.append(f'<path d="M{x0 + c * cell} {y0 + r * cell}v{cell}" stroke="#7fb069" stroke-width="5"/>')
        else:
            parts.append(f'<circle cx="{cx}" cy="{cy}" r="{cell * 0.36}" fill="{colours[kind]}"/>')
        if len(item) > 3:
            parts.append(text(cx, cy + cell * 0.95, item[3], 11.5, "#f3ecdf", "middle"))
    return parts


def ray(x0, y0, cell, c1, r1, c2, r2, colour=SIGNAL):
    ax, ay = x0 + c1 * cell + cell / 2, y0 + r1 * cell + cell / 2
    bx, by = x0 + c2 * cell + cell / 2, y0 + r2 * cell + cell / 2
    return (f'<path d="M{ax} {ay}L{bx} {by}" stroke="{colour}" stroke-width="2.5" stroke-dasharray="7 5"'
            f' marker-end="url(#s)"/>')


def bitfield(title, fields):
    """A 64-bit word as labelled fields of (bits, label, colour), most significant first."""
    left, top, width = 20, 50, 970
    parts = [text(20, 30, title, 16, INK, weight="bold")]
    x, bit = left, 64
    for bits, label, colour in fields:
        w = width * bits / 64
        parts.append(f'<rect x="{x:.1f}" y="{top}" width="{w - 3:.1f}" height="52" rx="5" fill="{colour}"/>')
        parts.append(text(x + w / 2, top + 24, label, 13.5, PAPER, "middle", "bold"))
        parts.append(text(x + w / 2, top + 42, f"{bits} bits", 11.5, "#e9e1d0", "middle"))
        parts.append(text(x + 2, top + 72, bit - 1, 11, MUTED))
        x += w
        bit -= bits
    parts.append(text(left + width - 4, top + 72, 0, 11, MUTED, "end"))
    return svg(1010, 140, title, parts)


def sonar_position_message():
    return bitfield("The tactics bot's sonar message", [
        (16, "team tag LO", FOREST), (16, "sender ID", "#3f6e8c"), (4, "role", "#7a4f8a"),
        (12, "length", "#a8801a"), (8, "head x", SIGNAL), (8, "head y", SIGNAL)])


def who_hears():
    cell, parts = 44, [text(20, 30, "A ray stops at the first body it meets, and the message carries no sender", 15, INK, weight="bold")]
    parts += grid_board(20, 50, 10, 3, cell, [("ours", 1, 1, "sender"), ("theirs", 5, 1, "enemy hears it"), ("mate", 8, 1, "teammate")])
    parts.append(ray(20, 50, cell, 1, 1, 4.5, 1))
    parts += grid_board(520, 50, 10, 3, cell, [("theirs", 1, 1, "enemy, sending LO…"), ("mate", 6, 1, "our dragon")])
    parts.append(ray(520, 50, cell, 1, 1, 5.5, 1))
    parts.append(text(20, 208, "Decoding: an enemy in the way reads what we send.", 13, MUTED))
    parts.append(text(520, 208, "Misinformation: nothing stops a message in our format.", 13, MUTED))
    return svg(990, 226, "Who hears a sonar message", parts)


def echo_totals():
    cell, parts = 40, [text(20, 30, "Two different neighbourhoods, the same echo counts", 15, INK, weight="bold")]
    for index, flip in enumerate((False, True)):
        x0 = 20 + index * 500
        head = (4, 3)
        enemy = (1, 3) if flip else (7, 3)
        kelp = ("kelp-h", 4, 6) if flip else ("kelp-h", 4, 0)
        parts += grid_board(x0, 50, 9, 7, cell, [("ours", *head), ("theirs", *enemy), kelp])
        parts.append(ray(x0, 50, cell, 4, 3, enemy[0] + (0.4 if flip else -0.4), 3))
        parts.append(ray(x0, 50, cell, 4, 3, 4, 5.6 if flip else 0.4))
        parts.append(text(x0, 350, "echoes: kelp 1, enemy head 1", 13, SIGNAL, weight="bold"))
    parts.append(text(20, 374, "The counts are totals over all of a dragon's rays, so they say what is out there, not which way.", 13, MUTED))
    return svg(990, 390, "Echo counts are totals over all rays", parts)


def sonar_poker():
    cell, parts = 44, [text(20, 30, "Poker over sonar: two single dragons, one line of sight", 15, INK, weight="bold")]
    parts += grid_board(20, 50, 12, 3, cell, [("ours", 1, 1, "jester"), ("theirs", 10, 1, "opponent")])
    parts.append(ray(20, 50, cell, 1.3, 0.9, 9.6, 0.9))
    parts.append(ray(20, 50, cell, 9.7, 1.1, 1.4, 1.1, colour=FOREST))
    parts.append(text(20, 214, "Commit to a card without showing it, catch cheating, and tell your opponent from an eavesdropper.", 13, MUTED))
    return svg(990, 232, "Poker over sonar", parts)


def mask_cost():
    return bars("Where the 9,200-point room count spent its points", [
        ("building the bitboards", 7_800, SIGNAL), ("flood fills and counting", 1_400, FOREST)], "points", log=False)


def judge_parts():
    parts = [
        card(20, 20, 250, 150, "Game engine", ["unswbc_engine.wasm", "owns every rule", "writes the replay"], dark=True),
        card(370, 20, 250, 150, "The judge", ["hosts the engine", "feeds each dragon its turn", "meters CPU points", "reads the reply"]),
        card(720, 20, 270, 70, "Dragon 0: bot.wasm", ["its view on stdin, a reply on stdout"]),
        card(720, 100, 270, 70, "Dragon 1: bot.wasm", ["…one instance per dragon"]),
        arrow([(270, 95), (368, 95)]), arrow([(368, 110), (272, 110)]),
        arrow([(620, 55), (718, 55)]), arrow([(620, 135), (718, 135)]),
        text(320, 135, "bot_spawn,", 11.5, MUTED, "middle"), text(320, 150, "bot_reply, log", 11.5, MUTED, "middle"),
    ]
    return svg(1010, 190, "What a judge does", parts)


def threads_fibres():
    parts = [text(20, 30, "The official sandbox", 16, INK, weight="bold"), text(530, 30, "Our judge", 16, INK, weight="bold")]
    parts += [card(20, 50, 200, 70, "Driver thread", ["notes parks, feeds turn"]),
              card(270, 50, 200, 70, "Dragon thread", ["blocks in fd_read"]),
              card(270, 140, 200, 70, "New child's thread", ["already running"], accent=SIGNAL),
              arrow([(220, 85), (268, 85)]), arrow([(220, 100), (268, 170)], colour=SIGNAL),
              text(20, 240, "A fresh sandbox can reach its first read between", 12.5, SIGNAL),
              text(20, 258, "the park count and the feed, and is taken as done.", 12.5, SIGNAL)]
    parts += [card(530, 50, 440, 70, "One thread per game", ["the driver, the engine and every dragon"], dark=True),
              card(530, 140, 210, 70, "Dragon fibre", ["paused mid fd_read"]),
              card(760, 140, 210, 70, "Child fibre", ["runs only when resumed"]),
              arrow([(640, 120), (640, 138)]), arrow([(860, 120), (860, 138)]),
              text(530, 240, "A blocked read pauses the fibre. Only the driver resumes it,", 12.5, MUTED),
              text(530, 258, "so no bot runs between noting the count and feeding a turn.", 12.5, MUTED)]
    return svg(990, 280, "Threads in the official sandbox, fibres in ours", parts)


def judge_speed():
    return bars("End-to-end wall time for one game, seconds", [
        ("Probe bot, Default: toolkit", 3.16, RULE), ("Probe bot, Default: our judge", 0.83, FOREST),
        ("Older bot, Arena: toolkit", 3.14, RULE), ("Older bot, Arena: our judge", 0.81, FOREST),
        ("Older bot, Default: toolkit", 124.9, RULE), ("Older bot, Default: our judge", 28.2, FOREST)],
        "s", width=1010, note="Log scale. Median of three runs each, on a Ryzen 7 5800X3D, with identical replays from both hosts.")


def fleet_run():
    parts = [
        text(20, 30, "Standing resources, declared in OpenTofu", 14, INK, weight="bold"),
        text(540, 30, "Made for each run by the launcher, then gone", 14, INK, weight="bold"),
        card(20, 44, 230, 92, "Buckets", ["run bundles and results,", "expired after 14 days,", "public access blocked"]),
        card(270, 44, 230, 92, "Fleet user", ["launches, tags and", "terminates tagged Spot", "workers, runs queues"]),
        card(20, 150, 480, 76, "Worker role", ["read the run's bundle, write results, lease jobs from its queue"]),
        card(540, 44, 200, 92, "Launcher", ["packs workers into the", "vCPU allowance, checks", "quota and the $50 ledger"], dark=True),
        card(780, 44, 210, 92, "One queue per run", ["one message per game,", "leased and acknowledged"]),
        card(540, 150, 450, 76, "Spot workers in Hyderabad and Mumbai", ["pull games as cores free up, upload each result, shut down at the deadline"]),
        arrow([(740, 90), (778, 90)]), arrow([(885, 136), (885, 148)]), arrow([(640, 136), (640, 148)]),
        arrow([(500, 188), (538, 188)], dashed=True),
        text(20, 256, "A reaper on a system timer, outside every agent, terminates any worker past its deadline and costs runs whose launcher died.", 13, MUTED),
    ]
    return svg(1010, 272, "The fleet: standing resources and one run's pieces", parts)


def unseen_losses():
    return bars("How the flood-fill bot's dragons died in its 3 losses on generated maps", [
        ("hit itself through a portal", 5, SIGNAL), ("moved into the same tile as a teammate", 6, FOREST),
        ("hit a wall", 4, FOREST)], "dragons", log=False)


def strategy_cost_nim():
    return bars("CPU points per turn for the strategy alone, idle cost removed", [
        ("C", 43_000, FOREST), ("Nim, written like Python", 69_000, "#a8801a"), ("Python", 19_700_000, SIGNAL)],
        "points", note="Log scale. The same flood-fill strategy in each language, making the same moves.")


def death_causes():
    rows = []
    for cause, flood, pearl in (("hit a wall", 46, 92), ("hit itself", 34, 91), ("hit another dragon", 46, 46), ("lost head-on", 24, 28)):
        rows += [(f"{cause}: room-c", flood, FOREST), (f"{cause}: room-pearls", pearl, SIGNAL)]
    return bars("How each bot's dragons died across their 70 games", rows, "dragons", log=False)


def pearl_lengths():
    return bars("Dragon lengths across the 70 games, in segments", [
        ("longest dragon per game: room-c", 22, FOREST), ("longest dragon per game: room-pearls", 46.5, SIGNAL),
        ("dragons that hit themselves: room-c", 8.5, FOREST), ("dragons that hit themselves: room-pearls", 27, SIGNAL)],
        "median", log=False)


def first_bot_deaths():
    rows = []
    for cause, first, flood in (("hit a wall", 0.8, 0.8), ("hit another dragon", 0.5, 0.8),
                                ("lost a head-to-head", 0.4, 0.4), ("hit itself", 0.4, 0.6)):
        rows += [(f"{cause}: first-bot", first, FOREST), (f"{cause}: room-c", flood, SIGNAL)]
    return bars("Deaths per game by cause, first bot against the flood-fill bot", rows, "a game", log=False)


def friendly_fire():
    return bars("Head-on collisions in the version that split at length 10", [
        ("between two of our own dragons", 491, SIGNAL), ("with an enemy dragon", 49, FOREST)], "collisions", log=False)


def judge_cpu():
    return bars("CPU time for one game, seconds", [
        ("Probe bot, Default: toolkit", 4.08, RULE), ("Probe bot, Default: our judge", 2.03, FOREST),
        ("Older bot, Arena: toolkit", 4.18, RULE), ("Older bot, Arena: our judge", 2.19, FOREST),
        ("Older bot, Default: toolkit", 125.96, RULE), ("Older bot, Default: our judge", 29.44, FOREST)],
        "s", width=1010, note="Log scale. Host user and system time, the same runs as the wall times above.")


def verdict_games_needed():
    return bars("Games needed to detect a better bot, at α 0.05 and 80% power", [
        ("true win rate 70%, about +150 Elo", 36, FOREST), ("65%, about +110 Elo", 66, FOREST),
        ("60%, about +70 Elo", 150, SIGNAL), ("55%, about +35 Elo", 600, FOREST)], "games", log=False)


def peeking():
    return bars("How often two equal bots look different, if you stop at the first p below 0.05", [
        ("one test at the planned size", 5, FOREST), ("checking after every game, up to 20", 9.9, SIGNAL),
        ("…up to 50 games", 15.8, SIGNAL), ("…up to 150 games", 22.7, SIGNAL), ("…up to 600 games", 31.0, SIGNAL)],
        "% of runs", log=False)


def sprt_walk():
    import math
    left, top, width, height = 90, 60, 820, 300
    upper, lower = math.log(0.8 / 0.05), math.log(0.2 / 0.95)
    lo, hi = -2.0, 3.2
    y = lambda v: top + height * (hi - v) / (hi - lo)
    x = lambda n: left + width * n / 18
    parts = [text(20, 30, "The test after each straight win, until it crosses the upper boundary", 16, INK, weight="bold")]
    parts.append(f'<path d="M{left} {top}V{top + height}" stroke="{RULE}"/>')
    parts.append(f'<path d="M{left} {y(0)}H{left + width}" stroke="{RULE}" stroke-dasharray="3 4"/>')
    for value, label in ((upper, "better: ln(0.8/0.05) = 2.77"), (lower, "no material difference: ln(0.2/0.95) = −1.56")):
        parts.append(f'<path d="M{left} {y(value):.1f}H{left + width}" stroke="{SIGNAL}" stroke-width="2"/>')
        parts.append(text(left + 10, y(value) - 8, label, 13, SIGNAL, "start", "bold"))
    for step, wins_needed, colour, label in ((math.log(0.6 / 0.5), 16, FOREST, "designed for +70 Elo: decided after 16 wins"),
                                            (math.log(0.7034 / 0.5), 9, "#3f6e8c", "designed for +150 Elo: decided after 9 wins")):
        points, value = [(x(0), y(0))], 0.0
        for n in range(1, wins_needed + 1):
            points.append((x(n - 1), y(value + step)))
            value += step
            points.append((x(n), y(value)))
        parts.append(f'<polyline points="{" ".join(f"{a:.1f},{b:.1f}" for a, b in points)}" fill="none" stroke="{colour}" stroke-width="3"/>')
        parts.append(f'<circle cx="{x(wins_needed):.1f}" cy="{y(value):.1f}" r="5" fill="{colour}"/>')
        legend_y = y(-0.55) + (0 if wins_needed == 16 else 22)
        parts.append(f'<path d="M{x(9.5):.1f} {legend_y - 4:.1f}h28" stroke="{colour}" stroke-width="3"/>')
        parts.append(text(x(9.5) + 36, legend_y, label, 12.5, colour, weight="bold"))
    parts.append(f'<circle cx="{x(5):.1f}" cy="{y(5 * math.log(0.6 / 0.5)):.1f}" r="5" fill="none" stroke="{SIGNAL}" stroke-width="2"/>')
    parts.append(text(x(5) + 8, y(5 * math.log(0.6 / 0.5)) + 16, "a naive sign test would stop here, at 5 wins", 12, SIGNAL))
    for n in range(0, 19, 2):
        parts.append(text(x(n), top + height + 20, n, 12, MUTED, "middle"))
    parts.append(text(left + width / 2, top + height + 42, "straight wins", 12.5, MUTED, "middle"))
    parts.append(text(left - 10, y(0) + 4, "0", 12, MUTED, "end"))
    return svg(960, 420, "A sequential test after each straight win", parts)


def map_supply():
    """Each map's expected pearls per 100 tiles per round, from harness.mapgen's map_profile:
    toolkit 1.2.2's 15 maps, then seed 2026's 20 maps from the first generator and the current one."""
    import math
    rows = [
        ("the toolkit's 15 maps", FOREST, [1.2591, 4.7816, 1.0691, 0.2663, 0.1538, 0.6069, 3.8329, 2.3996, 4.9716,
                                           0.237, 0.3161, 3.5251, 1.2127, 1.154, 0.388]),
        ("first generator, seed 2026", SIGNAL, [0.874, 7.6162, 0.7557, 0.9091, 0.297, 5.9313, 0.0016, 0.1489, 4.1445,
                                               0.0038, 4.8789, 1.2734, 0.905, 0.0001, 7.231, 3.5982, 0.6316,
                                               0.1417, 22.6323, 0.0012]),
        ("current generator, seed 2026", "#3f6e8c", [1.4702, 1.2777, 0.1693, 0.5822, 3.1608, 0.4987, 1.2933, 1.6615,
                                                    1.1569, 3.7037, 0.6183, 0.2818, 3.6518, 0.1692, 0.366,
                                                    0.6944, 0.1692, 1.7094, 1.0157, 0.2358]),
    ]
    left, width, top, gap = 250, 420, 76, 60
    lo, hi = -4, 2
    x = lambda v: left + width * (math.log10(v) - lo) / (hi - lo)
    low, high = min(rows[0][2]), max(rows[0][2])
    bottom = top + gap * len(rows)
    parts = [text(20, 34, "Pearl supply on each map, against the official range", 17, INK, weight="bold"),
             f'<rect x="{x(low):.1f}" y="{top - 18}" width="{x(high) - x(low):.1f}" height="{bottom - top + 6}" fill="{PALE}"/>',
             text((x(low) + x(high)) / 2, top - 26, "official range", 12.5, MUTED, "middle")]
    for index, (label, colour, values) in enumerate(rows):
        y = top + gap * index + 14
        parts.append(f'<path d="M{left} {y}H{left + width}" stroke="{RULE}"/>')
        parts.append(text(left - 14, y + 5, label, 14, INK, "end"))
        outside = sum(not low <= v <= high for v in values)
        for v in values:
            parts.append(f'<circle cx="{x(v):.1f}" cy="{y}" r="6" fill="{colour}" fill-opacity=".75"/>')
        if index:
            parts.append(text(left + width + 12, y + 5, f"{outside} outside", 13, colour, weight="bold"))
    for power in range(lo, hi + 1):
        label = f"{10 ** power:g}"
        parts.append(f'<path d="M{x(10 ** power):.1f} {bottom - 6}v6" stroke="{MUTED}"/>')
        parts.append(text(x(10 ** power), bottom + 16, label, 12, MUTED, "middle"))
    parts.append(text(left + width / 2, bottom + 38, "expected pearls per 100 tiles per round, log scale", 12.5, MUTED, "middle"))
    return svg(840, bottom + 56, "Pearl supply on each map, against the official maps' range", parts)


def gamedata_sizes():
    return bars("A 500-round game on disk", [
        ("the viewer's old JSON export", 552, SIGNAL), ("the same JSON, delta-encoded", 27, SIGNAL),
        ("the packed replay", 13.0, RULE), ("the columns file", 14.6, FOREST)], "MB", log=True,
        note="Log scale. The replay and the columns file are game 610, with 62,919 dragon turns, 263,328 events and 161,966 pings.")


def gamedata_viewer():
    return bars("Opening that game in the viewer", [
        ("before: memory at the point it was stopped", 6100, SIGNAL), ("now: peak memory to the first frame", 332, FOREST)],
        "MB", log=True, note="Before, the viewer ran for over 8 minutes without drawing a frame. Now the first frame takes 0.96 s.")


def gamedata_recovery():
    return bars("Recovering one dragon's diagnostics", [
        ("before", 31, SIGNAL), ("with columns", 3.0, FOREST)], "s", log=False,
        note="Peak memory fell from 709 MB to 122 MB.")


def gamedata_layout():
    parts = [text(20, 30, "A columns file", 16, INK, weight="bold")]
    blocks = [("header", 64, 120, FOREST, ["64 bytes", "magic, version,", "count, directory", "offset, length, kind"]),
              ("turn.round", 0, 150, "#3f6e8c", ["u32 × turns"]), ("turn.dragon", 0, 150, "#3f6e8c", ["u32 × turns"]),
              ("turn.points", 0, 150, "#3f6e8c", ["u64 × turns"]), ("event.kind", 0, 130, "#a8801a", ["u8 × events"]),
              ("…", 0, 60, RULE, [""]), ("directory", 0, 160, SIGNAL, ["80 bytes a column:", "name, type, count,", "offset"])]
    x = 20
    for name, _, w, colour, lines in blocks:
        parts.append(f'<rect x="{x}" y="50" width="{w - 4}" height="110" rx="5" fill="{colour}"/>')
        parts.append(text(x + (w - 4) / 2, 76, name, 13.5, PAPER, "middle", "bold"))
        for i, line in enumerate(lines):
            parts.append(text(x + (w - 4) / 2, 98 + 16 * i, line, 12, "#ede5d5", "middle"))
        x += w
    parts.append(text(20, 190, "Each column is one contiguous array of fixed-size values, 8-byte aligned. A reader maps the file,", 13, MUTED))
    parts.append(text(20, 208, "reads the directory, and uses each column where it lies.", 13, MUTED))
    return svg(960, 226, "A columns file: header, column arrays, directory", parts)


def gamedata_list():
    parts = [text(20, 30, "A list column: every row's values end to end, and where each row starts", 15, INK, weight="bold")]
    values = [1390, 1389, 1388, 1387, 1402, 1403, 1404, 1405, 1712, 1713, 1714, 1771]
    colours = [FOREST, "#3f6e8c", "#a8801a"]
    parts.append(text(20, 76, "start.body", 13, INK, weight="bold"))
    for i, v in enumerate(values):
        parts.append(f'<rect x="{150 + i * 62}" y="56" width="58" height="30" rx="4" fill="{colours[i // 4]}"/>')
        parts.append(text(179 + i * 62, 76, v, 13, PAPER, "middle", "bold"))
    parts.append(text(894, 76, "… 40 cells", 13, MUTED))
    parts.append(text(20, 136, "start.body#", 13, INK, weight="bold"))
    for i, v in enumerate([0, 4, 8, 12]):
        parts.append(f'<rect x="{150 + i * 62}" y="116" width="58" height="30" rx="4" fill="{CARD}" stroke="{RULE}"/>')
        parts.append(text(179 + i * 62, 136, v, 13, INK, "middle"))
    parts.append(text(398, 136, "… 11 starts", 13, MUTED))
    parts.append(text(20, 180, "The first three of game 610's ten starting dragons. Row i is body[start[i] ..< start[i + 1]], head first,", 13, MUTED))
    parts.append(text(20, 198, "and a cell is y × width + x, so dragon 0's head, 1390 on this 57-wide map, is at (22, 24).", 13, MUTED))
    return svg(990, 214, "A list column and its starts", parts)


FIGURES = {
    "gamedata-sizes": gamedata_sizes,
    "gamedata-viewer": gamedata_viewer,
    "gamedata-layout": gamedata_layout,
    "gamedata-recovery": gamedata_recovery,
    "gamedata-list": gamedata_list,
    "verdict-games-needed": verdict_games_needed,
    "peeking": peeking,
    "sprt-walk": sprt_walk,
    "death-causes": death_causes,
    "pearl-lengths": pearl_lengths,
    "first-bot-deaths": first_bot_deaths,
    "friendly-fire": friendly_fire,
    "judge-cpu": judge_cpu,
    "strategy-cost-nim": strategy_cost_nim,
    "unseen-losses": unseen_losses,
    "map-supply": map_supply,
    "fleet-run": fleet_run,
    "sonar-position-message": sonar_position_message,
    "who-hears": who_hears,
    "echo-totals": echo_totals,
    "sonar-poker": sonar_poker,
    "mask-cost": mask_cost,
    "judge-parts": judge_parts,
    "threads-fibres": threads_fibres,
    "judge-speed": judge_speed,
    "replay-requests": replay_requests,
    "turn-cost": turn_cost,
    "moving-targets": moving_targets,
    "two-rules": two_rules,
    "strategy-tactics": strategy_tactics,
    "rating-odds": rating_odds,
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
