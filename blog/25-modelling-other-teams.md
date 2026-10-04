# Modelling other teams

Every game on the ladder is public, replay and all, so every team's bot can be studied. Research on agents that model other agents has plenty of ways to do that. This post goes through the ones that fit this game, then what we actually did. In the end, it wasn't something we did much of.

## The research

Albrecht and Stone's survey, [Autonomous agents modelling other agents](https://arxiv.org/abs/1709.08071) (2018), sorts the field by what a model tries to recover. Some methods rebuild the other agent's policy from what it did. Some match it against a set of known types. Some recognise the plan it's following, or the goal behind its moves. Several papers show what that could look like here:

- Weber and Mateas classified strategies from replays. In [A data mining approach to strategy prediction](https://doi.org/10.1109/CIG.2009.5286483) (2009), they trained classifiers on StarCraft replays labelled with each player's strategy, and predicted a player's strategy from the early game. Our ladder publishes every replay, so the same approach could label each team's style.
- Rabinowitz and colleagues' [Machine Theory of Mind](https://arxiv.org/abs/1802.07740) (2018) trains a network on many agents' behaviour. From a few observed episodes of a new agent, it builds an embedding of that agent, and the embeddings cluster by the kind of agent. Trained on ladder games, it could place a new opponent near the teams it plays like.
- Bengio and Frasconi's [input/output hidden Markov model](https://proceedings.neurips.cc/paper/1994/hash/8065d07da4a77621450aa84fee5656d9-Abstract.html) (1994) has hidden states that change over time, each mapping the current input to an output. A dragon's role fits that shape: a hidden mode such as champion or worker, each choosing moves from the 7×7 window.
- Kipf and colleagues' [CompILE](https://arxiv.org/abs/1812.01483) (2019) splits recorded behaviour into reusable sub-skills and finds where each begins and ends. That would turn a dragon's life into a sequence of behaviours without anyone naming them first.
- Ng and Russell's [Algorithms for Inverse Reinforcement Learning](https://ai.stanford.edu/~ang/papers/icml00-irl.pdf) (2000) recovers the reward an agent acts on from its behaviour: in this game, how much a team values food, safety or length.
- Lin and colleagues' [unsupervised playstyle metric](https://arxiv.org/abs/2110.00950) (2021) compares players by the actions they take in the same discretised states. The 7×7 window is already a small discrete state, so teams could be compared directly.

## Our methods

We did six things. Two follow the research: census v2's style search is Weber and Mateas's approach, and the imitation fits rebuild a policy from what an agent did.

### A census of techniques

The biggest was a census of techniques. We wrote 68 measures, each counting one behaviour per team per game from its replay: how many dragons a team holds at round 50, how many pearls it eats, how often it crosses portals, how its dragons die, and so on. We measured them over 2,482 public games, sampled from six rating bands on the leaderboard of 24 September. Maps differ six-fold in how much food they supply, so each band's figure was pooled map by map and averaged over one common mix of maps. A second test asked, for games between teams within 75 rating points, how often the side with more of a behaviour won. To check the replays were read correctly, every game's rebuilt final standings matched the engine's.

The answer was economy. Top teams ate 2.18 pearls a round against 1.52 for teams around 1400, took 54% of the pearls the map spawned against 38%, held 15 dragons at round 50 against 9, and split first at round 9 against round 21. Among close games, the side that captured more of the spawned pearls won 75% of the time. Of the fifteen techniques on our list of ideas, nine didn't separate the bands the expected way.

The census also found three behaviours nobody had listed. Top teams took 42% of their food from dead dragons' bodies, their own and their enemies'. Some fed their champion deliberately: in the top band, 87% of deaths with no valid move happened beside an allied head, against 52% around 1400. And top teams crossed portals nearly three times as often. We found those because someone wrote a counter for each once the replays suggested it. A census only sees what it counts. It had no counter for tail strikes, for a hunter shadowing a champion or for escorts, and saw champion hunting, endgame feeding and ram rushes only indirectly.

### Census v2

On 30 September we rebuilt the census as one pipeline, with each stage on a textbook method. Every measure became a count over the opportunities it had, such as splits over the turns a dragon could have split, and every named behaviour became a detector that writes one row per event, so each count can be opened in the viewer. Bands were compared by direct standardisation over maps (Rothman, Greenland and Lash, *Modern Epidemiology*), with intervals from a bootstrap that resamples teams, because one team's games aren't independent (Efron and Tibshirani, *An Introduction to the Bootstrap*, 1993). Benjamini and Hochberg's procedure (1995) controlled false discoveries across the measures.

We checked the detectors first, against our own releases, whose sources say which behaviours each uses. Cronbach and Meehl (1955) call this validation by known groups. Only the tail strike separated the groups, at 3.6 against 2.6 per 1,000 children. Champion hunts and escorts didn't separate them at all, and releases that never shadow a champion still scored 9.4 shadows per 1,000 enemy champion rounds. The same geometry happens by chance, so a detector measures the excess over that baseline rather than counting deliberate acts.

The first study took the newest ranked games of the 16 teams with the most games in each of four rating bands, 2,403 games in all. The top band split earlier, 6.2 times per starting dragon by round 50 against 4.7 for teams rated 1500–1650, and started head-ons more than twice as often. It struck from the tail 6.1 times per 1,000 children against 2.3, well above chance. Across all the games, adjusting for the rating gap, the side that recovered more corpses, held more dragons or ate more pearls was far more likely to win, though much of that follows from being ahead.

To look for styles, each team's rates were shrunk towards the population by empirical Bayes (Clayton and Kaldor, 1987), reduced to principal components and clustered by Ward's method (1963). Only clusters that held up when the teams were resampled counted (Hennig, 2007). Across 71 teams with 15 or more ranked games, no clustering held up, so the ladder's bots form one continuous population. Five teams sit far from it, such as one that almost never sprints or starts a head-on.

Last, a search for behaviour nobody had named compared runs of one to three turns, each a coarse context and the action taken, between the top band and teams rated 1500–1650. Dong and Li (1999) call these emerging patterns. The clearest was top-band dragons of length 2 to 4 taking no action in rounds 300–449 with a pearl in sight and room to move, which never happened in the lower band. A dragon that doesn't act dies, and its body is food, so this looks like the deliberate feeding the first census found. Top-band champions of 5 to 9 also split when boxed in during the first 100 rounds about eight times as often.

The study covers one day of ranked play, because the replay collector has only recorded which series are ranked since that morning.

### Imitation

We tried predicting a team's moves from what its dragon saw. For seven submissions near the top, the better of a search over simple move-scoring rules and a nearest-neighbour match on the 7×7 window predicted the exact move 50% to 64% of the time on a held-out game, against 21% to 32% for always guessing the team's commonest move. That's a one-step predictor. It carries no memory and no sonar.

We built imitation only to give our own bots sparring partners. No bot of ours learned from a mimic's choices, and we never submitted a mimic.

### Sonar

We decoded other teams' sonar where we could. Across 800 replays from 20 teams, eight teams encrypted their messages, and we validated fields in the packets of three. We found no command we could forge to make an enemy split, and fake length claims moved none of the teams we could test. We built a table that fingerprints 19 teams by their packets, and our bot never used it.

### Upset screens

The screens that found the ram rushers and the other styles in [Playing the ladder](24-playing-the-ladder.md#opponents-we-named) looked at results rather than behaviour: teams that beat much stronger ones, and how the dragons in those games died.

### Determinism

Last, we asked whether the top teams' bots draw their moves at random. From the replays, we rebuilt each dragon's input in the opening rounds, where the same map and seat repeat across games and a dragon can receive byte-identical input twice. Every top team we sampled answered those repeats as consistently as our own deterministic bot did, including one that has said publicly that it trained with reinforcement learning. If that team plays a learned network, it plays the network's best move rather than sampling from it. The test only covers openings.

## The gaps

We never fitted hidden modes, such as an input/output hidden Markov model of a dragon's role, and had no test to tell a bot built from roles and rules apart from a learned policy beyond the determinism check. Machine theory of mind, CompILE, inverse reinforcement learning and the playstyle metric never ran on our replays.

So opponent modelling was a small part of our season. The census pointed our work at our own economy, and our bot models enemy positions and movement.
