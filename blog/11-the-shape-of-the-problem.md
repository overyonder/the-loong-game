# The shape of the problem

> **Editor's note, 28 September 2026.** This post has been rewritten to be shorter and to match how our bots are built now. The example bots were restructured into a repertoire of behaviour modules. They play exactly the same games as before, so the results stand.

With the tools in place, the series turns to strategy. First it's worth working out what kind of problem this is, because that decides what kind of bot is worth building. The short answer is that this game rewards bots that are well organised and easy to change, far more than raw compute or generated code.

## Not a problem to grind

With a fixed simulator and a clear score, it's tempting to generate thousands of candidate bots and keep whatever wins. That works when the target holds still, and here almost nothing does. Teams upload new bots twelve times an hour. Every tournament map will be new. The rules changed on 25 September, when matches started seeding pearls randomly and more than 20 teams' hardcoded pearl schedules stopped working overnight. And each dragon sees only a 7×7 window, with sonar as its only link to its team.

I learned this the expensive way. Early on I tuned a bot's decision weights with an evolutionary optimiser against a fixed set of opponents on two maps. The five best bots it produced each won only 1 to 3 of 11 games against a bot that moves at random. They had learned to beat their training opponents, and little else.

Handing the game to an AI model has the opposite problem. It produces a decent bot quickly, but every team has the same models, and the ladder fills with bots that look alike and mostly beat each other at random.

So the first real strategic choice is the bot's architecture: how its decisions are organised, so that when a dragon does something stupid we can see why, fix that one behaviour, and prove with the [verdict](04-better-worse-or-undecided.md) that the fix helped. In the terms of Russell and Norvig's *[Artificial Intelligence: A Modern Approach](https://aima.cs.berkeley.edu/4th-ed/pdfs/newchap02.pdf)*, this environment is partially observable, multi-agent in two directions at once, and unknown, with a hard compute budget on every decision. All of that favours behaviour we can inspect and adjust.

## A menu of architectures

Game AI has settled on a handful of ways to organise an agent's decisions, and real bots often mix them. The free *Game AI Pro* chapter *[Behavior Selection Algorithms](http://www.gameaipro.com/GameAIPro/GameAIPro_Chapter04_Behavior_Selection_Algorithms.pdf)* covers most of them with examples.

| Architecture | How it decides | Strengths | Weaknesses |
| --- | --- | --- | --- |
| **State machine** | The agent is in one state, and transitions move it between states. Hierarchical versions nest states inside states. | Simple, cheap and easy to trace. | Transitions multiply as states are added. |
| **Behaviour tree** | A tree of priorities and sequences, re-evaluated from the root each turn. | Modular and reactive. | Priorities are fixed in the tree's shape. |
| **Utility system** | Every option gets a score, and the best one wins. | Handles trade-offs smoothly. | Scores need tuning, and odd choices can be hard to explain. |
| **Subsumption** | Layers of reactive control, where higher layers override lower ones. | Several behaviours act at once, and reflexes win. | Hard to plan with. |
| **Belief, desire, intention** | Desires compete, and the chosen one becomes an intention held until it's done or impossible. | Commitment, so the agent doesn't dither. | Deciding when to drop an intention is subtle. |
| **Goal-oriented planning** | A planner searches for actions that reach a goal. | Finds new combinations of actions. | Replanning costs compute whenever the world changes. |
| **Hierarchical task network** | Tasks break down into subtasks by authored methods. | Plans with the designer's knowledge built in. | The methods take a lot of authoring. |
| **Search** | Minimax or Monte Carlo tree search looks ahead over moves. | Strong with a good model and budget. | Hidden information and many agents make the tree huge. |
| **Learned policy** | A trained model maps what the agent sees to an action. | Finds patterns nobody wrote down. | Needs a stable environment and lots of data. |

We don't have to pick one and live with it. The trick is to write the bot so that the architecture can be swapped.

## A repertoire, not a bot

I keep a reference layout that sorts code by what kind of thing it is, the way a textbook would. Here is the whole of that repertoire. Most files start as pseudocode notes on a technique, and a dot marks the ones a bot has needed enough to implement:

![Every file in my reference repertoire, in four folders. data_structures holds sixteen structures from array to tree. decision_architectures holds ten, from behaviour_tree to utility_ai. techniques is sorted by family: caching, constraints, control, dynamic_programming, evaluation, game_theory, inference, learning, optimisation, planning, sampling, search and sorting. games/loong holds agent, htn, utility and world, and a behaviours folder with escape, explore, forage and pursue_enemy. Dots mark the thirteen implemented modules: the behaviour tree, decision context, hierarchical state machine and utility AI, the hierarchical task network planner, and everything in games/loong.](images/kieran-repertoire.svg)

The categories set what may depend on what. Data structures, architectures and techniques are generic over their context and action types, and know nothing about this game. Only `games/loong/` does: it holds the world model, movement, the turn loop, one adapter per architecture, and one module per behaviour.

A behaviour module owns everything about one behaviour: when it's eligible, what it's worth and how it's carried out. It offers itself to each architecture through a thin factory. A bot is then assembly only, a short list of behaviours handed to an architecture. Here are two of my reference bots, built from the same four behaviours:

![Two strategy files. k_utility/strategy.nim imports the utility adapter and four behaviours, explore, forage, pursue_enemy and escape, and runs utility.run with each behaviour's utilityBehaviour factory, a score or weight for each, and a switching margin of 2. k_HTN/strategy.nim imports the HTN adapter and the same four behaviours, and runs htn.run with each behaviour's htnMethod factory, escape as an interrupt when trapped, and at most 256 expansions.](images/composition-assembly.png)

Nothing in either file knows how a behaviour works, and nothing in a behaviour knows which architecture will pick it. Our competition bot is built the same way on our own repertoire. Its main line selects behaviours by utility, with a margin that keeps a dragon on its current task until something clearly better turns up. Alongside it, experimental bots assemble the same behaviours under goal-oriented planning, subsumption, and belief, desire and intention. Each behaviour carries a factory for every architecture that uses it:

![Our escape behaviour, escape.nim, with boxes over each part. whenTrapped is its eligibility: fewer safe single steps than a minimum. execute is its execution: move away from the nearest enemy head, sprinting. Then one factory per architecture: utilityBehaviour builds a utility definition from the eligibility, a fixed score and the execution; subsumptionLayer builds a layer that takes over the whole intent; bdiDesire builds a desire that interrupts the current intention and resumes it once safe; and goapGoal and goapAction build a survival goal and an escape step for the planner.](images/composition-behaviour.png)

This is what keeps the bot loosely coupled and cheap to experiment with. Changing a bot means editing a list. Trying a new architecture means writing one generic module, one adapter, and a factory in each behaviour it needs, and every existing behaviour is then available to it. Two more rules keep the pieces honest. Hard constraints, such as illegal or fatal moves, are filtered out before anything is scored, so no behaviour's enthusiasm can outweigh a wall. And each behaviour judges moves by its own objective, instead of one global weighted sum where a role only changes the weights.

## The first strategy bot

Our first example bot is built the same way, on a small repertoire in [examples/repertoire](../examples/repertoire/games/loong/hsm.nim). Its architecture is a hierarchical state machine, entered from the root every turn: the first behaviour whose guard holds takes the turn.

![The first bot's structure. Each turn the dragon reads its 7×7 window. A state machine enters the first behaviour whose guard holds: Evade, when an enemy head is within two tiles, with the objective room plus four times the gap to the head; or Roam, with no guard and the objective room left. Movement first drops steps into kelp, bodies, portals and tiles next to an enemy head, then takes the best remaining step by the behaviour's objective.](images/first-bot-architecture.svg)

The whole bot is its assembly:

![examples/first-bot/strategy.nim: it imports the hsm adapter and the evade and roam behaviours, and runs hsm.run with a root holding evade.hsmState(within = 2) and roam.hsmState().](images/first-bot-strategy.png)

Each behaviour is one short module. Evade keeps room and opens the gap to the nearest enemy head, and its factory adds the guard that decides when it applies:

![examples/repertoire/games/loong/behaviours/evade.nim. Its objective returns the room a step leaves plus four times the gap from the step to the nearest enemy head. Its hsmState factory builds a state named Evade that applies when an enemy head is within the given distance of ours, and acts by taking the best step under that objective.](images/first-bot-evade.png)

Neither behaviour can pick a fatal step, because movement filters those out first. Steps into kelp, bodies and portals go, and so do tiles next to an enemy head, since dragons move in turn and a head-on collision kills both. Vision doesn't reach through portals, so a portal is only taken when nothing else is left:

![examples/repertoire/games/loong/movement.nim. safeSteps keeps the first steps that are open and, unless allowed, not next to an enemy head. best takes the safe steps, falls back to steps within an enemy head's reach, then to an unseen portal, then to the current facing, and otherwise returns the step the behaviour's objective scores highest.](images/first-bot-movement.png)

## The first result

We test the first bot in place of the flood-fill bot from [The choice](02-the-choice.md), on the 13 bundled maps and the 20 generated ones, over four seeds:

![A terminal running just first-bot, which copies the bot, builds it from Nim to C, and runs the verdict on four seeds. Of 264 paired games, first-bot gained 77, dropped 50 and left 137 unchanged. Random signs do this well about 3% of the time. Against the weak bots it lost 5 games that room-c won, all listed, and won 51 that room-c lost. The verdict is better.](images/first-bot-verdict.png)

Of the 264 paired games, 137 came out the same. Of the rest, the first bot gained 77 and dropped 50, which random signs match about 3% of the time, so this is a real improvement, if not a large one. Against the starters it won 51 games the flood-fill bot lost, and lost 5.

Almost all of the gain is on the generated maps: 56 gained and 25 dropped there, against 21 and 25 on the bundled maps. The replays show why. On those maps the first bot's dragons ran into their own bodies 23 times, against 74 for the flood-fill bot. That's the portal blind spot from [the map generator post](05-maps-nobody-has-seen.md), closed by movement refusing to step through portals it can't see past.

## Next up

[Roles](12-roles.md): giving dragons different jobs, and letting each one work out its job by sonar.
