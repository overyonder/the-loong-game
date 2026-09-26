# Better, worse or undecided

With the [evaluation harness](03-the-evaluation-harness.md) we can play as many games as we like. But at the end of the last post we had two bots that make identical moves finishing four wins apart. A results table on its own will always tempt us to read meaning into gaps like that. This post builds the second tool on the wishlist, which answers the question we actually care about: did this change make the bot better?

The command is `just verdict`, with the statistics in [harness/verdict.py](../harness/verdict.py). The current invocation is `just verdict --candidate room-pearls --baseline room-c --behaviour Pearl`; the screenshot below retains the original positional command. You give it a candidate bot and the baseline it changes, and it comes back with one of three answers: better, worse, or undecided.

## Judging a result against luck

The idea underneath is the same reasoning you'd use to judge any result by eye. Suppose a change made no difference at all. Then every game it won or lost could just as easily have gone the other way, like a coin flip. So the right question isn't "did the candidate win more?" but "how often would coin flips do at least this well?" If the answer is "almost never", the change is probably real. If it's "fairly often", we can't tell yet.

The numbers make this concrete. Out of 100 games, an even match will see one side win 60 or more only about 3% of the time, so a 60–40 result is strong evidence. But one side will win 55 or more about 18% of the time, so 55–45 could easily be luck. The verdict uses the usual cut-off: if coin flips would do this well less than 5% of the time, the candidate is better, and if they'd do this badly less than 5% of the time, it's worse.

The hard part is deciding which games to count, and that's where most of this tool's design goes.

## Comparing like with like

A game of unswbc depends on two things besides the bots: the map, and the seed that decides where pearls appear and how each bot's random choices fall. So the verdict plays every game twice. The candidate plays the baseline on a map, side and seed, and then the baseline plays that same map, side and seed against the same opponent, sitting in the candidate's seat.

Seeded games are deterministic. If the candidate's change never comes into play in a game, both versions make exactly the same moves and the two games are identical. They cancel out, and only the games whose result changed are left:

![Twelve pairs of games, the baseline above and the candidate below. Eight pairs have the same result and don't count. Four are outlined: in three the candidate won a game the baseline lost, and in one it lost a game the baseline won. Under each pair a bar shows how much of the game the changed behaviour ran.](images/paired-games.svg)

This matters more than it looks. Most changes to a bot only fire in some situations: a rule for portals, a tactic for narrow corridors. If a change never fires on nine maps in ten and wins the tenth outright, counting every game hides that win among nine maps' worth of games that couldn't have gone any other way. Pairing throws those games out, so a change is judged on the games it could actually affect.

## Weighing each game by how much the change ran

Pairing still treats every changed game the same, whether the new behaviour ran for most of the game or for two turns near the end. A game where it ran for most of the turns says much more about it. So each bot names its behaviours: on every turn it writes the one that chose its move as its indicator, the short text the viewer shows beside a dragon. Running games with `unswbc run -v` puts every indicator in the log, so the verdict can count them.

If you tell the verdict which behaviour changed, it weights each changed game by the share of the candidate's turns in which that behaviour was active. A result the change played a large part in counts for more than one it barely touched.

With weights, counting wins isn't enough any more, so the test becomes a sign flip. Add up the weighted changes, then ask how often random signs on the same changes would add up to at least as much:

```python
def sign_flip_p_values(changes: list[float], trials: int = 200_000) -> tuple[float, float]:
    """P(a random sign on each change sums to at least, and at most, the observed total)."""
    changes = [change for change in changes if change]
    if not changes:
        return 1.0, 1.0
    observed = sum(changes)
    magnitudes = [abs(change) for change in changes]
    generator = random.Random(0)
    at_least = at_most = 0
    for _ in range(trials):
        total = sum(magnitude if generator.random() < 0.5 else -magnitude for magnitude in magnitudes)
        at_least += total >= observed - 1e-12
        at_most += total <= observed + 1e-12
    return at_least / trials, at_most / trials
```

It's the coin-flip question again, asked of the changes themselves. With every weight equal to one, it gives the same answer as counting wins against losses.

## Games we should never lose

Testing a change against the bot it came from has a blind spot. It never shows how the bot does against bots unlike itself. So the candidate and the baseline also both play a set of weak bots, the two starters, on the same maps, sides and seeds, and those games are paired too.

The standard here is different. A decent bot should beat a bot that walks at random every single time, so a loss to one can't be put down to bad luck. It should be about as likely as a mouse beating a lion. A candidate that loses more of these games than the baseline did is never called better, and one that loses significantly more is worse. The verdict also lists every game the candidate lost to a weak bot that the baseline won, because each one is a bug to find, whatever the verdict says.

## How hard a win was

A win in 40 rounds and a win in 400 aren't the same result. So the verdict also compares game length, pair by pair: in the pairs both versions won, how often did the candidate win faster? It reports the median rounds to win for each version, and flags any win that's much shorter than the rest, because a very short game is sometimes a fluke worth looking at before trusting it.

## Checking the tool on questions we can answer

Before trusting a new tool with a real question, it's worth giving it questions where we already know the answer. For each of the runs below, the bots meet on all 13 bundled maps, from both sides, with four seeds.

The first check should be easy: the flood-fill bot from [The choice](02-the-choice.md) in place of the C starter bot, which just wanders about at random, so the flood-fill bot ought to come out clearly better. It does. Of the 104 paired games, 49 came out the same, and of the rest it gained 53 and dropped 2. Even so, it lost 4 games to the Python starter that the C starter had won, which is a reminder that a bot that only counts room can still walk into trouble.

The second check is the more important one. The C and Python versions of the flood-fill bot make exactly the same move in every position, so neither can be better than the other, and a trustworthy tool has to say so. With pairing, the answer is exact rather than statistical: all 104 paired games were identical, nothing changed, and the verdict was undecided. A tool that found a difference here would be finding it in pure noise.

## A real question

Now for something we don't know the answer to. The flood-fill bot only cares about keeping room to move, and it ignores food completely. That seems like an obvious thing to fix. Eating pearls makes a dragon longer, and the longest dragon decides the game at round 500, so a bot that heads for food ought to do better.

The candidate, `room-pearls`, keeps the flood fill, and adds one rule: when several moves all leave plenty of room, it picks the one nearest to a visible pearl. On the turns where that rule picks a different move from the one room alone would pick, it writes `Pearl` as its indicator, so the verdict can weigh each game by it. The rule decided about one turn in six:

![A terminal running just verdict room-pearls room-c Pearl. Of 104 paired games, room-pearls gained 19, dropped 32 and left 53 unchanged, weighted by Pearl activation. Random signs do this badly 13% of the time. Against the weak bots it lost 47 games that room-c won and won 7 that room-c lost, and the first five losses are listed. Median rounds to win: 183 for room-pearls, 213 for room-c. The verdict is worse.](images/verdict-room-pearls.png)

Head to head, the result is unclear. Of the 104 paired games, 53 came out the same, the pearl chaser won 19 that the flood-fill bot lost, and it lost 32 that the flood-fill bot won. Weighted by how much the pearl rule ran, random signs would do this badly 13% of the time, so on those games alone we couldn't call it worse.

The weak bots settle it. Against the two starters, the pearl chaser lost 47 games that the flood-fill bot won, and won back only 7. Chasing food makes the bot beatable by bots that don't try at all, which is exactly the kind of failure a head-to-head test between two versions of the same bot can miss. It does win faster when it wins, a median of 183 rounds against 213, which fits: a bot that eats more grows faster. Working out why it keeps dying is a job for the debug viewer later in this stage.

## Keeping the versions that win

When a candidate comes out better, it becomes the new baseline, and the next idea has to beat it. We also save a numbered snapshot of it, which for now is just a copy of the bot's folder, and keep the last few snapshots around so that every new candidate has to beat them as well as the current baseline.

The reason for keeping older versions is that beating the previous version isn't the same thing as getting better. Strategies in a game like this can go round in circles, the way rock, paper and scissors do. Suppose our first bot plays rock. Paper beats it, passes the verdict and becomes version 2. Scissors beats paper and becomes version 3. Then rock beats scissors and becomes version 4, even though it's exactly the bot we started with:

![Rock, paper, scissors, rock, paper, scissors, labelled v1 to v6, with each version beating the one before it. The labels read as steady progress, but v4 plays exactly like v1.](images/version-cycle.svg)

Every step in that sequence passed a fair test, and the version numbers suggest six rounds of progress, but the bot has only gone round in a circle. Real bots can do the same thing in subtler ways. A change that makes our dragons better at dodging the last version's attacks might also make them worse against a bot that simply forages, and if we only ever tested against the previous version, we'd never find out. Running the verdict against the last few snapshots as well catches this, because a version that has quietly gone back round the circle will lose to one of its own ancestors.

We keep only the last few snapshots in testing rather than all of them, because much older versions are usually easy wins, and playing them spends games without telling us anything new. The offline Elo ladder, which comes later in this stage, will rate every snapshot against every other, so the whole history can be seen at once.

## Next up

[Maps nobody has seen](05-maps-nobody-has-seen.md): generating plausible new maps, and what the flood-fill bot does on them.
