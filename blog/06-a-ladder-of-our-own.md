# A ladder of our own

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to say more about why we fit ratings offline. The ladder shown here was played by the earlier harness, which gave each pairing its own seeds. The released runner seeds by map instead, so a rerun plays different individual games.

The [verdict tool](04-better-worse-or-undecided.md) answers one question at a time: is this candidate better than that baseline? That's the right question when deciding whether to keep a change. But by now we have several bots, and the verdict post explained why beating the version before isn't enough, because a candidate can beat its parent and still lose to an older version, the way paper beats rock and loses to scissors. So we want something that plays every version against every other and gives each one a single number we can compare. That's the offline Elo ladder from the wishlist.

## What a rating means

The online ladder uses Elo ratings, and so will we, because the idea behind them is simple. Each bot gets a rating, and the gap between two ratings predicts how often the stronger bot wins. A gap of 400 points means ten-to-one odds, 200 points about three-to-one, and equal ratings mean an even match. A rating on its own means nothing. It only says something relative to the other bots it was measured against.

## Why we fit ratings offline

The online ladder updates ratings one game at a time: after each game, the winner takes some points from the loser, more if the win was a surprise. That suits a ladder that never stops, where new games keep arriving forever. But it has two side effects we'd rather avoid. The ratings depend on the order the games happened in, and the most recent games move them the most, which is exactly the noise the [wishlist](01-the-wishlist.md) complained about. You could see the first effect in [the harness post](03-the-evaluation-harness.md), where two bots with identical records ended up 7 points apart purely because of the order their games finished in.

Offline we have a different situation. The harness plays the whole round robin first, so we have every result at once, and instead of replaying them in some order we can look for the one set of ratings that explains all of them together. Every game counts equally, and the answer is the same whichever order the games were played in. The model is the same one Elo assumes, known to statisticians as Bradley–Terry: each bot has a hidden strength, and the chance that A beats B is A's strength divided by the sum of both. Finding the strengths that fit the results best takes a short loop:

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

Each pass nudges every bot's strength towards the value that would make its expected score match the points it actually scored, and after enough passes nothing moves. A draw counts as half a win for each side. The `0.5` and the extra `1 / (strength + 1)` add one imaginary draw against an average bot. Without it, a bot that won every game would have no finite rating, because no strength would ever be high enough. The last line puts the ratings on the familiar Elo scale, with the average bot at 1500.

The command is `just ladder`, with the model in [harness/ladder.py](../harness/ladder.py). It plays the round robin through the same harness as before, then fits the ratings from its results and prints them next to the head-to-head table.

## The first ladder

At this point in the series we have six bots: the two starters, the flood-fill bot from [The choice](02-the-choice.md) in C, Python and Nim, and the pearl-chasing version the verdict rejected. Every pair plays on the 13 bundled maps and the 20 generated ones, from both sides, which comes to 990 games:

![A terminal running just ladder, which builds the Nim flood-fill bot and rates six bots from 990 games with no errors. room-c 1645, room-nim 1641, room-py 1628, room-pearls 1504, starter-py 1307, starter-c 1275. The three flood-fill bots scored 33 of 66 against each other. room-pearls scored between 19.5 and 24 of 66 against them.](images/ladder.png)

The table reads row against column, so room-pearls scored 21.5 points out of 66 against room-c, for example.

The three flood-fill bots finish within 17 points of each other, and their games against each other split exactly 33–33. That's what it should look like, because they make the same move in every position. The small gaps between them come from their games against the other three bots, which the harness of the time seeded separately for each pairing, so they fell slightly differently. A gap that small between two bots is noise, and the head-to-head column shows it.

The pearl-chasing bot sits about 140 points below them, which predicts that it wins roughly three games in ten against them, and it did. The verdict already rejected it with a single comparison, and the ladder agrees with a much broader one. The two starters trail everything and are level with each other.

## Looking for circles

The head-to-head table is there for a reason besides checking the ratings. A single number per bot assumes the pool is ordered, so that if A beats B and B beats C, then A beats C. When a rock-paper-scissors circle breaks that, the table shows it plainly: a lower-rated bot will have a winning record against one above it, and the ratings get squeezed together to average over the circle.

There's no circle here. The only upset is between the two starters, where starter-c won 34–32 despite rating 32 points lower, and a two-game margin between two random walkers is a coin toss. Every other bot has a winning record against every bot rated below it. That's reassuring, but it's also a small pool of simple bots. The check matters more as the pool fills with versions of our own bot that differ in subtler ways, and from now on every saved version can join the ladder.

## Next up

The ladder measures our bots against each other. The next two tools look outward, at everyone else's games, starting with [a sampler](07-everyone-elses-games.md) that downloads the public ladder's replays without loading the organisers' site.
