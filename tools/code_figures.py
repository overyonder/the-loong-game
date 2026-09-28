"""Draw the code figures for the strategy posts: repertoire trees, and close-ups of
the modules that make up each bot.

    python3 tools/code_figures.py blog/images [PRIVATE_CHECKOUT]

Each close-up is drawn as Neovide with gruvbox dark hard inside a Hyprland window,
with boxes over the parts the post discusses. Regions are found by pattern, so the
figures follow the code when it changes. Figures of Kieran's reference and of our
competition repertoire read the private checkout, by default the sibling
the-loong-game-private, and are skipped without it.
Quantise the PNGs afterwards like the terminal figures, marking them as 2x images for the site:
    magick F -density 144 -units PixelsPerInch -colors 256 PNG8:F && oxipng -o 4 F
"""

import html
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from pygments.lexers import NimrodLexer as NimLexer
from pygments.styles import get_style_by_name

from figure_palette import COMPONENTS, FONT as DIAGRAM_FONT, GRUVBOX, INK, MUTED, PAPER, colour

ROOT = Path(__file__).resolve().parent.parent

# Neovide with gruvbox dark hard, in the same Hyprland window as the terminal figures.
BACKGROUND    = GRUVBOX["bg0"]
FOREGROUND    = GRUVBOX["fg1"]
LINE_NUMBER   = GRUVBOX["bg3"]
ACTIVE_BORDER = GRUVBOX["blue"]
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
PRIVATE = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT.parent / "the-loong-game-private"
EXAMPLES = ROOT / "examples"
LOONG = "repertoire/games/loong"


@dataclass
class Region:
    key: str
    start: str                # pattern for the region's first line
    until: str | None = None  # pattern for the first line after it; default: the next blank line
    label: str | None = None

    def span(self, lines):
        first = next(i for i, line in enumerate(lines) if re.search(self.start, line))
        if self.until is None:
            last = next((i for i in range(first + 1, len(lines)) if not lines[i].strip()), len(lines)) - 1
        elif self.until == "$":
            last = len(lines) - 1
        else:
            last = next(i for i in range(first + 1, len(lines)) if re.search(self.until, lines[i])) - 1
        while not lines[last].strip():
            last -= 1
        return first, last

    @property
    def title(self):
        return self.label or COMPONENTS[self.key][1]


@dataclass
class Block:
    path: Path               # the source file
    region: Region           # the lines shown
    boxes: list[Region] = field(default_factory=list)


@dataclass
class CloseUp:
    name: str
    blocks: list[Block]      # shown one after another, each headed by its file name


def whole(key="frame"):
    return Region(key, r".", "$")


def lines_of(path):
    return path.read_text().rstrip("\n").split("\n")


# ---- The figures -------------------------------------------------------------------------

def example(path):
    return EXAMPLES / path


def close_ups():
    loong = lambda name: example(f"{LOONG}/{name}")
    behaviour = lambda name: loong(f"behaviours/{name}.nim")
    figures = [
        CloseUp("first-bot-strategy", [Block(example("first-bot/strategy.nim"), whole())]),
        CloseUp("first-bot-evade", [Block(behaviour("evade"), whole(), [
            Region("evade", r"^proc objective", label="Objective"),
            Region("evade", r"^proc hsmState", label="State factory")])]),
        CloseUp("first-bot-movement", [Block(loong("movement.nim"), Region("safety", r"^proc safeSteps", "$"), [
            Region("safety", r"^proc safeSteps", label="Hard constraints"),
            Region("frame", r"^  let score = proc", "$", "The behaviour's objective")])]),
        CloseUp("roles-bot-strategy", [Block(example("roles-bot/strategy.nim"), Region("frame", r"^hsm\.run", "$"), [
            Region("frame", r"^  roles\.champion", r"^  roles\.kamikaze", "Champion"),
            Region("hunt", r"^  roles\.kamikaze", label="Kamikaze"),
            Region("roam", r"^  roles\.other", label="Worker"),
            Region("sonar", r"^\]\), sonar", label="Sonar protocol")])]),
        CloseUp("roles-bot-roles", [Block(loong("roles.nim"), Region("frame", r"^proc champion", "$"))]),
        CloseUp("roles-bot-hunt", [Block(behaviour("hunt"), Region("hunt", r"^proc objective", "$"), [
            Region("hunt", r"^proc objective", label="Objective"),
            Region("hunt", r"^proc strike", label="Reflex"),
            Region("hunt", r"^proc hsmState", label="State factory")])]),
        CloseUp("roles-bot-sonar", [Block(loong("length_radio.nim"), Region("sonar", r"^proc encode", r"^proc create"))]),
        CloseUp("tactics-bot-strategy", [Block(example("tactics-bot/strategy.nim"), Region("frame", r"^hsm\.run", "$"), [
            Region("coil", r"^  roles\.champion", r"^  roles\.kamikaze", "Champion coils"),
            Region("forage", r"^  roles\.other", r"^\]\)", "Feeders deliver or forage")])]),
        CloseUp("tactics-bot-coil", [Block(behaviour("coil"), Region("coil", r"^proc objective", "$"))]),
        CloseUp("tactics-bot-forage", [Block(loong("window.nim"), Region("forage", r"^proc nearestPearl")),
                                       Block(behaviour("forage"), Region("forage", r"^proc objective", "$"))]),
        CloseUp("tactics-bot-deliver", [Block(behaviour("deliver"), Region("deliver", r"^proc objective", "$"), [
            Region("deliver", r"^proc objective", label="Objective"),
            Region("deliver", r"^proc sacrifice", label="Reflex")])]),
        CloseUp("tactics-bot-sonar", [Block(loong("champion_radio.nim"), Region("sonar", r"^proc encode", r"^    announce"))]),
    ]
    kieran = PRIVATE / "bots/kieran"
    ours = PRIVATE / "bots/opus/repertoire/games/loong/behaviours/escape.nim"
    if kieran.is_dir():
        figures.append(CloseUp("composition-assembly", [
            Block(kieran / "k_utility/strategy.nim", whole()),
            Block(kieran / "k_HTN/strategy.nim", whole())]))
        figures.append(CloseUp("composition-behaviour", [Block(ours, Region("frame", r"^proc whenTrapped", "$"), [
            Region("safety", r"^proc whenTrapped", label="Eligibility"),
            Region("roam", r"^proc execute", label="Execution"),
            Region("evade", r"^proc utilityBehaviour", label="Utility AI"),
            Region("hunt", r"^proc subsumptionLayer", label="Subsumption"),
            Region("coil", r"^proc bdiDesire", label="BDI"),
            Region("forage", r"^proc goapGoal", "$", "GOAP")])]))
    return figures


def token_colour(token):
    style = STYLE.style_for_token(token)
    return f"#{style['color']}" if style["color"] and style["color"] != "dddddd" else FOREGROUND


def styled_lines(lines):
    """Each source line as (text, colour) runs. Lines are lexed one at a time, because
    pygments' Nim lexer loses its place after an FFI pragma."""
    styled = []
    for line in lines:
        runs = []
        for token, value in NimLexer().get_tokens(line):
            value = value.rstrip("\n")
            if value:
                runs.append((value, token_colour(token)))
        styled.append(runs)
    return styled


def label_path(path):
    for base in (ROOT, PRIVATE):
        if path.is_relative_to(base):
            return str(path.relative_to(base))
    return path.name


# ---- Close-ups: readable code with boxes -------------------------------------------------

def rows_of(close_up):
    """(block, line index) per drawn row, with (block, None) as each block's file heading."""
    rows = []
    for block in close_up.blocks:
        lines = lines_of(block.path)
        first, last = block.region.span(lines)
        rows.append((block, None))
        rows.extend((block, line) for line in range(first, last + 1))
    return rows


def draw_close_up(close_up, columns):
    """Every close-up is drawn `columns` wide, so code prints at the same size in every figure."""
    rows = rows_of(close_up)
    code_x = MARGIN + BORDER + PADDING + (GUTTER + 2) * CELL_WIDTH
    inner_width = (GUTTER + 2 + columns + 16) * CELL_WIDTH + 2 * PADDING
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
    row_of = {(id(block), line): row for row, (block, line) in enumerate(rows)}

    tabs = []
    for block in close_up.blocks:
        lines = lines_of(block.path)
        for region in block.boxes:
            first, last = region.span(lines)
            y1 = top + row_of[id(block), first] * LINE_HEIGHT - 3
            y2 = top + (row_of[id(block), last] + 1) * LINE_HEIGHT + 6
            x1, x2 = code_x - 14, MARGIN + BORDER + inner_width - 8
            parts.append(f'<rect x="{x1:.1f}" y="{y1:.1f}" width="{x2 - x1:.1f}" height="{y2 - y1:.1f}" rx="5"'
                         f' fill="{colour(region.key)}" fill-opacity="0.14" stroke="{colour(region.key)}" stroke-width="2.2"/>')
            tabs.append((region, x2, y1))

    styled = {id(block): styled_lines(lines_of(block.path)) for block in close_up.blocks}
    for row, (block, line) in enumerate(rows):
        y = top + row * LINE_HEIGHT + FONT_SIZE
        if line is None:
            parts.append(f'<text x="{MARGIN + BORDER + PADDING:.1f}" y="{y:.1f}" fill="{ACTIVE_BORDER}"'
                         f' font-weight="bold">{html.escape(label_path(block.path))}</text>')
            continue
        number = str(line + 1).rjust(GUTTER)
        parts.append(f'<text x="{MARGIN + BORDER + PADDING:.1f}" y="{y:.1f}" fill="{LINE_NUMBER}">{number}</text>')
        column = 0
        for text, fill in styled[id(block)][line]:
            for word in re.finditer(r"\S+", text):
                x = code_x + (column + word.start()) * CELL_WIDTH
                parts.append(f'<text x="{x:.1f}" y="{y:.1f}" fill="{fill}">{html.escape(word.group())}</text>')
            column += len(text)

    for region, x2, y1 in tabs:
        label = region.title
        tab_width = len(label) * CELL_WIDTH * 0.8 + 16
        parts.append(f'<rect x="{x2 - tab_width - 8:.1f}" y="{y1 + 3:.1f}" width="{tab_width:.1f}" height="19" rx="9.5"'
                     f' fill="{colour(region.key)}"/>')
        parts.append(f'<text x="{x2 - tab_width / 2 - 8:.1f}" y="{y1 + 17:.1f}" font-size="{FONT_SIZE * 0.8:.1f}"'
                     f' font-weight="bold" fill="{PAPER}" text-anchor="middle">{html.escape(label)}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


# ---- Trees: a repertoire's folders and files ---------------------------------------------

TREE_LINE = 19
TREE_INDENT = 16


def tree_entries(root):
    """(depth, name, path) for every folder and .nim file under root, folders first."""
    entries = []

    def walk(folder, depth):
        children = sorted(folder.iterdir(), key=lambda p: (p.is_file(), p.name))
        for child in children:
            if child.is_dir():
                entries.append((depth, child.name + "/", child))
                walk(child, depth + 1)
            elif child.suffix == ".nim":
                entries.append((depth, child.name, child))
    walk(root, 0)
    return entries


def imports(path, seen):
    """Every repertoire module a Nim file imports, followed transitively."""
    for match in re.finditer(r"^from (\S+) import", path.read_text(), re.M):
        target = (path.parent / (match[1] + ".nim")).resolve()
        if target.is_file() and target not in seen:
            seen.add(target)
            imports(target, seen)
    return seen


def draw_tree(title, description, root, columns_of, marks):
    """The tree in `columns_of` columns, each a list of top-level folder names. `marks` maps a
    heading to the set of files it marks with a dot; `None` as a set marks nothing."""
    column_width = 300 + 44 * len(marks)
    columns = []
    for names in columns_of:
        entries = []
        for name in names:
            folder = root / name
            entries.append((0, name + "/", folder))
            entries += [(depth + 1, label, path) for depth, label, path in tree_entries(folder)]
        columns.append(entries)
    height = 70 + max(len(entries) for entries in columns) * TREE_LINE + 20
    width = 20 + column_width * len(columns)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="{DIAGRAM_FONT}"'
             ' role="img" aria-labelledby="t d">',
             f'<title id="t">{html.escape(title)}</title><desc id="d">{html.escape(description)}</desc>',
             f'<rect width="{width}" height="{height}" fill="{PAPER}"/>']
    for index, entries in enumerate(columns):
        x0 = 20 + index * column_width
        for mark_index, (heading, _) in enumerate(marks):
            parts.append(f'<text x="{x0 + 280 + 44 * mark_index + 12}" y="44" font-size="11" fill="{MUTED}"'
                         f' text-anchor="middle" transform="rotate(-30 {x0 + 280 + 44 * mark_index + 12} 44)">{html.escape(heading)}</text>')
        for row, (depth, label, path) in enumerate(entries):
            y = 70 + row * TREE_LINE
            folder = label.endswith("/")
            key = ("frame" if depth == 0 else "window") if folder else "roam"
            weight = "bold" if folder else "normal"
            fill = colour(key) if folder else INK
            parts.append(f'<text x="{x0 + depth * TREE_INDENT}" y="{y}" font-size="13" font-weight="{weight}"'
                         f' fill="{fill}">{html.escape(label)}</text>')
            for mark_index, (_, marked) in enumerate(marks):
                if marked is not None and path.resolve() in marked:
                    parts.append(f'<circle cx="{x0 + 280 + 44 * mark_index + 12}" cy="{y - 4}" r="5" fill="{colour("sonar")}"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def trees():
    root = EXAMPLES / "repertoire"
    bots = [(name, imports(EXAMPLES / name / "strategy.nim", set())) for name in ("first-bot", "roles-bot", "tactics-bot")]
    figures = [("examples-repertoire", draw_tree(
        "The example bots' repertoire, and which modules each bot uses",
        "The repertoire folder of the example bots: a decision_architectures folder with the hierarchical state"
        " machine, and games/loong with the controller, window, turn, movement, roles, sonar protocols, the state"
        " machine adapter and seven behaviours. Dots mark the modules the first, roles and tactics bots use.",
        root, [["decision_architectures", "games"]], bots))]
    kieran = PRIVATE / "bots/kieran/repertoire"
    if kieran.is_dir():
        implemented = {(kieran / match).resolve() for match in
                       re.findall(r"^\s*- \[x\] \[[^\]]+\]\(([^)]+)\)", (kieran / "implementation-checklist.md").read_text(), re.M)}
        figures.append(("kieran-repertoire-wide", draw_tree(
            "The reference repertoire",
            "Every file in the reference repertoire, in four folders: data_structures, decision_architectures,"
            " techniques sorted by family, and games/loong. Dots mark the thirteen implemented modules; the rest are"
            " pseudocode notes waiting for a bot to need them.",
            kieran, [["data_structures", "decision_architectures"], ["techniques"], ["games"]],
            [("implemented", implemented)])))
    return figures


def write_png(svg, path):
    subprocess.run(["rsvg-convert", "--zoom", "2", "--output", str(path)], input=svg.encode(), check=True)


def main():
    output = Path(sys.argv[1])
    figures = close_ups()
    columns = max(len(lines_of(block.path)[line]) for close_up in figures
                  for block, line in rows_of(close_up) if line is not None)
    for close_up in figures:
        write_png(draw_close_up(close_up, min(columns, 96)), output / f"{close_up.name}.png")
    for name, svg in trees():
        (output / f"{name}.svg").write_text(svg)


if __name__ == "__main__":
    main()
