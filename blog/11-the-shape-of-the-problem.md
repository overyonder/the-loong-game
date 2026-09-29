# The shape of the problem

> **Editor's note, 29 September 2026.** I've rewritten this post to be shorter and to match how our bots are built now, from a repertoire of behaviour modules. I reran the first bot's test with the sequential verdict and toolkit 1.2.2 on the new generated maps. On the first generated maps it came out better. On these, which stay within the range of the official maps, it isn't clearly better, so the section ends by looking at how it loses, in a picture retaken in the current viewer.

With the tools in place, the series turns to strategy. Before writing any, it's worth working out what kind of problem this is, because that decides what kind of bot is worth building. This game rewards bots that are well organised and easy to change far more than it rewards raw compute or generated code. The rest of this post makes that case, looks at the main ways game AI organises decisions, and shows how I lay out a bot so the organisation itself can change.

## Not a problem to grind

When a game has a fixed simulator and a clear score, it's tempting to throw compute at it: generate thousands of candidate bots, play them against each other for a week, and keep whatever wins. That works when the thing you're optimising against holds still, and in Battlecode very little does. Every team can upload a new bot twelve times an hour, so a bot trained on this week's field is tuned for opponents that won't exist at the tournament. Every tournament map will be new. Even the rules move: until 25 September every match on a map used the same pearl schedule, more than 20 teams had hardcoded those schedules, and when the toolkit started seeding matches randomly all of that tuning stopped working overnight.

![Why a bot tuned to today's ladder doesn't last. Opponents change, with teams uploading new bots twelve times an hour. Maps change, with every tournament map unseen. Rules change, as random pearl seeding broke 20 teams' hardcoded schedules overnight. And views are partial: a 7×7 window, with sonar for the rest.](images/moving-targets.svg)

I learned this the expensive way. Early on I tuned a bot's decision weights with an evolutionary optimiser, playing each candidate against a fixed set of opponents on two maps. The five best bots it produced then each played a bot that moves at random, and each won only 1 to 3 of its 11 games. They'd learned to beat the opponents they trained against, and not much else.

The opposite temptation is to describe the game to an AI model and ask for a bot. That can produce a decent bot quickly, but every team has the same models, so the ladder fills with bots that look alike, play alike and mostly beat each other at random. The teams at the top will be the ones doing something the obvious bot doesn't.

## Adaptive problems need structure

Put together, this is an adaptive, adversarial problem, played on partial information. Russell and Norvig's *[Artificial Intelligence: A Modern Approach](https://aima.cs.berkeley.edu/4th-ed/pdfs/newchap02.pdf)* has a good vocabulary for it. It's *partially observable*, since a dragon only sees its 7×7 window. It's *multi-agent* in two directions at once, competing with the other team while cooperating with teammates it can't share memory with. And it's *unknown* in the book's sense, because the maps and opponents we'll face at the tournament aren't the ones we can test against now.

![The same round of a public ladder game twice. On the left, the whole board. On the right, everything outside one ringed dragon's 7 by 7 window is darkened.](images/board-vs-window.svg)

Problems like that reward bots we can understand and change quickly. When a dragon does something stupid, we need to see why, fix that one behaviour, and prove with the [verdict](04-better-worse-or-undecided.md) that the fix helped without breaking anything else. That makes the bot's architecture, the way its decisions are organised, the first real strategic choice.

## A menu of architectures

Game AI has settled on a handful of ways to organise an agent's decisions, and real bots often mix them. The free *Game AI Pro* chapter *[Behavior Selection Algorithms](http://www.gameaipro.com/GameAIPro/GameAIPro_Chapter04_Behavior_Selection_Algorithms.pdf)* covers most of them with examples.

| Architecture | How it decides | Strengths | Weaknesses |
| --- | --- | --- | --- |
| **State machine** | The agent is in one state, and transitions move it between states. Hierarchical versions nest states inside states. | Simple, cheap and easy to trace. | Transitions multiply as states are added. |
| **Behaviour tree** | A tree of priorities and sequences, re-evaluated from the root each turn. | Modular and reactive. | Priorities are fixed in the tree's shape. |
| **Utility system** | Every option gets a score, and the best one wins. | Handles trade-offs smoothly. | Scores need tuning, and odd choices can be hard to explain. |
| **Subsumption** | Layers of reactive control, where higher layers override lower ones. | Several behaviours act at once, and reflexes win. | Hard to plan with. |
| **Belief, desire, intention** | Desires compete, and the chosen one becomes an intention held until it's done or impossible. | The agent commits instead of dithering. | Deciding when to drop an intention is subtle. |
| **Goal-oriented planning** | A planner searches for a sequence of actions that reaches a goal. | Finds new combinations of actions. | Replanning costs compute whenever the world changes. |
| **Hierarchical task network** | Tasks break down into subtasks using authored methods. | Plans with the designer's knowledge built in. | The methods take a lot of authoring. |
| **Search** | Minimax or Monte Carlo tree search looks ahead over moves. | Strong with a good model and enough budget. | Hidden information and many agents make the tree huge. |
| **Learned policy** | A trained model maps what the agent sees to an action. | Finds patterns nobody wrote down. | Needs a stable environment and lots of data. |

Choosing one of these and living with it would be a mistake, because we won't know which suits this game until we've tried several. The trick is to write the bot so the architecture can be swapped.

## The repertoire

I keep a reference layout that sorts code by what kind of thing it is, the way a textbook would. Here is the whole of it. Most files start life as pseudocode notes on a technique, and the dots mark the ones a bot has needed enough to implement:

![Every file in my reference repertoire, in four folders. data_structures holds sixteen structures from array to tree. decision_architectures holds ten, from behaviour_tree to utility_ai. techniques is sorted by family: caching, constraints, control, dynamic_programming, evaluation, game_theory, inference, learning, optimisation, planning, sampling, search and sorting. games/loong holds agent, htn, utility and world, and a behaviours folder with escape, explore, forage and pursue_enemy. Dots mark the thirteen implemented modules: the behaviour tree, decision context, hierarchical state machine and utility AI, the hierarchical task network planner, and everything in games/loong.](images/kieran-repertoire-wide.svg)

The folders also decide what may depend on what. Data structures, decision architectures and techniques are written generically, over whatever context and action types they're given, and know nothing about this game. Only `games/loong/` does. It holds the world model, movement and the turn loop, a thin adapter for each architecture, and one module per behaviour.

That last part is the heart of it. A behaviour module owns everything about one behaviour: when it's eligible, what it's worth, and how it's carried out. It offers itself to each architecture through a small factory, and a bot is then nothing but assembly, a short list of behaviours handed to an architecture. Here are two of my reference bots, built from the same four behaviours, one choosing by utility and the other planning with a task network:

![Two strategy files. k_utility/strategy.nim imports the utility adapter and four behaviours, explore, forage, pursue_enemy and escape, and runs utility.run with each behaviour's utilityBehaviour factory, a score or weight for each, and a switching margin of 2. k_HTN/strategy.nim imports the HTN adapter and the same four behaviours, and runs htn.run with each behaviour's htnMethod factory, escape as an interrupt when trapped, and at most 256 expansions.](images/composition-assembly.png)

Nothing in either file knows how a behaviour works, and nothing in a behaviour knows which architecture will pick it. That's what keeps everything loosely coupled. Changing a bot means editing a list. Trying a whole new architecture means writing one generic module, one adapter, and a factory in each behaviour it needs, and from then on every existing behaviour is available to it.

Our competition bot is built the same way on our own repertoire. Its main line chooses behaviours by utility, with a margin that keeps a dragon on its current task until something clearly better turns up. Alongside it, experimental bots assemble the same behaviours under goal-oriented planning, subsumption, and belief, desire and intention, so we can compare architectures on the same footing. Here's what that looks like from the side of one behaviour, our escape, which carries a factory for every architecture that uses it:

![Our escape behaviour, escape.nim, with boxes over each part. whenTrapped is its eligibility: fewer safe single steps than a minimum. execute is its execution: move away from the nearest enemy head, sprinting. Then one factory per architecture: utilityBehaviour builds a utility definition from the eligibility, a fixed score and the execution. SubsumptionLayer builds a layer that takes over the whole intent. BdiDesire builds a desire that interrupts the current intention and resumes it once safe. And goapGoal and goapAction build a survival goal and an escape step for the planner.](images/composition-behaviour.png)

Two more rules apply to every piece. Hard constraints, like illegal or fatal moves, are filtered out before anything is scored, so no behaviour's enthusiasm can outweigh a wall. And each behaviour judges moves by its own objective. The alternative, one big weighted score where a dragon's role only changes the weights, is exactly the kind of bot that's hard to explain when it goes wrong.

## The first strategy bot

The example bots in this series are built the same way, on a small public repertoire in [examples/repertoire](../examples/repertoire/games/loong/hsm.nim). The first one uses a hierarchical state machine, entered from the root every turn, so the first behaviour whose guard holds takes the turn:

![The first bot's structure. Each turn the dragon reads its 7×7 window. A state machine enters the first behaviour whose guard holds: Evade, when an enemy head is within two tiles, with the objective room plus four times the gap to the head. Or Roam, with no guard and the objective room left. Movement first drops steps into kelp, bodies, portals and tiles next to an enemy head, then takes the best remaining step by the behaviour's objective.](images/first-bot-architecture.svg)

The whole bot is its assembly, two behaviours handed to the state machine:

![examples/first-bot/strategy.nim: it imports the hsm adapter and the evade and roam behaviours, and runs hsm.run with a root holding evade.hsmState(within = 2) and roam.hsmState().](images/first-bot-strategy.png)

Each behaviour is one short module. Roam keeps the most room, exactly as the flood-fill bot did. Evade starts from the same room score and adds four points for every tile between the move and the nearest enemy head, so it will give up a little room to get away, and its factory adds the guard that decides when it applies:

![examples/repertoire/games/loong/behaviours/evade.nim. Its objective returns the room a step leaves plus four times the gap from the step to the nearest enemy head. Its hsmState factory builds a state named Evade that applies when an enemy head is within the given distance of ours, and acts by taking the best step under that objective.](images/first-bot-evade.png)

Neither behaviour can pick a fatal step, because movement filters those out first. It drops steps into kelp and bodies, and steps next to an enemy head, since dragons move in turn and a head-on collision kills both. It also drops portals, because vision doesn't reach through them, and only takes one when nothing else is left:

![examples/repertoire/games/loong/movement.nim. safeSteps keeps the first steps that are open and, unless allowed, not next to an enemy head. best takes the safe steps, falls back to steps within an enemy head's reach, then to an unseen portal, then to the current facing, and otherwise returns the step the behaviour's objective scores highest.](images/first-bot-movement.png)

## The first result

To see whether the structure pays off, we test the first bot against the flood-fill bot from [The choice](02-the-choice.md), on toolkit 1.2.2's 15 bundled maps and the 20 generated ones. From `examples/tooling`, `just first-bot` builds the bot from Nim to C and runs the [verdict](04-better-worse-or-undecided.md) on it:

| Candidate | Opponent | W–D–L | Elo (95% interval) | Decision | Games used |
| --- | --- | --- | --- | --- | --- |
| `first-bot` | `room-c` | 17–2–21 | −35 (−151 to +73) | not better | 40, decided at 40 (cap 155) |

It isn't better. After 40 games the first bot had won 17 and lost 21, and the test crossed its lower line. The interval runs from −151 to +73 Elo, so the first bot could be a little worse or a little better, but it isn't the +70 gain the test was built to find. It won all ten of its upset games against the starter.

Its dragons do survive better. The verdict counts deaths from each game's result file:

![Deaths per game by cause, first bot against the flood-fill bot over their 40 games. The first bot's dragons died 2.0 times a game: 0.8 hitting a wall, 0.5 hitting another dragon, 0.4 losing a head-to-head and 0.4 hitting themselves. The flood-fill bot's died 2.5 times: 0.8 hitting a wall, 0.8 hitting another dragon, 0.6 hitting themselves and 0.4 losing a head-to-head.](images/first-bot-deaths.svg)

Fewer of the first bot's dragons run into their own bodies or into other dragons, and its dragons end the game longer on average, 41.5 segments for its longest against 38.0. None of that is turning into wins yet, so the useful question is how it loses. The run played 72 games against the flood-fill bot before it stopped, and the results file says how each one ended. The first bot won 30, and 18 of those were by eliminating the flood-fill bot. It lost 30, and 18 of those went the full 500 rounds and were decided on length. It's better at fights and at staying alive, and worse at ending the game with the longest dragon.

Here's one of those length losses in the viewer, the last round of a game on the bundled Portals map:

![The debug viewer at round 499 of room-c against first-bot on Portals. Pearls fill dozens of small walled boxes across the board, each reachable only through a portal edge. Outside them the board is nearly bare. The flood-fill bot's only dragon is 4 segments long, and the first bot's three dragons, on the right, are 3 segments each.](images/first-bot-length-loss.png)

Nobody on this board grew, and it isn't for lack of food. Nearly every pearl sits in one of those small walled boxes, which a dragon can only enter through a portal, and neither bot goes looking for food, let alone through a portal to reach it. The flood-fill bot's only dragon ends 4 segments long and the first bot's three end 3 each, so a single pearl picked up by chance decided the game. Surviving with more dragons doesn't count for anything at round 500, only the longest one does, which is a job for the roles in the next post.

So the first bot is a structure more than a clear improvement, and [the ladder at the end of the tactics post](13-tactics.md#every-version-on-one-ladder) puts it only a little ahead of the flood-fill bot. Every new behaviour now has an obvious place to go.

## Next up

From here the series adds behaviour one piece at a time, starting with [roles](12-roles.md): giving dragons different jobs, and letting each one work out its job by sonar.
