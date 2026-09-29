"""The evaluation: P(side A wins) from the two teams' features at a round.

An antisymmetric logistic model. Every input is a difference between the
teams, there is no intercept, and the weights change with the round: each
feature has one weight per knot round (0, 125, 250, 375, 500), interpolated
linearly between them. A level position scores 0.5 apart from the side term
(side B has a small measured edge), and swapping the teams gives 1 - p.
"""
import json
import math
import os

MODEL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model.json")
GROUPS = {
    "bodies": ["alive", "total", "longest", "second", "third", "big5", "big10"],
    "economy": ["eat", "eat_rich", "eat_hot"],
    "fights": ["deaths", "lost_len", "kills_h2h"],
    "ground": ["terr", "supply", "rich_ctrl", "hot_ctrl", "pearls_near"],
    "champion": ["champ_enemy_d", "champ_enemy_n3", "champ_enemy_n6", "champ_ally_d", "champ_exits"],
    "side": ["side"],
}
_model = None


def load_model(path=MODEL_PATH):
    with open(path) as f:
        return json.load(f)


def _default():
    global _model
    if _model is None:
        _model = load_model()
    return _model


def _hats(r, knots):
    r = min(max(r, knots[0]), knots[-1])
    out = []
    for i, k in enumerate(knots):
        lo = knots[i - 1] if i else None
        hi = knots[i + 1] if i + 1 < len(knots) else None
        if r == k:
            out.append(1.0)
        elif lo is not None and lo <= r < k:
            out.append((r - lo) / (k - lo))
        elif hi is not None and k < r <= hi:
            out.append((hi - r) / (hi - k))
        else:
            out.append(0.0)
    return out


def _diff(kind, a, b, scale):
    if kind == "log":
        return math.log1p(max(a, 0)) - math.log1p(max(b, 0))
    if kind == "share":
        s = a + b
        return a / s - 0.5 if s > 0 else 0.0
    return (a - b) / scale


def logit_parts(round_, a, b, model=None):
    """The log-odds that side A wins, split into GROUPS ({group: value})."""
    model = model or _default()
    h = _hats(round_, model["knots"])
    group_of = {f: g for g, fs in GROUPS.items() for f in fs}
    parts = {g: 0.0 for g in GROUPS}
    for f, kind in model["features"].items():
        d = _diff(kind, float(a[f]), float(b[f]), model["lin_scale"].get(f, 1.0))
        parts[group_of.get(f, "bodies")] += d * sum(w * x for w, x in zip(model["weights"][f], h))
    parts["side"] += sum(w * x for w, x in zip(model["weights"]["side"], h))
    return parts


def win_probability(round_, a, b, model=None):
    """P(side A wins) given each team's features (dicts keyed by TEAM_FEATURES)."""
    z = sum(logit_parts(round_, a, b, model).values())
    return 1.0 / (1.0 + math.exp(-max(-40.0, min(40.0, z))))
