# The evaluation harness

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to describe the harness as it's now released: a frozen copy of the round robin runner we use for our own bots, in place of the simpler one this post first described.

The [wishlist](01-the-wishlist.md) ended with eight tools, and most of them lean on the first one. The statistics need results to judge, the map generator needs something playing on its maps, and the ladder rates versions from games they've already played. So we start with the tool that produces games.

![How the tools fit together. A bot change goes through the evaluation harness, which plays on generated maps as well as the bundled ones. Results feed the offline Elo ladder and a statistical test, which decides the next change. Public replays come in through the sampler, the decoder rebuilds them, and the debug viewer shows what each dragon saw, for public games and our own. Profiling sits beside the bot.](images/wishlist-map.svg)

The fish loop from the wishlist post worked, but we're going to be testing ideas for weeks, each against a whole pool of bots including our own older versions. Running a loop by hand every time and reading results off the terminal gets old fast. What I want is to hand over a list of bots, walk away, and come back to a complete record of every game that I can trust and look back through later. That's the harness: `just round-robin`, with the runner in [harness/tournament.py](../harness/tournament.py). [just](https://just.systems) is a command runner. A `justfile` holds named recipes, like make's targets without the build-system rules, and every tool in this series is a recipe you run from `examples/tooling`. Under the hood it still calls the official `unswbc run` for every game, so every result is exactly what the organisers' tools would report. We're only automating the tedious part.

## Every pairing, both sides, the same seeds

You give the harness a list of bots, a list of maps and a number of seeds, and it plays every pair of bots against each other on every map, from both sides, once for each seed. Four bots on the 13 bundled maps with two seeds each already comes to 312 games.

Playing both sides matters because the two sides aren't quite equal, even on a symmetric map. Dragons take their turns one at a time in ID order, so one team's dragons always move first, and a bot that always started on that side could look stronger than it is.

![A round robin schedule on one map, arena, with two seeds, crc32 of arena.map:0 and arena.map:1. Each ordering of each pair, room-c against starter-c, starter-c against room-c, room-c against room-py and room-py against room-c, plays both seeds, with the same pearls and random numbers for every pairing. The same repeats on every other map, and rerunning the schedule replays the same games.](images/round-robin-schedule.svg)

The seeds matter for the reason we saw in the wishlist post: each seed decides where pearls appear and how both bots' random choices fall. The harness works each seed out from the map's name and an index, so every pairing and both side orders meet exactly the same pearls, and running the same schedule again replays exactly the same games. That means a surprising result can always be looked at again. The whole schedule fits in one comprehension:

```python
schedule = [
    (map_path, team_a, team_b, seed)
    for map_path in maps
    for seed in (
        [
            zlib.crc32(f"{map_path.name}:{i}".encode())
            for i in range(args.seed_start, args.seed_start + args.seeds)
        ]
        or [None]
    )
    for team_a, team_b in (
        [(selected[0], selected[0])]
        if self_play
        else [
            pair
            for left, right in itertools.combinations(bots, 2)
            for pair in ((left, right), (right, left))
        ]
    )
]
```

If you don't ask for seeds, the games run unseeded and outside the judge's sandbox, which is quick for a smoke test. With `--sandbox`, they run in the judge's own sandbox and are priced in CPU points, and a seeded sandbox game always plays out the same way. So the harness keeps each finished one in a cache, keyed by the contents of both bots, the map, the seed and the toolkit version, and reuses the result until one of those changes. Rerunning a big comparison after changing one bot only replays the games that bot is in.

## Running games side by side

A game takes anywhere from a second to several minutes, but games don't depend on each other, so the harness compiles each bot once and then plays as many games at once as you have cores. The one real risk is a bot that hangs, because in a long run that one bad game mustn't take the rest down with it. The catch is that `unswbc run` isn't a single process. It starts a separate process for every dragon, so if we only stopped the main process when a game hung, its dragons would be left running in the background, slowly eating the machine over a long run. So each game starts in its own process group, and when it finishes or runs past its time limit, the harness kills the whole group at once:

```python
process = subprocess.Popen(sys.argv[3:], stdout=output, stderr=subprocess.STDOUT,
                           env={**os.environ, "NO_COLOR": "1"}, start_new_session=True)
timed_out = False
try:
    code = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    code, timed_out = -1, True
finally:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
```

Games also go through a small wrapper around the toolkit that closes a race in its sandbox, which could otherwise kill a freshly split dragon on its first turn. We found that one the hard way, and [the machine inside the judge](16-the-machine-inside-the-judge.md) tells the story.

## Keeping errors separate from losses

There's one more thing the harness has to get right, and it's easy to miss: when a game goes wrong, it mustn't be recorded as a loss. Imagine a change that makes our bot crash on one map in ten. If crashes counted as losses, the win rate would dip a little and we'd probably conclude the change was a slightly bad idea. In fact it's a bug, and a very fixable one, and hiding it inside the win rate throws that information away.

![How the harness sorts a finished game. Counted: a win, a loss or a draw, read from the engine's result line. Errors, in their own column: the match exceeded the harness timeout, Battlecode exited with a nonzero code, a bot execution failure such as running out of time, exiting, hitting a limit or having no valid action, no engine result found, or the replay was not written.](images/game-outcomes.svg)

So the harness reads each game's result from its log, and anything that isn't a clean win, loss or draw goes into a separate errors column. The check runs in order of how badly the game went wrong:

```python
if timed_out:
    error = "Match exceeded the harness timeout"
elif returncode:
    error = f"Battlecode exited with code {returncode}"
elif failure:
    error = f"Bot execution failure: {failure.group(0)}"
elif outcome is None:
    error = "No engine result found"
```

A bot failure is a dragon that ran out of time, exited, hit a fuel, trap or memory limit, or died with no valid action, and a game that finished without writing its replay counts as an error too. Every game keeps its full log and replay, so when an error does turn up, we can go straight to the game and see what happened.

## A first run

To try it out, let's use the four bots we already have: the C and Python starters, and the flood-fill bot from [The choice](02-the-choice.md) in C and in Python. From `examples/tooling`, two seeds on each bundled map in the sandbox comes to those 312 games:

![A terminal showing the round robin's results table for the run. room-c and room-py each won 126 games and lost 30, both rated 1772.5. starter-c won 31 and lost 125, rated 1233.2, and starter-py won 29 and lost 127, rated 1221.8. No game had an error.](images/harness-round-robin.png)

Spread across 16 cores, the run took just under five minutes, for games that add up to about half an hour of CPU time. The results look the way we'd hope: both flood-fill bots beat both starters comfortably, and not a single game ended in an error. Everything lands in a folder under `results/round-robin/`, with a `results.json`, a `summary.md` linking every game, and one log and replay per game. Pointing `--output` at an existing folder resumes it, playing only the games that didn't complete, so the capture above just reprinted the finished run's table.

There's one detail in that table worth pausing on. The two flood-fill bots make exactly the same move in every position, and because every pairing meets the same seeds, they finish with exactly the same record, 126 wins and 30 losses, with 26 wins each in their games against each other. So they get exactly the same rating too. The rating column is fitted to every game at once, and [the ladder post](06-a-ladder-of-our-own.md) explains why that matters. What a table like this can't tell us is whether a gap between two bots means anything, and that's the problem the next tool solves.

## Next up

[Better, worse or undecided](04-better-worse-or-undecided.md): turning a pile of wins and losses into a clear answer on whether a change made the bot better.
