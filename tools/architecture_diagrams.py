"""Draw the block diagrams of the first, roles and tactics bots.

    python3 tools/architecture_diagrams.py blog/images

Each block takes its part's colour from figure_palette, the same colour its code
has in the code maps.
"""

import sys
from pathlib import Path

from figure_palette import CARD, FONT, INK, MUTED, PAPER, WHITE, colour


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
    fill, title_colour, line_colour = (colour(key), PAPER, WHITE) if filled else (CARD, INK, MUTED)
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
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="{FONT}"'
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
        card(160, 110, 400, 62, "State machine", ["enter the first behaviour whose guard holds"], "frame"),
        f'<path d="M300 172 L180 218" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        f'<path d="M420 172 L540 218" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        card(420, 220, 240, 84, "Evade", ["guard: enemy head within 2", "objective: room + 4 × gap"], "evade", filled=True),
        card(60, 220, 240, 84, "Roam", ["guard: none", "objective: room left"], "roam", filled=True),
        f'<path d="M180 304 L300 336" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        f'<path d="M540 304 L420 336" stroke="{MUTED}" stroke-width="1.6" fill="none" marker-end="url(#a)"/>',
        card(160, 338, 400, 84, "Movement: hard constraints first", ["drop steps into kelp, bodies, portals", "and tiles next to an enemy head"], "safety"),
        arrow(360, 422, 360, 448),
        card(185, 450, 350, 56, "Best remaining step by the objective", [], "frame"),
    ]
    return svg(720, 520, "The first bot's structure",
               "Each turn the dragon reads its 7 by 7 window. A state machine enters the first behaviour whose guard"
               " holds: Evade when an enemy head is within two tiles, otherwise Roam. Movement drops steps into kelp,"
               " bodies, portals and tiles next to an enemy head, then takes the remaining step the behaviour's"
               " objective scores highest.", body)


def roles_bot():
    body = [
        card(40, 20, 280, 58, "Listen", ["longest teammate heard"], "sonar"),
        card(400, 20, 280, 58, "Read the 7×7 window", ["bodies, kelp, portals, enemy heads"], "window"),
        arrow(180, 78, 300, 106), arrow(540, 78, 420, 106),
        card(200, 108, 320, 58, "State machine: a role", ["from length and the longest heard"], "frame"),
        arrow(300, 166, 130, 204), arrow(360, 166, 360, 204), arrow(420, 166, 590, 204),
        role_card(20, 206, 220, "Champion", [("split", "Split"), ("evade", "Evade"), ("roam", "Roam")]),
        role_card(250, 206, 220, "Kamikaze", [("hunt", "Hunt"), ("roam", "Roam")]),
        role_card(480, 206, 220, "Worker", [("evade", "Evade"), ("roam", "Roam")]),
        text(360, 302, "then the first behaviour whose guard holds; Split and Hunt's strike act as reflexes", 12, MUTED),
        arrow(360, 310, 360, 330),
        card(170, 332, 380, 80, "Movement: hard constraints first", ["no kelp, bodies or unseen portals; only Hunt", "may step next to an enemy head"], "safety"),
        arrow(360, 412, 360, 438),
        card(185, 440, 350, 56, "Best remaining step by the objective", [], "frame"),
        arrow(300, 496, 200, 522), arrow(420, 496, 520, 522),
        card(60, 524, 280, 58, "Move, or split", ["the step, or a champion's split"], "frame"),
        card(380, 524, 280, 58, "Announce", ["team tag, ID, role and length"], "sonar"),
    ]
    return svg(720, 598, "The roles bot's structure",
               "Each turn the dragon listens to sonar and reads its window. The state machine enters a role from its"
               " length and the longest teammate heard, then the first behaviour that role holds whose guard passes:"
               " the champion splits, evades or roams, a kamikaze hunts or roams, and a worker evades or roams. Movement"
               " drops deadly steps and takes the best by the behaviour's objective, and the dragon announces itself.", body)


def tactics_bot():
    body = [
        card(40, 20, 280, 58, "Listen", ["longest teammate and where it is"], "sonar"),
        card(400, 20, 280, 58, "Read the 7×7 window", ["bodies, pearls, the champion's body"], "window"),
        arrow(180, 78, 300, 106), arrow(540, 78, 420, 106),
        card(200, 108, 320, 58, "State machine: a role", ["from length and the longest heard"], "frame"),
        arrow(300, 166, 130, 204), arrow(360, 166, 360, 204), arrow(420, 166, 590, 204),
        role_card(10, 206, 280, "Champion", [("split", "Split"), ("evade", "Evade"), ("coil", "Coil"), ("roam", "Roam")]),
        role_card(300, 206, 170, "Kamikaze", [("hunt", "Hunt"), ("roam", "Roam")]),
        role_card(480, 206, 230, "Feeder", [("evade", "Evade"), ("deliver", "Deliver"), ("forage", "Forage")]),
        text(360, 302, "then the first behaviour whose guard holds; Split, Hunt's strike and Deliver's sacrifice act as reflexes", 12, MUTED),
        arrow(360, 310, 360, 330),
        card(170, 332, 380, 80, "Movement: hard constraints first", ["no kelp, bodies or unseen portals; only Hunt", "may step next to an enemy head"], "safety"),
        arrow(360, 412, 360, 438),
        card(185, 440, 350, 56, "Best remaining step by the objective", [], "frame"),
        arrow(300, 496, 200, 522), arrow(420, 496, 520, 522),
        card(60, 524, 280, 58, "Move, or split", ["the step, or a champion's split"], "frame"),
        card(380, 524, 280, 58, "Announce", ["team tag, ID, role, length and position"], "sonar"),
    ]
    return svg(720, 598, "The tactics bot's structure",
               "The roles bot's structure with new behaviours. The champion splits, evades, coils when no enemy head is"
               " within three tiles, or roams. A feeder evades, delivers itself to the champion once grown, or forages."
               " A kamikaze hunts or roams. Sonar messages"
               " now carry each dragon's head position.", body)


if __name__ == "__main__":
    directory = Path(sys.argv[1])
    for name, draw in [("first-bot-architecture", first_bot), ("roles-architecture", roles_bot),
                       ("tactics-architecture", tactics_bot)]:
        (directory / f"{name}.svg").write_text(draw())
