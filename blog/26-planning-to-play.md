# Planning to play

The planning bot makes its choices from rules and scores we wrote. This article follows one turn through the whole design: what each dragon believes, how it talks to its team, the roles, all twenty behaviours, and how it picks a move. The version described here is textbook-main-0025, about 11,700 lines of Nim: one strategy file that assembles behaviours from a repertoire of modules, built the way [The shape of the problem](13-the-shape-of-the-problem.md) set out.

Every dragon runs its own copy of the program. It sees the 7×7 cells round its head and whatever its teammates tell it by sonar, and nothing else. So everything below happens inside one dragon, and the team only acts as a team because every dragon runs the same rules on what it knows.

## Five layers

The design is a model-based, utility-based agent in the terms of chapter 2 of Russell and Norvig's *[Artificial Intelligence: A Modern Approach](https://aima.cs.berkeley.edu/4th-ed/pdfs/newchap02.pdf)* (4th edition, 2020). It has five layers, each a textbook technique:

1. a **world model**, recursive Bayes filters over everything the dragon can't see (Thrun, Burgard and Fox, *Probabilistic Robotics*, 2005)
2. **team roles**, where every dragon runs the same assignment so they agree without negotiating (Stone and Veloso's [locker-room agreement](https://doi.org/10.1016/S0004-3702(99)00025-9), 1999, and the plays of Browning and colleagues' [STP](https://doi.org/10.1243/095965105X9470), 2005)
3. **utility selection**, which scores every behaviour against every target and commits to the best (the infinite axis utility system of Dave Mark's *Behavioral Mathematics for Game AI*, 2009, and his GDC lectures of 2013 and 2015)
4. a **hierarchical state machine** inside each task, with interrupts that preempt it (Harel's [statecharts](https://doi.org/10.1016/0167-6423(87)90035-9), 1987, and chapter 5 of Millington and Funge's *Artificial Intelligence for Games*, 2nd edition, 2009)
5. **tactical search**, which turns the task's intent into a safe move

The code follows that shape and departs from each layer in places, which the last section lists. Here is one turn:

![One dragon's turn. Read the turn: the window, sonar and echoes. World model: memory.update keeps facts with their source and round, and belief.update runs the filters. Roles: roles.decide, the same assignment on every dragon's own picture. Task selection: every behaviour and target pair the role allows, kept within a switching margin of 2. State machine: the interrupts first, give way, rescue and evade, then the task's phases. Movement: chooseMove, legal steps, 11 safety classes, then the task's utility. The action is a move, a sprint or a split, and with none, movement's fallback. The radio sends one frame on each of the four rays, for whoever each reaches first, and teammates read them at their next turn into their own world model.](images/bot-turn.svg)

A turn may spend 100 million judge points. Optional work, such as the deeper parts of assessing a move, starts only while the turn has spent under 60 million and stops at 75 million.

## The world model

The world model has two halves. The **memory** keeps facts, each with its source and the round it was learned. Every cell of the board has a record: each side's kind (open, kelp or a portal, with the portal's landing), whether a pearl is there, its spawn timer, and what occupied it when last seen. Sight rewrites a record. A teammate's report only fills in sides that sight never described, and a pearl or timer only when it's newer. The memory also keeps teammates' statuses and tasks, sightings of enemies, and deaths.

The **belief** turns those facts into probabilities once a turn, and every later layer asks it questions rather than keeping rules of its own about how old a fact is. It has three parts:

- **Geometry.** Each unseen edge gets a chance of being open, kelp or a portal, from counts of the edges seen so far with a prior of 87% open, 12.5% kelp and 0.5% portal: a Dirichlet prior on a multinomial, as in section 3.4 of Gelman and colleagues' *Bayesian Data Analysis* (3rd edition, 2013). Official maps are symmetric, so the belief scores the three possible symmetries by how well described edges agree with their partners, and fills unseen edges from their partners in proportion. Sonar echoes then correct the edges along each ray: a ray that came back reporting nothing makes the unknown edges it crossed less likely to be kelp.
- **Pearls.** Each spawning tile's next attempt is a distribution over rounds, spread over the reset gaps we've watched there, which treats the tile as a renewal process (Feller, *An Introduction to Probability Theory and Its Applications*, volume 1, 3rd edition, 1968, chapter 13). Each cell's pearl is a two-state hidden Markov model (Rabiner's [tutorial](https://doi.org/10.1109/5.18626), 1989): out of sight, an attempt can make a pearl appear, and another dragon's head can eat it. The belief forecasts every cell's chance of a pearl for each of the next 64 rounds, so a behaviour can ask what will be there when it arrives.
- **Dragons.** Every dragon we've heard of or seen has a Bernoulli filter (Ristic and colleagues' [tutorial](https://doi.org/10.1109/TSP.2013.2257765), 2013), over a histogram as in section 4.1 of *Probabilistic Robotics*: the chance it's still alive, and a histogram over its head's cell and heading given that it is. Each round the filter predicts one move, using how often that team's dragons turn and sprint, and corrects on what our window shows, including where a dragon isn't. A dragon that dies out of sight is never seen dying, so the chance of being alive falls at the team's watched death rate, and a dragon under 1% is set aside. Across all the filters, the belief keeps at most 3,000 states a turn, choosing which to keep with Hoare's selection algorithm, [Find](https://doi.org/10.1145/366622.366647) (1961).

The memory adds three things the textbook doesn't have. It detects deaths from a body turning into pearls, and withdraws everything it knew about that dragon. A teammate still on a path this dragon claimed, a round after the claim, must outrank it, so it's believed to be a longer champion. And a distance field counts steps from our head, from the nearest teammate's head and from each visible enemy head, letting a body's cells clear as it moves off them.

## Sonar

A dragon sends one 64-bit value on each of its four rays every turn. A ray stops at the first body it meets, friend or enemy, and the sender learns only how many of its rays hit what. So the radio is transport, and behaviours decide what matters.

After the move, the radio asks the belief who each ray will meet first. A ray that will certainly hit kelp or our own body sends nothing, and so does one whose only likely reader is an enemy. For a teammate, the frame carries what that teammate probably lacks: our status and task always, then the facts it doesn't already see, newest first. With nobody likely on the line, it sends from the shared store in turn. A behaviour can also put a record on a particular ray, such as the champion's order to a teammate or its claim on the path ahead.

A frame starts with the send round mod 4, then records, each followed by a bit saying whether another follows, then at least 14 zero bits. The whole value is enciphered with SPECK64/128 ([Beaulieu and colleagues](https://eprint.iacr.org/2013/404), 2013) under the team's key. A value from any other team deciphers to noise, which passes the zero check about once in 16,000 values and must then pass every record's plausibility check. IDs, lengths and ages are written as exponential-Golomb codes (Golomb's [Run-length encodings](https://doi.org/10.1109/TIT.1966.1053907), 1966, and Teuhola's [compression method for clustered bit-vectors](https://doi.org/10.1016/0020-0190(78)90024-8), 1978), so small numbers take few bits. There are ten kinds of record:

| Record | What it carries |
| --- | --- |
| status | a dragon's length, head cell, facing, role and age |
| sighting | an enemy's head cell, the length seen, its facing and age |
| tiles | a run of cells with their east and south sides |
| pearl | a cell's pearl, and for a spawner its next due round |
| path | a champion's claim on a run of cells ahead of it, or on its coil's region |
| task | a dragon's task, its target cell and when the claim expires |
| death | a dragon that died |
| order | a command to one teammate: guard a door, or feed |
| portal | a portal's entry, side and landing |
| body | a newly split child's body |

## Roles

Each turn, every dragon builds a picture of its team from the belief: itself, and every teammate the belief places, at its likeliest cell. The team's exact size is known, so if the picture holds more dragons than that, some died unseen, and the least certainly placed are dropped. Then it fills the role slots in order, each with the best-suited dragon left:

![Role slots, filled in order. Champion, one: length 6 or more, and from round 420 any length if this dragon's picture holds the whole team; it goes to the longest. Understudy, one: from round 350, with a champion and 3 or more units; the next longest, 8 or more. Escort, one: with a champion and 4 or more units; the nearest, 4 or more shorter than the champion. Scouts, a third: while unseen board is left, with 2 or more units; the shortest. Harvesters: everyone left. Holding a role adds 3 to its suitability, and a role is kept for 20 rounds unless it stops being valid.](images/bot-roles.svg)

A dragon keeps its role for 20 rounds unless the role stops being valid: it can't take it any more, the team no longer needs it, or a teammate holding a one-place role outranks it. It also switches at once when it's assigned a one-place role that nobody holds, so the team never goes 20 rounds without a champion. Pictures differ between dragons, so their assignments can too. The rule that lets a short dragon be champion only when its picture holds the whole team came from a game where a team of twenty had eight champions at round 420.

## Choosing a task

A task is a behaviour bound to a target: a cell to reach, an enemy dragon to engage, or neither. Each turn, every behaviour the dragon's role allows offers its targets, and each eligible pair is scored as the role's weight for that behaviour times the behaviour's own formula. The best pair becomes the task, unless the current task is within 2 of it, so a dragon doesn't flip between two nearly equal plans. A task that can't act this turn gives way to the next best.

Most scores are in one unit, food: a pearl worth 80 over one plus the rounds to reach it. Fights are priced by the length they swing, and splits and orders at fixed scores set in the strategy file, so every choice competes on one scale.

A task on a cell claims it, a lightweight form of Smith's [contract net](https://doi.org/10.1109/TC.1980.1675516) (1980) with no bidding. The claim travels with the dragon's status to every teammate a ray reaches, and holds for 8 rounds unless renewed, a lease in Gray and Cheriton's sense ([Leases](https://doi.org/10.1145/74850.74870), 1989). Teammates leave a claimed cell alone unless the belief gives its owner under a 10% chance of being as near to it as they are. Two claims on one cell go to the lower ID, and the champion yields to no claim.

## Behaviours

Each role lets a different set of behaviours compete:

![What each role may do, as a grid of twenty behaviours against six roles. Eat: forage for harvesters, escorts and unassigned dragons; explore for scouts; scavenge and race for harvesters, scouts and escorts; farm for harvesters; probePortal for scouts. Grow the champion: championGrow for the champion, understudyGrow for the understudy, coil for both, escort for escorts. Split: expandSplit for every role but the understudy; standoffSplit for every role. Fight: contest, hunt and portalBlock for harvesters and escorts; strike for harvesters, scouts, escorts and unassigned dragons; tailStrike for harvesters, scouts and escorts. Orders and the end: door and feed for every role but the champion and understudy; endgame for every role.](images/bot-duties.svg)

Here is what each one does and how it scores.

| Behaviour | What it does | Score |
| --- | --- | --- |
| forage | Scores each possible move by a field over the cells within 26 steps of where it lands: each cell's chance of a pearl when we could get there, discounted 0.82 a step and saturating at 3 pearls, plus how long the ground has gone unseen and any fast spawners within 5 steps. A pearl a teammate in sight reaches first counts a quarter, one it reaches as soon counts half, so dragons share food without a message. | 80 × (the best pearl's chance over one plus the steps to it + 0.1 × the stale share of reachable ground) |
| explore | The scouts' forage, with exploring worth three times as much. | as forage, with 0.3 in place of 0.1 |
| scavenge | Heads for the nearest pearl a dead dragon's body will leave, while no teammate claims it and no enemy head gets there first. | 80 over one plus the steps |
| farm | Loops over a patch of fast spawners, tiles whose countdowns are at most a quarter of the map's median, and circles beside an empty tile whose next attempt comes due before our body would clear it. | 80 × pearls a round, at most 1, over one plus the steps |
| race | Sprints for a pearl two steps away that an enemy head would reach first by walking. | 80 |
| probePortal | A dragon of length 3 or less, before round 120 and never the team's last, walks through a portal whose landing nobody has seen. | 80 × 49 cells × the unexplored share × pearls per cell, over one plus the steps plus 3 |
| championGrow | Eats pearls it reaches a step ahead of every enemy head, or waits by the spawning tile that comes due soonest. It sheds two-segment children until the team is as large as the food supports, then keeps its body whole, and from round 350 whatever the team's size. | 120 × (1 − the corridor's risk) over one plus the rounds to eat |
| understudyGrow | The same, on pearls clear of the champion's. | as championGrow |
| coil | Harvests a region by walking one fixed cycle through every cell of it, so any pearl that spawns there lies on its path. The region is a tree of 2×2 blocks, grown while less than half of it is free. An intruder on the lane is met by splitting the body off behind a two-segment stub, which trades heads with it. The champion's coil orders a door to each of one or two entrances. | 80 × (pearls a turn + the champion's lead share), or 300 to leave or escape |
| escort | Puts itself between the champion and an enemy head within 5 of it, trading heads unless we're outnumbered, and otherwise closes on the champion. | 110 to guard, 40 to close in |
| expandSplit | Halves the dragon, or for the champion sheds two segments, while the team is under its population target, the child has room to leave and teammates don't crowd the tail. It stops at round 380. | 180 |
| standoffSplit | A lone dragon beside an enemy at least as long, with food too scarce to outgrow it, halves so its head can trade while its tail survives. | 150 |
| contest | Closes on an enemy head no longer than us within 4, taking the cells it can enter next and eating on the way. Needs a body of 4 or more. | 80 × their length ÷ their exits, over one plus the distance |
| hunt | Covers the last exit of an enemy head that has only one within 3, unless enemy heads near the exit outnumber ours. | 80 × their length over one plus the steps to the exit |
| strike | Trades heads with an enemy longer than us, or one of 8 or more and twice our length. Dragons of 8 or less also hunt one out of sight within 14 steps, where the belief places it with at least a 20% chance. Never with our last dragon, or while we're outnumbered. | 80 × (their length − ours) × the chance it's there, over one plus the steps; at least 250 plus their length for a kill in reach this turn; five times as much when the enemy may be down to its last dragon |
| tailStrike | When an enemy head will stand beside our tail, splits off a two-segment child there, which trades heads with it. Otherwise it may step or sprint so that the tail lines up next turn. | 80 × (their length − 2), or half that, less the segments a sprint pays, to set one up |
| portalBlock | Lays our body across a portal landing an enemy head can step to, so it dies if it takes that exit. | 80 × the pearls its death drops × the chance it takes that exit, over one plus the steps |
| door | On the champion's order, walks a ring across an entrance to its coil, so the lane has no way in. | 200 |
| feed | Dies beside the champion so it can eat the body. A dragon of 3 to 6 walks to it unasked from round 380 in a team of 6 or more, and dies from round 400, unless an enemy head is as close or the champion is already ringed with food. The champion can also order it. | 130 to die, 85 to travel |
| endgame | From round 420, the champion backs away from enemy heads within 3. A dragon shorter than our longest trades heads with a visible enemy at least as long as our longest and the enemy's longest, since that enemy is the one that beats us. | 500 to retreat, 400 to trade |

The population target sets how far the team splits. Where food is plentiful it's the team's cap of 63 dragons, where it's scarce 24, and in between one dragon per two spawning tiles seen and at least 24. The board caps it at one dragon per 16 cells. Splitting stops at round 380, when length starts flowing into the champion, feeding starts at 400, and the endgame at 420.

## The state machine

The task runs inside a small state machine. Three interrupts come first, in this order, and preempt any task while they apply:

1. **Give way.** A teammate's head inside cells a champion has claimed walks out by the shortest way through free cells, found by breadth-first search (Cormen, Leiserson, Rivest and Stein, *Introduction to Algorithms*, 4th edition, 2022, chapter 20), and dies only when there's no way out or the champion's head is about to meet it. The champion treats its claimed path as clear.
2. **Rescue.** With no legal step, the dragon dies whatever it does, so it splits off a child that takes all but two segments, unless every exit from the tail is known to be blocked.
3. **Evade.** With no safe single step, it sprints away from the nearest enemy head.

When none applies, the task acts. Seven behaviours work in phases, and the first phase that can act this turn runs: coil (escape, leave, follow, approach), door (destroy, leave, spin, reach), endgame (retreat, overtake), escort (guard, shadow), feed (dissolve, approach), probePortal (enter, approach) and tailStrike (strike, prepare). While an interrupt runs, the task keeps its phase and picks up where it was.

## Movement

Most behaviours don't choose a move themselves. They hand movement a target and an objective, and movement picks the safest move that serves them:

![How movement picks a move. Legal options: single steps across edges the belief holds passable for certain, and sprints of up to 3 steps, searched as a beam of 64. Assess each: exits, heads that can meet ours, survival to our length plus 2, at most 24, the squeeze, the duel and sealed allies. Then the task's utility: the caller's objective in pearls, less soft costs for a squeeze, blind landings, cramped pockets, corridors and crowding. Eleven safety classes are compared first, in order: an exit after the move; assessed within the budget; fewest heads that can meet ours, when it's our last dragon or we're outnumbered; survives the horizon; steps survived, when short of it; fewest allied heads sealed in; no squeeze now, unless trading; the duel shows no forced loss; fewest heads that can meet ours, the rest; not pinned to one contested exit; lands on a cycle. A task's target and utility only break ties within the same safety class.](images/bot-movement.svg)

A step is legal only across an edge the belief holds passable for certain, and onto a cell out of sight only if it's at least 50% likely to be empty. Routes to a target use [Dijkstra's algorithm](https://doi.org/10.1007/BF01386390) (1959), on Dial's [bucket queue](https://doi.org/10.1145/363269.363610) (1969), over every edge at least 5% likely to be passable, each priced 4 over that chance, so an uncertain shortcut costs more than a certain detour.

The last safety class, landing on a cycle, uses the 2-core of the known map, in Seidman's [k-core](https://doi.org/10.1016/0378-8733(83)90028-X) sense (1983): the cells on a cycle or on a path between cycles.

Survival is a search over our own single steps, with every other dragon frozen in place, to a depth of our length plus 2 and at most 24, within 512 expansions: a depth-limited search, as in section 3.4.4 of Russell and Norvig. Sprints of up to 3 steps are searched as a local beam of 64 (section 4.1.3). A second pass, the squeeze, bars each cell from the round the nearest enemy head could reach it. The only adversarial search is the duel: alpha-beta ([Knuth and Moore](https://doi.org/10.1016/0004-3702(75)90019-3), 1975) against the two nearest enemy heads within 6, which reply together, 4 plies deep within 8,192 expansions, and only when the nearest enemy's whole body is in view. Each opponent may reply with a sprint into our head when it would trade. Treating the two as one opponent is the paranoid search of Sturtevant and Korf's *On Pruning Techniques for Multi-Player Games* (2000), rather than the max^n of Luckhardt and Irani's *An Algorithmic Solution of N-Person Games* (1986), where each player maximises its own score.

An enemy head counts as a threat to a cell when its sprint reach takes in that cell. For the champion, our last dragon or a team the enemy outnumbers, every enemy head counts. For any other dragon, only heads no longer than it count, or up to 2 longer when its tail is at or beyond the edge of that head's window. Teammates' heads are never threats.

## Departures from the textbook

Each layer is a simpler version of its textbook form:

- There's no stage that passes a task's intent to the search. Each behaviour calls movement itself, with its own target and objective.
- A behaviour's score is one formula of its own, rather than a product of considerations on response curves.
- Selection filters only by each behaviour's own eligibility. Safety applies when the task executes, where it outranks the target.
- The state machine declares no transitions. Every compound state is an ordered list of children, rechecked every turn, and the first that can act wins.
- Survival treats every other dragon as frozen. The duel is the only search over opponents' replies, and splits and deaths never enter the search.
- There's no shared team picture. Each dragon assigns roles from what it believes, and the radio keeps those beliefs close.
- The filters are approximate: at most 300 states a dragon and 3,000 in all, and echoes correct geometry but not where dragons are.

This is the planning half of the final bot. [Learning to play](27-learning-to-play.md) follows the learned line from its teacher and critic to the small student that fits inside the judge. *A tour of our bot* will return after the Grand Final as Post 28, once the holdout that combines the two is finished.
