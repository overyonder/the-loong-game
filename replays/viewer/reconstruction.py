"""Reconstruct pre-action local observations from ordered recorded engine events."""

import hashlib
from collections import Counter, defaultdict
from pathlib import Path

from .observations import DecisionSample
from .replay import read_replay

DIRECTIONS = "NESW"
OFFSETS = ((0, -1), (1, 0), (0, 1), (-1, 0))


def point(value):
    return value["x"], value["y"]


class ReplayState:
    def __init__(self, map_text, lenient=False):
        # Lenient states take the first candidate for an ambiguous body heading
        # (two directions reach the same square) and count it in `ambiguous`.
        self.lenient = lenient
        self.ambiguous = 0
        self.round = -1
        self.unit_limit = 64
        self.edges = {}
        self.portals = defaultdict(list)
        self.dragons = {}
        self.occupied = {}
        self.pearls = set()
        self.due = {}
        self.messages = defaultdict(list)
        self.echoes = defaultdict(lambda: [0] * 5)
        for line in map_text.splitlines():
            fields = line.split()
            if not fields or fields[0].startswith("#"):
                continue
            if fields[0] == "MAP":
                self.width, self.height = map(int, fields[1:])
            elif fields[0] == "UNIT_LIMIT":
                self.unit_limit = int(fields[1])
            elif fields[0] == "EDGE":
                identifier, kind, portal = map(int, fields[1:])
                row, x = divmod(identifier, self.width + 1)
                key = (
                    x % self.width,
                    (row // 2) % self.height,
                    "W" if row % 2 else "N",
                )
                self.edges[key] = (
                    "w" if kind == 1 else str(portal) if kind == 2 else "."
                )
                if kind == 2 and key not in self.portals[portal]:
                    self.portals[portal].append(key)
            elif fields[0] == "DRAGON":
                values = list(map(int, fields[1:]))
                body = list(zip(values[2::2], values[3::2], strict=True))
                identifier = len(self.dragons)
                self.dragons[identifier] = {"team": "AB"[values[0]], "body": body}
        for identifier, dragon in self.dragons.items():
            body = dragon["body"]
            directions = [
                self.link_direction(body[i], body[i - 1]) for i in range(1, len(body))
            ]
            dragon["directions"] = [directions[0] if directions else "E", *directions]
            self.index_dragon(identifier)

    def adjacent(self, position, direction):
        dx, dy = OFFSETS[DIRECTIONS.index(direction)]
        return (position[0] + dx) % self.width, (position[1] + dy) % self.height

    def edge_key(self, position, direction):
        if direction in "SE":
            position = self.adjacent(position, direction)
        return (*position, "N" if direction in "NS" else "W")

    def step(self, position, direction):
        key = self.edge_key(position, direction)
        edge = self.edges.get(key, ".")
        if edge == "w":
            return None
        if edge == ".":
            return self.adjacent(position, direction)
        partner = [p for p in self.portals[int(edge)] if p != key]
        if len(partner) != 1:
            raise ValueError("Invalid portal pair")
        destination = partner[0][:2]
        return (
            self.adjacent(destination, direction) if direction in "NW" else destination
        )

    def link_direction(self, position, previous):
        candidates = [
            direction
            for direction in DIRECTIONS
            if self.step(position, direction) == previous
        ]
        if len(candidates) > 1 and self.lenient:
            self.ambiguous += 1
            return candidates[0]
        if len(candidates) != 1:
            raise ValueError(
                "Ambiguous body heading; observation cannot be reconstructed exactly"
            )
        return candidates[0]

    def sender_context(self, identifier):
        """What a pinging dragon knew when it pinged.

        Only the 7x7 window it can actually see, so a field that correlates with
        one of these values is something the sender could have encoded. Positions
        are also given as `x + width * y`, the linear form teams pack coordinates
        into, and distances are wrapped Manhattan distances.
        """
        dragon = self.dragons[identifier]
        head = dragon["body"][0]
        team = dragon["team"]
        window = [
            ((head[0] + dx) % self.width, (head[1] + dy) % self.height)
            for dy in range(-3, 4)
            for dx in range(-3, 4)
        ]

        def gap(a, b, size):
            direct = abs(a - b)
            return min(direct, size - direct)

        def distance(position):
            return gap(position[0], head[0], self.width) + gap(
                position[1], head[1], self.height
            )

        pearls = [position for position in window if position in self.pearls]
        enemies, allies = [], []
        for position in window:
            owner = self.occupied.get(position)
            if owner is None or not owner[3] or owner[1] == identifier:
                continue
            (enemies if owner[0] != team else allies).append(position)
        kelp = sum(
            1
            for position in window
            for direction in DIRECTIONS
            if self.edges.get(self.edge_key(position, direction)) == "w"
        )
        units = Counter(d["team"] for d in self.dragons.values())
        context = {
            "unit_count": units[team],
            "enemy_unit_count": units["B" if team == "A" else "A"],
            "team_total_length": sum(
                len(d["body"]) for d in self.dragons.values() if d["team"] == team
            ),
            "team_longest": max(
                (len(d["body"]) for d in self.dragons.values() if d["team"] == team),
                default=0,
            ),
            "seen_pearls": len(pearls),
            "seen_enemy_heads": len(enemies),
            "seen_ally_heads": len(allies),
            "seen_kelp_edges": kelp,
        }
        for name, positions in (
            ("pearl", pearls),
            ("enemy", enemies),
            ("ally", allies),
        ):
            nearest = min(positions, key=distance, default=None)
            context[f"nearest_{name}_x"] = nearest[0] if nearest else 0
            context[f"nearest_{name}_y"] = nearest[1] if nearest else 0
            context[f"nearest_{name}_linear"] = (
                nearest[0] + self.width * nearest[1] if nearest else 0
            )
            context[f"nearest_{name}_distance"] = distance(nearest) if nearest else 0
        if enemies:
            nearest = min(enemies, key=distance)
            owner = self.occupied[nearest]
            context["nearest_enemy_id"] = owner[1]
            context["nearest_enemy_length"] = len(self.dragons[owner[1]]["body"])
        else:
            context["nearest_enemy_id"] = 0
            context["nearest_enemy_length"] = 0
        return context

    def unindex_dragon(self, identifier):
        for position in self.dragons[identifier]["body"]:
            self.occupied.pop(position, None)

    def index_dragon(self, identifier):
        dragon = self.dragons[identifier]
        for index, (position, direction) in enumerate(
            zip(dragon["body"], dragon["directions"], strict=True)
        ):
            self.occupied[position] = (
                dragon["team"],
                identifier,
                direction,
                index == 0,
            )

    def observe(self, identifier):
        dragon = self.dragons[identifier]
        x, y = dragon["body"][0]
        team = dragon["team"]
        init = (
            f"ID {identifier}\nTEAM {team}\nMAP {self.width} {self.height}\n"
            f"UNIT_LIMIT {self.unit_limit}\n"
        )
        messages = self.messages.pop(identifier, [])
        echoes = self.echoes.pop(identifier, [0] * 5)
        lines = [
            f"ROUND {self.round}",
            f"FACING {dragon['directions'][0]}",
            f"LENGTH {len(dragon['body'])}",
            f"UNIT_COUNT {sum(d['team'] == team for d in self.dragons.values())}",
            f"SONAR {len(messages)}",
            *map(str, messages),
            "ECHOES " + " ".join(map(str, echoes)),
        ]
        visible = [
            ((x + dx) % self.width, (y + dy) % self.height)
            for dy in range(-3, 4)
            for dx in range(-3, 4)
        ]
        for position in visible:
            due = self.due.get(position)
            countdown = -1 if due is None else max(0, due - self.round)
            lines.append(
                f"{position[0]} {position[1]} "
                f"{int(position in self.pearls)} {countdown}"
            )
        parts = []
        for position in visible:
            if position in self.occupied:
                owner, unit, direction, is_head = self.occupied[position]
                parts.append(
                    f"{owner} {unit} {position[0]} {position[1]} "
                    f"{direction} {int(is_head)}"
                )
        lines += [f"DRAGONS {len(parts)}", *parts]
        for side, rows, columns in (("N", 8, 7), ("W", 7, 8)):
            for row in range(rows):
                lines.append(
                    " ".join(
                        self.edges.get(
                            (
                                (x - 3 + column) % self.width,
                                (y - 3 + row) % self.height,
                                side,
                            ),
                            ".",
                        )
                        for column in range(columns)
                    )
                )
        return init, "\n".join(lines) + "\n\n"

    def apply(self, event):
        kind = event["type"]
        if kind == "roundStart":
            self.round = event["round"]
        elif kind == "pearlCountdown":
            self.due[point(event["tile"])] = max(0, self.round) + event["countdown"]
        elif kind == "tileChange":
            position = point(event["tile"])
            if event["hasPearl"]:
                self.pearls.add(position)
            else:
                self.pearls.discard(position)
        elif kind == "dragonUpdate":
            identifier = event["id"]
            dragon = self.dragons[identifier]
            if self.round < 0:
                if dragon["body"][0] != point(event["head"]):
                    raise ValueError("Unexpected initial dragon placement")
                return
            self.unindex_dragon(identifier)
            direction = event["facing"][0].upper()
            dragon["directions"][0] = direction
            dragon["body"].insert(0, point(event["head"]))
            dragon["directions"].insert(0, direction)
            while len(dragon["body"]) > 1 and dragon["body"][-1] != point(
                event["tail"]
            ):
                dragon["body"].pop()
                dragon["directions"].pop()
            self.index_dragon(identifier)
        elif kind == "dragonSplit":
            parent = event["parentId"]
            child = event["childId"]
            self.unindex_dragon(parent)
            dragon = self.dragons[parent]
            dragon["body"] = [point(p) for p in event["parentBody"]]
            dragon["directions"] = dragon["directions"][: len(dragon["body"])]
            self.index_dragon(parent)
            body = [point(p) for p in event["childBody"]]
            self.dragons[child] = {
                "team": event["team"].upper(),
                "body": body,
                "directions": [
                    event["childFacing"][0].upper(),
                    *[
                        self.link_direction(body[i], body[i - 1])
                        for i in range(1, len(body))
                    ],
                ],
            }
            self.index_dragon(child)
        elif kind == "dragonDeath":
            self.unindex_dragon(event["id"])
            del self.dragons[event["id"]]
        elif kind == "sonarPing":
            value = event["value64"]
            if "hitId" in event:
                self.messages[event["hitId"]].append(value)
            if event["hitKind"] >= 2:
                self.echoes[event["senderId"]][event["hitKind"] - 2] += 1


def extract_replay(
    path: Path,
    submissions: dict | None = None,
    lenient: bool = False,
    decisions_wanted: bool = True,
):
    replay = read_replay(path)
    if replay["formatVersion"] != 2:
        raise ValueError("Exact observations require version 2 sonar echo events")
    state = ReplayState(replay["map"], lenient)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    decisions = []
    sonars = []
    pending = {}
    pre_action = {}
    for event in replay["events"]:
        kind = event["type"]
        if kind == "turnStart":
            identifier = event["id"]
            if decisions_wanted:
                pending[identifier] = state.observe(identifier)
            dragon = state.dragons[identifier]
            pre_action[identifier] = {
                "pre_x": dragon["body"][0][0],
                "pre_y": dragon["body"][0][1],
                "pre_length": len(dragon["body"]),
                "pre_facing": DIRECTIONS.index(dragon["directions"][0]),
            }
        elif kind == "dragonAction":
            identifier = event["id"]
            if not decisions_wanted:
                state.apply(event)
                continue
            team = state.dragons[identifier]["team"]
            action = event.get("action")
            if action is None:
                label = "NO_ACTION"
            elif "move" in action:
                label = "MOVE " + "".join(d[0].upper() for d in action["move"])
            elif "split" in action:
                label = f"SPLIT {action['split']}"
            else:
                label = "SUICIDE"
            init, observation = pending.pop(identifier)
            decisions.append(
                DecisionSample(
                    digest,
                    team,
                    identifier,
                    state.round,
                    (submissions or {}).get(team),
                    init,
                    observation,
                    (label,),
                    "recorded",
                )
            )
        elif kind == "sonarPing":
            dragon = state.dragons[event["senderId"]]
            receiver = event.get("hitId")
            sonars.append(
                {
                    **event,
                    **pre_action[event["senderId"]],
                    **state.sender_context(event["senderId"]),
                    "replay": digest,
                    "round": state.round,
                    "team": dragon["team"],
                    "head_x": dragon["body"][0][0],
                    "head_y": dragon["body"][0][1],
                    "length": len(dragon["body"]),
                    "facing": DIRECTIONS.index(dragon["directions"][0]),
                    "width": state.width,
                    "height": state.height,
                    "receiver_team": (
                        state.dragons[receiver]["team"]
                        if receiver in state.dragons
                        else None
                    ),
                    "receiver_length": (
                        len(state.dragons[receiver]["body"])
                        if receiver in state.dragons
                        else 0
                    ),
                }
            )
        state.apply(event)
    return decisions, sonars


def extract_decisions(replay_path: Path, lenient: bool = False) -> list[DecisionSample]:
    return extract_replay(replay_path, lenient=lenient)[0]


def extract_sonar(replay_path: Path, lenient: bool = False) -> list[dict]:
    """Sonar rows only. The state machine is the same one the decision samples
    use, minus the 7x7 observation strings, which sonar decoding never reads and
    which cost most of the runtime."""
    return extract_replay(replay_path, lenient=lenient, decisions_wanted=False)[1]
