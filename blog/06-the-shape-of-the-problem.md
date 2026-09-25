# The shape of the problem

<!-- draft: fcc4c7b128, stage: Strategic ideas -->

With the tools in place, the series turns to strategy. Before writing any, it's worth working out what kind of problem this is, because that decides what kind of bot is worth building. This post argues that the game rewards adaptable, well-structured bots more than raw compute or generated code, walks through the main ways to structure a game-playing agent, and commits to one for our first strategy bot.

## Not a problem to grind

When a game has a fixed simulator and a clear score, it's tempting to throw compute at it: generate thousands of candidate bots, play them against each other on a GPU for a week, and keep whatever wins. That works when the thing you're optimising against holds still. Here, very little does.

- **The opponents change.** Every team on the ladder can upload a new bot twelve times an hour. A bot trained to beat this week's field is tuned for opponents that won't exist at the tournament.
- **The maps change.** Every Sprint, Qualifier and Grand Final map will be new. The [map generator post](05-maps-nobody-has-seen.md) showed how a bot that looks solid on the bundled maps can have a blind spot the moment the boards change.
- **The rules change.** Until 25 September every match on a map used the same pearl schedule, and more than 20 teams hardcoded those schedules. Toolkit 1.1.0 and the judge now seed each match randomly, and all of that tuning stopped working overnight.
- **Each dragon sees very little.** A dragon sees a 7×7 window, can't see through portals, and shares nothing with its teammates except sonar. Much of the state that matters is hidden.

I learned this the expensive way. Early on I tuned a bot's decision weights with an evolutionary optimiser, playing each candidate against a fixed set of opponents on two maps. The five best bots it produced were then each played against a bot that moves at random, and each won only 1 to 3 of its 11 games. They had learned to beat the opponents they trained against, and not much else.

## Not a problem to hand to a model

The opposite temptation is to describe the game to an AI model and ask it for a bot. That can produce a decent bot quickly. But every team has the same models, and the ladder will be full of bots written that way. They'll look similar and play similarly, and they'll mostly beat each other at random. The teams at the top will be the ones doing something the obvious bot doesn't: noticing what the others do, exploiting a rule the others missed, or building a bot that holds up on maps and opponents it hasn't met.

## Adaptive problems need structure

Put together, this is an adaptive, adversarial problem. The opponents, the maps and even the rules shift, and each agent acts on partial information. Problems like that reward bots that can be understood and changed quickly. When a dragon does something stupid, we need to see why, fix that one behaviour, and prove with the [verdict tool](04-better-worse-or-undecided.md) that the fix helped, without breaking everything else.

That makes the bot's architecture, the way its decisions are organised, the first real strategic choice.

Chapter 2 of Russell and Norvig's *[Artificial Intelligence: A Modern Approach](https://aima.cs.berkeley.edu/4th-ed/pdfs/newchap02.pdf)* is the standard reference for this kind of reasoning. It classifies environments by whether they're fully or partially observable, single or multi-agent, deterministic or stochastic, static or dynamic, and known or unknown, and shows how each property shapes the right agent design. By that classification, Battlecode is partially observable, multi-agent (competitive between teams and cooperative within one), stochastic, sequential and unknown, with a hard compute budget on every decision.

## A menu of control architectures

Game AI has settled on a handful of ways to organise an agent's decisions. This list isn't exhaustive, and real bots often mix them. For a fuller survey, the free chapter *[Behavior Selection Algorithms: An Overview](http://www.gameaipro.com/GameAIPro/GameAIPro_Chapter04_Behavior_Selection_Algorithms.pdf)* from *Game AI Pro* covers most of them with examples.

| Architecture | How it decides | Strengths | Weaknesses |
| --- | --- | --- | --- |
| **Finite-state machine** | The agent is in one state, such as feeding or fleeing, and fixed transitions move it between states. | Simple, cheap and easy to trace. | Transitions multiply as states are added. |
| **Hierarchical state machine** | States contain sub-states, and shared transitions live on the parent. | Scales to more behaviours and keeps related logic together. | Still hand-authored, and a state change can hide a mistake. |
| **Behaviour tree** | A tree of priorities and sequences is re-evaluated from the root each turn. | Modular and reactive. Branches are reusable. | Priorities are fixed in the tree's shape, and deep trees get hard to read. |
| **State tree** | Hierarchical states whose selection works like a behaviour tree, as in Unreal Engine's StateTree. | Combines a state machine's memory with a tree's reactive selection. | Newer, with fewer published patterns. |
| **Utility system** | Every option gets a score, and the best one wins. | Handles trade-offs smoothly and degrades gracefully. | Scores need tuning, and odd choices are hard to explain. |
| **Goal-oriented planning (GOAP)** | A planner searches for a sequence of actions that reaches a goal. | Finds novel combinations of actions. | Planning costs compute every time the world changes. |
| **Hierarchical task network (HTN)** | Tasks break down into subtasks using authored methods. | Plans with the designer's knowledge built in. | The methods take a lot of authoring. |
| **Search** | Minimax or Monte Carlo tree search looks ahead over possible moves. | Strong when the model of the game is good and the budget allows. | Hidden information and many agents make the tree huge. |
| **Learned policy** | A trained model maps what the agent sees to an action. | Can find patterns nobody wrote down. | Needs a stable environment and lots of data. |

## What we're building

Given a partially observable, adversarial and changing game, and a need to see and fix behaviour quickly, our first strategy bot is a small **hierarchical state machine with scored moves inside each state**:

![The first bot's structure. Each turn, the dragon reads its 7×7 window. A safety layer removes moves into kelp, portals, bodies and tiles next to an enemy head. A mode is then chosen from what's visible: Roam when nothing threatens, Evade when an enemy head is within two tiles. The chosen mode scores the remaining moves, and the best one is sent.](images/first-bot-architecture.svg)

- **A safety layer** that no mode can overrule. It removes any move into kelp, a dragon's body, or a portal. Vision doesn't reach through portals, so a portal is only taken when there's nothing else. It also avoids tiles next to an enemy head, because dragons move in turn and a head-to-head collision kills both.
- **Modes**, chosen fresh each turn from what the dragon can see. The first version has two. It **roams** when nothing threatens it, keeping the most room, as the flood-fill bot did. It **evades** when an enemy head is within two tiles, trading a little room for distance.
- **Scores inside each mode**, so each mode can weigh its own trade-offs without adding more states.

Each part stays small enough to read, and each new behaviour arrives as a new mode or a change to one score. The verdict tool can test every change on its own.

It's written in Nim, as [The choice](02-the-choice.md) planned, and compiled to C for the judge. The code is in [examples/first-bot](../examples/first-bot/strategy.nim).

## The first result

Against the flood-fill bot, on the 13 bundled maps and the 20 generated ones:

![A terminal running just first-bot, which copies the bot, builds it from Nim to C, and runs the verdict. first-bot wins 78 games against room-c, loses 48 and draws 6, with no errors. The chance an even match does this well is 0.0048, and the verdict is better.](images/first-bot-verdict.png)

The first bot is better, 78 wins to 48, and an even match would do that well about 1 time in 200. The gain comes almost entirely from the generated maps. On the bundled maps the two bots are level, 25 wins to 27. On the generated maps the first bot won 53 games to 21. There, its dragons ran into their own bodies 7 times against the flood-fill bot's 36, which is the portal blind spot from the last post closing, and into other dragons 24 times against 42. It's a modest start, but it's measurably better, and there's a clear place to put each new behaviour.

## Next up

From here the series adds behaviour one mode at a time, starting with feeding: the pearl-seeking change that failed in the verdict post, now inside a structure that can tell when it's safe to eat.

Questions, heckling and "have you tried X" are all welcome 😄
