# The evaluation harness

<!-- draft: 322e9c66ca, stage: Building our tooling -->

The [wishlist](01-the-wishlist.md) ended with eight tools, and building all of them before touching the bot would take weeks. So it's worth asking which ones we need before we can start improving a bot with any confidence. The answer is three. We need something that plays lots of games for us, something that looks at the results and tells us honestly whether a change helped, and something that checks our results still hold on maps we've never seen. Everything else on the list can wait until a later post needs it.

This post builds the first of the three, the evaluation harness, because the other two both depend on having a pile of games to work with.

## Why the loop isn't enough

In the wishlist post, a short fish loop played every bundled map from both sides. It worked, so it's fair to ask why we need anything more.

The answer is that we're going to be doing this for weeks. Every idea we try for the bot needs testing, and not just against one opponent but against a whole pool of bots, including our own older versions. Running a loop by hand each time and reading results off the terminal gets old fast, and it's easy to lose track of what was run against what. What we really want is to hand over a list of bots, walk away, and come back to a complete record of every game that we can trust and look back through later.

The harness does that. It's a single Python file, [harness/round_robin.py](../harness/round_robin.py), and under the hood it still runs the official `unswbc run` for every game. That matters, because it means every result is exactly what the organisers' own tools would report. We're only automating the tedious part.

## Playing every pairing

You give the harness a list of bots, a list of maps and a number of seeds. It then plays every pair of bots against each other, on every map, from both sides, once for each seed. That's a lot of games very quickly. Four bots on the 13 bundled maps with two seeds each comes to 312.

Playing both sides matters because the two sides aren't quite equal even on a symmetric map. Dragons take their turns one at a time in ID order, so one team's dragons always get to move first, and a bot that always started on that side could look stronger than it is. The seeds matter for the reason we saw in the wishlist post: each seed decides where pearls appear and how both bots' random choices fall, so more seeds means more genuinely different games.

The harness also picks the seeds itself, in a repeatable way. Each game's seed is worked out from the two bots, the map and which repeat it is. That has two nice consequences. Running the same schedule again replays exactly the same games, so a surprising result can always be looked at again. And both side orders of a pairing get the same seed, so each bot faces the same map and the same pearls from each side, which takes one more source of luck out of the comparison.

## Running games side by side

A game takes anywhere from a second to several minutes, and hundreds of them one after another would take hours. Luckily, games don't depend on each other, so there's no reason to play them one at a time. The harness runs as many at once as you have cores.

Running games in parallel brings one real risk, though. Sooner or later a bot will hang, or crash in some odd way, and in a long run that one bad game mustn't take the rest down with it. Here's the part of the harness that handles it:

```python
with log_path.open("w") as log:
    # A new session puts the match and every dragon process in one group we can kill together.
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                               env={**os.environ, "NO_COLOR": "1"}, start_new_session=True)
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
```

The important detail is that `unswbc run` doesn't run as a single process. It starts a separate process for every dragon in the game. If we only stopped the main process when a game hung, all of its dragons would be left running in the background, and over a long run they'd slowly eat the machine. So each game is started in its own process group, and when it finishes or runs past its time limit, the harness shuts down the whole group at once.

## Keeping errors separate from losses

There's one more thing the harness has to get right, and it's easy to miss. When a game goes wrong, it mustn't be recorded as a loss.

Imagine a change to our bot that makes it crash on one map in ten. If crashes counted as losses, the bot's win rate would drop a little, and we'd probably conclude the change was a slightly bad idea. In fact it's a bug, and a very fixable one. Hiding it inside the win rate would throw that information away. So the harness reads each game's result from its log, and anything that isn't a clean win, loss or draw goes into a separate errors column instead. That includes timeouts and crashes, and dragons that ran out of CPU time. It also keeps every game's full log and replay, so when an error does turn up, we can go straight to the game and see what happened.

## A first run

To try it out, let's use the four bots we already have: the C and Python starter bots, and the flood-fill bot from [The choice](02-the-choice.md), in C and in Python. The command lives in a [justfile](../examples/tooling/justfile) in `examples/tooling`, so the whole thing is `just round-robin`:

![A terminal running time just round-robin. The harness plays 312 games and prints a table: room-py 127 wins, 3 draws, 26 losses; room-c 123 wins, 3 draws, 30 losses; starter-c 35 wins, 121 losses; starter-py 23 wins, 2 draws, 131 losses; no errors. The games add up to 49.3 minutes, and the run takes 190 seconds.](images/harness-round-robin.png)

Played one after another, those 312 games would have taken 49 minutes. Spread across 16 cores, the run finished in a little over three. The results look the way we'd hope. Both flood-fill bots beat both starters comfortably, and not a single game ended in an error.

There's one detail in that table worth pausing on. The two flood-fill bots finished four wins apart, even though they're the same strategy and make exactly the same move in every position. Their games against each other always split evenly, because with the same seed and the same moves, swapping sides just replays the same game with the names swapped. So the entire four-win gap comes from how their games against the starters happened to fall.

That's a good illustration of the problem the next tool solves. A results table tells us who won more games, but it can't tell us whether a gap like that means anything.

## Next up

Statistics: turning a pile of wins and losses into a clear answer on whether a change made the bot better.
