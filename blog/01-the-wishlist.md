# The wishlist

The [last post](00-the-loong-game.md) got the official toolkit installed and a first bot running. This one covers what happens after that first game. It's about working out whether a change actually made your bot better. I'll use the stock toolkit on the stock starter bots to show where it runs out, and each gap turns into an item on a wishlist of tools that later posts will build.

## One game

`unswbc init` gives you a starter bot in C, C++ or Python. I made a C one called `alpha` and a Python one called `bravo`, and played them against each other in the judge's sandbox:

![Terminal output of unswbc run --sandbox on default_small with alpha against bravo. Three dragons die, one by hitting itself, one by hitting a wall. Team A wins after 65 rounds by elimination. Team A used 3.0M points per turn at p50, p99 and max. Team B used 5.0M at p50, 20.3M at p99 and 20.4M at max.](images/unswbc-run.png)

That's a lot of useful information for one command. You get the winner, how each dragon died, and how many CPU points each team spent per turn. There's also a replay you can open in the [visualiser](https://game.battlecode.au/visualiser).

<!-- screenshot: the web visualiser showing this replay -->

What it can't tell you is whether `alpha` is the better bot. That takes more than one game.

## Playing it again tells you nothing

The obvious next step is to run it a few more times. Both starter bots pick a random direction each turn, but both seed their random number generator with 0, and the engine is deterministic. So the same two bots on the same map give exactly the same game every time. I ran it twice to check, and got team A winning after 65 rounds both times.

That's a good thing for debugging, since you can reproduce any game. It does mean that re-running a match gives you no new evidence. New games have to come from somewhere else: different maps, swapped sides, or different seeds.

## A hand-rolled round robin

So here's the next obvious step, a loop over all 11 bundled maps with both bots taking each side:

```sh
for map in maps/*.map; do
  for pair in "alpha bravo" "bravo alpha"; do
    echo "$map ($pair): $(unswbc run --sandbox --no-replay "$map" $pair | grep -o 'team . wins')"
  done
done
```

![Terminal output of the loop: 22 results, one per map and side, taking 1 minute 19 seconds.](images/unswbc-loop.png)

`alpha` won 12 of the 22 games. Is it better? No. Both bots run the same random walk, just in different languages. Some maps look like strong evidence on their own. On `default`, `bravo` won from both sides. On `default_small`, whoever was team A won both times. They're still just noise.

12 wins out of 22 is what you'd expect from two equal bots more than 40% of the time. To tell a bot that wins 60% of its games from a coin flip, with the usual 95% confidence, you need roughly 150 games. Smaller improvements need a lot more. The question "did my change help?" is really a statistics question, and a `grep` loop can't answer it.

## And it gets slow

Those 22 games took 1 minute 19 seconds, and the starter bots barely think. They also die early, so no game got anywhere near the 500-round limit. Real bots are a different story. In one of my recent offline ladders, 600 games between stronger bots took a median of 17 seconds each. One in ten went past four minutes, and the longest took over nine. Played back to back, that ladder is 14 hours of games.

Your machine has more than one core, and games are independent, so they should run in parallel. Doing that properly means more than adding `&`. You need to cap how many games run at once, keep one hung game from blocking the batch, clean up the child processes when something dies, and keep crashes and timeouts apart from genuine losses.

## Why not just use the ladder?

The online ladder already plays lots of games, but it's a poor way to test a change:

- **It's slow.** Battles are drawn every two hours, five games each, and uploads are limited to 12 an hour.
- **It's noisy.** Each new submission resets your rating's K factor to 96 for its first rated battle. So the rating swings hardest right when you want to read it.
- **It measures the wrong thing.** Your rating says how you're doing against whoever else is on the ladder this week, and they're changing their bots too. It doesn't say whether this version beats your last one.

What you want is a ladder of your own. It should rate your current bot against your own older versions and a few fixed baselines, on hardware you control, and a separate test should give a yes-or-no answer on whether the new version is better.

## Maps you haven't seen

The toolkit bundles 11 maps. The ladder has served others, and the tournaments will use maps nobody has seen yet. The organisers have said on Discord that Sprint and Qualifier maps may differ from the ladder's.

This bit me already. The docs say maps are at least 10 tiles on a side, and my bot trusted that and gave up on anything smaller. Then the ladder served a 16×8 map called Small, and every one of my dragons died in round 0. You can't tune your way around maps you've never seen, but you can test on plenty of plausible ones. That needs a way to make them.

## What everyone else is doing

Every ladder battle is public, and game IDs on the site are already past 88,000. That's a huge record of what other bots do: how they open, whether they split early, how they use sonar, how they die. Nobody's going to watch 88,000 games in the visualiser, though, and the replay files aren't something you can grep:

![A hexdump of a replay file. It is packed binary, with fragments of the map text and bot names visible.](images/replay-hexdump.png)

A replay is a packed binary file. You can make out the bot names and the map text, but not much else. Using the archive means downloading it politely, decoding the format, and rebuilding the game state turn by turn. Only then can you ask it questions.

## What your dragon saw

The visualiser shows the whole board, but none of your dragons ever sees that. Each dragon sees a 7×7 window around its head and whatever it chose to remember. When a dragon does something stupid, the question is usually "what did it think was there?" `unswbc run` can record each dragon's log lines, indicator text and drawn dots and lines into the replay, and that helps. But you still have to reconstruct the dragon's actual view and memory in your head from the full board.

<!-- screenshot: the visualiser's full-board view mid-game, to contrast with the 7×7 window -->

Debugging needs the fog of war: the board as one dragon saw it on one turn, next to what it remembered and what it decided.

## Where the points go

The sandbox's summary lines tell you how many CPU points each team spent per turn. They don't tell you what spent them.

Take the C starter. It spends 3.0 million points a turn on a random walk. My first guess was its log line, so I deleted it. That saved about 0.1 million. Most of the rest is the one write to stdout that every turn needs to send its move, which costs 2.5 million on its own. The Python starter spends 5.0 million at the median, and over 20 million on its worst turns. That's fine for a random walk. It's not fine once you're running a search and every point you waste is search depth you don't get.

Finding that out took an experiment and a guess. With a real bot you want a profile that tells you directly.

## The wishlist

Here's what the series will build, in roughly this order. Each item answers one of the questions above.

| Tool | The question it answers |
| --- | --- |
| **Evaluation harness** | What happens across every map, both sides, and many bots? It runs games in parallel in the judge's sandbox, with timeouts, clean shutdown and errors kept apart from losses. |
| **Offline Elo ladder** | How does this version rank against my older ones and fixed baselines? It includes frozen copies of your own bot. |
| **Statistics** | Is the new version actually better, or did it get lucky? It gives a yes-or-no verdict from a proper test, and says how many games that takes. |
| **Map generator** | Does my bot survive maps it's never seen? It makes plausible maps modelled on the ones the ladder uses. |
| **Public replay sampler** | What are the other bots doing? It downloads public replays at a polite pace, sampled by rating. |
| **Replay decoder** | What happened in that game, turn by turn? It decodes replays and rebuilds what each dragon could see. |
| **Debug viewer** | What did my dragon think was there? It shows the board through one dragon's eyes, with its memory. |
| **Profiling** | Where do my CPU points go? It tracks cost from wall time down to individual instructions, native and WASM. |

Most of these already exist in some form in my own setup, so the posts will be write-ups of working tools, with code, rather than plans. The weird bot ideas, including the Jev test from the intro, come later. They'll be a lot more fun to judge with this lot in place.

## Next up

The evaluation harness: running lots of games in parallel without your machine or your results falling over.

Questions, heckling and "have you tried X" are all welcome 😄
