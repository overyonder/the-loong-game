"""Bradley–Terry ratings fitted offline to every game at once, on the Elo scale.

A bot with strength s beats one with strength t with probability s / (s + t).
Fitting all games together, instead of updating after each one, makes the
ratings independent of the order the games were played in. Ratings are
1500 + 400 * log10(s), so 400 points is ten-to-one odds. A draw is half a win
for each side, and failed executions are left out. A prior of one draw against
a 1500-rated bot keeps a bot that won or lost every game finite. The fit is
shifted so the pool averages 1500; ratings describe this pool only.
"""

import math

ELO_SCALE = 400 / math.log(10)


def head_to_head(bots: list[str], games: list) -> dict[tuple[str, str], float]:
    """Points each bot scored against each other bot: 1 for a win, 1/2 for a draw."""
    scores = {(a, b): 0.0 for a in bots for b in bots if a != b}
    for game in games:
        if game["status"] != "completed":
            continue
        a, b = game["A"], game["B"]
        if game["winner_side"] is None:
            scores[a, b] += 0.5
            scores[b, a] += 0.5
        else:
            winner, loser = (a, b) if game["winner_side"] == "A" else (b, a)
            scores[winner, loser] += 1
    return scores


def fit_ratings(
    bots: list[str], games: list, start: dict[str, float] | None = None
) -> dict[str, float]:
    """Maximum a posteriori ratings by Newton's method on the log-posterior.

    The log-posterior is concave in log strength, so each step solves the
    system its Hessian gives; `start`, earlier ratings, only saves steps.
    """
    scores = head_to_head(bots, games)
    size = len(bots)
    points = [
        0.5 + sum(scores[bot, other] for other in bots if other != bot) for bot in bots
    ]
    played = [
        [scores[a, b] + scores[b, a] if a != b else 0.0 for b in bots] for a in bots
    ]
    theta = [((start or {}).get(bot, 1500.0) - 1500) / ELO_SCALE for bot in bots]
    for _ in range(100):
        # Gradient and negated Hessian, the prior game against strength 1 included.
        gradient = points[:]
        hessian = [[0.0] * size for _ in range(size)]
        for i in range(size):
            expected = 1 / (1 + math.exp(-theta[i]))
            gradient[i] -= expected
            hessian[i][i] += expected * (1 - expected)
            for j in range(size):
                if played[i][j]:
                    expected = 1 / (1 + math.exp(theta[j] - theta[i]))
                    gradient[i] -= played[i][j] * expected
                    curvature = played[i][j] * expected * (1 - expected)
                    hessian[i][i] += curvature
                    hessian[i][j] -= curvature
        step = solve(hessian, gradient)
        # Far from the optimum a full step can overshoot; one unit is 174 points.
        largest = max(abs(value) for value in step)
        scale = min(1.0, 1 / largest) if largest else 1.0
        theta = [
            value + scale * change for value, change in zip(theta, step, strict=True)
        ]
        if largest < 1e-10:
            break
    mean = sum(theta) / size
    return {
        bot: 1500 + ELO_SCALE * (value - mean)
        for bot, value in zip(bots, theta, strict=True)
    }


def solve(matrix: list[list[float]], vector: list[float]) -> list[float]:
    """Solve a symmetric positive-definite system by Cholesky decomposition."""
    size = len(vector)
    lower = [[0.0] * size for _ in range(size)]
    for i in range(size):
        for j in range(i + 1):
            total = matrix[i][j] - sum(lower[i][k] * lower[j][k] for k in range(j))
            lower[i][j] = math.sqrt(total) if i == j else total / lower[j][j]
    forward = [0.0] * size
    for i in range(size):
        forward[i] = (
            vector[i] - sum(lower[i][k] * forward[k] for k in range(i))
        ) / lower[i][i]
    result = [0.0] * size
    for i in reversed(range(size)):
        result[i] = (
            forward[i] - sum(lower[k][i] * result[k] for k in range(i + 1, size))
        ) / lower[i][i]
    return result
