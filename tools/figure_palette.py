"""Colours shared by the architecture diagrams and the code maps.

Each part of a bot keeps one colour everywhere it's drawn, so a box in a block
diagram and the box over the same code in a code map match.
"""

PAPER, CARD, INK, MUTED, RULE = "#ede5d5", "#f6f1e7", "#20251f", "#66675e", "#b9ad99"

COMPONENTS = {  # key: (colour, label)
    "window":  ("#3f6e8c", "Read the 7×7 window"),
    "sonar":   ("#2f7f79", "Sonar"),
    "safety":  ("#b53b13", "Safety layer"),
    "frame":   ("#a8801a", "State machine"),
    "roam":    ("#5d8a2e", "Roam"),
    "evade":   ("#7a4f8a", "Evade"),
    "hunt":    ("#a23b5f", "Hunt"),
    "split":   ("#6f6a5f", "Split"),
    "coil":    ("#4f5d99", "Coil"),
    "forage":  ("#8f8a25", "Forage"),
    "deliver": ("#9c5b2e", "Deliver"),
}


def colour(key):
    return COMPONENTS[key][0]
