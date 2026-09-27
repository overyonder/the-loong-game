# The wishlist

> **Editor's note, 28 September 2026.** This post has been edited to be shorter.

Most of us start the same way: run `unswbc init`, get a starter bot going, and immediately have a list of ideas for making it better. Before trying any of them, we need a way to tell whether a change actually helped. This post tries to answer that one question with only the official toolkit, and every time we get stuck, it writes down the tool that would have got us unstuck. That list is the wishlist.

## Two starter bots and one game

`unswbc init` makes a starter bot in C, C++ or Python. We'll make one in C and one in Python and play them in the judge's sandbox:

![A terminal running unswbc init c alpha and unswbc init python bravo, which list the files each creates, then unswbc run --sandbox on default_small. The match uses seed 0xf80f04670677fc31, three dragons hit themselves, and team A wins after 60 rounds by elimination. Team A used 3.0M points per turn at p50, p99 and max. Team B used 5.0M at p50 and 20.4M at p99 and max.](images/unswbc-run.png)

That tells us who won one game, saves a replay for the [visualiser](https://game.battlecode.au/visualiser), and prints the CPU points each team spent. It can't tell us whether `alpha` is the better bot. Each run picks a random seed, which decides where pearls appear and what both bots' random numbers come out as, so running again gives a genuinely different game, and `--seed` replays one exactly:

![Running the same match again without a seed gets seed 0x5007de0a57fc374d and a different 75-round game. Running it with --seed 0xf80f04670677fc31 repeats the first game exactly: the same three deaths and team A winning after 60 rounds.](images/unswbc-seed.png)

## Every map, both sides

A bot can be strong on one layout and hopeless on another, and which side you start on matters too. So the obvious next step is a loop over all 13 bundled maps, with each bot taking each side:

![A terminal showing loop.fish in bat, then time fish loop.fish printing 26 results, one per map and side, in 175.8 seconds.](images/unswbc-loop.png)

Those 26 games took three minutes, and the starter bots barely think. A bot that searches takes far longer: 600 games between stronger bots once took me 14 hours played one after another. We'll be testing changes for weeks against a whole pool of bots, so we want the games played side by side on every core, a tidy record of every result, and hung or crashed games handled without mistaking a crash for a loss.

![Wishlist, 1 of 8: Evaluation harness.](images/wishlist-1.svg)

## Seventeen wins out of twenty-six

`alpha` won 17 of the 26 games. Both starters step in a random unblocked direction every turn, so neither can really be better, and two equal bots split at least that lopsidedly about 8% of the time. A handful of wins feels like proof, and it isn't. Reliably telling a bot that wins 60% of its games from an even match takes about 150 games, and a smaller edge takes far more:

![Games needed to detect a better bot at 95% confidence and 80% power, by its true win rate: about 3,900 at 52%, 617 at 55%, 153 at 60%, 37 at 70% and 23 at 75%. A 26-game loop only catches bots that win about 74% of the time or more.](images/games-needed.svg)

So "did my change help?" is a statistics question. We want an answer of better, worse or not sure yet, and how many more games it would take to be sure.

![Wishlist, 2 of 8: Evaluation harness, Statistics.](images/wishlist-2.svg)

## A ladder of our own

Why not upload each version and let the online ladder play the games? It's slow: battles are drawn every two hours, five games at a time, and uploads are limited to 12 an hour, so a modest improvement would take days to see. It's noisy: each new submission resets the K factor to 96, so the rating swings hardest right after an upload. And it measures something else, since the other teams change their bots too. What we want to know is whether this version beats the last one, and a ladder we run ourselves, with frozen copies of our older versions, answers that.

![Wishlist, 3 of 8: Evaluation harness, Statistics, Offline Elo ladder.](images/wishlist-3.svg)

## Maps nobody has seen

Every Sprint, Qualifier and Grand Final map will be new, and a bot tested only on the bundled maps can quietly depend on them. That caught me out once. The docs say maps are at least 10 tiles on a side, so my bot refused anything smaller, and then the ladder served a 16×8 map and every one of my dragons died in round 0. We can't tune for unseen maps, but we can make plenty of plausible ones.

![Wishlist, 4 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator.](images/wishlist-4.svg)

## Everyone else's games

The real opponents are the other teams, and every ladder battle is public, with game IDs already past 88,000. That's a huge record of what the best bots do, and nobody can watch it all. We need a tool that downloads a useful sample, slowly enough not to load the organisers' server.

![Wishlist, 5 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler.](images/wishlist-5.svg)

## Reading a replay

A replay file is packed binary. A hex viewer shows the bot names, scraps of the map text, and nothing else we can read:

![hexyl showing the first 160 bytes of a replay file. The bot names alpha and bravo and parts of the map text are readable, and the rest is binary.](images/replay-hexdump.png)

To ask questions of thousands of games, like how often top bots split early, we need to decode the format and rebuild each game turn by turn.

![Wishlist, 6 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder.](images/wishlist-6.svg)

## Through one dragon's eyes

When one of our dragons does something stupid, the visualiser shows the whole board, but the dragon only saw the 7×7 square around its head:

![The same round of a public ladder game twice. On the left, the whole board. On the right, everything outside one ringed dragon's 7 by 7 window is darkened.](images/board-vs-window.svg)

The debugging question is never "what was on the board?" but "what did this dragon think was on the board?" That wants a viewer that shows what one dragon saw and decided, turn by turn. I'm writing it in Odin, and the next post explains why.

![Wishlist, 7 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer.](images/wishlist-7.svg)

## Where the points go

Each dragon gets 100 million points a turn to think with, and the summary says how many were spent but not on what. The C starter spends 3.0 million a turn just walking randomly. My first guess was its per-turn log line, and deleting it saved about 0.1 million. Most of the rest is the single write to stdout that sends each move, 2.5 million on its own. Finding that took a guess and an experiment. Once the bot runs a real search, we'll want a profiler to show where the points go directly.

![Wishlist, 8 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer, Profiling.](images/wishlist-8.svg)

## The full wishlist

Here's how the eight tools connect:

![How the tools fit together. A bot change goes through the evaluation harness, which plays on generated maps as well as the bundled ones. Results feed the offline Elo ladder and a statistical test, which decides the next change. Public replays come in through the sampler, the decoder rebuilds them, and the debug viewer shows what each dragon saw, for public games and our own. Profiling sits beside the bot.](images/wishlist-map.svg)

And here's where they sit around the bot, next to the official toolkit:

![Our tools around the bot. The current bot sits in the middle, written in Nim with hot paths in C and compiled to WebAssembly, with numbered snapshots of earlier versions saved below it. The official toolkit is on the right: unswbc init, unswbc run --sandbox, --seed, unswbc maps, the visualiser and unswbc submit. The eight wishlist tools are on the left with their languages, all still on the wishlist: the evaluation harness, statistics, map generator, offline Elo ladder, replay sampler and replay decoder in Python, the debug viewer in Odin, and profiling with perf. Ideas from the grand strategy, tactical ideas and espionage stages flow into the bot from the top.](images/pipeline-wishlist.svg)

The tools posts build them one at a time, with real, working code, and every later post leans on them.

## Next up

[Choosing a language](02-the-choice.md), which settles how much of the CPU budget is left for thinking.
