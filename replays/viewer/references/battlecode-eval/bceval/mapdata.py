"""Just enough of the .map format to walk the board: size, kelp, portals, dragons."""

DIRS = ((0, -1), (1, 0), (0, 1), (-1, 0))   # N E S W


def map_data(text):
    hkind, vkind, dragons = {}, {}, []
    width = height = 0
    name = ""
    for line in text.splitlines():
        part = line.split()
        if not part:
            continue
        if part[0] == "MAP":
            width, height = int(part[1]), int(part[2])
            for y in range(height):
                for x in range(width):
                    hkind[x, y] = (0, -1)
                    vkind[x, y] = (0, -1)
        elif part[0] == "MAP_NAME":
            name = " ".join(part[1:])
        elif part[0] == "EDGE":
            index, kind, portal = map(int, part[1:])
            row, col = divmod(index, width + 1)
            if col == width:
                col = 0
            if row % 2 == 0:
                y = row // 2
                hkind[col, 0 if y == height else y] = (kind, portal)
            else:
                vkind[col, (row - 1) // 2] = (kind, portal)
        elif part[0] == "DRAGON":
            length = int(part[2])
            dragons.append({"team": "AB"[int(part[1])], "body": [
                (int(part[3 + i * 2]), int(part[4 + i * 2])) for i in range(length)
            ]})
    portals = {}
    for (x, y), (kind, portal) in hkind.items():
        if kind == 2:
            portals.setdefault(portal, []).append(("h", x, y))
    for (x, y), (kind, portal) in vkind.items():
        if kind == 2:
            portals.setdefault(portal, []).append(("v", x, y))
    return {"width": width, "height": height, "name": name, "hkind": hkind,
            "vkind": vkind, "portals": portals, "dragons": dragons}


def step(board, point, direction):
    """The tile one step from `point` in `direction` (0-3, N E S W): through a
    portal to its partner, wrapping at the border, or None into kelp."""
    x, y = point
    width, height = board["width"], board["height"]
    if direction == 0:
        edge, value = ("h", x, y), board["hkind"][x, y]
    elif direction == 1:
        edge, value = ("v", (x + 1) % width, y), board["vkind"][(x + 1) % width, y]
    elif direction == 2:
        edge, value = ("h", x, (y + 1) % height), board["hkind"][x, (y + 1) % height]
    else:
        edge, value = ("v", x, y), board["vkind"][x, y]
    kind, portal = value
    if kind == 1:
        return None
    if kind == 2:
        first, second = board["portals"][portal]
        side, px, py = second if first == edge else first
        if side == "h":
            return (px, py) if direction == 2 else (px, (py - 1) % height)
        return (px, py) if direction == 1 else ((px - 1) % width, py)
    dx, dy = DIRS[direction]
    return (x + dx) % width, (y + dy) % height
