# Introducing The Loong Game

Hi all! The Loong Game is a little open source series running alongside UNSW Battlecode 2026. I'll be building tools for `unswbc`, trying out odd bot ideas and writing up what I learn along the way. This first post sets the scene: who I am and why I'm doing this, then a quick look at the tournament and the tools it comes with.

## Who I am

<!-- namecard -->

I'm Kieran Hannigan, and I run [over|yonder](https://over-yonder.tech), a performance engineering practice. Before that I spent about ten years as a professional electrical engineer, working on critical power and integrated control systems, and finished up leading a national renewable energy team as a Principal Engineer.

## What to expect

- **Weird bot ideas.** Some will work. Most won't. I'll post both! One I'm keen on is testing ~~my-name-is~~-jev to see how smart this highly hyped 'System 1' model is.
- **Beginner tips.** Getting a first bot running, reading the 7×7 window properly, and sprinting into our own tails as a rite of passage.
- **Tools for unswbc.** Round-robin harnesses, offline Elo ladders, replay analysis and whatever else I end up wanting at 2am.
- **WASM deep dives.** What our C actually compiles to under the judge's toolchain: SIMD, instruction counts, where the cycles go, and how to fit more search into the same budget.

Will this win you the tournament? Probably not on its own. The top teams will turn up with advanced strategies and plenty of tooling behind them, and most beginner and intermediate teams won't have either. The point of this series is to raise the tide a little: share the tools, techniques and mistakes so more teams can give the top of the ladder a proper game. Everything's open source, and each post links to the code and results behind it.

And if I lose, will I retire as a performance engineer? No. I've got a get out of jail free card: the online judge only accepts C, C++ and Python source, so nobody gets to submit micro-optimised WASM kernels. We'll still dig into that in a later post :)

## The tournament

UNSW Battlecode is a bot programming competition. You write one program, every dragon on your team runs its own copy, and each dragon sees only the 7×7 square around its head. Dragons eat pearls, split, and talk only through sonar. The [official site](https://battlecode.au) and [game docs](https://game.battlecode.au/docs/) have the full, current rules.

![The 2026 season: the seed ladder runs from 21 September, the Sprint is on 1 October, the Qualifiers on 10 October, final submissions close on 16 October, and the Grand Final is on 17 October at UNSW Sydney.](images/2026-timeline.svg)

The ladder runs all season and sets the tournament seeding. The Sprint is open to every team. The Qualifiers and the in-person Grand Final are only for eligible teams: everyone on the team has to study in the Asia-Pacific, or be an Asia-Pacific citizen studying overseas. Two things the organisers have said on Discord are worth knowing early:

- **Tournament maps are unseen**, so don't tune your bot to the ladder's maps.
- **Each new submission resets your rating's K factor**, so a fresh upload swings your rating harder.

The organisers' `unswbc` toolkit covers the basics well. It gives you a starter bot to build on, and it runs matches in the same sandbox the judge uses, compiled with the judge's own clang, so a game on your machine plays out the way it would on the ladder. The website adds the documentation, a replay visualiser and the public replays of every ladder battle.

## Missing pieces

The toolkit gets you as far as playing a game and watching it. What it won't tell you is whether your changes are actually helping, and that's essential if we want to improve a bot. Beyond that, we'll want to know why our dragons die and what they could see at the time, so we can tell whether they could have done anything about it. And we'll want to know where the CPU budget goes, to see whether more of it could have been spent finding a way out.

Building those tools is the next stage of the series, and the [next post](01-the-wishlist.md) works out exactly which ones we need. After that the series turns to strategy, and eventually to squeezing more out of that CPU budget in the WASM deep dives.
