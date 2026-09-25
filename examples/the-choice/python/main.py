import helper as unswbc
from helper import Direction, EdgeType

SIZE = 7
HEAD = 24
SIDES = Direction.get_direction_list()  # north, east, south, west
STEPS = [(0, -1), (1, 0), (0, 1), (-1, 0)]


def read_window(ct, game):
    """Which tiles are off the map or hold a dragon, and which sides of each tile are open."""
    tiles = ct.get_tiles()
    head = ct.get_position()
    width, height = game.get_map_size()
    occupied = [
        not (0 <= head.x + i % SIZE - 3 < width and 0 <= head.y + i // SIZE - 3 < height) or tile.get_dragon() is not None
        for i, tile in enumerate(tiles)
    ]
    open_sides = [[tile.get_edge(side).get_edge_type() != EdgeType.KELP for side in SIDES] for tile in tiles]
    return occupied, open_sides


def step(window, index, side):
    occupied, open_sides = window
    column, row = index % SIZE + STEPS[side][0], index // SIZE + STEPS[side][1]
    if not (0 <= column < SIZE and 0 <= row < SIZE):
        return -1
    nxt = row * SIZE + column
    return nxt if open_sides[index][side] and not occupied[nxt] else -1


def reachable(window, start, first):
    visited = {HEAD, first, start}
    queue = [start]
    for index in queue:
        for side in range(4):
            nxt = step(window, index, side)
            if nxt >= 0 and nxt not in visited:
                visited.add(nxt)
                queue.append(nxt)
    return len(queue)


def choose_move(window, fallback):
    best, best_room = fallback, -1
    for first_side in range(4):
        first = step(window, HEAD, first_side)
        if first < 0:
            continue
        room = 0
        for second_side in range(4):
            second = step(window, first, second_side)
            if second >= 0 and second != HEAD:
                room = max(room, reachable(window, second, first))
        if room > best_room:
            best, best_room = SIDES[first_side], room
    return best


def main():
    ct, game = unswbc.init()
    while unswbc.update(ct, game):
        ct.make_move(choose_move(read_window(ct, game), ct.get_dir()))
        unswbc.end_turn()


if __name__ == "__main__":
    main()
