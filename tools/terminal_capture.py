"""Record fish commands as they appear in Kieran's kitty and render them as a PNG.

Each command runs in a pseudo-terminal, so the fish prompt, fish's own syntax
highlighting and each program's colours are real. The capture is drawn as a
kitty window under Hyprland: gruvbox dark hard (stylix base16), FiraCode Nerd
Font, 2px active border and 10px rounding.

    python3 tools/terminal_capture.py --cwd DIR --output out.png -- 'command' ...
"""

import argparse
import html
import os
import re
import subprocess
import tempfile
from pathlib import Path

import pyte

# kitty-gruvbox-dark-hard.conf from nixos-config home/users/user/programs/terminal.nix
BACKGROUND    = "#1d2021"
FOREGROUND    = "#d5c4a1"
ACTIVE_BORDER = "#83a598"  # stylix sets Hyprland's col.active_border to base0D
ANSI_COLOURS  = ["#1d2021", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#d5c4a1",
                 "#504945", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#fbf1c7"]
FONT          = "FiraCode Nerd Font"
FONT_SIZE     = 15
CELL_WIDTH    = FONT_SIZE * 0.6
LINE_HEIGHT   = FONT_SIZE * 1.45
PADDING       = 18
BORDER        = 2
ROUNDING      = 10
MARGIN        = 12

TERMINAL_COLUMNS = 120
PYTE_COLOUR_NAMES = {"default": FOREGROUND} | {
    ("bright" if index >= 8 else "") + name: ANSI_COLOURS[index]
    for index, name in enumerate(["black", "red", "green", "brown", "blue", "magenta", "cyan", "white"] * 2)
}


def run_in_pseudo_terminal(fish_source, cwd, script_directory):
    script = Path(script_directory) / "step.fish"
    script.write_text(fish_source)
    environment = dict(os.environ, TERM="xterm-kitty", COLUMNS=str(TERMINAL_COLUMNS), LINES="50")
    result = subprocess.run(["script", "-qec", f"stty cols {TERMINAL_COLUMNS} rows 50; fish {script}", "/dev/null"], cwd=cwd,
                            env=environment, capture_output=True)
    return result.stdout.decode()


def record_commands_as_ansi(commands, cwd):
    transcript = ""
    with tempfile.TemporaryDirectory() as script_directory:
        for command in commands:
            source = Path(script_directory) / "command.fish"
            source.write_text(command)
            transcript += run_in_pseudo_terminal("fish_prompt", cwd, script_directory)
            highlighted = run_in_pseudo_terminal(f"fish_indent --ansi {source}", cwd, script_directory)
            transcript += highlighted.rstrip("\r\n") + "\n"
            transcript += run_in_pseudo_terminal(command, cwd, script_directory)
    return transcript


def ansi_to_styled_lines(transcript):
    """Play the transcript through a VT emulator and return lines of (text, colour, bold) runs."""
    screen = pyte.Screen(TERMINAL_COLUMNS, transcript.count("\n") + 2)
    screen.set_mode(pyte.modes.LNM)
    pyte.Stream(screen).feed(transcript)
    lines = []
    for row in range(screen.lines):
        line = screen.buffer[row]
        runs = []
        for column in range(screen.columns):
            character = line[column]
            colour = PYTE_COLOUR_NAMES.get(character.fg)
            if colour is None:
                colour = "#" + character.fg if re.fullmatch(r"[0-9a-f]{6}", character.fg) else FOREGROUND
            if runs and runs[-1][1:] == (colour, character.bold):
                runs[-1] = (runs[-1][0] + character.data, colour, character.bold)
            else:
                runs.append((character.data, colour, character.bold))
        text = "".join(run[0] for run in runs).rstrip()
        while runs and len("".join(run[0] for run in runs)) > len(text):
            excess = len("".join(run[0] for run in runs)) - len(text)
            last = runs.pop()
            if len(last[0]) > excess:
                runs.append((last[0][: len(last[0]) - excess], last[1], last[2]))
        lines.append(runs)
    while lines and not lines[-1]:
        lines.pop()
    return lines


def render_kitty_window_svg(lines):
    columns = max((sum(len(run[0]) for run in line) for line in lines), default=0)
    inner_width = columns * CELL_WIDTH + 2 * PADDING
    inner_height = len(lines) * LINE_HEIGHT + 2 * PADDING
    width, height = inner_width + 2 * (BORDER + MARGIN), inner_height + 2 * (BORDER + MARGIN)
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}"'
        f' font-family="{FONT}" font-size="{FONT_SIZE}">',
        f'<rect x="{MARGIN + BORDER / 2}" y="{MARGIN + BORDER / 2}" width="{inner_width + BORDER}"'
        f' height="{inner_height + BORDER}" rx="{ROUNDING}" fill="{BACKGROUND}"'
        f' stroke="{ACTIVE_BORDER}" stroke-width="{BORDER}"/>',
    ]
    for row, line in enumerate(lines):
        y = MARGIN + BORDER + PADDING + row * LINE_HEIGHT + FONT_SIZE
        column = 0
        for text, colour, bold in line:
            weight = ' font-weight="bold"' if bold else ""
            # Place each word at its own cell: renderers draw spaces narrower than a cell.
            for word in re.finditer(r"\S+", text):
                x = MARGIN + BORDER + PADDING + (column + word.start()) * CELL_WIDTH
                parts.append(f'<text x="{x:.1f}" y="{y:.1f}" fill="{colour}"{weight}>'
                             f"{html.escape(word.group())}</text>")
            column += len(text)
    parts.append("</svg>")
    return "\n".join(parts)


def main():
    global TERMINAL_COLUMNS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--columns", type=int, default=TERMINAL_COLUMNS)
    parser.add_argument("commands", nargs="+")
    arguments = parser.parse_args()
    TERMINAL_COLUMNS = arguments.columns
    svg = render_kitty_window_svg(ansi_to_styled_lines(record_commands_as_ansi(arguments.commands, arguments.cwd)))
    subprocess.run(["rsvg-convert", "--zoom", "2", "--output", str(arguments.output)],
                   input=svg.encode(), check=True)


if __name__ == "__main__":
    main()
