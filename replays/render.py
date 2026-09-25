"""Draw one round of a replay as an SVG board, for figures and post banners.

    python3 -m replays.render game.replay --round 140 -o board.svg
    python3 -m replays.render game.replay --round 140 --fog 22 -o window.svg

--fog dims everything outside one dragon's 7×7 window. --busiest prints the round
with the most dragons alive instead of drawing.
"""

import argparse
from pathlib import Path

from replays.decode import GameState, events, read_replay, state_at_round

CELL = 24
TEAM_COLOURS = {"A": "#ff7a3d", "B": "#f3ecdf"}
BOARD = "#1d3027"
GRID = "rgba(243,236,223,.07)"
KELP = "#7fb069"
PORTAL = "#e8c872"
PEARL = "#e8c872"


def busiest_round(replay) -> tuple[int, int]:
    state = GameState(replay.map)
    best = (0, 0)
    for kind, event in events(replay):
        if kind == "roundStart" and len(state.dragons) > best[1]:
            best = (event["round"], len(state.dragons))
        state.apply(kind, event)
    return best


def centre(position) -> tuple[float, float]:
    return position[0] * CELL + CELL / 2, position[1] * CELL + CELL / 2


def body_runs(body):
    """A body as runs of neighbouring cells, broken where it wraps round the board or goes through a portal."""
    runs = [[body[0]]]
    for previous, current in zip(body, body[1:]):
        if abs(previous[0] - current[0]) + abs(previous[1] - current[1]) == 1:
            runs[-1].append(current)
        else:
            runs.append([current])
    return runs


def render(state: GameState, fog: int | None = None) -> str:
    width, height = state.width * CELL, state.height * CELL
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">',
             f'<rect width="{width}" height="{height}" fill="{BOARD}"/>']
    grid = [f"M{x * CELL} 0V{height}" for x in range(1, state.width)]
    grid += [f"M0 {y * CELL}H{width}" for y in range(1, state.height)]
    parts.append(f'<path d="{"".join(grid)}" stroke="{GRID}" stroke-width="1"/>')

    kelp, portals = [], []
    for (x, y, side), kind in state.edges.items():
        (kelp if kind == "w" else portals).append(f"M{x * CELL} {y * CELL}{'h' if side == 'N' else 'v'}{CELL}")
    parts.append(f'<path d="{"".join(kelp)}" stroke="{KELP}" stroke-width="4" stroke-linecap="round" fill="none"/>')
    parts.append(f'<path d="{"".join(portals)}" stroke="{PORTAL}" stroke-width="4" stroke-dasharray="3 3" fill="none"/>')

    for position in state.pearls:
        x, y = centre(position)
        parts.append(f'<circle cx="{x}" cy="{y}" r="{CELL * 0.18}" fill="{PEARL}"/>')
    for dragon in state.dragons.values():
        colour = TEAM_COLOURS[dragon["team"]]
        for run in body_runs(dragon["body"]):
            points = " ".join("{},{}".format(*centre(position)) for position in run)
            parts.append(f'<polyline points="{points}" fill="none" stroke="{colour}" stroke-width="{CELL * 0.5}"'
                         ' stroke-linecap="round" stroke-linejoin="round" opacity=".85"/>')
        x, y = centre(dragon["body"][0])
        parts.append(f'<circle cx="{x}" cy="{y}" r="{CELL * 0.36}" fill="{colour}"/>')

    if fog is not None:
        window = set(state.window(fog))
        dark = [f"M{x * CELL} {y * CELL}h{CELL}v{CELL}h-{CELL}z"
                for x in range(state.width) for y in range(state.height) if (x, y) not in window]
        parts.append(f'<path d="{"".join(dark)}" fill="#0f1a14" opacity=".82"/>')
        x, y = centre(state.dragons[fog]["body"][0])
        parts.append(f'<circle cx="{x}" cy="{y}" r="{CELL * 0.62}" fill="none" stroke="{TEAM_COLOURS["B"]}" stroke-width="3"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("replay", type=Path)
    parser.add_argument("--round", type=int, default=0)
    parser.add_argument("--fog", type=int, help="the dragon whose 7×7 window stays lit")
    parser.add_argument("--busiest", action="store_true")
    parser.add_argument("-o", "--output", type=Path)
    arguments = parser.parse_args()
    replay = read_replay(arguments.replay)
    if arguments.busiest:
        print(*busiest_round(replay))
        return
    svg = render(state_at_round(replay, arguments.round), arguments.fog)
    if arguments.output:
        arguments.output.write_text(svg)
    else:
        print(svg, end="")


if __name__ == "__main__":
    main()
