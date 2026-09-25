# Introducing The Loong Game

Hi all! The Loong Game is a little open source series running alongside UNSW Battlecode 2026. I'll be building tools for `unswbc`, trying out odd bot ideas and writing up what I learn along the way. This first post covers who I am, what the series is for, the tournament itself, and what you get out of the box before we start building on it.

## Who I am

<!-- namecard -->

I'm Kieran Hannigan, and I run [over|yonder](https://over-yonder.tech), a performance engineering practice. Before that I spent about ten years as a professional electrical engineer, working on critical power and integrated control systems, and finished up leading a national renewable energy team as a Principal Engineer. These days I make software faster for a living.

## What to expect

- **Weird bot ideas.** Some will work. Most won't. I'll post both! One I'm keen on is testing ~~my-name-is~~-jev to see how smart this highly hyped 'System 1' model is.
- **Beginner tips.** Getting a first bot running, reading the 7×7 window properly, and sprinting into our own tails as a rite of passage.
- **Tools for unswbc.** Round-robin harnesses, offline Elo ladders, replay analysis and whatever else I end up wanting at 2am.
- **WASM deep dives.** What our C actually compiles to under the judge's toolchain: SIMD, instruction counts, where the cycles go, and how to fit more search into the same budget.

Will this win me the tournament? Probably not. The top teams will turn up with advanced strategies and plenty of tooling behind them, and most beginner and intermediate teams won't have either. The point of this series is to raise the tide a little: share the tools, techniques and mistakes so more teams can give the top of the ladder a proper game. Everything's open source, and each post links to the code and results behind it.

And if I lose, will I retire as a performance engineer? No. I've got a get out of jail free card: the online judge only accepts C, C++ and Python source, so nobody gets to submit micro-optimised WASM kernels. We'll still dig into that in a later post :)

## The tournament

UNSW Battlecode is a bot programming competition. You write one program, and every dragon on your team runs its own copy of it. Dragons eat pearls to grow, can split in two, and can only talk to each other through sonar. Wipe out the other team, or have the longest living dragon after 500 rounds, and you win.

This is a quick overview as of 25 September. The official site at [battlecode.au](https://battlecode.au) and the [game docs](https://game.battlecode.au/docs/) have the full, current rules, so check them before relying on anything here.

### Stages

Two things run side by side. The **ladder** runs all season: every team with an active submission plays five-game battles against nearby teams, drawn automatically every two hours, and you can challenge teams yourself too. Your ladder rating only decides tournament seeding (and a few ladder-rank prizes). The **tournaments** are three one-day, seeded best-of-5 knockouts:

- **Sprint, 1 October, online.** Open to every team.
- **Qualifiers, 10 October, online.** Eligible teams only: every member has to be enrolled at a university or high school in the Asia-Pacific, or be an Asia-Pacific citizen studying elsewhere. Ten teams go through.
- **Grand Final, 17 October, in person at UNSW Sydney.** Final submissions close on 16 October.

![The 2026 season: the seed ladder runs from 21 September, the Sprint is on 1 October, the Qualifiers on 10 October, final submissions close on 16 October, and the Grand Final is on 17 October at UNSW Sydney.](images/2026-timeline.svg)

The Sprint pays $800 and $400, and the Grand Final pays from $8,000 for first down to $500 for sixth, plus a handful of sponsor awards.

### Key rules

- **Every dragon is on its own.** Each one runs a separate copy of your program with its own memory, and a split starts a fresh copy. A dragon sees only the 7×7 square around its head.
- **Sonar is the only way to talk.** Up to four 64-bit values a turn, one per direction, and whoever the ray hits gets it, friend or enemy, with no sender attached.
- **Moves are cheap until they aren't.** One step a turn is free. Sprinting several steps costs a tail segment for each extra step, and running into any body, including your own tail, kills you.
- **Each dragon gets 100 million CPU points a turn**, 48 MB of memory and one thread. Most instructions cost a point or two, and every write to stdout costs at least 2.5 million, so buffer your output.
- **Submissions are C, C++ or Python.** C and C++ are compiled to WASM by the judge's own clang at `-O2` with SIMD enabled. Uploads are a ZIP of up to 4 MB, 12 an hour.

### Clarifications from the Discord

The organisers have answered plenty of questions on Discord. These are the ones worth knowing early:

- **Tournament maps are unseen.** Sprint and Qualifier maps may differ from the ladder's, though they won't be wildly out of distribution. Don't tune your bot to the current map pool.
- **Head-on collisions killing both dragons is intended**, and it's staying.
- **Each new submission resets your rating volatility.** K starts at 96 for a submission's first rated battle and falls to 24 from its eleventh, so a fresh upload swings your rating harder than an old one.
- **Eligibility needs a resume on file.** The leaderboard's eligible flag comes from your profile, and resumes are due before the Qualifiers on 10 October.
- **There's a bug bounty but no staging server.** Report vulnerabilities you find while playing, with a sketch the organisers can test, and don't take the live site down proving one.

## What you get out of the box

The organisers' `unswbc` toolkit is a Python package (`uv tool install unswbc`), and it covers the basics well:

- **`unswbc init`** creates a starter bot in Python, C or C++, with a helper library that handles the engine protocol.
- **`unswbc run`** plays one match between two bots on a map and writes a replay. Add `--sandbox` to run under the judge's CPU-point pricing and limits.
- **The judge's clang** comes with it, so C and C++ bots build exactly as they will online.
- **`unswbc maps`** adds the bundled maps, and **`unswbc vscode`** installs a replay viewer for VS Code and friends.
- **`unswbc auth`** and **`unswbc submit`** upload your bot.

The website adds the docs, a [visualiser](https://game.battlecode.au/visualiser) for replays, a map editor, the leaderboard, public replays of every battle and an API.

What you don't get is everything between one match and knowing whether a change helped. That's what this series will build, starting with the next post.

## Next up

[Post 1](01-the-wishlist.md) looks at what the toolkit can't tell you yet, and turns that into a wishlist of tools for the rest of the series.

Questions, heckling and "have you tried X" are all welcome 😄
