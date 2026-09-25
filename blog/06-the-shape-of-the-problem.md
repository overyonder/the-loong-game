# The shape of the problem

<!-- draft: fcc4c7b128, stage: Strategic ideas -->

With the tools in place, the series turns to strategy. Before writing any, it's worth working out what kind of problem this is, because that decides what kind of bot is worth building. The short version is that this game rewards bots that are well organised and easy to change far more than it rewards raw compute or generated code. The rest of this post makes that case, looks at the main ways game AI organises an agent's decisions, and picks one for our first strategy bot.

## Not a problem to grind

When a game has a fixed simulator and a clear score, it's tempting to throw compute at it: generate thousands of candidate bots, play them against each other on a GPU for a week, and keep whatever wins. That works when the thing you're optimising against holds still. In Battlecode, very little does, for four reasons.

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

There's a standard way to think about this. Chapter 2 of Russell and Norvig's *[Artificial Intelligence: A Modern Approach](https://aima.cs.berkeley.edu/4th-ed/pdfs/newchap02.pdf)* describes environments by a handful of properties and shows how each one changes what a good agent looks like. A few of them describe Battlecode especially well.

It's *partially observable*: a dragon only sees its 7×7 window, so it has to act on an incomplete picture and remember what it can. It's *multi-agent*, and in two ways at once, competing against the other team while cooperating with its own dragons, which can't share memory. And it's *unknown* in the book's sense: the maps and opponents we'll face at the tournament aren't the ones we can test against now. On top of all that, every decision has a hard compute budget. Each of those properties pushes towards bots whose behaviour we can inspect and adjust, rather than ones tuned blindly for the conditions we happen to see today.

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

Everything above points the same way. The dragon has to decide from its own limited view, and we have to be able to find and fix bad behaviour quickly as the game and the opponents change. So our first strategy bot is a small **hierarchical state machine with scored moves inside each state**:

![The first bot's structure. Each turn, the dragon reads its 7×7 window. A safety layer removes moves into kelp, portals, bodies and tiles next to an enemy head. A mode is then chosen from what's visible: Roam when nothing threatens, Evade when an enemy head is within two tiles. The chosen mode scores the remaining moves, and the best one is sent.](images/first-bot-architecture.svg)

- **A safety layer** that no mode can overrule. It removes any move into kelp, a dragon's body, or a portal. Vision doesn't reach through portals, so a portal is only taken when there's nothing else. It also avoids tiles next to an enemy head, because dragons move in turn and a head-to-head collision kills both.
- **Modes**, chosen fresh each turn from what the dragon can see. The first version has two. It **roams** when nothing threatens it, keeping the most room, as the flood-fill bot did. It **evades** when an enemy head is within two tiles, trading a little room for distance.
- **Scores inside each mode**, so each mode can weigh its own trade-offs without adding more states.

Each part stays small enough to read, and each new behaviour arrives as a new mode or a change to one score. The verdict tool can test every change on its own.

It's written in Nim, as [The choice](02-the-choice.md) planned, and compiled to C for the judge. The code is in [examples/first-bot](../examples/first-bot/strategy.nim).

## The first result

To see whether the structure pays off, we'll test the first bot against the flood-fill bot from The choice, on the 13 bundled maps and the 20 generated ones from the last post:

![A terminal running just first-bot, which copies the bot, builds it from Nim to C, and runs the verdict. first-bot wins 78 games against room-c, loses 48 and draws 6, with no errors. The chance an even match does this well is 0.0048, and the verdict is better.](images/first-bot-verdict.png)

The first bot is better, winning 78 games to 48. Two equally good bots would produce a result that lopsided only about once in 200 tries, so this is a real improvement.

Where the gain comes from is interesting. On the bundled maps the two bots are level, 25 wins to 27. Almost all of the improvement is on the generated maps, where the first bot won 53 games to 21. The replays show why. On those maps, the first bot's dragons ran into their own bodies 7 times, against 36 times for the flood-fill bot. That's the portal blind spot from the last post, closed by the safety layer refusing to step through portals it can't see past.

It's a modest start, but it's measurably better, and now each new behaviour has an obvious place to go.

## Next up

From here the series adds behaviour one piece at a time, starting with [roles](07-roles.md): giving dragons different jobs, and letting each one work out its job by sonar.
