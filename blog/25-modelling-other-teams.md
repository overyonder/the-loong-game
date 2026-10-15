# Modelling other teams

Every game on the ladder is public, replay and all, so every team's bot can be studied. This post goes through the research methods that fit this game, then what we actually did, which in the end wasn't much.

## The research

Albrecht and Stone's survey, [Autonomous agents modelling other agents](https://arxiv.org/abs/1709.08071) (2018), sorts the field by what a model tries to recover: the other agent's policy, its type from a known set, its plan or its goal. These papers fit this game:

- Weber and Mateas, in [A data mining approach to strategy prediction](https://doi.org/10.1109/CIG.2009.5286483) (2009), predicted a StarCraft player's strategy from the early game with classifiers trained on labelled replays. The same approach could label each team's style from our ladder's replays.
- Rabinowitz and colleagues' [Machine Theory of Mind](https://arxiv.org/abs/1802.07740) (2018) embeds a new agent from a few observed episodes, and the embeddings cluster by the kind of agent, so it could place a new opponent near the teams with the most similar play.
- Bengio and Frasconi's [input/output hidden Markov model](https://proceedings.neurips.cc/paper/1994/hash/8065d07da4a77621450aa84fee5656d9-Abstract.html) (1994) has hidden states that each map the current input to an output, which fits a dragon's hidden role choosing moves from the 7×7 window.
- Kipf and colleagues' [CompILE](https://arxiv.org/abs/1812.01483) (2019) splits recorded behaviour into reusable sub-skills, which would turn a dragon's life into a sequence of behaviours without anyone labelling them first.
- Ng and Russell's [Algorithms for Inverse Reinforcement Learning](https://ai.stanford.edu/~ang/papers/icml00-irl.pdf) (2000) recovers an agent's reward from its behaviour, here how much a team values food, safety or length.
- Lin and colleagues' [unsupervised playstyle metric](https://arxiv.org/abs/2110.00950) (2021) compares players by their actions in the same discretised states, and the 7×7 window is already one.

## Our methods

We did six things. Two follow the research: census v2's style search is Weber and Mateas's approach, and the imitation fits rebuild a policy from what an agent did.

### A census of techniques

The census counted 68 behaviours per team per game from replays, such as dragons held at round 50, pearls eaten, portal crossings and causes of death, over 2,482 public games from six rating bands on the leaderboard of 24 September. Maps differ six-fold in how much food they supply, so each band's figures were pooled map by map over one common mix of maps.

The answer was economy:

| Measure | Top band | Around 1400 |
| --- | ---: | ---: |
| Pearls eaten per round | 2.18 | 1.52 |
| Share of spawned pearls taken | 54% | 38% |
| Dragons held at round 50 | 15 | 9 |
| Round of the first split | 9 | 21 |
| Deaths with no valid move beside an allied head | 87% | 52% |

In games between teams within 75 rating points, the side that captured more of the spawned pearls won 75% of the time. Nine of the fifteen techniques on our list of ideas didn't separate the bands the expected way.

The census also found three previously unlisted behaviours. Top teams took 42% of their food from dead dragons' bodies, their own and their enemies'. Some fed their champion deliberately, as the table's last row shows, and top teams crossed portals nearly three times as often. The census had no counter for tail strikes, for a hunter shadowing a champion or for escorts, and census v2 added detectors for them.

### Census v2

We then rebuilt the census with a textbook method for each stage. Every measure became a rate over its opportunities, such as splits over the turns when a dragon could have split, and every behaviour became a detector that writes one row per event, so each count can be opened in the viewer. Bands were compared by direct standardisation over maps (Rothman, Greenland and Lash, *Modern Epidemiology*), with intervals from a bootstrap that resamples teams, because one team's games aren't independent (Efron and Tibshirani, *An Introduction to the Bootstrap*, 1993), and Benjamini and Hochberg's procedure (1995) controlled false discoveries.

We checked the detectors against our own releases, since their sources show which behaviours each one uses. Cronbach and Meehl (1955) call this validation by known groups. Only the tail strike separated the groups, at 3.6 against 2.6 per 1,000 children. Releases that never shadow a champion still scored 9.4 shadows per 1,000 enemy champion rounds, because the same geometry happens by chance, so a detector measures the excess over that baseline.

Over the newest ranked games of the 16 most active teams in each of four rating bands, 2,403 games in all, the top band split earlier, started head-ons more than twice as often and struck from the tail well above chance:

| Measure | Top band | 1500–1650 |
| --- | ---: | ---: |
| Splits per starting dragon by round 50 | 6.2 | 4.7 |
| Tail strikes per 1,000 children | 6.1 | 2.3 |

Adjusting for the rating gap, the side that recovered more corpses, held more dragons or ate more pearls was far more likely to win, though much of that follows from being ahead.

To look for styles, each team's rates were shrunk towards the population by empirical Bayes (Clayton and Kaldor, 1987), reduced to principal components and clustered by Ward's method (1963), and only clusters that held up when the teams were resampled counted (Hennig, 2007). Across 71 teams with 15 or more ranked games, no clustering held up, so the ladder's bots form one continuous population. Five outlying teams include one that almost never sprints or starts a head-on.

We also compared sequences of one to three turns between the top band and teams rated 1500–1650, looking for what Dong and Li (1999) call emerging patterns. The clearest was top-band dragons of length 2 to 4 taking no action in rounds 300–449 with a pearl in sight and room to move, which never happened in the lower band. A dragon that doesn't act dies, and its body is food, so this looks like deliberate feeding. Top-band champions of 5 to 9 also split when boxed in during the first 100 rounds about eight times as often. The study covers one day of ranked play.

### Imitation

To give our own bots sparring partners, we predicted a team's moves from its dragon's view. For seven submissions near the top, the better of a search over simple move-scoring rules and a nearest-neighbour match on the 7×7 window predicted the exact move 50% to 64% of the time on a held-out game, against 21% to 32% for always guessing the team's commonest move. It's a one-step predictor, with no memory and no sonar. None of our bots learned from a mimic, and we never submitted one.

### Sonar

We decoded other teams' sonar where we could. Across 800 replays from 20 teams, eight teams encrypted their sonar, and we validated fields in the packets of three. We found no forgeable command that would make an enemy split, and fake length claims moved none of the testable teams. A table fingerprinting 19 teams by their packets went unused.

### Upset screens

The screens behind the ram rushers and the other styles in [Playing the ladder](24-playing-the-ladder.md#opponent-styles) looked at results instead of behaviour: teams that beat much stronger ones, and how the dragons in those games died.

### Determinism

We also tested whether the top teams' bots choose moves randomly. In the opening rounds the same map and seat repeat across games, so a dragon can receive byte-identical input twice, and we rebuilt those inputs from the replays. Every sampled top team answered the repeats as consistently as our own deterministic bot did, including one that has said publicly that it trained with reinforcement learning. If that team plays a learned network, it plays the network's best move instead of sampling from it.

## The gaps

We never fitted hidden modes, such as an input/output hidden Markov model of a dragon's role, and beyond the determinism check we had no test to tell a bot built from roles and rules apart from a learned policy. Machine theory of mind, CompILE, inverse reinforcement learning and the playstyle metric never ran on our replays. Opponent modelling was a small part of our season: the census pointed our work at our own economy, and our bot models enemy positions and movement.
