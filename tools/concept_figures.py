"""Draw the explanatory diagrams in the series: small card-and-arrow figures in the
over|yonder palette that illustrate one idea each.

    python3 tools/concept_figures.py blog/images [NAME...]

Each figure is a function below, registered in FIGURES under the file name it writes.
"""

import html
import sys
from pathlib import Path

from figure_palette import (
    BLUE,
    BOARD,
    BOARD_GRID,
    CARD,
    DARK_LINE,
    DARK_TITLE,
    FONT,
    FOREST,
    GOLD,
    HOT,
    INK,
    KELP,
    MATE,
    MUTED,
    OURS,
    PALE,
    PAPER,
    PEARL,
    PURPLE,
    RULE,
    SIGNAL,
    THEIRS,
)


def svg(width, height, title, parts):
    return "\n".join([
        (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
         f' font-family="{FONT}" role="img" aria-labelledby="t">'),
        f'<title id="t">{html.escape(title)}</title>',
        (f'<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
         f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{MUTED}"/></marker>'
         f'<marker id="s" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
         f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{SIGNAL}"/></marker></defs>'),
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        *parts, "</svg>", ""])


def text(x, y, value, size=14, fill=INK, anchor="start", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" text-anchor="{anchor}"'
            f' font-weight="{weight}">{html.escape(str(value))}</text>')


def card(x, y, w, h, title, lines=(), dark=False, accent=RULE, centre=False, title_size=15, body_size=12.5, line_height=18):
    """A rounded card: a bold title, which may run to two lines with \n, then body lines."""
    fill, title_fill, line_fill = (FOREST, PAPER, DARK_LINE) if dark else (CARD, INK, MUTED)
    tx, anchor = (x + w / 2, "middle") if centre else (x + 14, "start")
    titles = title.split("\n")
    parts = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{accent}" stroke-width="1.6"/>']
    parts += [text(tx, y + 25 + 19 * i, t, title_size, title_fill, anchor, "bold") for i, t in enumerate(titles)]
    top = y + (60 if body_size >= 18 else 46) + 19 * (len(titles) - 1)
    parts += [text(tx, top + line_height * index, line, body_size, line_fill, anchor) for index, line in enumerate(lines)]
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
    colours = {"ours": HOT, "theirs": THEIRS, "mate": MATE}
    parts = [f'<rect x="{x0}" y="{y0}" width="{columns * cell}" height="{rows * cell}" fill="{BOARD}" rx="4"/>']
    grid = "".join(f"M{x0 + c * cell} {y0}v{rows * cell}" for c in range(1, columns))
    grid += "".join(f"M{x0} {y0 + r * cell}h{columns * cell}" for r in range(1, rows))
    parts.append(f'<path d="{grid}" stroke="{BOARD_GRID}"/>')
    for item in items:
        kind, c, r = item[:3]
        cx, cy = x0 + c * cell + cell / 2, y0 + r * cell + cell / 2
        if kind == "kelp-h":
            parts.append(f'<path d="M{x0 + c * cell} {y0 + r * cell}h{cell}" stroke="{KELP}" stroke-width="5"/>')
        elif kind == "kelp-v":
            parts.append(f'<path d="M{x0 + c * cell} {y0 + r * cell}v{cell}" stroke="{KELP}" stroke-width="5"/>')
        else:
            parts.append(f'<circle cx="{cx}" cy="{cy}" r="{cell * 0.36}" fill="{colours[kind]}"/>')
        if len(item) > 3:
            parts.append(text(cx, cy + cell * 0.95, item[3], 11.5, THEIRS, "middle"))
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
        parts.append(text(x + w / 2, top + 42, f"{bits} bits", 11.5, DARK_TITLE, "middle"))
        parts.append(text(x + 2, top + 72, bit - 1, 11, MUTED))
        x += w
        bit -= bits
    parts.append(text(left + width - 4, top + 72, 0, 11, MUTED, "end"))
    return svg(1010, 140, title, parts)


def sonar_position_message():
    return bitfield("The tactics bot's sonar message", [
        (16, "team tag LO", FOREST), (16, "sender ID", BLUE), (4, "role", PURPLE),
        (12, "length", GOLD), (8, "head x", SIGNAL), (8, "head y", SIGNAL)])


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
        card(540, 44, 200, 102, "Launcher", ["checks vCPUs and $75 cap,", "records the run's owner,", "starts its workers"], dark=True),
        card(780, 44, 210, 92, "One queue per run", ["one message per game,", "leased and acknowledged"]),
        card(540, 150, 450, 76, "Spot workers in Hyderabad and Mumbai", ["pull games as cores free up, upload each result, shut down at the deadline"]),
        arrow([(740, 90), (778, 90)]), arrow([(885, 136), (885, 148)]), arrow([(640, 136), (640, 148)]),
        arrow([(500, 188), (538, 188)], dashed=True),
        text(20, 256, "A reaper on a system timer, outside every agent, terminates any worker past its deadline and costs runs whose launcher died.", 13, MUTED),
    ]
    return svg(1010, 272, "The fleet: standing resources and one run's pieces", parts)


def fleet_result_links():
    parts = [
        text(20, 30, "Results go directly to the rented GPU", 20, INK, weight="bold"),
        card(20, 55, 440, 100, "Launcher", ["holds AWS credentials,", "signs links to completed result archives"],
             dark=True, title_size=20, body_size=17),
        arrow([(240, 155), (240, 207)]),
        text(258, 184, "links valid 12 hours", 17, MUTED),
        card(20, 209, 440, 100, "Rented GPU", ["downloads each archive directly,", "holds no AWS credentials"], title_size=20, body_size=17),
        arrow([(145, 309), (145, 377)], dashed=True),
        text(163, 348, "GET", 17, MUTED),
        arrow([(325, 379), (325, 311)], colour=SIGNAL),
        text(343, 348, "archive", 17, SIGNAL),
        card(20, 379, 440, 100, "Private bucket", ["serves the linked object,", "checks its signature and expiry"], title_size=20, body_size=17),
        text(20, 516, "Each link reads one object. The bucket stays private.", 16, MUTED),
    ]
    return svg(480, 536, "Presigned links carry results from the bucket to a rented GPU", parts)


def unseen_losses():
    return bars("How the flood-fill bot's dragons died in its 3 losses on generated maps", [
        ("hit itself through a portal", 5, SIGNAL), ("moved into the same tile as a teammate", 6, FOREST),
        ("hit a wall", 4, FOREST)], "dragons", log=False)


def strategy_cost_nim():
    return bars("CPU points per turn for the strategy alone, idle cost removed", [
        ("C", 43_000, FOREST), ("Nim, written like Python", 69_000, GOLD), ("Python", 19_700_000, SIGNAL)],
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
                                            (math.log(0.7034 / 0.5), 9, BLUE, "designed for +150 Elo: decided after 9 wins")):
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
        ("current generator, seed 2026", BLUE, [1.4702, 1.2777, 0.1693, 0.5822, 3.1608, 0.4987, 1.2933, 1.6615,
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
              ("turn.round", 0, 150, BLUE, ["u32 × turns"]), ("turn.dragon", 0, 150, BLUE, ["u32 × turns"]),
              ("turn.points", 0, 150, BLUE, ["u64 × turns"]), ("event.kind", 0, 130, GOLD, ["u8 × events"]),
              ("…", 0, 60, RULE, [""]), ("directory", 0, 160, SIGNAL, ["80 bytes a column:", "name, type, count,", "offset"])]
    x = 20
    for name, _, w, colour, lines in blocks:
        parts.append(f'<rect x="{x}" y="50" width="{w - 4}" height="110" rx="5" fill="{colour}"/>')
        parts.append(text(x + (w - 4) / 2, 76, name, 13.5, PAPER, "middle", "bold"))
        for i, line in enumerate(lines):
            parts.append(text(x + (w - 4) / 2, 98 + 16 * i, line, 12, PAPER, "middle"))
        x += w
    parts.append(text(20, 190, "Each column is one contiguous array of fixed-size values, 8-byte aligned. A reader maps the file,", 13, MUTED))
    parts.append(text(20, 208, "reads the directory, and uses each column where it lies.", 13, MUTED))
    return svg(960, 226, "A columns file: header, column arrays, directory", parts)


def gamedata_list():
    parts = [text(20, 30, "A list column: every row's values end to end, and where each row starts", 15, INK, weight="bold")]
    values = [1390, 1389, 1388, 1387, 1402, 1403, 1404, 1405, 1712, 1713, 1714, 1771]
    colours = [FOREST, BLUE, GOLD]
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



def viewer_recovery():
    parts = [
        text(20, 30, "In play", 15, INK, weight="bold"),
        card(20, 44, 230, 96, "bot.wasm", ["diagnostics compiled in,", "switched off: one flag check", "per block"], dark=True),
        arrow([(250, 92), (298, 92)]),
        card(300, 44, 230, 96, "The judge", ["plays the game", "and writes the replay"]),
        arrow([(530, 92), (578, 92)]),
        card(580, 44, 410, 96, "The replay", ["what each dragon observed, turn by turn,", "and what it did"]),
        text(20, 184, "In the viewer", 15, INK, weight="bold"),
        card(20, 198, 230, 110, "The same bot.wasm", ["from the build registry,", "started with LOONG_INSPECT,", "so its diagnostics run"], dark=True),
        arrow([(785, 140), (785, 170), (415, 170), (415, 196)]),
        arrow([(250, 253), (298, 253)]),
        card(300, 198, 230, 110, "loong-recover", ["runs it in the judge on each", "dragon's recorded observations",
                                                   "and checks each action"]),
        arrow([(530, 253), (578, 253)]),
        card(580, 198, 410, 110, "The viewer", ["draws each turn's records beside the board", "and hides a dragon's overlays after its",
                                                 "rebuilt action first differs from the replay"]),
    ]
    return svg(1010, 328, "Decisions come back by rerunning the build that played", parts)


def mini_board(x0, y0, columns=7, rows=5, cell=34):
    parts = [f'<rect x="{x0}" y="{y0}" width="{columns * cell}" height="{rows * cell}" fill="{BOARD}" rx="4"/>']
    grid = "".join(f"M{x0 + c * cell} {y0}v{rows * cell}" for c in range(1, columns))
    grid += "".join(f"M{x0} {y0 + r * cell}h{columns * cell}" for r in range(1, rows))
    parts.append(f'<path d="{grid}" stroke="{BOARD_GRID}"/>')
    return parts


def centre(x0, y0, c, r, cell=34):
    return x0 + c * cell + cell / 2, y0 + r * cell + cell / 2


def gizmo_board():
    """The record kinds drawn on the board, each on its own small board."""
    cell, panels = 34, []
    titles = [("line", "two cells joined, such as a threat"), ("target", "a cell, with its label beside it"),
              ("path", "cells in the order they're walked"), ("search", "cells, each with a value"),
              ("map markers", "labelled cells from the bot's memory"), ("positions", "where a dragon was, and may be now")]
    for index, (title, caption) in enumerate(titles):
        x0, y0 = 20 + (index % 3) * 330, 44 + (index // 3) * 250
        panels.append(text(x0, y0 - 14, title, 15, INK, weight="bold"))
        panels += mini_board(x0, y0)
        panels.append(text(x0, y0 + 5 * cell + 22, caption, 12.5, MUTED))
        head = centre(x0, y0, 1, 3)
        def dot(c, r, colour=OURS, x0=x0, y0=y0):
            return '<circle cx="{}" cy="{}" r="{}" fill="{}"/>'.format(*centre(x0, y0, c, r), cell * 0.34, colour)
        if title == "line":
            enemy = centre(x0, y0, 5, 1)
            panels += [dot(1, 3), dot(5, 1, THEIRS),
                       f'<path d="M{head[0]} {head[1]}L{enemy[0]} {enemy[1]}" stroke="{SIGNAL}" stroke-width="2.5"/>']
        elif title == "target":
            tx, ty = centre(x0, y0, 4, 1)
            panels += [dot(1, 3), f'<circle cx="{tx}" cy="{ty}" r="7" fill="{PEARL}"/>',
                       f'<rect x="{tx - 15}" y="{ty - 15}" width="30" height="30" fill="none" stroke="{GOLD}" stroke-width="2.5"/>',
                       text(tx + 20, ty + 5, "pearl", 12, PEARL)]
        elif title == "path":
            steps = [(1, 3), (2, 3), (3, 3), (3, 2), (4, 2), (4, 1)]
            points = " ".join(f"{'M' if i == 0 else 'L'}{centre(x0, y0, c, r)[0]} {centre(x0, y0, c, r)[1]}" for i, (c, r) in enumerate(steps))
            px, py = centre(x0, y0, 4, 1)
            panels += [dot(1, 3), f'<circle cx="{px}" cy="{py}" r="7" fill="{PEARL}"/>',
                       f'<path d="{points}" fill="none" stroke="{GOLD}" stroke-width="3" stroke-linejoin="round"/>']
        elif title == "search":
            panels.append(dot(1, 3))
            for c in range(7):
                for r in range(5):
                    steps = abs(c - 1) + abs(r - 3)
                    if 0 < steps <= 4:
                        cx, cy = centre(x0, y0, c, r)
                        panels.append(f'<rect x="{cx - 16}" y="{cy - 16}" width="32" height="32" fill="{GOLD}" opacity="{0.36 - 0.07 * steps:.2f}"/>')
                        panels.append(text(cx - 13, cy - 3, steps, 11, PALE))
        elif title == "map markers":
            panels.append(dot(1, 3))
            for c, r, seen in ((4, 1, "r120"), (5, 3, "r131")):
                cx, cy = centre(x0, y0, c, r)
                panels += [f'<circle cx="{cx}" cy="{cy}" r="7" fill="none" stroke="{PEARL}" stroke-width="2" stroke-dasharray="3 2"/>',
                           text(cx, cy + 25, f"pearl seen {seen}", 11, PEARL, "middle")]
        else:
            last = centre(x0, y0, 4, 2)
            for c in range(7):
                for r in range(5):
                    if abs(c - 4) + abs(r - 2) <= 2:
                        cx, cy = centre(x0, y0, c, r)
                        panels.append(f'<rect x="{cx - 17}" y="{cy - 17}" width="34" height="34" fill="{THEIRS}" opacity="0.13"/>')
            panels += [f'<rect x="{last[0] - 15}" y="{last[1] - 15}" width="30" height="30" fill="none" stroke="{THEIRS}" stroke-width="2.5"/>',
                       text(last[0], last[1] + 5, "2", 12, THEIRS, "middle"), dot(1, 3),
                       text(x0 + 7 * cell - 6, y0 + 16, "enemy D5, 2 rounds ago", 11, THEIRS, "end")]
    return svg(1010, 540, "Records the viewer draws on the board", panels)


def gizmo_inspector():
    """The record kinds the inspector lays out beside the board."""
    parts = []

    def row(x, y, w, label, state, colour, indent=0, fill=CARD):
        return (f'<rect x="{x + indent}" y="{y}" width="{w - indent}" height="26" rx="4" fill="{fill}" stroke="{colour}" stroke-width="1.5"/>'
                + text(x + indent + 10, y + 18, label, 12.5, INK) + text(x + w - 10, y + 18, state, 12.5, colour, "end"))

    # A state tree: every option, with its eligibility and score.
    parts.append(text(20, 30, "state, as a tree", 15, INK, weight="bold"))
    parts.append(row(20, 44, 300, "Dragon", "not evaluated", MUTED))
    for i, (label, state, colour) in enumerate([("Flee", "ineligible", SIGNAL), ("Eat", "selected / utility 6", GOLD),
                                                 ("Split", "ineligible", SIGNAL), ("Explore", "eligible / utility 1", FOREST)]):
        parts.append(row(20, 76 + 32 * i, 300, label, state, colour, indent=18))
    parts.append(text(20, 222, "Each option with its eligibility, score and", 12.5, MUTED))
    parts.append(text(20, 240, "reason. The chosen one opens its children.", 12.5, MUTED))

    # A state graph laid out by the bot.
    parts.append(text(360, 30, "state, as a graph", 15, INK, weight="bold"))
    for i, (label, active) in enumerate([("Young", False), ("Grown", False), ("Parent", True)]):
        x = 360 + i * 105
        fill, ink = (FOREST, PAPER) if active else (CARD, INK)
        parts.append(f'<rect x="{x}" y="80" width="80" height="36" rx="18" fill="{fill}" stroke="{RULE}" stroke-width="1.5"/>')
        parts.append(text(x + 40, 103, label, 13, ink, "middle", "bold" if active else "normal"))
        if i:
            parts.append(arrow([(x - 25, 98), (x - 2, 98)]))
    parts.append(text(438, 136, "length 6", 11.5, MUTED, "middle"))
    parts.append(text(543, 136, "split", 11.5, MUTED, "middle"))
    parts.append(text(360, 222, "Nodes at the bot's own coordinates, the", 12.5, MUTED))
    parts.append(text(360, 240, "active one filled, links with their conditions.", 12.5, MUTED))

    # Candidates, each scored by the option's own measure.
    parts.append(text(700, 30, "candidate", 15, INK, weight="bold"))
    for i, (label, score, chosen) in enumerate([("Move N", "−1 moves to the pearl", True), ("Move W", "−1 moves to the pearl", False)]):
        parts.append(row(700, 44 + 32 * i, 290, label, score + (", chosen" if chosen else ""), GOLD if chosen else MUTED))
    parts.append(text(700, 222, "A score and what it measures. Scores from", 12.5, MUTED))
    parts.append(text(700, 240, "different objectives are never compared.", 12.5, MUTED))

    # A table with row states.
    parts.append(text(20, 290, "table", 15, INK, weight="bold"))
    columns = ["side", "safe", "room"]
    for j, name in enumerate(columns):
        parts.append(text(34 + j * 95, 322, name, 12.5, MUTED, weight="bold"))
    for i, (cells, colour) in enumerate([(("N", "yes", "4"), GOLD), (("E", "no", "-"), SIGNAL), (("W", "yes", "4"), FOREST)]):
        parts.append(f'<rect x="20" y="{332 + 30 * i}" width="300" height="26" rx="4" fill="{CARD}" stroke="{colour}" stroke-width="1.5"/>')
        for j, value in enumerate(cells):
            parts.append(text(34 + j * 95, 350 + 30 * i, value, 12.5, INK))
    parts.append(text(20, 448, "Rows marked selected, eligible or ineligible;", 12.5, MUTED))
    parts.append(text(20, 466, "a row can open records of its own.", 12.5, MUTED))

    # A calculation: the bot's own expression, operands and result.
    parts.append(text(360, 290, "calculation", 15, INK, weight="bold"))
    parts.append(card(360, 304, 300, 90, "utility = 8 − moves", ["moves   2", "result   6"]))
    parts.append(text(360, 448, "The expression as the bot wrote it; the", 12.5, MUTED))
    parts.append(text(360, 466, "viewer shows the values and evaluates nothing.", 12.5, MUTED))

    # A sonar table joined with the ping the replay recorded.
    parts.append(text(700, 290, "sonar table", 15, INK, weight="bold"))
    parts.append(card(700, 304, 130, 70, "D2 sent", ["D2's head, length 7"]))
    parts.append(card(860, 304, 130, 70, "D0 received", ["position of D2", "updated"]))
    parts.append(arrow([(830, 339), (858, 339)], colour=SIGNAL))
    parts.append(text(845, 396, "the replay's ping", 11.5, SIGNAL, "middle"))
    parts.append(text(700, 448, "Sender's meaning, receiver's reading and", 12.5, MUTED))
    parts.append(text(700, 466, "outcome, joined on the recorded ping.", 12.5, MUTED))
    return svg(1010, 486, "Records the inspector lays out beside the board", parts)


def rl_compute_topology():
    """The machines and deliberately credential-free paths used by the RL run."""
    parts = [
        text(20, 30, "Where a training run lived", 17, INK, weight="bold"),
        card(20, 50, 300, 144, "Local workstation", [
            "AM4 · Ryzen 7 5800X3D",
            "32 GB DDR4 · RTX 5070 Ti 16 GB",
            "builds bundles and checks exports",
            "keeps the durable copy of every run",
        ], dark=True),
        card(400, 50, 280, 144, "Private S3 object store", [
            "large input and result archives",
            "short-lived signed transfers",
            "no cloud key on the rental",
            "no public objects",
        ], accent=GOLD),
        card(760, 50, 320, 144, "Vast.ai rental", [
            "2 × Xeon Gold 6448Y",
            "64 cores / 128 threads · 1 TB RAM",
            "4 × H100",
            "3 cards teach · 1 card distils",
        ], accent=SIGNAL),
        arrow([(320, 98), (398, 98)]),
        arrow([(680, 98), (758, 98)]),
        text(360, 86, "archives", 11.5, MUTED, "middle"),
        text(720, 86, "signed fetch", 11.5, MUTED, "middle"),
        arrow([(320, 166), (365, 166), (365, 220), (715, 220), (715, 166), (758, 166)], dashed=True),
        text(540, 214, "rental connector: commands, tar streams, checkpoints and logs", 11.5, SIGNAL, "middle"),
        text(20, 264, "What the scripts did", 17, INK, weight="bold"),
    ]
    stages = [
        ("1. Pack", ["source, judge, maps", "and demonstrations"]),
        ("2. Connect", ["copy the bundle", "start pinned jobs"]),
        ("3. Run", ["teacher + student", "CPU demo workers"]),
        ("4. Save", ["atomic latest.pt", "immutable snapshots"]),
        ("5. Recover", ["pull every 15 min", "and before shutdown"]),
    ]
    for index, (title, lines) in enumerate(stages):
        x = 20 + index * 216
        parts.append(card(x, 284, 194, 105, title, lines, dark=index == 2,
                          accent=SIGNAL if index in (1, 4) else RULE))
        if index:
            parts.append(arrow([(x - 20, 336), (x - 2, 336)]))
    parts += [
        text(20, 426, "The rental is disposable. The checkpoints are not.", 14, INK, weight="bold"),
        text(20, 450, "The connector carries control traffic; S3 carries bulky fleet archives through expiring links.", 13, MUTED),
        text(20, 471, "Names, addresses, account details, credentials and instance identifiers are intentionally absent.", 13, MUTED),
    ]
    return svg(1100, 494, "The local workstation, private object store, Vast.ai rental and their orchestration", parts)


def pearl_reconstruction():
    return vertical_flow("From a replay to a checked reconstruction", [
        ("Replay and match seed", ["Observed pearls and occupancy", "Named map, but gaps are zero"]),
        ("Seeded engine draws", ["Mirrored tiles share a countdown", "Occupied attempts still take a draw"]),
        ("Candidate gap table", ["Check appearances and missing pearls", "Keep unresolved games unresolved"]),
        ("Reconstruction check", ["Compare state and our bot's actions", "Stop at the first difference"]),
    ])


def vertical_flow(title, stages):
    """Short, legible stages for article figures that also fit a phone."""
    parts = []
    for index, (heading, lines) in enumerate(stages):
        y = 20 + index * 136
        parts.append(card(20, y, 480, 108, heading, lines, dark=index == 0,
                          accent=SIGNAL if index == len(stages) - 1 else RULE,
                          title_size=23, body_size=21, line_height=26))
        if index:
            parts.append(arrow([(260, y - 28), (260, y - 2)]))
    return svg(520, 20 + len(stages) * 136 - 8, title, parts)


def textbook_hierarchy():
    return vertical_flow("The textbook bot's roles, tasks, states and movement", [
        ("Observed world and sonar", ["Local beliefs, no central controller", "What does this dragon know?"]),
        ("Role: objective and need", ["Scout, champion, guard, assassin", "How many dragons does the job need?"]),
        ("Task: behaviour and target", ["Role duties offer eligible choices", "Utility selects; a margin retains"]),
        ("Task state machine", ["Ordered guards select the phase", "Commit, interrupt and resume"]),
        ("Movement and action", ["Check safety and available fallbacks", "Compare by the active objective"]),
    ])


def collector_retention():
    return vertical_flow("How the capped replay store chooses what to retain", [
        ("Select indexed games", ["Our games → top teams → pins", "Then recent teams rated above us"]),
        ("One manifest", ["Highest qualifying priority wins", "Keep identifiers, pins and file sizes"]),
        ("Make room under the cap", ["Remove unselected files first", "Then lower-priority, older files"]),
        ("Keep the useful files", ["Default storage cap: 100 GB", "The index survives file eviction"]),
    ])


def points_profile():
    parts = [card(20, 20, 480, 108, "One registered build", [
        "WebAssembly and a name sidecar", "The exact staged source and flags"],
        dark=True, title_size=23, body_size=21, line_height=26)]
    reports = [
        ("Judge: charged work", ["Counters by function and class", "Input and output have separate rows"]),
        ("Clang: vectorisation remarks", ["Loop and SLP transformations", "Reasons for loops left scalar"]),
    ]
    for index, (heading, lines) in enumerate(reports):
        y = 160 + index * 136
        parts.append(card(58, y, 442, 108, heading, lines,
                          title_size=23, body_size=20, line_height=26))
        parts.append(arrow([(38, 128), (38, y + 54), (56, y + 54)]))
        parts.append(arrow([(500, y + 54), (510, y + 54), (510, 486), (502, 486)]))
    parts.append(card(20, 432, 480, 108, "Join by function name", [
        "Start with the costliest functions", "Change, check actions, profile again"],
        accent=SIGNAL, title_size=23, body_size=21, line_height=26))
    return svg(520, 562, "Join charged function costs to compiler vectorisation remarks", parts)


def judge_modes():
    modes = [
        ("Ordinary game", ["Official engine; metered bot instances", "100M points per dragon turn"]),
        ("Inspection", ["Recorded observations into a bot", "Actions, annotations and memory"]),
        ("Served team", ["Local socket to an external process", "Its work is not metered"]),
        ("Lockstep", ["Official engine and CPU reference", "Same replies; first differing input"]),
    ]
    parts = [card(20, 20, 480, 70, "One judge host", dark=True, title_size=23)]
    for index, (heading, lines) in enumerate(modes):
        y = 120 + index * 128
        parts.append(card(58, y, 442, 108, heading, lines, title_size=23, body_size=20, line_height=26))
        parts.append(arrow([(38, 90), (38, y + 54), (56, y + 54)]))
    return svg(520, 640, "Four workflows through the same judge host", parts)


def inspection_accounting():
    return vertical_flow("Inspection temporarily switches from policy metering to observer metering", [
        ("Policy work", ["Gameplay instructions remain charged", "Action output: charged, 10 KiB limit"]),
        ("Enter observer scope", ["Save and pause the policy meter", "Clock sees frozen policy time"]),
        ("Explain the decision", ["Separate 1B-point observer allowance", "Separate 64 MiB annotation path"]),
        ("Leave observer scope", ["Restore the saved policy meter", "No gameplay I/O inside the observer"]),
    ])


def rake_program():
    parts = [text(260, 32, "Two routes to the same judge", 23, INK, "middle", "bold")]
    parts += [
        card(20, 58, 480, 108, "Our current split", ["Nim strategy + Rake kernels", "Each compiler emits C"], dark=True,
             title_size=23, body_size=21, line_height=26),
        card(20, 200, 480, 134, "A whole Rake program", ["slow: setup, state and ordinary code", "run: traversals over racks", "crunch: lane-wise vector work"],
             title_size=23, body_size=21, line_height=26),
        card(20, 388, 480, 108, "C and the starter API", ["Link the chosen route with C helpers", "The judge's clang makes bot.wasm"], accent=SIGNAL,
             title_size=23, body_size=21, line_height=26),
        arrow([(500, 112), (510, 112), (510, 442), (502, 442)]),
        arrow([(260, 334), (260, 386)]),
        text(260, 532, "Same protocol. Measure points separately.", 21, MUTED, "middle"),
    ]
    return svg(520, 558, "Nim with Rake kernels, or whole-program Rake, both emit C for the judge", parts)


def map_variant_counts():
    rows = [
        ("Prisoners Dilemma", 20, FOREST),
        ("Queen Of Spades", 14, FOREST),
        ("Devil", 16, FOREST),
        ("Schooltime", 23, FOREST),
        ("Slithery Fight, unresolved", 19, SIGNAL),
    ]
    parts = [text(20, 30, "Games the published gaps didn't explain", 23, INK, weight="bold"),
             text(20, 58, "40 stored games per map · 1 October 2026", 21, MUTED)]
    for index, (label, value, colour) in enumerate(rows):
        y = 90 + index * 64
        parts.append(text(20, y, label, 22, INK))
        parts.append(f'<rect x="20" y="{y + 12}" width="400" height="20" rx="4" fill="{PALE}"/>')
        parts.append(f'<rect x="20" y="{y + 12}" width="{400 * value / 40}" height="20" rx="4" fill="{colour}"/>')
        parts.append(text(498, y + 28, f"{value} / 40", 21, MUTED, "end"))
    parts += [text(20, 428, "Trauma, Default, Trophy, Portals", 21, MUTED),
              text(20, 454, "and Autarky: 0 of 40 each", 21, MUTED)]
    return svg(520, 478, "Games out of 40 that the published gap table did not explain", parts)


def three_bot_lines():
    parts = [
        text(20, 30, "Three lines answer different questions", 17, INK, weight="bold"),
        card(20, 54, 310, 150, "Textbook", ["known methods, assembled clearly", "each departure is a candidate", "for the next improvement"], dark=True),
        card(355, 54, 310, 150, "Foil", ["a rival free to use any method", "a benchmark and counterpoint", "to the textbook line"], accent=SIGNAL),
        card(690, 54, 310, 150, "Learned", ["a policy learned from games", "teacher distilled into a student", "small enough for the judge"], accent=GOLD),
        text(20, 242, "They share the game, the evaluation pool and the evidence from replays. Their implementations stay separate.", 13, MUTED),
    ]
    return svg(1020, 266, "The textbook, foil and learned bot lines", parts)


def bot_assembly():
    parts = [
        text(20, 30, "A bot is an assembly, not a copy of the whole library", 17, INK, weight="bold"),
        card(20, 56, 250, 112, "main/NNNN", ["strategy.nim", "library.toml"], dark=True),
        card(20, 194, 250, 112, "The catalogues", ["this line's lib/", "common/lib/"]),
        card(350, 102, 250, 144, "Materialise", ["read the manifest", "copy only its pinned pieces", "mount one repertoire/"], accent=GOLD),
        card(680, 56, 310, 112, "Assembled source", ["strategy.nim", "repertoire/ with stable imports"]),
        card(680, 194, 310, 112, "common/runtime", ["entry point and judge boundary", "shared, but separately snapshotted"]),
        card(680, 350, 310, 112, "Registered build", ["WebAssembly", "source and toolchain hashes"], accent=SIGNAL),
        arrow([(270, 112), (320, 112), (320, 150), (348, 150)]),
        arrow([(270, 250), (320, 250), (320, 200), (348, 200)]),
        arrow([(600, 174), (640, 174), (640, 112), (678, 112)]),
        arrow([(990, 112), (1005, 112), (1005, 406), (992, 406)]),
        arrow([(835, 306), (835, 348)]),
        text(20, 346, "library.toml chooses versions; it does not describe the turn loop.", 13, MUTED),
        text(20, 369, "strategy.nim and the selected pieces own that decision structure.", 13, MUTED),
    ]
    return svg(1020, 486, "How a numbered bot, pinned library pieces and the runtime become one registered build", parts)


def frozen_versions():
    parts = [text(20, 30, "A version becomes evidence once it plays", 17, INK, weight="bold")]
    stages = [
        ("In development", ["the highest number", "changes as we work"]),
        ("Freeze", ["make the source immutable", "keep its identifier"]),
        ("Build", ["pin every library piece", "register the WebAssembly"]),
        ("Keep", ["replay provenance", "opponent and regression test"]),
    ]
    for index, (title, lines) in enumerate(stages):
        x = 20 + index * 250
        parts.append(card(x, 52, 220, 112, title, lines, dark=index == 1, accent=SIGNAL if index == 1 else RULE))
        if index:
            parts.append(arrow([(x - 28, 108), (x - 2, 108)]))
    parts += [
        text(20, 205, "A frozen version never changes. New work gets the next number, so an old result can always be rebuilt.", 13, MUTED),
        text(20, 250, "One library piece can advance without moving the others", 15, INK, weight="bold"),
        card(20, 270, 220, 92, "0001 · pseudocode", ["the algorithm and contract"]),
        arrow([(240, 316), (278, 316)]),
        card(280, 270, 220, 92, "0002.nim", ["the clear implementation"]),
        arrow([(500, 316), (538, 316)]),
        card(540, 270, 220, 92, "0003.rk", ["the measured hot kernel"]),
        text(790, 300, "library.toml pins the", 13, MUTED),
        text(790, 320, "versions one bot uses", 13, MUTED),
    ]
    return svg(1020, 386, "How bot versions and library pieces become immutable", parts)

FIGURES = {
    "textbook-hierarchy": textbook_hierarchy,
    "collector-retention": collector_retention,
    "points-profile": points_profile,
    "judge-modes": judge_modes,
    "inspection-accounting": inspection_accounting,
    "rake-program": rake_program,
    "bot-assembly": bot_assembly,
    "frozen-versions": frozen_versions,
    "three-bot-lines": three_bot_lines,
    "map-variant-counts": map_variant_counts,
    "pearl-reconstruction": pearl_reconstruction,
    "rl-compute-topology": rl_compute_topology,
    "viewer-recovery": viewer_recovery,
    "gizmo-board": gizmo_board,
    "gizmo-inspector": gizmo_inspector,
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
    "fleet-result-links": fleet_result_links,
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
