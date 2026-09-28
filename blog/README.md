# The Loong Game blog

An open source series running alongside the UNSW Battlecode competition. It covers weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Posts are published at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). This folder is the only source for them. `tools/build_loong_series.py` in the `over-yonder.tech` repository reads the table below, turns each post into a page, and links files mentioned in posts to this repository on GitHub.

| # | Post | Stage | Summary |
| ---: | --- | --- | --- |
| 0 | [Introducing The Loong Game](00-the-loong-game.md) | Understanding the problem | Who I am, what the series is for, the 2026 tournament in brief, and what the official toolkit does and doesn't give you. |
| 1 | [The wishlist](01-the-wishlist.md) | Understanding the problem | Trying to improve a bot with only the stock toolkit, and the eight tools we'll need along the way. |
| 2 | [The choice](02-the-choice.md) | Understanding the problem | Python, C or C++: what the language costs in CPU points, and why this series also uses Nim, Odin, Zig and Rake. |
| 3 | [The evaluation harness](03-the-evaluation-harness.md) | Building our tooling | A harness that plays every pairing on every map from both sides with shared seeds, runs games side by side, and keeps crashes apart from losses. |
| 4 | [Better, worse or undecided](04-better-worse-or-undecided.md) | Building our tooling | A paired verdict that says whether a change made the bot better, weighs each game by how much the change ran, and counts every loss to a weak bot. |
| 5 | [Maps nobody has seen](05-maps-nobody-has-seen.md) | Building our tooling | Generating plausible unseen maps, and the portal blind spot they find in the flood-fill bot. |
| 6 | [A ladder of our own](06-a-ladder-of-our-own.md) | Building our tooling | Rating every saved version against every other, and checking the pool for rock-paper-scissors circles. |
| 7 | [Everyone else's games](07-everyone-elses-games.md) | Building our tooling | A polite sampler that downloads the top public replays without loading the organisers' site. |
| 8 | [Reading a replay](08-reading-a-replay.md) | Building our tooling | Decoding the packed replay format, rebuilding each game turn by turn, and counting how dragons die. |
| 9 | [Through one dragon's eyes](09-through-one-dragons-eyes.md) | Building our tooling | An Odin debug viewer that shows a game through one dragon's window and memory, and why chasing pearls kills. |
| 10 | [Where the points go](10-where-the-points-go.md) | Building our tooling | Profiling a bot with the judge's own clock, and following the flood fill down to its instructions with perf. |
| 11 | [The shape of the problem](11-the-shape-of-the-problem.md) | Grand strategy | Why this game rewards structure over raw compute, a menu of control architectures, a repertoire that keeps them swappable, and the first strategy bot assembled from behaviour modules. |
| 12 | [Roles](12-roles.md) | Grand strategy | Champions, workers and kamikazes as parent states over shared behaviours, each dragon working out its own role by sonar, and the bugs the replays found. |
| 13 | [Tactics](13-tactics.md) | Tactical ideas and espionage | Coiling the champion and feeding it: what worked, what didn't, and every version on one ladder. |
| 16 | [The machine inside the judge](16-the-machine-inside-the-judge.md) | Performance | A judge written in Zig that plays the toolkit's games four times faster, why running bots as fibres rules out a race that kills freshly split dragons, and the machine the meter presents to a bot. |
| 17 | [Games in the cloud](17-games-in-the-cloud.md) | Performance | Running big batches of games on AWS Spot workers, the standing resources declared in OpenTofu, and how every run ends on its own. |
| 18 | [Game data in columns](18-game-data-in-columns.md) | Performance | One binary format for all our game data: columns a reader maps into memory and uses without parsing, and a converter that writes them from a replay. |

Next up: sonar.

## Stages

The series runs through these stages in order. The site shows them as a stepper at the top of each post.

1. Understanding the problem
2. Building our tooling
3. Grand strategy
4. Tactical ideas and espionage
5. Performance
