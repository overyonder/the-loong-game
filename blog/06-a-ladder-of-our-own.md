# A ladder of our own

> **Editor's note, 28 September 2026.** This post has been rewritten to be shorter. The ladder now schedules its games through the released round robin runner, which seeds games differently from the harness that played the ladder shown here, so a rerun plays different individual games.

The [verdict](04-better-worse-or-undecided.md) answers one question at a time: is this candidate better than that baseline? But a candidate can beat its parent and still lose to an older version, the way paper beats rock and loses to scissors. So we want every version played against every other, with one number each we can compare. That's the offline Elo ladder.

## What a rating means

The gap between two Elo ratings predicts how often the stronger bot wins: 400 points is ten-to-one odds, 200 about three-to-one, and equal ratings an even match. A rating means nothing on its own, only relative to the bots it was measured against.

The online ladder updates ratings one game at a time, so they depend on the order games happened in, and the latest games move them most, which is the noise the [wishlist](01-the-wishlist.md) complained about. Offline, the round robin gives us every result at once, and we can look for the ratings that explain all of them together. The model is the one Elo assumes, known to statisticians as Bradley–Terry: each bot has a hidden strength, and the chance that A beats B is A's strength divided by both strengths added together. Fitting it takes a short loop:

```python
def fit_ratings(bots: list[str], scores: dict[tuple[str, str], float], iterations: int = 2000) -> dict[str, float]:
    strength = dict.fromkeys(bots, 1.0)
    for _ in range(iterations):
        updated = {}
        for bot in bots:
            points = 0.5 + sum(scores[bot, other] for other in bots if other != bot)
            weight = 1 / (strength[bot] + 1)
            for other in bots:
                if other != bot:
                    games = scores[bot, other] + scores[other, bot]
                    weight += games / (strength[bot] + strength[other])
            updated[bot] = points / weight
        mean_log = sum(math.log(value) for value in updated.values()) / len(bots)
        strength = {bot: value / math.exp(mean_log) for bot, value in updated.items()}
    return {bot: 1500 + ELO_SCALE * math.log(strength[bot]) for bot in bots}
```

Each pass nudges every strength towards the value that makes the bot's expected score match its actual points, and after enough passes nothing moves. A draw counts half a win each way. The `0.5` and the extra `1 / (strength + 1)` add one imaginary draw against an average bot, without which a bot that won every game would have no finite rating. The last line puts the result on the familiar scale, with the average bot at 1500.

`just ladder` plays the round robin through the harness, then fits the ratings from its results with [harness/ladder.py](../harness/ladder.py) and prints them beside the head-to-head table.

## The first ladder

We have six bots: the two starters, the flood-fill bot from [The choice](02-the-choice.md) in C, Python and Nim, and the pearl chaser the verdict rejected. Every pair on the 13 bundled and 20 generated maps, both sides, comes to 990 games:

![A terminal running just ladder, which builds the Nim flood-fill bot and rates six bots from 990 games with no errors. room-c 1645, room-nim 1641, room-py 1628, room-pearls 1504, starter-py 1307, starter-c 1275. The three flood-fill bots scored 33 of 66 against each other. room-pearls scored between 19.5 and 24 of 66 against them.](images/ladder.png)

The table reads row against column: room-pearls scored 21.5 of 66 against room-c, for example.

The three flood-fill bots finish within 17 points and split their games against each other exactly 33–33, as they should, since they make the same move in every position. The small gaps come from how their games against the other three bots fell, the same effect that separated two identical bots in [the harness post](03-the-evaluation-harness.md). The pearl chaser sits about 140 points below them, which predicts about three wins in ten, and it did. The two starters trail everything, level with each other.

## Looking for circles

One number per bot assumes the pool is ordered: if A beats B and B beats C, A beats C. When a circle breaks that, the head-to-head table shows it plainly, as a lower-rated bot with a winning record against a higher one, and the ratings get squeezed together to average over it. There's no circle here. The only upset is starter-c beating starter-py 34–32 while rating 32 points lower, and two games between random walkers is a coin toss. The check matters more as the pool fills with versions of our own bot that differ in subtler ways, and from now on every saved version joins the ladder.

## Next up

The ladder measures our bots against each other. The next two tools look outward, at everyone else's games, starting with [a sampler](07-everyone-elses-games.md) that downloads the public ladder's replays without loading the organisers' site.
