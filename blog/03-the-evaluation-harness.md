# The evaluation harness

<!-- draft: 322e9c66ca, stage: Building our tooling -->

This post starts the tooling stage by building the first item on the [wishlist](01-the-wishlist.md). The loop from that post played every map from both sides, but it ran one game at a time, had no timeout, and would have reported a crashed bot as a loss. The evaluation harness fixes all three. It's a single Python file, [harness/round_robin.py](../harness/round_robin.py), and it drives the official `unswbc run` for every game, so each result is exactly what the toolkit would report.

Out of the eight wishlist items, I'm building three now: this harness, the [statistics](04-better-worse-or-undecided.md) that turn its results into a verdict, and the [map generator](05-maps-nobody-has-seen.md) that tests on maps we haven't seen. Those three are enough to start improving a bot with evidence. The rest can wait until a later post needs them.

## What a round robin plays

Give the harness a list of bots, a list of maps and a number of seeds, and it plays every pair of bots on every map, from both sides, once per seed. Four bots on the 13 bundled maps with two seeds each comes to 312 games.

Each game gets a fixed seed, worked out from the pairing, the map and the repeat number. Running the same schedule again replays the same games, and any single game can be replayed on its own with `unswbc run --seed`. Both side orders of a pairing share their seed, so each bot plays the same map and pearl schedule from each side, which takes one source of luck out of the comparison.

## Running games side by side

Games don't depend on each other, so the harness runs as many at once as you give it workers, one per core by default. The hard part is making sure a game that goes wrong can't take the rest down with it:

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

Every game runs in its own process group. `unswbc run` starts a process for every dragon, so when a game finishes or runs past its timeout, the harness kills the whole group. Stray dragon processes can't pile up over a long run.

The harness keeps each game's full output as a log and its replay. It reads the result from the log, and anything that stops a game from counting as a win, loss or draw is recorded as an error: a timeout, `unswbc` exiting with an error, or a dragon that crashed or ran out of time. Errors are counted in their own column and never scored as losses, because a crash says something different about a bot than losing does.

## A first run

The four bots from earlier posts make a good first field: the C and Python starters, and the flood-fill bot from [The choice](02-the-choice.md) in C and in Python. The [justfile](../examples/tooling/justfile) in `examples/tooling` holds the command:

![A terminal running time just round-robin. The harness plays 312 games and prints a table: room-py 127 wins, 3 draws, 26 losses; room-c 123 wins, 3 draws, 30 losses; starter-c 35 wins, 121 losses; starter-py 23 wins, 2 draws, 131 losses; no errors. The games add up to 49.3 minutes, and the run takes 190 seconds.](images/harness-round-robin.png)

The 312 games add up to 49 minutes of play, and the run took just over three minutes with 16 workers, one per core. Both flood-fill bots beat both starters easily, and no game ended in an error.

The two flood-fill bots finished four wins apart, even though they make exactly the same move in every position. Their games against each other always split evenly: with the same seed and the same moves, swapping sides replays the same game with the names swapped. So the whole gap comes from how their games against the starters happened to fall. A table like this can't say whether a four-win gap means anything. That's the job of the next tool.

## Next up

Statistics: turning a pile of wins and losses into a clear answer on whether a change made the bot better.

Questions, heckling and "have you tried X" are all welcome 😄
