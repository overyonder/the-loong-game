# bceval: a position evaluation for UNSW Battlecode

`bceval` reads an engine replay of [UNSW Battlecode](https://game.battlecode.au)
(the dragons game) and gives **each side's chance of winning after every
round**, like a chess engine's evaluation bar.

```
$ python -m bceval game.replay --every 50
map Default   A: ...   B: ...   winner: B (elimination, round 365)
after round   P(A wins)   P(B wins)
          0       0.455       0.545   ##################
         49       0.409       0.591   ################
         99       0.092       0.908   ####
        ...
```

It is a small logistic model: 120 weights (5 for each of 23 features and the side),
fitted on about 5,700 real games. There is no neural network, and the scorer
has no dependencies. Reading replays needs `pycapnp`.

## What it scores

For each team at the start of a round it measures the features below. The model
compares the two teams feature by feature: log-difference for counts, share for
ground, scaled difference for distances.

| group | features |
|---|---|
| bodies | dragons alive, total length, longest / 2nd / 3rd longest, dragons ≥5 and ≥10 long |
| economy (last 25 rounds) | pearls eaten; eaten on rich tiles (mean spawn gap ≤ 60); eaten on *hot* tiles (the fastest-spawning tiles that together make 30% of the map's pearls) |
| fights (last 25 rounds) | dragons lost, length lost, head-to-head kills |
| ground (walking distance through kelp and portals) | tiles nearer to this team's heads than the other's, the pearl supply of those tiles, rich and hot tiles among them, pearls lying nearer |
| champion (the team's longest dragon) | walking distance to the nearest enemy head, enemy heads within 3 and 6 steps, nearest ally, free exits beside its head |
| side | side A or B: the engine moves dragons in id order, and side B has a small measured edge |

**Each weight is a curve over the game, not a single number.** It is set at
rounds 0, 125, 250, 375 and 500 and interpolated between them. So the model
can learn things such as:
- total length and territory decide the middle game, and the longest living
  dragon (the round-500 tiebreak) decides the end;
- with length held fixed, *more* dragons is worse after about round 125: the
  same length in fewer bodies wins more often.

The model is antisymmetric: swapping the teams gives 1 - p, and two equal
positions score 0.5 apart from the side term.

## How good it is

Fitted on ~5,700 ladder and local games. Scored with one official map held out
of fitting at a time:

| board after round | 1-100 | 101-200 | 201-300 | 301-400 | 401-490 |
|---|---|---|---|---|---|
| games called right | 66% | 74% | 71% | 74% | 84% |

- **It is calibrated.** Of positions it scores at 25% the side wins 29%, at 45%
  → 46%, at 85% → 85%.
- **Most of what it knows is length.** Longest + total alone does only
  slightly worse (log-loss 0.502 against 0.498).
- **It cannot see the effect of a single choice soon after it is made.**
  Continuations forked from one position that end differently look the same
  to it for about 50 rounds, and only 57-62% separable from 50 to 120 rounds
  after (2,880 forked games). Use it to read who is ahead, not as a
  30-round reward for training a bot.
- **It sees the whole board.** It uses both teams and every tile's spawn gaps
  from the map text. A bot sees a 7x7 window, so it cannot compute this
  evaluation during a game.

## Use

```bash
pip install .            # needs pycapnp
python -m bceval game.replay                 # every 10 rounds
python -m bceval game.replay --every 1 --json
```

```python
from bceval import evaluate_replay, replay_features, win_probability

for r in evaluate_replay("game.replay"):
    print(r["after_round"], r["p_a"], r["parts"])   # parts: log-odds by group

game, rows = replay_features("game.replay", every=10)   # the raw features
p = win_probability(rows[20]["round"], rows[20]["a"], rows[20]["b"])
```

`bceval/model.json` holds the weights: the feature list with each feature's
transform, the knot rounds, and five weights per feature. `score.py` is ~100
lines of plain Python and is the whole model.

The replay schema (`bceval/replay.capnp`) was reconstructed from the unswbc
replay viewer for reading replays. The game and its replay format belong to
UNSW Battlecode.

## Licence

MIT, see `LICENSE`.
