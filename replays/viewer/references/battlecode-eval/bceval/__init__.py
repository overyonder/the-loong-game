"""bceval: a learned position evaluation for UNSW Battlecode replays.

    from bceval import evaluate_replay
    for r in evaluate_replay("game.replay"):
        print(r["after_round"], r["p_a"])
"""
from .features import TEAM_FEATURES, replay_features
from .score import GROUPS, load_model, logit_parts, win_probability

__all__ = ["evaluate_replay", "replay_features", "win_probability", "logit_parts",
           "load_model", "TEAM_FEATURES", "GROUPS"]
__version__ = "0.1.0"


def evaluate_replay(path, every=1, model=None):
    """Side A's win probability after each round of a replay.

    A list of {"after_round", "p_a", "parts"}. The board at the start of round
    t is the board after round t-1; the last entry is the board after the final
    round. `parts` splits the log-odds into GROUPS, to show what moves it."""
    game, rows = replay_features(path, every)
    out = []
    for row in rows:
        after = game["last_round"] if row["round"] == 501 else row["round"] - 1
        parts = logit_parts(row["round"], row["a"], row["b"], model)
        out.append({"after_round": after, "p_a": win_probability(row["round"], row["a"], row["b"], model),
                    "parts": parts})
    return out
