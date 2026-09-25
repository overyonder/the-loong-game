# The evaluation harness

<!-- draft: 322e9c66ca, stage: Building our tooling -->

The [wishlist](01-the-wishlist.md) has eight tools on it, but we don't need all eight before we can start improving a bot. What we need first is a way to tell whether a change helped. That takes three of them: something to play lots of games, something to judge the results, and something to make sure the results hold on maps we haven't seen. So this stage builds those three, starting with the one everything else depends on, the evaluation harness. The rest of the wishlist can wait until a later post needs it.

The loop from the wishlist post already played every map from both sides. Its real problem is that we'll be running tests like it for weeks, and a hand-run loop doesn't scale to that. We want to hand over a pool of bots, walk away, and come back to a complete, trustworthy record of every game. The harness is a single Python file, [harness/round_robin.py](../harness/round_robin.py), and it runs the official `unswbc run` for every game, so each result is exactly what the toolkit would report.

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

The harness also has to be honest about games that go wrong. If a bot crashes, that's a bug to fix, not a game it lost, and scoring it as a loss would hide the bug inside the win rate. So the harness reads each game's result from its log and keeps anything that isn't a clean win, loss or draw in a separate errors column. That covers timeouts and crashes, as well as dragons that run out of CPU time. Every game's full log and replay are kept too, so any odd result can be looked at later.

## A first run

The four bots from earlier posts make a good first field: the C and Python starters, and the flood-fill bot from [The choice](02-the-choice.md) in C and in Python. The [justfile](../examples/tooling/justfile) in `examples/tooling` holds the command:

![A terminal running time just round-robin. The harness plays 312 games and prints a table: room-py 127 wins, 3 draws, 26 losses; room-c 123 wins, 3 draws, 30 losses; starter-c 35 wins, 121 losses; starter-py 23 wins, 2 draws, 131 losses; no errors. The games add up to 49.3 minutes, and the run takes 190 seconds.](images/harness-round-robin.png)

The 312 games add up to 49 minutes of play, and the run took just over three minutes with 16 workers, one per core. Both flood-fill bots beat both starters easily, and no game ended in an error.

The two flood-fill bots finished four wins apart, even though they make exactly the same move in every position. Their games against each other always split evenly: with the same seed and the same moves, swapping sides replays the same game with the names swapped. So the whole gap comes from how their games against the starters happened to fall. A table like this can't say whether a four-win gap means anything. That's the job of the next tool.

## Next up

Statistics: turning a pile of wins and losses into a clear answer on whether a change made the bot better.
