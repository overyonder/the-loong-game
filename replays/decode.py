"""Read a replay and rebuild the game from it, turn by turn.

    python3 -m replays.decode game.replay            # what's in the file
    python3 -m replays.decode game.replay --deaths   # every death and its cause

A replay is a packed Cap'n Proto message (format.capnp): the map text, both bot
names, the result, and one long list of events in the order the engine produced
them. Nothing in it is a snapshot of the board, so GameState replays the events
one at a time, the same way the official viewer does.
"""

import argparse
import gzip
from collections import Counter, defaultdict
from pathlib import Path

import capnp

SCHEMA = capnp.load(str(Path(__file__).with_name("format.capnp")))

DIRECTIONS = "NESW"
OFFSETS = ((0, -1), (1, 0), (0, 1), (-1, 0))
# The viewer's names for DragonDeath.reason and GameResult.endReason.
DEATH_REASONS = ["hit a wall", "hit itself", "hit another body", "head-on collision", "no valid action"]
END_REASONS = ["team eliminated", "round limit"]


def read_replay(path: Path):
    """The whole replay as a Cap'n Proto reader. The toolkit writes it packed, sometimes gzipped too."""
    raw = path.read_bytes()
    packed = gzip.decompress(raw) if raw.startswith(b"\x1f\x8b") else raw
    return SCHEMA.Replay.from_bytes_packed(packed, traversal_limit_in_words=1 << 27)


def events(replay):
    """Each event as (kind, fields), with fields as plain Python values."""
    for event in replay.events:
        kind = event.which()
        yield kind, getattr(event, kind).to_dict()


def point(value) -> tuple[int, int]:
    return value["x"], value["y"]


class GameState:
    """The board as it stands after the events applied so far."""

    def __init__(self, map_text: str):
        self.round = -1
        self.edges = {}                  # (x, y, "N" or "W") -> "w" for kelp, or a portal number
        self.portals = defaultdict(list)
        self.dragons = {}                # id -> {"team": "A" or "B", "body": [head, ..., tail]}
        self.pearls = set()
        for line in map_text.splitlines():
            fields = line.split()
            if not fields or fields[0].startswith("#"):
                continue
            if fields[0] == "MAP":
                self.width, self.height = map(int, fields[1:])
            elif fields[0] == "EDGE":
                # Edges are numbered row by row: even rows are north edges, odd rows west edges.
                identifier, kind, portal = map(int, fields[1:])
                row, x = divmod(identifier, self.width + 1)
                key = (x % self.width, (row // 2) % self.height, "W" if row % 2 else "N")
                if kind == 1:
                    self.edges[key] = "w"
                elif kind == 2:
                    self.edges[key] = portal
                    self.portals[portal].append(key)
            elif fields[0] == "DRAGON":
                values = list(map(int, fields[1:]))
                body = list(zip(values[2::2], values[3::2]))
                self.dragons[len(self.dragons)] = {"team": "AB"[values[0]], "body": body}

    def apply(self, kind: str, event: dict) -> None:
        if kind == "roundStart":
            self.round = event["round"]
        elif kind == "tileChange":
            (self.pearls.add if event["hasPearl"] else self.pearls.discard)(point(event["tile"]))
        elif kind == "dragonUpdate" and self.round >= 0:
            # A move adds a new head, and the tail shrinks back to where the engine says it now is.
            body = self.dragons[event["id"]]["body"]
            body.insert(0, point(event["head"]))
            while len(body) > 1 and body[-1] != point(event["tail"]):
                body.pop()
        elif kind == "dragonSplit":
            self.dragons[event["parentId"]]["body"] = [point(p) for p in event["parentBody"]]
            self.dragons[event["childId"]] = {"team": event["team"].upper(),
                                              "body": [point(p) for p in event["childBody"]]}
        elif kind == "dragonDeath":
            del self.dragons[event["id"]]

    def window(self, identifier: int) -> list[tuple[int, int]]:
        """The 49 tiles one dragon can see: the 7×7 square around its head, wrapping at the edges."""
        head_x, head_y = self.dragons[identifier]["body"][0]
        return [((head_x + dx) % self.width, (head_y + dy) % self.height)
                for dy in range(-3, 4) for dx in range(-3, 4)]


def state_at_round(replay, round_number: int) -> GameState:
    """The board at the start of a round."""
    state = GameState(replay.map)
    for kind, event in events(replay):
        if kind == "roundStart" and event["round"] >= round_number:
            break
        state.apply(kind, event)
    return state


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("replays", nargs="+", type=Path)
    parser.add_argument("--deaths", action="store_true", help="count how dragons died, by team")
    arguments = parser.parse_args()

    if not arguments.deaths:
        for path in arguments.replays:
            replay = read_replay(path)
            state = GameState(replay.map)
            counts = Counter()
            for kind, event in events(replay):
                counts[kind] += 1
                state.apply(kind, event)
            result = replay.result
            winner = "draw" if result.which() == "noWinner" else f"team {str(result.winner).upper()} wins"
            # Public ladder replays leave the bot names blank.
            print(f"{path.name}: {replay.botA or 'team A'} vs {replay.botB or 'team B'}"
                  f" on a {state.width}×{state.height} map, format {replay.formatVersion}")
            print(f"  {winner} after {state.round} rounds ({END_REASONS[result.endReason]})")
            for kind, count in counts.most_common():
                print(f"  {count:>8,} {kind}")
        return

    deaths = Counter()
    for path in arguments.replays:
        replay = read_replay(path)
        state = GameState(replay.map)
        for kind, event in events(replay):
            if kind == "dragonDeath":
                bot = replay.botA if state.dragons[event["id"]]["team"] == "A" else replay.botB
                deaths[bot, DEATH_REASONS[event["reason"]]] += 1
            state.apply(kind, event)
    bots = sorted({bot for bot, _ in deaths})
    print(f"{'':<14}" + "".join(f"{reason:>18}" for reason in DEATH_REASONS))
    for bot in bots:
        print(f"{bot:<14}" + "".join(f"{deaths[bot, reason]:>18,}" for reason in DEATH_REASONS))
    print(f"{len(arguments.replays)} replays")


if __name__ == "__main__":
    main()
