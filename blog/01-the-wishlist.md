# The wishlist

<!-- draft: a2fd9e19d8 -->

The [last post](00-the-loong-game.md) ended with a first bot running. The next job is making it better, and that means knowing when a change actually helped. So in this post we'll try to answer that with nothing but the stock toolkit and the stock starter bots. Every time we hit a wall, we'll put the tool that would get us past it into a basket. By the end we'll have the wishlist the rest of the series builds.

## Starting with one game

`unswbc init` gives you a starter bot in C, C++ or Python. I made a C one called `alpha` and a Python one called `bravo`, and played them against each other in the judge's sandbox:

![A terminal running unswbc run --sandbox on default_small with alpha against bravo. Three dragons die, one by hitting itself, one by hitting a wall. Team A wins after 65 rounds by elimination. Team A used 3.0M points per turn at p50, p99 and max. Team B used 5.0M at p50, 20.3M at p99 and 20.4M at max.](images/unswbc-run.png)

That's plenty for one command: the winner, how each dragon died, the CPU points each team spent per turn, and a replay for the [visualiser](https://game.battlecode.au/visualiser). What it can't tell us is whether `alpha` is the better bot.

Running it again doesn't help either. Both starters pick a random direction each turn, but both seed their random number generator with 0, and the engine is deterministic. I ran it twice and got team A winning after 65 rounds both times. That's handy for debugging, but it means new evidence has to come from somewhere else: different maps and swapped sides.

## Every map, both sides

So we write the obvious loop, over all 11 bundled maps with each bot taking each side:

![A terminal showing loop.fish in bat, then time fish loop.fish printing 22 results, one per map and side, in 57.8 seconds.](images/unswbc-loop.png)

That took 58 seconds, and the starter bots barely think. Real bots are a different story. In one of my recent offline ladders, 600 games between stronger bots took a median of 17 seconds each, one in ten went past four minutes, and the longest took over nine. Back to back, that's 14 hours.

Games are independent, so they should run in parallel on every core. Doing that properly takes more than adding `&`, though. We need to cap how many games run at once, stop one hung game from blocking the batch, clean up child processes when something dies, and keep crashes and timeouts apart from real losses.

Into the basket goes an **evaluation harness**.

![Wishlist, 1 of 8: Evaluation harness.](images/wishlist-1.svg)

## Twelve wins out of twenty-two

Back to the loop's results. `alpha` won 12 of the 22 games, and it isn't the better bot. Both bots run the same random walk, just in different languages. Some maps even look convincing on their own: on `default`, `bravo` won from both sides.

A bot that's exactly as good as its opponent wins 12 or more of 22 about 42% of the time. To tell a bot that really wins 60% of its games from a coin flip, at the usual 95% confidence, takes about 150 games, and smaller improvements need far more:

![Games needed to detect a better bot at 95% confidence and 80% power, by its true win rate: about 3,900 at 52%, 617 at 55%, 153 at 60%, 37 at 70% and 23 at 75%. A 22-game loop only catches bots that win about 75% of the time or more.](images/games-needed.svg)

"Did my change help?" is a statistics question. We need a test that gives a yes-or-no verdict and says how many games it needs.

Into the basket goes **statistics**.

![Wishlist, 2 of 8: Evaluation harness, Statistics.](images/wishlist-2.svg)

## A ladder of our own

The online ladder already plays lots of games, but it's the wrong bench for testing a change:

- **It's slow.** Battles are drawn every two hours, five games each, and uploads are limited to 12 an hour.
- **It's noisy.** Each new submission resets your rating's K factor to 96, so the rating swings hardest right when you want to read it.
- **It measures something else.** Your rating tracks you against whoever's on the ladder this week, and they're changing their bots too.

What we want is a ladder we control. It should rate the current bot against frozen copies of our older versions and a few fixed baselines, so a new version has to beat the old ones to count as progress.

Into the basket goes an **offline Elo ladder**.

![Wishlist, 3 of 8: Evaluation harness, Statistics, Offline Elo ladder.](images/wishlist-3.svg)

## Maps nobody has seen

Our loop only played the 11 bundled maps. The ladder has served others, and the organisers have said the Sprint and Qualifier maps may differ from the ladder's.

This already bit me once. The docs say maps are at least 10 tiles on a side, and my bot trusted that and refused anything smaller. Then the ladder served a 16×8 map called Small, and every one of my dragons died in round 0. We can't tune for maps we haven't seen, but we can test on lots of plausible ones.

Into the basket goes a **map generator**.

![Wishlist, 4 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator.](images/wishlist-4.svg)

## Everyone else's games

Our own games only show us our own bot. Every ladder battle is public, though, and game IDs on the site are already past 88,000. That's a record of how other bots open, when they split, how they use sonar and how they die. Nobody's watching 88,000 games in the visualiser, so we need to fetch a useful sample of them, at a pace that doesn't hammer the organisers' server.

Into the basket goes a **replay sampler**.

![Wishlist, 5 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler.](images/wishlist-5.svg)

## Reading a replay

Once we have the replays, we find they aren't something we can grep:

![hexyl showing the first 160 bytes of a replay file. It is packed binary, with the bot names and fragments of the map text visible.](images/replay-hexdump.png)

A replay is packed binary. You can make out the bot names and the map text, and not much else. Before we can ask the archive anything, we need to decode the format and rebuild the game state turn by turn.

Into the basket goes a **replay decoder**.

![Wishlist, 6 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder.](images/wishlist-6.svg)

## Through one dragon's eyes

With games decoded, we can go back to debugging our own bot, and that's where the visualiser's view gets in the way. It shows the whole board, which none of our dragons ever sees. Each dragon sees the 7×7 square around its head, plus whatever it chose to remember:

![The same round of a public ladder game twice. On the left, the whole board. On the right, everything outside one ringed dragon's 7 by 7 window is darkened.](images/board-vs-window.svg)

When a dragon does something stupid, the question is what it thought was there. `unswbc run` can record each dragon's logs, indicator text and drawings into the replay, which helps, but we'd still be rebuilding its view in our heads. We want a viewer that shows one dragon's window, its memory and its decision, turn by turn.

I'm writing that viewer in Odin. Partly because it's good to try new things, and partly because Odin is exceptionally good for graphics programming. It ships first-party vendor bindings for libraries like raylib, calling into C is easy, and memory management is granular, with the allocator chosen through an implicit context. If those terms are unfamiliar, don't worry, we'll get to them in the series.

Into the basket goes a **debug viewer**.

![Wishlist, 7 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer.](images/wishlist-7.svg)

## Where the points go

Last stop: that first screenshot's summary lines. They say how many CPU points each team spent per turn, but not what spent them.

The C starter spends 3.0 million points a turn on a random walk. My first guess was its log line, so I deleted it. That saved about 0.1 million. Most of the rest is the one write to stdout that every turn needs to send its move, which costs 2.5 million on its own. The Python starter spends 5.0 million at the median and over 20 million on its worst turns. That's fine for a random walk. It isn't once we're running a search, where every wasted point is search depth we don't get. An experiment and a guess got us here. For a real bot we want a profile that shows it directly.

Into the basket goes **profiling**.

![Wishlist, 8 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer, Profiling.](images/wishlist-8.svg)

## The full basket

That's the wishlist. Here's how the pieces fit together:

![How the tools fit together. A bot change goes through the evaluation harness, which plays on generated maps as well as the bundled ones. Results feed the offline Elo ladder and a statistical test, which decides the next change. Public replays come in through the sampler, the decoder rebuilds them, and the debug viewer shows what each dragon saw, for public games and our own. Profiling sits beside the bot.](images/wishlist-map.svg)

| Tool | What it gives us |
| --- | --- |
| **Evaluation harness** | Games across every map and both sides, in parallel in the judge's sandbox, with errors kept apart from losses. |
| **Statistics** | A yes-or-no verdict on whether a change helped, and the number of games that takes. |
| **Offline Elo ladder** | Ratings against our own older versions and fixed baselines. |
| **Map generator** | Plausible maps modelled on the ladder's, for testing on maps we haven't seen. |
| **Replay sampler** | A polite, rating-ordered sample of public ladder replays. |
| **Replay decoder** | Game state rebuilt turn by turn, including what each dragon could see. |
| **Debug viewer** | The board through one dragon's eyes, with its memory and decisions. |
| **Profiling** | CPU cost from wall time down to individual instructions, native and WASM. |

Most of these already exist in some form in my own setup, so the posts will be write-ups of working tools, with code. The weird bot ideas, including the Jev test from the intro, come later. They'll be a lot more fun to judge with this lot in place.

## Next up

The evaluation harness: running lots of games in parallel without your machine or your results falling over.

Questions, heckling and "have you tried X" are all welcome 😄
