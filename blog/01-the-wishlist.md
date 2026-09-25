# The wishlist

Most of us start the same way: `unswbc init`, a starter bot that runs, and a list of ideas for making it better. Before trying any of them, we need a way to tell whether a change actually helped. This post tries to do that with only the official toolkit and its starter bots. Each time we get stuck, we'll add the tool that would have helped to a wishlist. These tools are one strand of the series, alongside the bot ideas, beginner tips and WASM deep dives.

## Two starter bots and one game

`unswbc init` makes a starter bot in C, C++ or Python. Here it makes one in C and one in Python, then plays them against each other in the judge's sandbox:

![A terminal running unswbc init c alpha and unswbc init python bravo, which list the files each creates, then unswbc run --sandbox on default_small. The match uses seed 0xf80f04670677fc31, three dragons hit themselves, and team A wins after 60 rounds by elimination. Team A used 3.0M points per turn at p50, p99 and max. Team B used 5.0M at p50 and 20.4M at p99 and max.](images/unswbc-run.png)

The run prints the seed, how each dragon died, who won, and how many CPU points each team spent per turn. It also writes a replay for the [visualiser](https://game.battlecode.au/visualiser). It doesn't tell us whether `alpha` is the better bot, and one game can't.

Each run picks a random seed, which sets the pearl spawns and both bots' random numbers. Running the same match again gives a different game, and passing a seed back with `--seed` reproduces one exactly:

![Two runs of the same match print different seeds and different game lengths. A third run with --seed 0xf80f04670677fc31 reproduces the first game's 60-round win.](images/unswbc-seed.png)

## Every map, both sides

The next step is a loop over all 13 bundled maps, with each bot playing each side:

![A terminal showing loop.fish in bat, then time fish loop.fish printing 26 results, one per map and side, in 175.8 seconds.](images/unswbc-loop.png)

The 26 games took nearly three minutes, and the starter bots do almost no work per turn. Stronger bots take much longer. In one of my recent offline ladders, 600 games had a median of 17 seconds each, one in ten took more than four minutes, and the longest took over nine. Played one after another, that ladder would take 14 hours.

The games don't depend on each other, so they can run in parallel on every core. That needs a few things the loop doesn't have: a cap on how many games run at once, a timeout so one stuck game can't hold up the rest, cleanup of child processes when a game crashes, and a record that keeps crashes and timeouts separate from real losses.

That's the first item on the wishlist, an **evaluation harness**.

![Wishlist, 1 of 8: Evaluation harness.](images/wishlist-1.svg)

## Seventeen wins out of twenty-six

`alpha` won 17 of the 26 games. Both starters do the same thing each turn, stepping in a random direction that isn't blocked, so a 17–9 split looks like more than it is. If the two bots are equally good, a result at least that lopsided in `alpha`'s favour still happens about 8% of the time. That's too often to rule out luck. Team A also won 16 of the 26, which could be an advantage for the first side or more noise.

Separating a real improvement from luck takes more games than most people expect. To tell a bot that wins 60% of its games from an even match, at the usual 95% confidence, takes about 150 games, and smaller improvements need far more:

![Games needed to detect a better bot at 95% confidence and 80% power, by its true win rate: about 3,900 at 52%, 617 at 55%, 153 at 60%, 37 at 70% and 23 at 75%. A 26-game loop only catches bots that win about 74% of the time or more.](images/games-needed.svg)

Whether a change helped is a statistics question. We need a test that gives a clear yes or no, and tells us how many games that answer needs.

The second item is **statistics**.

![Wishlist, 2 of 8: Evaluation harness, Statistics.](images/wishlist-2.svg)

## A ladder of our own

The online ladder already plays plenty of games, but it can't tell us whether one version of our bot beats the last:

- **It's slow.** Battles are drawn every two hours, five games each, and uploads are limited to 12 an hour.
- **It's noisy.** Each new submission resets your rating's K factor to 96, so the rating moves most right after an upload.
- **It measures something else.** Your rating compares you with whoever's on the ladder this week, and they're changing their bots too.

A ladder we run ourselves can answer it. It rates the current bot against frozen copies of our older versions and a few fixed baselines, so a new version only counts as progress if it beats the old ones.

The third item is an **offline Elo ladder**.

![Wishlist, 3 of 8: Evaluation harness, Statistics, Offline Elo ladder.](images/wishlist-3.svg)

## Maps nobody has seen

The loop only played the 13 bundled maps. The ladder has served others, and the organisers have said every Sprint, Qualifier and Grand Final map will be new.

An unseen map already caught me out once. The docs say maps are at least 10 tiles on a side, and my bot refused to play on anything smaller. Then the ladder served a 16×8 map called Small, and every one of my dragons died in round 0. We can't tune for maps we haven't seen, but we can test on lots of plausible ones.

The fourth item is a **map generator**.

![Wishlist, 4 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator.](images/wishlist-4.svg)

## Everyone else's games

Our own games only show our own bot. Every ladder battle is public, and game IDs on the site are past 88,000. Those replays show how other bots open, when they split, how they use sonar and how they die. There are far too many to watch, so we need to download a useful sample, slowly enough not to load the organisers' server.

The fifth item is a **replay sampler**.

![Wishlist, 5 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler.](images/wishlist-5.svg)

## Reading a replay

A replay file is packed binary. Opening one in a hex viewer shows the bot names and scraps of the map text, and nothing else readable:

![hexyl showing the first 160 bytes of a replay file. The bot names alpha and bravo and parts of the map text are readable, and the rest is binary.](images/replay-hexdump.png)

Before we can search the archive, we need to decode the format and rebuild the game state turn by turn.

The sixth item is a **replay decoder**.

![Wishlist, 6 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder.](images/wishlist-6.svg)

## Through one dragon's eyes

Decoded games are also what we need to debug our own bot. The visualiser shows the whole board, but a dragon only sees the 7×7 square around its head, plus whatever it chose to remember:

![The same round of a public ladder game twice. On the left, the whole board. On the right, everything outside one ringed dragon's 7 by 7 window is darkened.](images/board-vs-window.svg)

When a dragon makes a bad move, we want to know what it thought was around it. `unswbc run` can record each dragon's logs, indicator text and drawings into the replay, but we'd still be working out its view from the full board. A viewer should show one dragon's window, its memory and its decision, turn by turn.

I'm writing that viewer in Odin. It's good to try new things, and Odin is very good for graphics programming. It ships first-party vendor bindings for libraries like raylib, calling into C is easy, and memory management is granular, with the allocator chosen through an implicit context. If those terms are unfamiliar, don't worry, we'll get to them in the series.

The seventh item is a **debug viewer**.

![Wishlist, 7 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer.](images/wishlist-7.svg)

## Where the points go

The first game's summary lines say how many CPU points each team spent per turn, but not what they were spent on.

The C starter spends 3.0 million points a turn on a random walk. I guessed the log line it writes every turn was to blame, so I deleted it. That saved about 0.1 million. Most of the rest is the one write to stdout that every turn needs to send its move, which costs 2.5 million by itself. The Python starter spends 5.0 million at the median and over 20 million on its worst turns. Once a bot runs a search, every wasted point is search depth it doesn't get. Finding this took a guess and an experiment, and a real bot needs a profiler to show it directly.

The last item is **profiling**.

![Wishlist, 8 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer, Profiling.](images/wishlist-8.svg)

## The full wishlist

Here's how the eight tools connect:

![How the tools fit together. A bot change goes through the evaluation harness, which plays on generated maps as well as the bundled ones. Results feed the offline Elo ladder and a statistical test, which decides the next change. Public replays come in through the sampler, the decoder rebuilds them, and the debug viewer shows what each dragon saw, for public games and our own. Profiling sits beside the bot.](images/wishlist-map.svg)

| Tool | What it gives us |
| --- | --- |
| **Evaluation harness** | Games across every map and both sides, in parallel in the judge's sandbox, with errors kept apart from losses. |
| **Statistics** | A yes-or-no verdict on whether a change helped, and the number of games that takes. |
| **Offline Elo ladder** | Ratings against our own older versions and fixed baselines. |
| **Map generator** | Plausible maps modelled on the ladder's, for testing on maps we haven't seen. |
| **Replay sampler** | A slow, rating-ordered sample of public ladder replays. |
| **Replay decoder** | Game state rebuilt turn by turn, including what each dragon could see. |
| **Debug viewer** | The board through one dragon's eyes, with its memory and decisions. |
| **Profiling** | CPU cost from wall time down to individual instructions, native and WASM. |

I already have most of these working in some form, so the tools posts will walk through working code. They'll run alongside the rest of the series, including the weird bot ideas like the Jev test from the [intro](00-the-loong-game.md), where these tools will tell us whether an idea actually works.

## Next up

The evaluation harness, and how to run lots of games in parallel without losing results to crashes or hung games.

Questions, heckling and "have you tried X" are all welcome 😄
