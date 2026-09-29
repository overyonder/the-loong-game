# The wishlist

> **Editor's note, 28 September 2026.** I've edited this post to be shorter, and to say what the statistics are for: telling how far a difference can be trusted, while the games themselves are where we find what to fix.

Most of us start the same way: we run `unswbc init`, get a starter bot going, and immediately have a list of ideas for making it better. Before trying any of them, though, we need a way to tell whether a change actually helped. Otherwise we're just guessing, and a guess that feels like progress is worse than no change at all.

So this post tries to answer that one question using only the official toolkit and its starter bots. Every time we get stuck, we'll write down the tool that would have got us unstuck. By the end, that list is the wishlist, and building it is the next stage of the series.

## Two starter bots and one game

`unswbc init` makes a starter bot in C, C++ or Python. To have something to compare, we'll make one in C and one in Python and play them against each other in the judge's sandbox:

![A terminal running unswbc init c alpha and unswbc init python bravo, which list the files each creates, then unswbc run --sandbox on default_small. The match uses seed 0xf80f04670677fc31, three dragons hit themselves, and team A wins after 60 rounds by elimination. Team A used 3.0M points per turn at p50, p99 and max. Team B used 5.0M at p50 and 20.4M at p99 and max.](images/unswbc-run.png)

That's one game, and it tells us who won it. It also saves a replay we can watch in the [visualiser](https://game.battlecode.au/visualiser), and prints how many CPU points each team spent, which we'll come back to at the end. One game obviously isn't statistically significant, though, and working out how many games it does take is part of what this post is about.

We can get more games easily enough. Each run picks a random seed, which decides where pearls appear and what both bots' random numbers come out as, so running the same match again gives a different game. Passing a seed back with `--seed` replays one exactly, which will be handy for debugging:

![Running the same match again without a seed gets seed 0x5007de0a57fc374d and a different 75-round game. Running it with --seed 0xf80f04670677fc31 repeats the first game exactly: the same three deaths and team A winning after 60 rounds.](images/unswbc-seed.png)

## Every map, both sides

If one game isn't enough, the natural thing is to play lots. Maps matter too, since a bot can be strong on one layout and hopeless on another, and so does which side you start on. So the obvious next move is a loop that plays every one of the 13 bundled maps, with each bot taking each side. My shell is [fish](https://fishshell.com), which has a friendlier scripting syntax than bash, so the loop is a few lines of fish, shown here with [bat](https://github.com/sharkdp/bat), a `cat` with syntax highlighting:

![A terminal showing loop.fish in bat, then time fish loop.fish printing 26 results, one per map and side, in 175.8 seconds.](images/unswbc-loop.png)

Those 26 games took nearly three minutes, and the starter bots barely think. A bot that searches takes far longer: in one of my own test runs, 600 games between stronger bots added up to 14 hours played one after another.

We're going to be improving our bot for weeks, and every change needs this kind of test, so running a loop by hand and reading the output isn't going to last. We'll want to pit a whole pool of bots against each other and keep a tidy record of every result, and since the games don't depend on each other, we can play them side by side on every core. Doing that well brings the usual chores with it: capping how many games run at once, giving up on a game that hangs, cleaning up after crashes, and not mistaking a crash for a loss.

That's the first item on the wishlist, an **evaluation harness**.

![Wishlist, 1 of 8: Evaluation harness.](images/wishlist-1.svg)

## Seventeen wins out of twenty-six

Back to the results. `alpha` won 17 of the 26 games, which looks like a clear lead. It isn't one. Both starters do exactly the same thing each turn, stepping in a random direction that isn't blocked, so neither can really be better, and two equally good bots will still produce a split at least that lopsided about 8% of the time.

This is the trap every bot developer falls into sooner or later: a handful of wins feels like proof. It takes far more games than intuition suggests. Reliably telling a bot that wins 60% of its games from an even match takes about 150 games, and a smaller improvement needs far more:

![Games needed to detect a better bot at 95% confidence and 80% power, by its true win rate: about 3,900 at 52%, 617 at 55%, 153 at 60%, 37 at 70% and 23 at 75%. A 26-game loop only catches bots that win about 74% of the time or more.](images/games-needed.svg)

So a pile of results can't be read by eye. The games are how we find what's wrong with a bot: the ones it should have won and didn't. But to say one version scores better than another, we need a tool that says how far the difference can be trusted, and how many more games it would take to be sure.

The second item is **statistics**.

![Wishlist, 2 of 8: Evaluation harness, Statistics.](images/wishlist-2.svg)

## A ladder of our own

You might wonder why we don't just upload each version and let the online ladder play the games for us. The trouble is that it's slow, noisy, and answers a different question from ours. It's slow because battles are only drawn every two hours, five games at a time, and uploads are limited to 12 an hour, so a modest improvement would take days per idea to show up. It's noisy because each new submission resets your rating's K factor to 96, which makes the rating swing hardest in exactly the games right after an upload. And even a settled rating compares you with whoever happens to be on the ladder this week, while they're changing their bots too.

What we actually want to know is whether this version beats the last one. A ladder we run ourselves can answer that, rating the current bot against frozen copies of our older versions, so a new version only counts as progress if it beats the ones before it.

The third item is an **offline Elo ladder**.

![Wishlist, 3 of 8: Evaluation harness, Statistics, Offline Elo ladder.](images/wishlist-3.svg)

## Maps nobody has seen

Everything so far has used the 13 bundled maps, but those aren't the maps that matter. The organisers have said every Sprint, Qualifier and Grand Final map will be new, and a bot that has only been tested on the bundled maps can be quietly relying on something about them.

That's already caught me out once. The docs say maps are at least 10 tiles on a side, so my bot refused to play on anything smaller. Then the ladder served a 16×8 map called Small, and every one of my dragons died in round 0. We can't tune for maps we haven't seen, but we can make lots of plausible ones and test on those.

The fourth item is a **map generator**.

![Wishlist, 4 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator.](images/wishlist-4.svg)

## Everyone else's games

So far every test has been our bot against our own bots, but the real opponents are the other teams, and every ladder battle is public. Game IDs on the site are already past 88,000. That's a huge record of what the best bots actually do, and learning from it is how we'll spot ideas worth borrowing and weaknesses worth exploiting. Nobody can watch that many games, so we need a tool that downloads a useful sample, slowly enough not to load the organisers' server.

The fifth item is a **replay sampler**.

![Wishlist, 5 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler.](images/wishlist-5.svg)

## Reading a replay

Once we have the replays, we hit the next wall. A replay file is packed binary, and opening one in a hex viewer shows the bot names and scraps of the map text, and nothing else we can read:

![hexyl showing the first 160 bytes of a replay file. The bot names alpha and bravo and parts of the map text are readable, and the rest is binary.](images/replay-hexdump.png)

To ask questions of thousands of games, like how often top bots split early, we first need to decode the format and rebuild each game turn by turn.

The sixth item is a **replay decoder**.

![Wishlist, 6 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder.](images/wishlist-6.svg)

## Through one dragon's eyes

Decoding replays helps with our own bot too. When one of our dragons does something stupid, the visualiser shows us the whole board, but the dragon never saw the whole board. It only saw the 7×7 square around its head, plus whatever it chose to remember:

![The same round of a public ladder game twice. On the left, the whole board. On the right, everything outside one ringed dragon's 7 by 7 window is darkened.](images/board-vs-window.svg)

So the question when debugging is never "what was on the board?" but "what did this dragon think was on the board?" It would be much easier with a viewer that shows exactly what one dragon saw and decided, turn by turn. I'm writing that viewer in Odin, and the next post explains why.

The seventh item is a **debug viewer**.

![Wishlist, 7 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer.](images/wishlist-7.svg)

## Where the points go

Last, back to that first game's CPU points. Each dragon gets a budget of 100 million points per turn, and a smart bot will want to spend as much of it as possible thinking. The summary tells us how much was spent, but not what it was spent on.

The C starter spends 3.0 million points a turn just walking randomly, which seemed like a lot. My first guess was the log line it writes every turn, so I deleted it, and that saved about 0.1 million. Most of the rest is the single write to stdout that every turn needs to send its move, which costs 2.5 million on its own. That's useful to know, but it took a guess and an experiment to find out. Once our bot is running a real search, every wasted point is search depth it doesn't get, and we'll want a profiler to show us where the points go directly.

The last item is **profiling**.

![Wishlist, 8 of 8: Evaluation harness, Statistics, Offline Elo ladder, Map generator, Replay sampler, Replay decoder, Debug viewer, Profiling.](images/wishlist-8.svg)

## The full wishlist

Here's how the eight tools connect, and where they'll sit around the bot next to the official toolkit:

![How the tools fit together. A bot change goes through the evaluation harness, which plays on generated maps as well as the bundled ones. Results feed the offline Elo ladder and a statistical test, which says how sure we can be of a difference, and the loop back to the bot is what to fix next. Public replays come in through the sampler, the decoder rebuilds them, and the debug viewer shows what each dragon saw, for public games and our own. Profiling sits beside the bot.](images/wishlist-map.svg)

![Our tools around the bot. The current bot sits in the middle, written in Nim with hot paths in C and compiled to WebAssembly, with numbered snapshots of earlier versions saved below it. The official toolkit is on the right: unswbc init, unswbc run --sandbox, --seed, unswbc maps, the visualiser and unswbc submit. The eight wishlist tools are on the left with their languages, all still on the wishlist: the evaluation harness, statistics, map generator, offline Elo ladder, replay sampler and replay decoder in Python, the debug viewer in Odin, profiling with perf, and the Zig judge. Ideas from the grand strategy, tactical ideas and espionage stages flow into the bot from the top.](images/pipeline-wishlist.svg)

I already have most of these working in some form, so the tools posts will walk through real, working code, and everything after that leans on them. Whenever a later post tries a strategic idea, these tools are how we'll know whether it worked.

## Next up

[Choosing a language](02-the-choice.md), which settles how much of the CPU budget is left for thinking.
