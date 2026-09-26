"""Rate a pool of bots against each other from one round robin.

    just ladder --bots starter-c room-c first-bot --maps maps/*.map \\
        --seeds 1 --output results/ladder

Every pair plays on every map from both sides, through the round-robin harness.
The ratings are then fitted to all the games at once (a Bradley-Terry model),
so they don't depend on the order the games were played in. They're printed on
the Elo scale: 400 points is ten-to-one odds. Draws count as half a win each way,
and errors are left out. The table of head-to-head results is printed too,
because a single rating can hide a pool where A beats B, B beats C and C beats A.
"""

import math

ELO_SCALE = 400 / math.log(10)


def head_to_head(bots: list[str], games: list) -> dict[tuple[str, str], float]:
    """Points each bot scored against each other bot: 1 for a win, 1/2 for a draw."""
    scores = {(a, b): 0.0 for a in bots for b in bots if a != b}
    for game in games:
        if game.error:
            continue
        a, b = game.team_a_bot, game.team_b_bot
        if game.winner is None:
            scores[a, b] += 0.5
            scores[b, a] += 0.5
        else:
            winner, loser = (a, b) if game.winner == "A" else (b, a)
            scores[winner, loser] += 1
    return scores


def fit_ratings(
    bots: list[str], scores: dict[tuple[str, str], float], iterations: int = 2000
) -> dict[str, float]:
    """Bradley-Terry strengths by the classic minorisation-maximisation update,
    with a small prior of one draw against an average bot, so a bot that won or
    lost every game still gets a finite rating."""
    strength = dict.fromkeys(bots, 1.0)
    for _ in range(iterations):
        updated = {}
        for bot in bots:
            points = 0.5 + sum(scores[bot, other] for other in bots if other != bot)
            weight = 1 / (strength[bot] + 1)
            for other in bots:
                if other != bot:
                    games = scores[bot, other] + scores[other, bot]
                    weight += games / (strength[bot] + strength[other])
            updated[bot] = points / weight
        # Keep the average strength at 1, which puts the average rating at 1500.
        mean_log = sum(math.log(value) for value in updated.values()) / len(bots)
        strength = {bot: value / math.exp(mean_log) for bot, value in updated.items()}
    return {bot: 1500 + ELO_SCALE * math.log(strength[bot]) for bot in bots}
