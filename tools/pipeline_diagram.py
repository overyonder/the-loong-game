"""Draw how our tools and the official toolkit fit around the bot we're improving.

    python3 tools/pipeline_diagram.py blog/images/pipeline.svg

Tools in BUILT are drawn solid. The rest of the wishlist is drawn dashed until
a post builds it.
"""

import sys

PAPER, CARD, INK, MUTED, RULE = "#ede5d5", "#f6f1e7", "#20251f", "#66675e", "#b9ad99"
SIGNAL, FOREST = "#b53b13", "#263d31"
LANGUAGE_COLOURS = {"Python": "#3f6e8c", "Odin": "#2f7f79", "Nim": "#a8801a", "C": "#5b5e57", "perf": "#7a4f8a"}

BUILT = {"Evaluation harness", "Statistics", "Map generator"}
OUR_TOOLS = [  # name, language, what it does for us
    ("Evaluation harness", "Python", "every map, both sides, in parallel"),
    ("Statistics", "Python", "better, worse or undecided"),
    ("Map generator", "Python", "maps nobody has seen"),
    ("Offline Elo ladder", "Python", "ratings against old versions"),
    ("Replay sampler", "Python", "public games, fetched politely"),
    ("Replay decoder", "Python", "game state, turn by turn"),
    ("Debug viewer", "Odin", "one dragon's eyes and memory"),
    ("Profiling", "perf", "where the points go"),
]
OFFICIAL_TOOLS = [
    ("unswbc init", "starter bots in C, C++, Python"),
    ("unswbc run --sandbox", "one match at judge prices"),
    ("--seed", "replay a match exactly"),
    ("unswbc maps", "the 13 bundled maps"),
    ("Visualiser", "watch the whole board"),
    ("unswbc submit", "upload to the ladder"),
]
FROZEN_VERSIONS = ["v3", "v2", "v1"]

WIDTH, HEIGHT = 800, 760
LEFT_X, CENTRE_X, RIGHT_X = 20, 300, 580
CARD_WIDTH, CENTRE_WIDTH = 200, 200


def text(x, y, value, size=13, colour=INK, anchor="start", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{colour}" text-anchor="{anchor}"'
            f' font-weight="{weight}">{value}</text>')


def arrow(x1, y1, x2, y2, dashed=False):
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    return (f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{MUTED}" stroke-width="1.5" fill="none"'
            f'{dash} marker-end="url(#arrow)"/>')


def our_tool_card(y, name, language, purpose):
    built = name in BUILT
    border = f'stroke="{SIGNAL}" stroke-width="1.8"' if built else f'stroke="{RULE}" stroke-dasharray="5 4"'
    badge_width = 12 + 7 * len(language)
    return "\n".join([
        f'<rect x="{LEFT_X}" y="{y}" width="{CARD_WIDTH}" height="66" rx="6" fill="{CARD if built else PAPER}" {border}/>',
        text(LEFT_X + 12, y + 22, name, 14, INK if built else MUTED, weight="bold" if built else "normal"),
        text(LEFT_X + 12, y + 44, purpose, 11.5, MUTED),
        f'<rect x="{LEFT_X + CARD_WIDTH - badge_width - 10}" y="{y + 50}" width="{badge_width}" height="17" rx="8"'
        f' fill="{LANGUAGE_COLOURS[language]}"/>',
        text(LEFT_X + CARD_WIDTH - badge_width / 2 - 10, y + 62.5, language, 10.5, PAPER, "middle", "bold"),
    ])


def official_tool_card(y, name, purpose):
    return "\n".join([
        f'<rect x="{RIGHT_X}" y="{y}" width="{CARD_WIDTH}" height="56" rx="6" fill="{CARD}" stroke="{RULE}"/>',
        text(RIGHT_X + 12, y + 22, name, 13.5, INK, weight="bold"),
        text(RIGHT_X + 12, y + 42, purpose, 11.5, MUTED),
    ])


def main():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t d">',
        '<title id="t">Our tools around the bot</title>',
        '<desc id="d">The current bot sits in the middle, written in Nim with hot paths in C and compiled to WebAssembly,'
        ' with frozen earlier versions trailing below it. The official toolkit is on the right. Our wishlist tools are on'
        f' the left, with the ones built so far drawn solid: {", ".join(sorted(BUILT))}.</desc>',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{MUTED}"/></marker></defs>',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{PAPER}"/>',
        text(LEFT_X, 34, "Our tools", 15, INK, weight="bold"),
        text(RIGHT_X, 34, "Official toolkit", 15, INK, weight="bold"),
        text(CENTRE_X + CENTRE_WIDTH / 2, 34, "Where our time goes", 15, INK, "middle", "bold"),
        text(CENTRE_X + CENTRE_WIDTH / 2, 58, "strategic ideas, espionage,", 12, MUTED, "middle"),
        text(CENTRE_X + CENTRE_WIDTH / 2, 74, "advanced tactics", 12, MUTED, "middle"),
    ]

    # The current bot, and the frozen versions it had to beat trailing below it.
    bot_y = 110
    parts.append(arrow(CENTRE_X + CENTRE_WIDTH / 2, 82, CENTRE_X + CENTRE_WIDTH / 2, bot_y - 4))
    parts += [
        f'<rect x="{CENTRE_X}" y="{bot_y}" width="{CENTRE_WIDTH}" height="150" rx="8" fill="{FOREST}"/>',
        text(CENTRE_X + CENTRE_WIDTH / 2, bot_y + 34, "Current bot", 19, PAPER, "middle", "bold"),
        text(CENTRE_X + CENTRE_WIDTH / 2, bot_y + 58, "the thing we improve", 12.5, "#c7c1b2", "middle"),
    ]
    for index, (language, role) in enumerate([("Nim", "strategy"), ("C", "hot paths")]):
        badge_x = CENTRE_X + 22 + index * 82
        parts += [f'<rect x="{badge_x}" y="{bot_y + 80}" width="74" height="22" rx="11" fill="{LANGUAGE_COLOURS[language]}"/>',
                  text(badge_x + 37, bot_y + 95, f"{language}", 12, PAPER, "middle", "bold"),
                  text(badge_x + 37, bot_y + 120, role, 11, "#c7c1b2", "middle")]
    parts.append(text(CENTRE_X + CENTRE_WIDTH / 2, bot_y + 141, "→ C → WebAssembly", 11.5, "#c7c1b2", "middle"))
    frozen_y = bot_y + 190
    for index, version in enumerate(FROZEN_VERSIONS):
        y = frozen_y + index * 92
        opacity = 0.8 - index * 0.22
        parts += [
            f'<g opacity="{opacity:.2f}"><rect x="{CENTRE_X + 20}" y="{y}" width="{CENTRE_WIDTH - 40}" height="60" rx="6" fill="{FOREST}"/>',
            text(CENTRE_X + CENTRE_WIDTH / 2, y + 26, f"Frozen {version}", 14, PAPER, "middle", "bold"),
            text(CENTRE_X + CENTRE_WIDTH / 2, y + 45, "beaten by the next", 11, "#c7c1b2", "middle") + "</g>",
        ]
        previous_bottom = bot_y + 150 if index == 0 else y - 32
        parts.append(arrow(CENTRE_X + CENTRE_WIDTH / 2, y, CENTRE_X + CENTRE_WIDTH / 2, previous_bottom + 4))
    parts.append(text(CENTRE_X + CENTRE_WIDTH / 2, frozen_y + 3 * 92 + 10, "Each version is frozen when", 11.5, MUTED, "middle"))
    parts.append(text(CENTRE_X + CENTRE_WIDTH / 2, frozen_y + 3 * 92 + 26, "the statistics call the next one better", 11.5, MUTED, "middle"))

    # Each side feeds the bot through one spine, so the arrows stay readable.
    left_spine_x, right_spine_x = CENTRE_X - 34, CENTRE_X + CENTRE_WIDTH + 34
    spine_join_y = bot_y + 75
    for index, (name, language, purpose) in enumerate(OUR_TOOLS):
        y = 60 + index * 82
        parts.append(our_tool_card(y, name, language, purpose))
        dash = "" if name in BUILT else ' stroke-dasharray="5 4"'
        parts.append(f'<path d="M{LEFT_X + CARD_WIDTH} {y + 33} H{left_spine_x}" stroke="{MUTED}" stroke-width="1.5"{dash}/>')
    parts.append(f'<path d="M{left_spine_x} {60 + 33} V{60 + 7 * 82 + 33}" stroke="{MUTED}" stroke-width="1.5"/>')
    parts.append(arrow(left_spine_x, spine_join_y, CENTRE_X - 4, spine_join_y))
    for index, (name, purpose) in enumerate(OFFICIAL_TOOLS):
        y = 60 + index * 80
        parts.append(official_tool_card(y, name, purpose))
        parts.append(f'<path d="M{RIGHT_X} {y + 28} H{right_spine_x}" stroke="{MUTED}" stroke-width="1.5"/>')
    parts.append(f'<path d="M{right_spine_x} {60 + 28} V{60 + 5 * 80 + 28}" stroke="{MUTED}" stroke-width="1.5"/>')
    parts.append(arrow(right_spine_x, spine_join_y, CENTRE_X + CENTRE_WIDTH + 4, spine_join_y))

    legend_y = HEIGHT - 30
    parts.append(f'<rect x="{LEFT_X}" y="{legend_y - 12}" width="22" height="14" rx="3" fill="{CARD}" stroke="{SIGNAL}" stroke-width="1.8"/>')
    parts.append(text(LEFT_X + 30, legend_y, "built so far", 12, MUTED))
    parts.append(f'<rect x="{LEFT_X + 130}" y="{legend_y - 12}" width="22" height="14" rx="3" fill="{PAPER}" stroke="{RULE}" stroke-dasharray="4 3"/>')
    parts.append(text(LEFT_X + 160, legend_y, "still on the wishlist", 12, MUTED))
    parts.append("</svg>")
    with open(sys.argv[1], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
