"""Local logistic Elo; ratings are relative to this pool, not an online ladder."""


def update_ratings(
    ratings: dict[str, float], first: str, second: str, score: float, k: float = 24.0
) -> None:
    expected = 1 / (1 + 10 ** ((ratings[second] - ratings[first]) / 400))
    change = k * (score - expected)
    ratings[first] += change
    ratings[second] -= change


def rate_games(names, games, initial: float = 1500.0, k: float = 24.0) -> dict:
    ratings = dict.fromkeys(names, initial)
    for game in games:
        if game["status"] != "completed":
            continue
        score = (
            0.5 if game["winner_side"] is None else float(game["winner_side"] == "A")
        )
        update_ratings(ratings, game["A"], game["B"], score, k)
    return ratings


def pairing_rounds(names: list[str], rounds: int) -> list[list[tuple[str, str]]]:
    """Circle schedule: n-1 rounds meet everyone; next cycle reverses sides."""
    if len(names) < 2 or len(set(names)) != len(names):
        raise ValueError("Require at least two distinct bots")
    rotation = list(names) + ([None] if len(names) % 2 else [])
    size = len(rotation)
    cycle = []
    for index in range(size - 1):
        pairs = list(
            zip(
                rotation[: size // 2],
                reversed(rotation[size // 2 :]),
                strict=True,
            )
        )
        pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
        if index % 2:
            pairs = [(right, left) for left, right in pairs]
        cycle.append(pairs)
        rotation = [rotation[0], rotation[-1], *rotation[1:-1]]
    return [
        [(right, left) for left, right in cycle[index % len(cycle)]]
        if (index // len(cycle)) % 2
        else cycle[index % len(cycle)]
        for index in range(rounds)
    ]
