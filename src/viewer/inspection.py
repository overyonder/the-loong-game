"""Headless inspection using the viewer's canonical replay and observation models."""

import json
from collections import Counter
from dataclasses import asdict
from pathlib import Path

from .reconstruction import ReplayState, extract_decisions
from .replay import DEATH_REASONS, death_reason, read_replay


def inspect_replays(
    paths: list[Path], *, deaths: bool = False, observations: bool = False
) -> None:
    causes = Counter()
    for path in paths:
        if observations:
            for sample in extract_decisions(path):
                print(json.dumps(asdict(sample)))
            continue
        replay = read_replay(path)
        state = ReplayState(replay["map"], lenient=True)
        events = Counter()
        for event in replay["events"]:
            events[event["type"]] += 1
            if event["type"] == "dragonDeath":
                side = state.dragons[event["id"]]["team"]
                bot = replay[f"bot{side}"] or f"team {side}"
                causes[bot, death_reason(event["reason"])] += 1
            state.apply(event)
        if not deaths:
            winner = replay["result"].get("winner")
            outcome = f"team {winner.upper()} wins" if winner else "draw"
            print(
                f"{path.name}: {replay['botA'] or 'team A'} vs "
                f"{replay['botB'] or 'team B'} on a {state.width}×{state.height} map, "
                f"format {replay['formatVersion']}"
            )
            print(f"  {outcome} after {state.round + 1} rounds")
            for kind, count in events.most_common():
                print(f"  {count:>8,} {kind}")
    if deaths:
        reasons = list(DEATH_REASONS.values())
        print(f"{'bot':<20}" + "".join(f"{reason:>22}" for reason in reasons))
        for bot in sorted({bot for bot, _ in causes}):
            print(
                f"{bot:<20}"
                + "".join(f"{causes[bot, reason]:>22,}" for reason in reasons)
            )
        print(f"{len(paths)} replays")
