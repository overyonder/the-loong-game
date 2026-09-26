"""Decide whether a candidate bot is better than the baseline it changes.

    just verdict --candidate tactics-coil --baseline roles-bot --behaviour Coil \\
        --maps maps/*.map --seeds 4 --output results/coil

Every game is paired. The candidate plays the baseline on each map, side and seed, and the
same game is played with the baseline in the candidate's seat. Seeded games are
deterministic, so where the change never fires the two games are identical and cancel out.
Only pairs whose result changed count, each weighted by the share of the candidate's turns
in which the changed behaviour was active, as the bot reports it in its indicator.

The p values come from random sign flips of those weighted changes: how often a coin
deciding each change's direction does at least as well. The candidate and baseline also play
each weak bot on the same seeds. A candidate that loses more games to weak bots than it wins
back isn't better, however it does head to head, and one that loses significantly more is worse.
Every such loss is listed. Wins are compared by length too.
"""

import hashlib
import random
import re
import statistics
from pathlib import Path

from harness.round_robin import PlayedGame

# A dragon's turn in `unswbc run -v`: its stdout, up to the next line the toolkit writes.
TURN = re.compile(
    r"^round \d+: bot \d+ \(team (?P<team>[AB])\) stdout:\n(?P<output>(?:(?!round \d).*\n)*)",
    re.MULTILINE,
)
INDICATOR = re.compile(r"^INDICATOR (.*)$", re.MULTILINE)


def paired_seed(base_seed: str, map_path: str, repeat: int) -> str:
    """The same seed for every game on one map and repeat, whichever bots play it."""
    return (
        "0x"
        + hashlib.sha256(f"{base_seed}/{map_path}/{repeat}".encode()).digest()[:8].hex()
    )


def score(game: PlayedGame, side: str) -> float | None:
    if game.error:
        return None
    return 0.5 if game.winner is None else float(game.winner == side)


def activation(game: PlayedGame, side: str, behaviours: list[str]) -> float:
    """Share of the side's dragon-turns whose indicator names one of the behaviours."""
    turns = [
        " ".join(INDICATOR.findall(match["output"]))
        for match in TURN.finditer(Path(game.log_path).read_text(errors="replace"))
        if match["team"] == side
    ]
    if not turns:
        return 0.0
    return sum(
        any(word in turn.split() for word in behaviours) for turn in turns
    ) / len(turns)


def sign_flip_p_values(
    changes: list[float], trials: int = 200_000
) -> tuple[float, float]:
    """P(a random sign on each change sums to at least, and at most, the observed total)."""
    changes = [change for change in changes if change]
    if not changes:
        return 1.0, 1.0
    observed = sum(changes)
    magnitudes = [abs(change) for change in changes]
    generator = random.Random(0)
    at_least = at_most = 0
    for _ in range(trials):
        total = sum(
            magnitude if generator.random() < 0.5 else -magnitude
            for magnitude in magnitudes
        )
        at_least += total >= observed - 1e-12
        at_most += total <= observed + 1e-12
    return at_least / trials, at_most / trials


def changed_games_needed(gained: int, dropped: int, significance: float) -> int | None:
    """Changed games needed to tell this gained share from an even one with 80% power."""
    if gained + dropped == 0 or gained == dropped:
        return None
    share = gained / (gained + dropped)
    z_significance = statistics.NormalDist().inv_cdf(1 - significance)
    z_power = statistics.NormalDist().inv_cdf(0.8)
    spread = z_significance * 0.5 + z_power * (share * (1 - share)) ** 0.5
    return int(-(-((spread / abs(share - 0.5)) ** 2) // 1))
