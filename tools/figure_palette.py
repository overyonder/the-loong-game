"""Colours and the typeface for the article figures, from over|yonder's design tokens.

over-yonder.tech owns every colour, in https://over-yonder.tech/styles/tokens.css, and the
figures read it each time they're drawn. Each part of a bot keeps one colour everywhere it's
drawn, so a box in a block diagram and the box over the same code in a code map match.
"""

import re
import urllib.request

TOKENS = "https://over-yonder.tech/styles/tokens.css?v=5"


def read_tokens(url=TOKENS):
    """Every token's light-scheme value, with var() references resolved and colour functions
    written without spaces, as the figures write them."""
    # Cloudflare refuses urllib's default user agent.
    request = urllib.request.Request(url, headers={"User-Agent": "the-loong-game figure tools"})
    try:
        light = urllib.request.urlopen(request, timeout=30).read().decode().split("@media", 1)[0]
    except OSError as error:
        raise SystemExit(f"figure_palette: can't read the site's colours from {url}: {error}") from error
    values = dict(re.findall(r"--([\w-]+):\s*([^;]+);", light))

    def resolve(value):
        value = re.sub(r"var\(--([\w-]+)\)", lambda match: resolve(values[match.group(1)]), value.strip())
        return re.sub(r"\s*([(),])\s*", r"\1", value) if value.startswith("rgb") else value

    return {name: resolve(value) for name, value in values.items()}


TOKEN = read_tokens()

PAPER, PALE, CARD, INK, MUTED, RULE = (TOKEN[name] for name in ("paper", "paper-deep", "card", "ink", "muted", "rule"))
FOREST, BOARD, BOARD_GRID, SIGNAL, HOT, WHITE = (TOKEN[name] for name in ("forest", "board", "board-grid", "signal-ink", "signal-hot", "white"))
DARK_RULE, DARK_MUTED, DARK_TEXT, DARK_LINE, DARK_TITLE = (TOKEN[name] for name in ("dark-rule", "dark-muted", "dark-text", "dark-line", "dark-title"))
BLUE, TEAL, GOLD, GREEN, PURPLE, ROSE, STONE, INDIGO, OLIVE, RUST, CLAY, SLATE = (TOKEN[name] for name in (
    "blue", "teal", "gold", "green", "purple", "rose", "stone", "indigo", "olive", "rust", "clay", "slate"))
LIGHT_GREEN, LIGHT_GOLD, LIGHT_ORANGE = (TOKEN[name] for name in ("light-green", "light-gold", "light-orange"))
GRUVBOX = {name.removeprefix("gruvbox-"): value for name, value in TOKEN.items() if name.startswith("gruvbox-")}
FONT = TOKEN["diagram-font"]

# A board's pieces: kelp walls, pearls, our dragons, theirs, and a teammate.
KELP, PEARL, OURS, THEIRS, MATE = LIGHT_GREEN, LIGHT_GOLD, HOT, WHITE, LIGHT_ORANGE

COMPONENTS = {  # key: (colour, label)
    "window":  (BLUE, "Read the 7×7 window"),
    "sonar":   (TEAL, "Sonar"),
    "safety":  (SIGNAL, "Safety layer"),
    "frame":   (GOLD, "State machine"),
    "roam":    (GREEN, "Roam"),
    "evade":   (PURPLE, "Evade"),
    "hunt":    (ROSE, "Hunt"),
    "split":   (STONE, "Split"),
    "coil":    (INDIGO, "Coil"),
    "forage":  (OLIVE, "Forage"),
    "deliver": (RUST, "Deliver"),
}


def colour(key):
    return COMPONENTS[key][0]
