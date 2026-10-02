# The Loong Game blog

An open source series running alongside the UNSW Battlecode competition, with weird bot ideas, beginner tips, `unswbc` tools and WASM performance deep dives.

Posts are published at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). This folder is the only source for them. `tools/build_loong_series.py` in the `over-yonder.tech` repository reads the table below, turns each post into a page, and links files mentioned in posts to this repository on GitHub.

| # | Post | Stage | Summary |
| ---: | --- | --- | --- |
| 1 | [Introducing The Loong Game](01-the-loong-game.md) | Understanding the problem | Who I am, what the series is for, the 2026 tournament in brief, and what the official toolkit does and doesn't give you. |
| 2 | [The wishlist](02-the-wishlist.md) | Understanding the problem | Trying to improve a bot with only the stock toolkit, where that falls short, and the eight tools this series builds to fill the gaps. |
| 3 | [The choice](03-the-choice.md) | Understanding the problem | Python, C and Nim under the judge's CPU-point meter, plus Odin for tools, Zig for the host, and Rake for SIMD kernels or a whole program. |
| 4 | [The evaluation harness](04-the-evaluation-harness.md) | Building our tooling | A harness that plays every pairing on every map from both sides with shared seeds, runs games side by side, and keeps crashes apart from losses. |
| 5 | [Better, worse or undecided](05-better-worse-or-undecided.md) | Building our tooling | A sequential test that says how far a difference between two bots can be trusted, and the upset games that turn up faults to watch. |
| 6 | [Maps nobody has seen](06-maps-nobody-has-seen.md) | Building our tooling | Generating plausible unseen maps with a generator another competitor shared, and the blind spots they find in the flood-fill bot. |
| 7 | [A ladder of our own](07-a-ladder-of-our-own.md) | Building our tooling | Rating every saved version against every other with a Bradley–Terry fit of all games at once, and checking the pool for rock-paper-scissors circles. |
| 8 | [Everyone else's games](08-everyone-elses-games.md) | Building our tooling | A paced, resumable replay collector with a capped store, recent games from strong teams, pins for study, and explicit retention and deletion. |
| 9 | [Reading a replay](09-reading-a-replay.md) | Building our tooling | Decoding the packed Cap'n Proto replay format with a reader written in Nim, rebuilding each game turn by turn, and counting how dragons die. |
| 10 | [Pearls from the seed](10-pearls-from-the-seed.md) | Building our tooling | Recovering compatible pearl schedules from a replay and seed, checking hidden map variants, and refusing a reconstruction that doesn't match. |
| 11 | [Through one dragon's eyes](11-through-one-dragons-eyes.md) | Building our tooling | An Odin debug viewer that reruns a bot to show each dragon's window, decisions and graded memory, and what it shows about why chasing pearls kills. |
| 12 | [Where the points go](12-where-the-points-go.md) | Building our tooling | Profiling charged points by function and instruction class, joining compiler vectorisation remarks, and following hot code into native perf. |
| 13 | [The shape of the problem](13-the-shape-of-the-problem.md) | Grand strategy | Organising the textbook bot around role objectives, utility-selected tasks and state machines, then reviewing the first small strategy bot. |
| 14 | [Three lines](14-three-lines.md) | Grand strategy | How a numbered strategy, pinned library pieces and a shared runtime form a bot, then why textbook, foil and learned lines develop side by side. |
| 15 | [Roles](15-roles.md) | Grand strategy | Champions, workers and kamikazes as parent states over shared behaviours, each dragon working out its own role by sonar, and the bugs the replays found. |
| 16 | [Tactics](16-tactics.md) | Tactical ideas and espionage | Coiling the champion and feeding it with smaller dragons that die beside it, the numbers left to tune, and every version on one ladder. |
| 17 | [Sonar](17-sonar.md) | Tactical ideas and espionage | How sonar rays, echoes and open messages work, what 800 public replays showed about encryption and forgery, and the idea of poker over sonar. |
| 18 | [Counting room faster](18-counting-room-faster.md) | Performance | Taking the room count from Nim through bitboards to SIMD, 66 times cheaper in CPU points, and keeping it vectorised with a Rake kernel. |
| 19 | [The machine inside the judge](19-the-machine-inside-the-judge.md) | Performance | A faster Zig host with metered bot fibres, inspection-only observers, external served teams, and lockstep checks against a CPU engine reference. |
| 21 | [Games in the cloud](21-games-in-the-cloud.md) | Performance | Running big batches of games on AWS Spot workers, the standing resources declared in OpenTofu, and how every run ends on its own. |
| 22 | [Game data in columns](22-game-data-in-columns.md) | Performance | One binary format for all our game data: columns a reader maps into memory and uses without parsing, and a converter that writes them from a replay. |
| 24 | [Playing the ladder](24-playing-the-ladder.md) | Behind the bot | How we played the ranked ladder: picking opponents by expected gain, judging a bot before release, when to swap bots, and the unusual opponents we met. |
| 25 | [Modelling other teams](25-modelling-other-teams.md) | Behind the bot | What research on modelling other agents offers a public ladder, and what we did: a census of techniques, imitation, sonar decoding and determinism. |
| 26 | [Planning to play](26-planning-to-play.md) | Behind the bot | The planning line: its world model, sonar, roles, utility selection, twenty behaviours, state machines and tactical search. |
| 27 | [Learning to play](27-learning-to-play.md) | Behind the bot | The learned line: a large teacher trained by self-play, a league of past selves, and distillation into an integer student that fits the judge. |
| 31 | [Slay the Queen](31-slay-the-queen.md) | Slay the Queen | The competition changes to Slay the Queen after the Sprint, so earlier planning and learning designs are being revisited under the new rules. |

Next up: a tour of our bot.

## Stages

The series runs through these stages in order. The site shows them as a stepper at the top of each post. Planned posts keep their numbered place in that sequence as an unreleased bubble until they are published.

1. Understanding the problem
2. Building our tooling
3. Grand strategy
4. Tactical ideas and espionage
5. Performance
6. Behind the bot
7. Fun and games
8. Slay the Queen
