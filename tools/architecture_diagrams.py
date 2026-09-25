"""Draw the block diagrams of the first, roles and tactics bots.

    python3 tools/architecture_diagrams.py blog/images

Each block takes its part's colour from figure_palette, the same colour its code
has in the code maps.
"""

import sys
from pathlib import Path

from figure_palette import CARD, INK, MUTED, PAPER, colour

SOFT_TEXT = "#f3ece0"


def text(x, y, value, size=13, fill=INK, anchor="middle", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" text-anchor="{anchor}"'
            f' font-weight="{weight}">{value}</text>')


def arrow(x1, y1, x2, y2, label=None):
    parts = [f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>']
    if label:
        parts.append(text((x1 + x2) / 2 + (14 if x1 == x2 else 0), (y1 + y2) / 2 - 4, label, 12, MUTED))
    return "\n".join(parts)


def card(x, y, width, height, title, lines, key, filled=False):
    """A block outlined in its part's colour, or filled with it for a behaviour."""
    fill, title_colour, line_colour = (colour(key), PAPER, SOFT_TEXT) if filled else (CARD, INK, MUTED)
    parts = [f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="7" fill="{fill}"'
             f' stroke="{colour(key)}" stroke-width="2.2"/>',
             text(x + width / 2, y + (26 if lines else height / 2 + 5.5), title, 16, title_colour, weight="bold")]
    for index, line in enumerate(lines):
        parts.append(text(x + width / 2, y + 48 + index * 18, line, 12.5, line_colour))
    return "\n".join(parts)


def chip(x, y, key, label):
    width = 14 + 7.4 * len(label)
    return (f'<rect x="{x}" y="{y}" width="{width:.0f}" height="22" rx="11" fill="{colour(key)}"/>'
            + text(x + width / 2, y + 15.5, label, 12, PAPER, weight="bold")), width


def role_card(x, y, width, title, behaviours):
    """A role in the state machine, with chips for the behaviours it may plug in."""
    parts = [f'<rect x="{x}" y="{y}" width="{width}" height="74" rx="7" fill="{CARD}" stroke="{colour("frame")}" stroke-width="2.2"/>',
             text(x + width / 2, y + 25, title, 16, INK, weight="bold")]
    widths = [14 + 7.4 * len(label) for _, label in behaviours]
    cursor = x + (width - sum(widths) - 6 * (len(widths) - 1)) / 2
    for key, label in behaviours:
        drawn, chip_width = chip(cursor, y + 40, key, label)
        parts.append(drawn)
        cursor += chip_width + 6
    return "\n".join(parts)


def svg(width, height, title, description, body):
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t d">',
        f'<title id="t">{title}</title>',
        f'<desc id="d">{description}</desc>',
        f'<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7"'
        f' orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{MUTED}"/></marker></defs>',
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        *body, "</svg>", ""])


def first_bot():
    body = [
        card(235, 20, 250, 62, "Read the 7×7 window", ["bodies, kelp, portals, enemy heads"], "window"),
        arrow(360, 82, 360, 108),
        card(160, 110, 400, 84, "Safety layer", ["drops moves into kelp, bodies and portals,", "and tiles next to an enemy head"], "safety"),
        arrow(360, 194, 360, 220),
        card(235, 222, 250, 62, "Choose a mode", ["enemy head within two tiles?"], "frame"),
        f'<path d="M300 284 L180 330" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        f'<path d="M420 284 L540 330" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        text(222, 307, "no", 12, MUTED), text(498, 307, "yes", 12, MUTED),
        card(60, 332, 240, 84, "Roam", ["score = room left", "after two moves"], "roam", filled=True),
        card(420, 332, 240, 84, "Evade", ["score = room left", "+ 4 × gap to the nearest head"], "evade", filled=True),
        f'<path d="M180 416 L300 448" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        f'<path d="M540 416 L420 448" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        card(235, 450, 250, 56, "Send the best safe move", [], "frame"),
    ]
    return svg(720, 520, "The first bot's structure",
               "Each turn the dragon reads its 7 by 7 window. A safety layer removes moves into kelp, portals, bodies"
               " and tiles next to an enemy head. A mode is chosen from what is visible: Roam when nothing threatens,"
               " Evade when an enemy head is within two tiles. The mode's behaviour scores the remaining moves and the"
               " best one is sent.", body)


def roles_bot():
    body = [
        card(40, 20, 280, 58, "Read sonar", ["longest teammate heard"], "sonar"),
        card(400, 20, 280, 58, "Read the 7×7 window", ["bodies, kelp, portals, enemy heads"], "window"),
        arrow(180, 78, 300, 106), arrow(540, 78, 420, 106),
        card(230, 108, 260, 58, "Pick a role", ["from length and the longest heard"], "frame"),
        arrow(300, 166, 130, 204), arrow(360, 166, 360, 204), arrow(420, 166, 590, 204),
        role_card(20, 206, 220, "Champion", [("roam", "Roam"), ("evade", "Evade"), ("split", "Split")]),
        role_card(250, 206, 220, "Worker", [("roam", "Roam"), ("evade", "Evade")]),
        role_card(480, 206, 220, "Kamikaze", [("roam", "Roam"), ("hunt", "Hunt")]),
        arrow(130, 280, 280, 306), arrow(360, 280, 360, 306), arrow(590, 280, 440, 306),
        card(170, 308, 380, 80, "Safety layer", ["no kelp, bodies or unseen portals; a hunting", "kamikaze alone may step next to an enemy head"], "safety"),
        arrow(360, 388, 360, 414),
        card(200, 416, 320, 58, "Score moves", ["with the chosen mode's behaviour"], "frame"),
        arrow(300, 474, 200, 500), arrow(420, 474, 520, 500),
        card(60, 502, 280, 58, "Move, or split", ["the best move, or a champion's split"], "frame"),
        card(380, 502, 280, 58, "Announce", ["team tag, ID, role and length"], "sonar"),
    ]
    return svg(720, 576, "The roles bot's structure",
               "Each turn the dragon reads its sonar and its window, then picks a role. The role limits its modes: the"
               " champion roams, evades and splits off kamikazes, a worker roams or evades, and a kamikaze roams or"
               " hunts. The safety layer removes deadly moves, the chosen mode's behaviour scores the rest, the best"
               " move is sent or the champion splits, and the dragon announces itself on sonar.", body)


def tactics_bot():
    body = [
        card(40, 20, 280, 58, "Read sonar", ["longest teammate and where it is"], "sonar"),
        card(400, 20, 280, 58, "Read the 7×7 window", ["bodies, pearls, the champion's body"], "window"),
        arrow(180, 78, 300, 106), arrow(540, 78, 420, 106),
        card(230, 108, 260, 58, "Pick a role", ["from length and the longest heard"], "frame"),
        arrow(300, 166, 130, 204), arrow(360, 166, 360, 204), arrow(420, 166, 590, 204),
        role_card(10, 206, 250, "Champion", [("evade", "Evade"), ("coil", "Coil"), ("roam", "Roam"), ("split", "Split")]),
        role_card(270, 206, 180, "Feeder", [("evade", "Evade"), ("forage", "Forage")]),
        role_card(460, 206, 250, "Kamikaze", [("roam", "Roam"), ("hunt", "Hunt")]),
        chip(166, 290, "deliver", "Deliver")[0],
        text(240, 305, "a feeder's sacrifice, switched off: it made the bot worse", 12, MUTED, "start"),
        arrow(360, 314, 360, 330),
        card(170, 332, 380, 80, "Safety layer", ["no kelp, bodies or unseen portals; a hunting", "kamikaze alone may step next to an enemy head"], "safety"),
        arrow(360, 412, 360, 438),
        card(200, 440, 320, 58, "Score moves", ["with the chosen mode's behaviour"], "frame"),
        arrow(300, 498, 200, 524), arrow(420, 498, 520, 524),
        card(60, 526, 280, 58, "Move, or split", ["the best move, or a champion's split"], "frame"),
        card(380, 526, 280, 58, "Announce", ["team tag, ID, role, length and position"], "sonar"),
    ]
    return svg(720, 600, "The tactics bot's structure",
               "The roles bot's structure with new behaviours. The champion evades, coils when nothing threatens it,"
               " roams and splits. A feeder evades or forages, with its Deliver mode switched off because it made the"
               " bot worse. A kamikaze roams or hunts. Sonar messages now carry each dragon's head position.", body)


if __name__ == "__main__":
    directory = Path(sys.argv[1])
    for name, draw in [("first-bot-architecture", first_bot), ("roles-architecture", roles_bot),
                       ("tactics-architecture", tactics_bot)]:
        (directory / f"{name}.svg").write_text(draw())
