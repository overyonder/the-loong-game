"""Draw code maps of the example bots: where each part of the architecture lives in
the source file, and close-ups of the key pieces.

    python3 tools/code_map.py blog/images

For each bot this writes <bot>-code-map.svg, the whole file as an editor minimap
with a box over each part, and one <bot>-code-<piece>.png per close-up, drawn as
Neovide with gruvbox dark hard inside a Hyprland window. Boxes take their part's
colour from figure_palette, the same colour the part has in the block diagrams.
Regions are found by pattern, so the figures follow the code when it changes.
Quantise the PNGs afterwards like the terminal figures (magick -colors 256, oxipng).
"""

import html
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from pygments.lexers import NimrodLexer as NimLexer
from pygments.styles import get_style_by_name

from figure_palette import COMPONENTS, MUTED, PAPER, colour

ROOT = Path(__file__).resolve().parent.parent

# Neovide with gruvbox dark hard, in the same Hyprland window as the terminal figures.
BACKGROUND    = "#1d2021"
FOREGROUND    = "#ebdbb2"
LINE_NUMBER   = "#665c54"
ACTIVE_BORDER = "#83a598"
FONT          = "FiraCode Nerd Font"
FONT_SIZE     = 15
CELL_WIDTH    = FONT_SIZE * 1200 / 1950  # FiraCode's advance: 1200 units on a 1950-unit em
LINE_HEIGHT   = FONT_SIZE * 1.5
PADDING       = 20
BORDER        = 2
ROUNDING      = 10
MARGIN        = 12
GUTTER        = 5  # columns for line numbers

STYLE = get_style_by_name("gruvbox-dark")


@dataclass
class Region:
    key: str
    start: str                # pattern for the region's first line
    until: str | None = None  # pattern for the first line after it; default: the next blank line,
                              # or just the first line for an indented region such as a socket
    label: str | None = None

    def span(self, lines):
        first = next(i for i, line in enumerate(lines) if re.search(self.start, line))
        if self.until is None and self.start.startswith("^  "):
            last = first
        elif self.until is None:
            last = next((i for i in range(first + 1, len(lines)) if not lines[i].strip()), len(lines)) - 1
        else:
            last = next(i for i in range(first + 1, len(lines)) if re.search(self.until, lines[i])) - 1
        while not lines[last].strip():
            last -= 1
        return first, last

    @property
    def title(self):
        return self.label or COMPONENTS[self.key][1]


@dataclass
class CloseUp:
    name: str
    blocks: list[Region]                              # the code shown, joined by a fold marker
    boxes: list[Region] = field(default_factory=list)  # boxes drawn over it


@dataclass
class Bot:
    name: str
    fold: Region                  # the FFI bindings, folded to one line in the map
    regions: list[Region]         # boxes in the map, outer ones first
    close_ups: list[CloseUp]


def block(start, until=None):
    return Region("frame", start, until)


BOTS = [
    Bot("first-bot",
        fold=Region("frame", r"^# ---- The starter", r"^# ---- What"),
        regions=[
            Region("window", r"^# ---- What", r"^# ---- Safety", "Read the window, and flood fill"),
            Region("safety", r"^# ---- Safety", r"^# ---- Behaviours"),
            Region("roam", r"^proc roam\("),
            Region("evade", r"^proc evade\("),
            Region("frame", r"^# ---- The state machine", r"^# ---- The turn loop", "State machine: choose a mode"),
            Region("roam", r"^  of Roam:", label="Roam socket"),
            Region("evade", r"^  of Evade:", label="Evade socket"),
            Region("frame", r"^var ct: ptr Controller", label="Turn loop: send the best safe move"),
        ],
        close_ups=[
            CloseUp("frame", [block(r"^type Mode = enum", r"^proc chooseMove")],
                    [Region("frame", r"^type Mode = enum", r"^proc chooseMove", "State machine"),
                     Region("roam", r"^  of Roam:", label="Roam socket"),
                     Region("evade", r"^  of Evade:", label="Evade socket")]),
            CloseUp("roam", [block(r"^proc roam\(")], [Region("roam", r"^proc roam\(")]),
            CloseUp("evade", [block(r"^proc evade\(")], [Region("evade", r"^proc evade\(")]),
            CloseUp("safety", [block(r"^proc nextToEnemyHead", r"^# ---- Behaviours")],
                    [Region("safety", r"^proc nextToEnemyHead", r"^# ---- Behaviours")]),
        ]),
    Bot("roles-bot",
        fold=Region("frame", r"^# ---- The starter", r"^# ---- What"),
        regions=[
            Region("window", r"^# ---- What", r"^# ---- Sonar", "Read the window, and flood fill"),
            Region("sonar", r"^# ---- Sonar", r"^# ---- Safety"),
            Region("safety", r"^# ---- Safety", r"^# ---- Behaviours"),
            Region("roam", r"^proc roam\("),
            Region("evade", r"^proc evade\("),
            Region("hunt", r"^proc hunt\(", r"^# ---- The state machine"),
            Region("frame", r"^# ---- The state machine", r"^# ---- The turn loop", "State machine: a role, then a mode"),
            Region("roam", r"^  of Roam:", label="Roam socket"),
            Region("evade", r"^  of Evade:", label="Evade socket"),
            Region("hunt", r"^  of Hunt:", label="Hunt socket"),
            Region("frame", r"^var ct: ptr Controller", label="Turn loop"),
            Region("split", r"^  if role == Champion and length >= 10", r"^  else:", "Champion splits"),
            Region("sonar", r"^  announce\(", label="Announce"),
        ],
        close_ups=[
            CloseUp("frame", [block(r"^proc chooseRole", r"^proc chooseMove")],
                    [Region("frame", r"^proc chooseRole", r"^proc chooseMove", "State machine"),
                     Region("roam", r"^  of Roam:", label="Roam socket"),
                     Region("evade", r"^  of Evade:", label="Evade socket"),
                     Region("hunt", r"^  of Hunt:", label="Hunt socket")]),
            CloseUp("hunt", [block(r"^proc hunt\(", r"^# ---- The state machine")],
                    [Region("hunt", r"^proc hunt\(", r"^# ---- The state machine")]),
            CloseUp("sonar", [block(r"^proc encode\(", r"^var longestTeammateHeard")],
                    [Region("sonar", r"^proc encode\(", r"^var longestTeammateHeard")]),
            CloseUp("turn", [block(r"^while unswbc_update")],
                    [Region("frame", r"^while unswbc_update", label="Turn loop"),
                     Region("sonar", r"^  ct\.listen", label="Listen"),
                     Region("split", r"^  if role == Champion and length >= 10", r"^  else:", "Champion splits"),
                     Region("sonar", r"^  announce\(", label="Announce")]),
        ]),
    Bot("tactics-bot",
        fold=Region("frame", r"^# ---- The starter", r"^# ---- What"),
        regions=[
            Region("window", r"^# ---- What", r"^# ---- Sonar", "Read the window, and flood fill"),
            Region("coil", r"^proc ownBodyAround", label="Coil helper"),
            Region("sonar", r"^# ---- Sonar", r"^# ---- Safety"),
            Region("safety", r"^# ---- Safety", r"^# ---- Behaviours"),
            Region("roam", r"^proc roam\("),
            Region("evade", r"^proc evade\("),
            Region("hunt", r"^proc hunt\("),
            Region("coil", r"^proc coil\("),
            Region("forage", r"^proc forage\("),
            Region("deliver", r"^proc deliver\("),
            Region("hunt", r"^proc headOnMove", label="Hunt: strike"),
            Region("deliver", r"^proc deliveryMove", r"^# ---- The state machine", "Deliver: sacrifice"),
            Region("frame", r"^# ---- The state machine", r"^# ---- The turn loop", "State machine: a role, then a mode"),
            Region("roam", r"^  of Roam:", label="Roam socket"),
            Region("evade", r"^  of Evade:", label="Evade socket"),
            Region("hunt", r"^  of Hunt:", label="Hunt socket"),
            Region("coil", r"^  of Coil:", label="Coil socket"),
            Region("forage", r"^  of Forage:", label="Forage socket"),
            Region("deliver", r"^  of Deliver:", label="Deliver socket"),
            Region("frame", r"^var ct: ptr Controller", label="Turn loop"),
            Region("split", r"^  if role == Champion and length >= 10", r"^  else:", "Champion splits"),
            Region("sonar", r"^  for side in 0 \.\. 3: unswbc_send_sonar_to", label="Announce"),
        ],
        close_ups=[
            CloseUp("frame", [block(r"^proc chooseMode", r"^proc chooseMove")],
                    [Region("frame", r"^proc chooseMode", r"^proc chooseMove", "State machine"),
                     Region("roam", r"^  of Roam:", label="Roam socket"),
                     Region("evade", r"^  of Evade:", label="Evade socket"),
                     Region("hunt", r"^  of Hunt:", label="Hunt socket"),
                     Region("coil", r"^  of Coil:", label="Coil socket"),
                     Region("forage", r"^  of Forage:", label="Forage socket"),
                     Region("deliver", r"^  of Deliver:", label="Deliver socket")]),
            CloseUp("coil", [block(r"^proc ownBodyAround"), block(r"^proc coil\(")],
                    [Region("coil", r"^proc ownBodyAround", label="Coil helper"), Region("coil", r"^proc coil\(")]),
            CloseUp("forage", [block(r"^proc nearestPearl"), block(r"^proc forage\(")],
                    [Region("forage", r"^proc nearestPearl", label="Forage helper"), Region("forage", r"^proc forage\(")]),
            CloseUp("deliver", [block(r"^proc deliver\("), block(r"^proc deliveryMove", r"^# ---- The state machine")],
                    [Region("deliver", r"^proc deliver\("),
                     Region("deliver", r"^proc deliveryMove", r"^# ---- The state machine", "Deliver: sacrifice")]),
            CloseUp("sonar", [block(r"^proc encode\(", r"^# ---- Safety")],
                    [Region("sonar", r"^proc encode\(", r"^# ---- Safety")]),
        ]),
]


def token_colour(token):
    style = STYLE.style_for_token(token)
    return f"#{style['color']}" if style["color"] and style["color"] != "dddddd" else FOREGROUND


def styled_lines(source):
    """Each source line as (text, colour) runs. Lines are lexed one at a time, because
    pygments' Nim lexer loses its place after an FFI pragma and none of these bots has
    a construct that spans lines."""
    lines = []
    for line in source.split("\n"):
        runs = []
        for token, value in NimLexer().get_tokens(line):
            value = value.rstrip("\n")
            if value:
                runs.append((value, token_colour(token)))
        lines.append(runs)
    return lines


# ---- The map: the whole file as a minimap -----------------------------------------------

MAP_LINE = 4.2
MAP_CELL = 3.6
MAP_CODE_X = 30
MAP_TOP = 24


def draw_map(bot, source_lines, styled):
    fold_first, fold_last = bot.fold.span(source_lines)
    # Rows drawn in the map: every source line, with the FFI bindings folded to one row.
    rows = [i for i in range(len(source_lines)) if not fold_first < i <= fold_last]
    row_of = {line: row for row, line in enumerate(rows)}
    for line in range(fold_first + 1, fold_last + 1):
        row_of[line] = row_of[fold_first]
    height = MAP_TOP * 2 + len(rows) * MAP_LINE + 20
    columns = max(len(source_lines[line]) for line in rows if line != fold_first)
    window_width = MAP_CODE_X + columns * MAP_CELL + 16
    label_x = MARGIN + window_width + 56
    width = label_x + 250
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.0f} {height:.0f}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t">',
        f'<title id="t">Code map of examples/{bot.name}/strategy.nim</title>',
        f'<rect width="{width:.0f}" height="{height:.0f}" fill="{PAPER}"/>',
        f'<rect x="{MARGIN}" y="{MARGIN}" width="{window_width}" height="{height - 2 * MARGIN:.0f}" rx="{ROUNDING}"'
        f' fill="{BACKGROUND}" stroke="{ACTIVE_BORDER}" stroke-width="{BORDER}"/>',
    ]
    for row, line in enumerate(rows):
        y = MAP_TOP + row * MAP_LINE
        if line == fold_first:
            parts.append(f'<text x="{MAP_CODE_X}" y="{y + 3.6:.1f}" font-size="9" fill="{LINE_NUMBER}">'
                         f'+-- {fold_last - fold_first + 1} lines: the starter\'s C helper, called through FFI ···</text>')
            continue
        column = 0
        for text, fill in styled[line]:
            for word in re.finditer(r"\S+", text):
                x = MAP_CODE_X + (column + word.start()) * MAP_CELL
                parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{len(word.group()) * MAP_CELL:.1f}"'
                             f' height="{MAP_LINE * 0.62:.1f}" rx="0.8" fill="{fill}" opacity="0.8"/>')
            column += len(text)

    labels = []
    for index, region in enumerate(bot.regions):
        first, last = region.span(source_lines)
        top, bottom = MAP_TOP + row_of[first] * MAP_LINE - 2, MAP_TOP + row_of[last] * MAP_LINE + MAP_LINE + 0.5
        inset = 3 if region.start.startswith("^  ") else 0
        left, right = MAP_CODE_X - 8 + inset, window_width + MARGIN - 8 - inset
        parts.append(f'<rect x="{left}" y="{top:.1f}" width="{right - left}" height="{bottom - top:.1f}" rx="3"'
                     f' fill="{colour(region.key)}" fill-opacity="0.16" stroke="{colour(region.key)}" stroke-width="2"/>')
        labels.append((min((top + bottom) / 2, top + 12), right, region))

    # Stack labels top to bottom so none overlap, each joined to its box by a leader.
    placed = MAP_TOP
    for middle, right, region in sorted(labels, key=lambda item: item[0]):
        y = max(middle, placed + 17)
        placed = y
        parts.append(f'<path d="M{right} {middle:.1f} C{right + 24} {middle:.1f} {label_x - 34} {y:.1f} {label_x - 6} {y:.1f}"'
                     f' stroke="{colour(region.key)}" stroke-width="1.4" fill="none"/>')
        parts.append(f'<text x="{label_x}" y="{y + 4.5:.1f}" font-size="13" font-weight="bold"'
                     f' fill="{colour(region.key)}">{html.escape(region.title)}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


# ---- Close-ups: readable code with the same boxes -----------------------------------------

def close_up_rows(close_up, source_lines):
    rows = []  # source line index, or None for a fold marker between blocks
    for index, piece in enumerate(close_up.blocks):
        first, last = piece.span(source_lines)
        if index:
            rows.append(None)
        rows.extend(range(first, last + 1))
    return rows


def draw_close_up(close_up, source_lines, styled, columns):
    """Every close-up is drawn `columns` wide, so code prints at the same size in every figure."""
    rows = close_up_rows(close_up, source_lines)
    code_x = MARGIN + BORDER + PADDING + (GUTTER + 2) * CELL_WIDTH
    inner_width = (GUTTER + 2 + columns + 18) * CELL_WIDTH + 2 * PADDING
    inner_height = len(rows) * LINE_HEIGHT + 2 * PADDING + 10
    width, height = inner_width + 2 * (BORDER + MARGIN), inner_height + 2 * (BORDER + MARGIN)
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}"'
        f' font-family="{FONT}" font-size="{FONT_SIZE}">',
        f'<rect x="{MARGIN + BORDER / 2}" y="{MARGIN + BORDER / 2}" width="{inner_width + BORDER}"'
        f' height="{inner_height + BORDER}" rx="{ROUNDING}" fill="{BACKGROUND}"'
        f' stroke="{ACTIVE_BORDER}" stroke-width="{BORDER}"/>',
    ]
    top = MARGIN + BORDER + PADDING + 10
    row_of = {line: row for row, line in enumerate(rows) if line is not None}

    boxes = []
    for region in close_up.boxes:
        first, last = region.span(source_lines)
        nested = region.start.startswith("^  ")
        y1 = top + row_of[first] * LINE_HEIGHT + (1 if nested else -3)
        y2 = top + (row_of[last] + 1) * LINE_HEIGHT + (2 if nested else 6)
        x1 = code_x - (8 if nested else 14)
        x2 = MARGIN + BORDER + inner_width - (14 if nested else 8)
        parts.append(f'<rect x="{x1:.1f}" y="{y1:.1f}" width="{x2 - x1:.1f}" height="{y2 - y1:.1f}" rx="5"'
                     f' fill="{colour(region.key)}" fill-opacity="0.14" stroke="{colour(region.key)}" stroke-width="2.2"/>')
        boxes.append((region, x2, y1, nested))

    for row, line in enumerate(rows):
        y = top + row * LINE_HEIGHT + FONT_SIZE
        if line is None:
            parts.append(f'<text x="{code_x:.1f}" y="{y:.1f}" fill="{LINE_NUMBER}">···</text>')
            continue
        number = str(line + 1).rjust(GUTTER)
        parts.append(f'<text x="{MARGIN + BORDER + PADDING:.1f}" y="{y:.1f}" fill="{LINE_NUMBER}">{number}</text>')
        column = 0
        for text, fill in styled[line]:
            for word in re.finditer(r"\S+", text):
                x = code_x + (column + word.start()) * CELL_WIDTH
                parts.append(f'<text x="{x:.1f}" y="{y:.1f}" fill="{fill}">{html.escape(word.group())}</text>')
            column += len(text)

    # Label tabs sit on each box's right edge: at the top for outer boxes, inside for sockets.
    for region, x2, y1, nested in boxes:
        label = region.title
        tab_width = len(label) * CELL_WIDTH * 0.8 + 16
        tab_y = y1 + 3 if nested else y1 - 11
        parts.append(f'<rect x="{x2 - tab_width - 8:.1f}" y="{tab_y:.1f}" width="{tab_width:.1f}" height="19" rx="9.5"'
                     f' fill="{colour(region.key)}"/>')
        parts.append(f'<text x="{x2 - tab_width / 2 - 8:.1f}" y="{tab_y + 14:.1f}" font-size="{FONT_SIZE * 0.8:.1f}"'
                     f' font-weight="bold" fill="{PAPER}" text-anchor="middle">{html.escape(label)}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


def write_png(svg, path):
    subprocess.run(["rsvg-convert", "--zoom", "2", "--output", str(path)], input=svg.encode(), check=True)


def main():
    output = Path(sys.argv[1])
    sources = {bot.name: (ROOT / "examples" / bot.name / "strategy.nim").read_text().split("\n") for bot in BOTS}
    columns = max(len(sources[bot.name][line]) for bot in BOTS for close_up in bot.close_ups
                  for line in close_up_rows(close_up, sources[bot.name]) if line is not None)
    for bot in BOTS:
        source = (ROOT / "examples" / bot.name / "strategy.nim").read_text()
        source_lines = source.split("\n")
        styled = styled_lines(source)
        (output / f"{bot.name}-code-map.svg").write_text(draw_map(bot, source_lines, styled))
        for close_up in bot.close_ups:
            write_png(draw_close_up(close_up, source_lines, styled, columns), output / f"{bot.name}-code-{close_up.name}.png")


if __name__ == "__main__":
    main()
