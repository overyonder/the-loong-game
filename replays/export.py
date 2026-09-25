"""Turn a replay into the JSON the debug viewer loads.

    python3 -m replays.export game.replay --output game.json

The export holds the map's kelp and portal edges, the true board before every
round, and every dragon turn: what that dragon could see in its 7×7 window, what
it did, and the indicator text it set. Cells are numbered y * width + x.
"""

import argparse
import json
from pathlib import Path

from replays.decode import DEATH_REASONS, GameState, events, read_replay


def board_frame(state: GameState, deaths: list[dict]) -> dict:
    cell = lambda position: position[1] * state.width + position[0]
    return {
        "dragons": [{"id": identifier, "team": "AB".index(dragon["team"]),
                     "body": [cell(position) for position in dragon["body"]]}
                    for identifier, dragon in sorted(state.dragons.items())],
        "pearls": sorted(cell(position) for position in state.pearls),
        "deaths": deaths,
    }


def window_text(state: GameState, identifier: int) -> str:
    """The dragon's window as 49 characters: . empty, o pearl, a/A team A body/head, b/B team B."""
    occupant = {}
    for dragon in state.dragons.values():
        for index, position in enumerate(dragon["body"]):
            letter = dragon["team"].lower()
            occupant[position] = letter.upper() if index == 0 else letter
    return "".join(occupant.get(position, "o" if position in state.pearls else ".")
                   for position in state.window(identifier))


def action_text(action: dict | None) -> str:
    if action is None:
        return "no action"
    if "move" in action:
        return "MOVE " + "".join(direction[0].upper() for direction in action["move"])
    if "split" in action:
        return f"SPLIT {action['split']}"
    return "SUICIDE"


def export(path: Path) -> dict:
    replay = read_replay(path)
    state = GameState(replay.map)
    edges = [{"x": x, "y": y, "side": 0 if side == "N" else 1,
              "kelp": kind == "w", "portal": -1 if kind == "w" else kind}
             for (x, y, side), kind in sorted(state.edges.items(), key=str)]
    frames, turns, deaths = [], [], []
    observed = {}      # the window each dragon saw at the start of its current turn
    for kind, event in events(replay):
        if kind == "roundStart" and event["round"] >= 0:
            frames.append(board_frame(state, deaths))
            deaths = []
        elif kind == "turnStart":
            dragon = state.dragons[event["id"]]
            head = dragon["body"][0]
            observed[event["id"]] = {"dragon": event["id"], "team": "AB".index(dragon["team"]),
                                     "round": state.round, "head": head[1] * state.width + head[0],
                                     "length": len(dragon["body"]), "window": window_text(state, event["id"]),
                                     "indicator": ""}
        elif kind == "dragonIndicator" and event["id"] in observed:
            # A dragon sets its indicator during its turn, before its action is recorded.
            observed[event["id"]]["indicator"] = event["text"]
        elif kind == "dragonAction":
            turn = observed.pop(event["id"])
            turn["action"] = action_text(event.get("action"))
            turns.append(turn)
        elif kind == "dragonDeath":
            head = state.dragons[event["id"]]["body"][0]
            deaths.append({"id": event["id"], "team": "AB".index(state.dragons[event["id"]]["team"]),
                           "cell": head[1] * state.width + head[0], "reason": DEATH_REASONS[event["reason"]]})
        state.apply(kind, event)
    frames.append(board_frame(state, deaths))
    result = replay.result
    return {"version": 1, "width": state.width, "height": state.height,
            "bot_a": replay.botA or "team A", "bot_b": replay.botB or "team B",
            "winner": "draw" if result.which() == "noWinner" else str(result.winner).upper(),
            "edges": edges, "frames": frames, "turns": turns}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("replay", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    data = export(arguments.replay)
    arguments.output.write_text(json.dumps(data, separators=(",", ":")))
    print(f"{arguments.output}: {len(data['frames']) - 1} rounds, {len(data['turns']):,} dragon turns")


if __name__ == "__main__":
    main()
