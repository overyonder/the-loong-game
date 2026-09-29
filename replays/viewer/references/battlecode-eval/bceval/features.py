"""Per-team features of the board at the start of each round, from a replay.

Bodies are rebuilt from the replay's events: the steps a move implies are
provisional, dragonUpdate is authoritative, and a tail trims at its first
occurrence. At the end the rebuilt standing is checked against the engine's
GameResult (`ok`).

The features see the whole board -- both teams, and every tile's spawn gaps
from the map text -- so they describe a game after the fact. A bot, which sees
a 7x7 window, cannot compute them during play.
"""
from .mapdata import map_data, step
from .replay import load

RICH_GAP = 60        # a tile whose mean spawn gap is at most this is "rich"
HOT_SHARE = 0.30     # "hot" tiles: the fastest tiles that together make this share of the map's supply
WINDOW = 25          # rounds of history behind the rate features
FAR = 30             # distance cap for the champion features
TEAM_FEATURES = [
    "alive", "total", "longest", "second", "third", "big5", "big10",
    "eat", "eat_rich", "eat_hot", "deaths", "lost_len", "kills_h2h",
    "terr", "supply", "rich_ctrl", "hot_ctrl", "pearls_near",
    "champ_enemy_d", "champ_enemy_n3", "champ_enemy_n6", "champ_ally_d", "champ_exits",
]
DEATH_HEAD_TO_HEAD = 3


def _map_name(text):
    for line in text.split("\n"):
        p = line.split()
        if p and p[0] == "MAP_NAME":
            return " ".join(p[1:]).strip()
    return ""


def _spawn_rates(text):
    """Pearls per round for each spawning tile: 2 / (min_gap + max_gap)."""
    rate = {}
    for line in text.split("\n"):
        p = line.split()
        if p and p[0] == "TILE":
            lo, hi = int(p[3]), int(p[4])
            if hi > 0:
                rate[(int(p[1]), int(p[2]))] = 2.0 / max(1, lo + hi)
    return rate


def _hot_tiles(rate):
    total, acc, hot = sum(rate.values()), 0.0, set()
    for t, r in sorted(rate.items(), key=lambda kv: -kv[1]):
        if acc >= HOT_SHARE * total:
            break
        hot.add(t)
        acc += r
    return hot


def _neighbours(board):
    nb = {}
    for y in range(board["height"]):
        for x in range(board["width"]):
            nb[(x, y)] = [t for t in (step(board, (x, y), d) for d in range(4)) if t is not None]
    return nb


def _bfs_multi(nb, sources):
    """Walking distance from the nearest source and whose it is ({tile: team});
    ties are labelled None. Bodies are not walls: they move."""
    dist, lab = {}, {}
    frontier = []
    for t, l in sources.items():
        if t in dist:
            if lab[t] != l:
                lab[t] = None
            continue
        dist[t], lab[t] = 0, l
        frontier.append(t)
    d = 0
    while frontier:
        d += 1
        nxt = []
        for t in frontier:
            lt = lab[t]
            for u in nb[t]:
                if u not in dist:
                    dist[u], lab[u] = d, lt
                    nxt.append(u)
                elif dist[u] == d and lab[u] != lt:
                    lab[u] = None
        frontier = nxt
    return dist, lab


def _bfs_from(nb, start, cap):
    dist = {start: 0}
    frontier = [start]
    for d in range(1, cap + 1):
        nxt = []
        for t in frontier:
            for u in nb[t]:
                if u not in dist:
                    dist[u] = d
                    nxt.append(u)
        frontier = nxt
        if not frontier:
            break
    return dist


def _snapshot(dragons, pearls, nb, rate, rich, hot, hist, rnd):
    alive = {"A": [], "B": []}
    for d in dragons.values():
        if d["alive"] and d["body"]:
            alive[d["team"]].append(d)
    occupied = set()
    for side in "AB":
        for d in alive[side]:
            occupied.update(d["body"])
    heads = {}
    for side in "AB":
        for d in alive[side]:
            h = d["body"][0]
            heads[h] = side if heads.get(h, side) == side else None
    _, lab = _bfs_multi(nb, heads) if heads else ({}, {})
    out = {}
    lo = rnd - WINDOW
    for side in "AB":
        other = "B" if side == "A" else "A"
        lens = sorted((len(d["body"]) for d in alive[side]), reverse=True) + [0, 0, 0]
        f = {"alive": len(alive[side]), "total": sum(lens), "longest": lens[0],
             "second": lens[1], "third": lens[2],
             "big5": sum(1 for L in lens if L >= 5), "big10": sum(1 for L in lens if L >= 10)}
        h = hist[side]
        f["eat"] = sum(1 for r in h["eat"] if r >= lo)
        f["eat_rich"] = sum(1 for r in h["eat_rich"] if r >= lo)
        f["eat_hot"] = sum(1 for r in h["eat_hot"] if r >= lo)
        f["deaths"] = sum(1 for r, _ in h["death"] if r >= lo)
        f["lost_len"] = sum(L for r, L in h["death"] if r >= lo)
        f["kills_h2h"] = sum(1 for r in h["h2h"] if r >= lo)
        mine = [tile for tile, l in lab.items() if l == side]
        f["terr"] = len(mine)
        f["supply"] = sum(rate.get(tile, 0.0) for tile in mine)
        f["rich_ctrl"] = sum(1 for tile in mine if tile in rich)
        f["hot_ctrl"] = sum(1 for tile in mine if tile in hot)
        f["pearls_near"] = sum(1 for p in pearls if lab.get(p) == side)
        champ = max(alive[side], key=lambda d: len(d["body"]), default=None)
        if champ is None:
            f.update(champ_enemy_d=0, champ_enemy_n3=0, champ_enemy_n6=0, champ_ally_d=0, champ_exits=0)
        else:
            ch = champ["body"][0]
            cd = _bfs_from(nb, ch, FAR)
            ed = [cd[d["body"][0]] for d in alive[other] if d["body"][0] in cd]
            ad = [cd[d["body"][0]] for d in alive[side] if d is not champ and d["body"][0] in cd]
            f["champ_enemy_d"] = min(ed, default=FAR + 1)
            f["champ_enemy_n3"] = sum(1 for x in ed if x <= 3)
            f["champ_enemy_n6"] = sum(1 for x in ed if x <= 6)
            f["champ_ally_d"] = min(ad, default=FAR + 1)
            f["champ_exits"] = sum(1 for u in nb[ch] if u not in occupied)
        out[side] = f
    return out


def replay_features(path, every=1):
    """(game, rows) for a replay file.

    Each row is the board at the start of round `round`, every `every` rounds,
    plus the board after the last round as `round` 501: {"round": r, "a": {...},
    "b": {...}} with the TEAM_FEATURES of each side. `game` holds the map, the
    bot names, the result and `ok` (the rebuilt final standing matches the
    engine's)."""
    rep = load(path)
    board = map_data(rep.map)
    nb = _neighbours(board)
    rate = _spawn_rates(rep.map)
    rich = {t for t, r in rate.items() if 2.0 / r <= RICH_GAP}
    hot = _hot_tiles(rate)
    dragons = {i: {**d, "alive": True, "body": [tuple(p) for p in d["body"]], "pending": 0}
               for i, d in enumerate(board["dragons"])}
    pearls = set()
    hist = {s: {"eat": [], "eat_rich": [], "eat_hot": [], "death": [], "h2h": []} for s in "AB"}
    rows = []
    rnd, cur = 0, None
    want = set(range(every, 501, every)) | {1}

    for ev in rep.events:
        kind = ev.which()
        if kind == "roundStart":
            rnd = ev.roundStart.round
            if rnd in want:
                snap = _snapshot(dragons, pearls, nb, rate, rich, hot, hist, rnd)
                rows.append({"round": rnd, "a": snap["A"], "b": snap["B"]})
        elif kind == "turnStart":
            cur = ev.turnStart.id
        elif kind == "tileChange":
            tile = (ev.tileChange.tile.x, ev.tileChange.tile.y)
            if ev.tileChange.hasPearl:
                pearls.add(tile)
                continue
            pearls.discard(tile)
            d = dragons.get(cur) if cur is not None else None
            if d:
                hist[d["team"]]["eat"].append(rnd)
                if tile in rich:
                    hist[d["team"]]["eat_rich"].append(rnd)
                if tile in hot:
                    hist[d["team"]]["eat_hot"].append(rnd)
        elif kind == "dragonAction":
            act, i = ev.dragonAction.action, ev.dragonAction.id
            d = dragons.get(i)
            if not d or not d["alive"] or act.which() != "move":
                continue
            d["pending"] = 0
            for direction in act.move:
                dest = step(board, d["body"][0], direction)
                if dest is None:
                    break
                d["body"].insert(0, dest)
                d["pending"] += 1
        elif kind == "dragonUpdate":
            u = ev.dragonUpdate
            d = dragons.get(u.id)
            if not d or not d["alive"]:
                continue
            head, tail = (u.head.x, u.head.y), (u.tail.x, u.tail.y)
            if d["body"] and d["body"][0] != head and d["pending"]:
                del d["body"][:d["pending"]]
            d["pending"] = 0
            if not d["body"] or d["body"][0] != head:
                d["body"].insert(0, head)
            at = [n for n, p in enumerate(d["body"]) if p == tail]
            d["body"] = d["body"][:at[0] + 1] if at else [head, tail]
        elif kind == "dragonSplit":
            sp = ev.dragonSplit
            t = "AB"[sp.team]
            dragons.setdefault(sp.parentId, {"team": t, "alive": True, "pending": 0})
            dragons[sp.parentId].update({"team": t, "alive": True, "pending": 0,
                                         "body": [(p.x, p.y) for p in sp.parentBody]})
            dragons[sp.childId] = {"team": t, "alive": True, "pending": 0,
                                   "body": [(p.x, p.y) for p in sp.childBody]}
        elif kind == "dragonDeath":
            d = dragons.get(ev.dragonDeath.id)
            if not d or not d["alive"]:
                continue
            d["alive"] = False
            hist[d["team"]]["death"].append((rnd, len(d["body"])))
            if ev.dragonDeath.reason == DEATH_HEAD_TO_HEAD:
                hist["B" if d["team"] == "A" else "A"]["h2h"].append(rnd)

    final = _snapshot(dragons, pearls, nb, rate, rich, hot, hist, rnd)
    rows.append({"round": 501, "a": final["A"], "b": final["B"]})
    res = rep.result
    ok = all((final[s]["alive"], final[s]["longest"], final[s]["total"])
             == (st.dragonCount, st.longestDragon, st.totalLength)
             for s, st in (("A", res.teamA), ("B", res.teamB)))
    game = {"map": _map_name(rep.map), "bot_a": rep.botA, "bot_b": rep.botB,
            "winner": "AB"[res.winner] if res.which() == "winner" else None,
            "end": "elimination" if res.endReason == 0 else "length", "last_round": rnd, "ok": ok}
    return game, rows
