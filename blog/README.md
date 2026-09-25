# The Loong Game blog

An open source series running alongside the UNSW Battlecode competition. It covers weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Posts are published at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). This folder is the only source for them. `tools/build_loong_series.py` in the `over-yonder.tech` repository reads the table below, turns each post into a page, and links files mentioned in posts to this repository on GitHub.

| # | Post | Stage | Summary |
| ---: | --- | --- | --- |
| 0 | [Introducing The Loong Game](00-the-loong-game.md) | Understanding the problem | Who I am, what the series is for, the 2026 tournament in brief, and what the official toolkit does and doesn't give you. |
| 1 | [The wishlist](01-the-wishlist.md) | Understanding the problem | Trying to improve a bot with only the stock toolkit, and the eight tools we'll need along the way. |
| 2 | [The choice](02-the-choice.md) | Understanding the problem | Python, C or C++: what the language costs in CPU points, and why this series also uses Nim and Odin. |
| 3 | [The evaluation harness](03-the-evaluation-harness.md) | Building our tooling | A harness that plays every pairing on every map from both sides, runs games side by side, and keeps crashes apart from losses. |
| 4 | [Better, worse or undecided](04-better-worse-or-undecided.md) | Building our tooling | A paired verdict that says whether a change made the bot better, weighs each game by how much the change ran, and counts every loss to a weak bot. |
| 12 | [Roles](12-roles.md) | Grand strategy | Champions, workers and kamikazes, each dragon working out its own role by sonar, and the bugs the replays found. |
| 13 | [Tactics](13-tactics.md) | Tactical ideas and espionage | Coiling the champion and feeding it: what worked, what didn't, and every version on one ladder. |

Next up: maps nobody has seen.

## Stages

The series runs through these stages in order. The site shows them as a stepper at the top of each post.

1. Understanding the problem
2. Building our tooling
3. Grand strategy
4. Tactical ideas and espionage
5. Performance
