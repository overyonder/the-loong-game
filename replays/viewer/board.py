"""Recorded board and observations for the viewer, independent of bot strategy."""

from pathlib import Path

from .reconstruction import ReplayState
from .replay import death_reason, read_replay


def cell_index(state: ReplayState, position) -> int:
    return position[1] * state.width + position[0]


def observed_window(state: ReplayState, head) -> str:
    """Encode the 7×7 view row by row: . empty, o pearl, a/A and b/B segments."""
    characters = []
    for dy in range(-3, 4):
        for dx in range(-3, 4):
            position = ((head[0] + dx) % state.width, (head[1] + dy) % state.height)
            occupant = state.occupied.get(position)
            if occupant is not None:
                team, _, _, is_head = occupant
                character = team.lower()
                characters.append(character.upper() if is_head else character)
            elif position in state.pearls:
                characters.append("o")
            else:
                characters.append(".")
    return "".join(characters)


def board_snapshot(state: ReplayState, deaths: list) -> dict:
    return {
        "dragons": [
            {
                "id": identifier,
                "team": "AB".index(dragon["team"]),
                "body": [cell_index(state, p) for p in dragon["body"]],
            }
            for identifier, dragon in sorted(state.dragons.items())
        ],
        "pearls": sorted(cell_index(state, p) for p in state.pearls),
        "deaths": deaths,
        "timers": [
            {"cell": cell_index(state, p), "remaining": max(0, due - state.round)}
            for p, due in sorted(state.due.items())
        ],
    }


def board_export(replay_path: Path, bot_a: str, bot_b: str) -> dict:
    replay = read_replay(replay_path)
    state = ReplayState(replay["map"])
    map_name = next(
        (
            line.split(maxsplit=1)[1]
            for line in replay["map"].splitlines()
            if line.startswith("MAP_NAME ")
        ),
        replay_path.stem,
    )
    frames, turns, deaths = [], [], []
    turn_by_dragon = {}
    for event in replay["events"]:
        kind = event["type"]
        if kind == "roundStart":
            frames.append(board_snapshot(state, deaths))
            deaths = []
        elif kind == "turnStart":
            identifier = event["id"]
            dragon = state.dragons[identifier]
            head = dragon["body"][0]
            window = observed_window(state, head)
            turn = {
                "dragon": identifier,
                "team": "AB".index(dragon["team"]),
                "round": state.round,
                "head": cell_index(state, head),
                "length": len(dragon["body"]),
                "action": "none",
                "window": window,
                "report_present": False,
                "board": board_snapshot(state, []),
            }
            turn_by_dragon[identifier] = turn
            turns.append(turn)
        elif kind == "dragonAction" and event["id"] in turn_by_dragon:
            action = event.get("action", {})
            turn_by_dragon[event["id"]]["action"] = (
                "MOVE " + "".join(d[0].upper() for d in action["move"])
                if "move" in action
                else f"SPLIT {action['split']}"
                if "split" in action
                else "SUICIDE"
            )
        elif kind == "dragonDeath":
            dragon = state.dragons[event["id"]]
            deaths.append(
                {
                    "id": event["id"],
                    "team": "AB".index(dragon["team"]),
                    "cell": cell_index(state, dragon["body"][0]),
                    "reason": death_reason(event["reason"]),
                }
            )
        state.apply(event)
    frames.append(board_snapshot(state, deaths))
    edges = []
    for (x, y, side), edge in sorted(state.edges.items()):
        if edge != ".":
            edges.append(
                {
                    "x": x,
                    "y": y,
                    "side": "NW".index(side),
                    "kelp": edge == "w",
                    "portal": -1 if edge == "w" else int(edge),
                }
            )
    result = replay["result"]
    winner = result.get("winner")
    return {
        "version": 1,
        "map_name": map_name,
        "width": state.width,
        "height": state.height,
        "bot_a": bot_a,
        "bot_b": bot_b,
        "winner": winner.upper() if winner else "draw",
        "edges": edges,
        "frames": frames,
        "turns": turns,
    }
