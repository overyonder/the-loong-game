"""Decide whether a candidate is better than its opponents, sequentially.

A run is planned by power. The effect to detect (default +70 Elo, a 60% score),
the one-sided error α (0.05) and the power (80%) give each opponent's planned
maximum: the games a fixed-size test at the same error rates would need, 155
at the defaults.

Each opponent gets Wald's sequential probability ratio test of a 50% score
against the effect's score, on the candidate's direct games scored 1, ½ or 0.
After every game the log-likelihood ratio moves by ln(p/0.5) for a win and
ln((1 − p)/0.5) for a loss, a draw by half of each. The test stops at
ln((1 − β)/α) ("better") or ln(β/(1 − α)) ("not better"), where β = 1 − power.
Straight wins decide in 16 games at the defaults. A test still undecided at the
planned maximum reads "no material difference".

The schedule interleaves from the first game: each map, shuffled per seed, is
played against every opponent as a side-swapped pair before the next map, so an
early stop rests on many maps, both sides and every opponent. The test reads the
longest completed prefix of that order, never arrival order, so games that
finish quickly cannot decide a run by arriving first. Ten games against the
upset bot (default starter-c, which moves at random), spread over the first
maps, check for upsets: any game not won is a fault to watch in the viewer.

Close versions of one bot win by side, not by strength, so a candidate can be
judged by matched pairs instead: with `--baseline`, the candidate and the
baseline both play every fixture (map, seed, side, opponent) against the common
opponents, and each test counts only the fixtures the two play differently, 1
where the candidate scores more and 0 where the baseline does. Ties are counted
and reported. The planned maximum then counts these discordant fixtures, with
at most twice as many fixtures played.
"""

import math
import random
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from statistics import NormalDist

# Bots are directories named relative to the working directory, examples/tooling.
OPPONENTS = ["room-c"]
UPSET_BOT = "starter-c"
EFFECT_ELO = 70.0
ALPHA = 0.05
POWER = 0.8
UPSET_GAMES = 10


def default_maps() -> list[Path]:
    """The organiser's maps and the generated ones, as `just article-bots` and
    `just mapgen` leave them."""
    return [
        path
        for folder in ("maps", "maps-generated")
        for path in sorted(Path(folder).glob("*.map"))
    ]


def plan_arguments(parser) -> None:
    """The options that fix a sequential run's plan; the runner records them."""
    parser.add_argument(
        "--opponents",
        nargs="+",
        default=OPPONENTS,
        help=f"Opponents, each with its own test (default: {' '.join(OPPONENTS)})",
    )
    parser.add_argument(
        "--baseline",
        help="Judge by matched pairs against this bot over the common opponents, "
        "as for close versions of one bot",
    )
    parser.add_argument(
        "--effect-elo",
        type=float,
        default=EFFECT_ELO,
        help=f"Smallest edge worth detecting (default {EFFECT_ELO:g} Elo)",
    )
    parser.add_argument("--alpha", type=float, default=ALPHA)
    parser.add_argument("--power", type=float, default=POWER)
    parser.add_argument(
        "--upset-bot",
        default=UPSET_BOT,
        help=f"Weak bot the candidate should always beat (default {UPSET_BOT})",
    )
    parser.add_argument(
        "--upset-games",
        type=int,
        default=UPSET_GAMES,
        help=f"Games against the upset bot; any not won is a fault "
        f"(default {UPSET_GAMES})",
    )
    parser.add_argument(
        "--maps",
        nargs="+",
        type=Path,
        default=None,
        help="Map files (default: maps/*.map and maps-generated/*.map)",
    )
    parser.add_argument(
        "--seed-start",
        type=int,
        default=0,
        help="First seed index; a confirmation run uses seeds it never played",
    )


def plan(args, candidate: str) -> dict:
    """A run's plan from `plan_arguments`, as the runner records it."""
    maps = [path.resolve() for path in (args.maps or default_maps())]
    return {
        "candidate": candidate,
        "baseline": args.baseline,
        "opponents": args.opponents,
        "effect_elo": args.effect_elo,
        "alpha": args.alpha,
        "power": args.power,
        "cap": planned_games(args.effect_elo, args.alpha, args.power),
        "upset_bot": args.upset_bot,
        "upset_games": args.upset_games,
        "maps": [str(path) for path in maps],
        "seed_start": args.seed_start,
    }


def win_rate(edge: float) -> float:
    """The expected score of an Elo edge."""
    return 1 / (1 + 10 ** (-edge / 400))


def planned_games(effect_elo: float, alpha: float, power: float) -> int:
    """Games a fixed-size one-sided test needs to detect `effect_elo`.

    The sequential test's planned maximum per opponent: at the same error rates it
    decides sooner on average and never needs more than a fixed test would.
    """
    z = NormalDist().inv_cdf
    target = win_rate(effect_elo)
    spread = z(1 - alpha) * 0.5 + z(power) * math.sqrt(target * (1 - target))
    return math.ceil((spread / (target - 0.5)) ** 2)


@dataclass
class Sprt:
    """Wald's test of a 50% score against the effect's score, one opponent."""

    effect_elo: float = EFFECT_ELO
    alpha: float = ALPHA
    power: float = POWER
    llr: float = 0.0
    games: int = 0
    decided_at: int | None = None
    trace: list = field(default_factory=list)

    def __post_init__(self):
        target = win_rate(self.effect_elo)
        self.win = math.log(target / 0.5)
        self.loss = math.log((1 - target) / 0.5)
        self.upper = math.log(self.power / self.alpha)
        self.lower = math.log((1 - self.power) / (1 - self.alpha))
        self.cap = planned_games(self.effect_elo, self.alpha, self.power)

    @property
    def done(self) -> bool:
        return self.decided_at is not None or self.games >= self.cap

    def add(self, score: float) -> None:
        """Count one game; a decided or capped test takes no more."""
        if self.done:
            return
        self.games += 1
        self.llr += score * self.win + (1 - score) * self.loss
        self.trace.append(round(self.llr, 4))
        if self.llr >= self.upper or self.llr <= self.lower:
            self.decided_at = self.games

    @property
    def decision(self) -> str:
        if self.decided_at is not None:
            return "better" if self.llr >= self.upper else "not better"
        return "no material difference" if self.games >= self.cap else "undecided"

    def summary(self) -> dict:
        return {
            "decision": self.decision,
            "llr": round(self.llr, 4),
            "lower": round(self.lower, 4),
            "upper": round(self.upper, 4),
            "games": self.games,
            "decided_at": self.decided_at,
            "cap": self.cap,
        }


def schedule(plan: dict) -> list[dict]:
    """The interleaved order a sequential run plays.

    Per seed index, maps are shuffled (seeded by the index, so the order is
    reproducible); each map is played against every opponent that still needs
    games as a side-swapped pair, and the first maps also carry the upset
    pairs. With a baseline, each side of the pair is a fixture both the candidate
    and the baseline play, back to back. Each entry names its `player`, the side
    it plays and the fixture it belongs to. An opponent is scheduled up to its
    planned maximum of fixtures, twice that with a baseline, since only fixtures
    the two play differently count.
    """
    maps = [Path(name) for name in plan["maps"]]
    opponents, cap = plan["opponents"], plan["cap"]
    baseline = plan.get("baseline")
    players = [plan["candidate"], *([baseline] if baseline else [])]
    fixtures = cap * (2 if baseline else 1)
    needed = {opponent: fixtures + fixtures % 2 for opponent in opponents}
    # A run that tests the upset bot directly needs no separate upset check.
    upset_bot = plan["upset_bot"]
    upsets = (
        0 if upset_bot in opponents else plan["upset_games"] + plan["upset_games"] % 2
    )
    order, index, fixture = [], plan["seed_start"], 0
    while any(needed.values()) or upsets:
        shuffled = sorted(maps)
        random.Random(index).shuffle(shuffled)
        for path in shuffled:
            seed = zlib.crc32(f"{path.name}:{index}".encode())
            pairs = [o for o in opponents if needed[o]]
            if upsets:
                pairs.append(upset_bot)
            for opponent in pairs:
                upset = opponent == upset_bot and opponent not in needed
                for side in ("A", "B"):
                    for player in players[:1] if upset else players:
                        order.append(
                            {
                                "opponent": opponent,
                                "map": path,
                                "seed": seed,
                                "side": side,
                                "player": player,
                                "fixture": fixture,
                            }
                        )
                    fixture += 1
                if upset:
                    upsets -= 2
                else:
                    needed[opponent] -= 2
            if not any(needed.values()) and not upsets:
                break
        index += 1
    return order


def teams(entry: dict) -> tuple[str, str]:
    """(side A, side B) of a scheduled game."""
    player, opponent = entry["player"], entry["opponent"]
    return (player, opponent) if entry["side"] == "A" else (opponent, player)


def score(game: dict, side: str) -> float | None:
    """The score of the player on `side` of a game: 1, ½ or 0; None if it
    errored. By side, not name: with the baseline also an opponent, the
    baseline's own games have it on both sides."""
    if game["status"] != "completed":
        return None
    if game["winner_side"] is None:
        return 0.5
    return 1.0 if game["winner_side"] == side else 0.0


def judge(plan: dict, played: dict[int, dict]) -> dict:
    """Every opponent's test over the completed prefix of the schedule.

    `played` maps schedule positions to game records. An errored game ends the
    prefix like an unplayed one: the resumed run plays it again. Without a
    baseline, each of the candidate's games against an opponent counts its
    score. With one, each fixture both played counts once the second lands: 1
    where the candidate scored more, 0 where the baseline did; a tie carries no
    evidence and counts in `ties`.
    """
    order = schedule(plan)
    tests = {
        opponent: Sprt(plan["effect_elo"], plan["alpha"], plan["power"])
        for opponent in plan["opponents"]
    }
    ties = {opponent: 0 for opponent in plan["opponents"]}
    fixtures = {opponent: 0 for opponent in plan["opponents"]}
    candidate, baseline = plan["candidate"], plan.get("baseline")
    upsets, faults, prefix, pending, used = 0, [], 0, {}, []
    for position, entry in enumerate(order):
        game = played.get(position)
        result = score(game, entry["side"]) if game else None
        if result is None:
            break
        prefix = position + 1
        opponent = entry["opponent"]
        if opponent not in tests:
            upsets += 1
            if result < 1:
                faults.append({**game, "position": position})
        elif not baseline:
            fixtures[opponent] += 1
            if not tests[opponent].done:
                used.append(position)
            tests[opponent].add(result)
        elif entry["fixture"] not in pending:
            pending[entry["fixture"]] = (entry["player"], result, position)
        else:
            other, earlier, first = pending.pop(entry["fixture"])
            mine = result if entry["player"] == candidate else earlier
            theirs = earlier if entry["player"] == candidate else result
            fixtures[opponent] += 1
            if tests[opponent].done:
                continue
            used += [first, position]
            if mine == theirs:
                ties[opponent] += 1
            else:
                tests[opponent].add(1.0 if mine > theirs else 0.0)
    limit = plan["cap"] * (2 if baseline else 1)
    done = all(
        test.done or fixtures[opponent] >= limit for opponent, test in tests.items()
    )
    return {
        "tests": tests,
        "used": used,
        "ties": ties,
        "fixtures": fixtures,
        "upsets": upsets,
        "faults": faults,
        "prefix": prefix,
        "done": done and (plan["upset_bot"] in tests or upsets >= plan["upset_games"]),
    }


def wanted(plan: dict, played: dict[int, dict], running: set[int]) -> list[int]:
    """Schedule positions still worth starting, in order.

    An opponent whose test has decided, or whose fixtures reach the limit, gets
    no more; nor do the upset games once the check has enough.
    """
    order = schedule(plan)
    state = judge(plan, played)
    baseline = plan.get("baseline")
    limit = plan["cap"] * (2 if baseline else 1)
    counted, positions = {}, []
    for position, entry in enumerate(order):
        opponent = entry["opponent"]
        test = state["tests"].get(opponent)
        allowed = plan["upset_games"] if test is None else 0 if test.done else limit
        key = (opponent, entry["player"])
        if counted.get(key, 0) >= allowed:
            continue
        counted[key] = counted.get(key, 0) + 1
        if position not in played or played[position]["status"] != "completed":
            if position not in running:
                positions.append(position)
    return positions
