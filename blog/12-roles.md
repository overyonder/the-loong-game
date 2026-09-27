# Roles

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to show the roles bot as it's built now, from behaviour modules in a shared repertoire. It plays exactly the same games as before, so the results stand.

The [first strategy bot](11-the-shape-of-the-problem.md) treats every dragon the same. But dragons on the same team aren't in the same position. One is long and carries the team's chance of winning at round 500, and another is two segments long and not worth much alive. This post gives dragons different roles, so the same program behaves differently depending on who's running it, and uses sonar to let each dragon work out its own role.

## Why dragons need different jobs

Two of the game's rules pull our dragons in opposite directions, and that's what makes roles worth having. If neither team is wiped out, the winner at round 500 is the team with the longest living dragon, so whichever of our dragons is longest carries the whole team's result. And when two heads meet, both dragons die, however long each of them was:

![Two rules that pull dragons in opposite directions. At round 500, if neither team is wiped out, the longest living dragon wins, so our longest dragon should grow and stay out of trouble. In a head-on collision both dragons die, however long each was, so a two-segment dragon has almost nothing to lose.](images/two-rules.svg)

So a long dragon should avoid enemy heads and a short one should seek them out, and the plan is three roles:

- The **champion** is the team's longest dragon. It plays for length.
- A **kamikaze** is a short dragon, three segments or fewer, with a longer teammate to protect. It hunts enemy heads.
- A **worker** is everyone else, and plays exactly like the first bot.

## One program, three roles

Every dragon runs the same program as a separate process with its own memory, and nothing tells a dragon it's the champion. It has to work that out for itself, and the only way to learn about teammates out of sight is sonar. So each turn every dragon announces its length, and each one remembers the longest teammate it has heard from in the last 12 turns and picks its role from that:

![How a dragon picks its role. It listens for the longest teammate heard in the last 12 turns. If it is at least that long, it is the champion. Otherwise, if it has three segments or fewer, it is a kamikaze, and if not, a worker.](images/roles-rule.svg)

The role doesn't replace the first bot's state machine. It adds a layer on top: each role is a parent state with a guard, and its children are the behaviours that role is allowed to use. The champion also gets a reflex, a check that runs before its children and can take the turn for itself, which we'll need further down:

![The roles bot's structure. Each turn the dragon listens to sonar and reads its window. The state machine enters a role from its length and the longest teammate heard: Champion with Split, Evade and Roam. Kamikaze with Hunt and Roam. Worker with Evade and Roam. Then the first behaviour whose guard holds. Split and Hunt's strike act as reflexes. Movement drops deadly steps, only Hunt may step next to an enemy head, and the best remaining step by the objective is taken. The dragon moves or splits, then announces its team tag, ID, role and length.](images/roles-architecture.svg)

Because behaviours are modules, the roles bot is still just an assembly. The same `evade` and `roam` modules the first bot used now appear under more than one role, alongside a new `hunt` behaviour for kamikazes and the sonar protocol:

![examples/roles-bot/strategy.nim. hsm.run is given a root with three roles. roles.champion holds evade.hsmState(within = 2) and roam.hsmState(), with split.reflex(atLength = 10, childSize = 3). roles.kamikaze holds hunt.hsmState() and roam.hsmState(). roles.other names the Worker role and holds evade and roam. The call also passes sonar = length_radio.create(memoryTurns = 12) and indicate = 1.](images/roles-bot-strategy.png)

The roles themselves are three tiny factories, each a guard on a parent state:

![examples/repertoire/games/loong/roles.nim. champion builds a state named Champion that applies when the dragon's length is at least the longest teammate heard, with an optional reflex. kamikaze builds a state that applies at three segments or fewer. other builds an unguarded state under the name of the job its dragons do.](images/roles-bot-roles.png)

Hunt is the one new behaviour. It keeps just enough room to stay alive, then scores a move higher the closer it gets to an enemy head. When the head is right next to it, its reflex skips the scoring and drives straight in. It's also the only behaviour movement allows to step next to an enemy head, because that's the point:

![examples/repertoire/games/loong/behaviours/hunt.nim. The objective returns the room left, capped at 6, minus ten times the gap to the nearest enemy head. The strike reflex returns a move into an adjacent, open enemy head. The hsmState factory builds a Hunt state that applies when an enemy head is in sight, with strike as its reflex, and acts by the best step under its objective with enemy reach allowed.](images/roles-bot-hunt.png)

## Talking by sonar

Sonar is simple, and that simplicity is what makes it tricky. A message is a single 64-bit number, sent out as a ray that travels in a straight line until it hits kelp or a dragon segment, and whichever dragon it hits receives the number. It carries nothing else, not even who sent it or which team they're on, so an enemy in the way hears it just as clearly as a teammate would. That means a dragon needs a way to tell our messages from everyone else's, so every message we send starts with a fixed team tag, and a dragon ignores anything without it:

![One sonar message, 64 bits. The top 32 bits hold the team tag 0x4C4F4F4E, which spells LOON. Bits 31 to 16 hold the sender's ID, bits 15 to 12 its role, and bits 11 to 0 its length.](images/sonar-message.svg)

The tag stops a dragon mistaking random enemy traffic for a teammate. It won't stop an opponent who decodes our messages and copies it. Packing and unpacking take a couple of shifts each way, and decoding also throws away our own messages, for a reason the replays turned up below:

![examples/repertoire/games/loong/length_radio.nim. encode puts the team tag in the top 32 bits, then the sender's ID, its role and its length. decodeLength returns -1 when the tag is wrong or the sender is this dragon, and the length otherwise.](images/roles-bot-sonar.png)

## The first try was worse

Since the champion carries the team's hopes for round 500, the first version played it extra carefully, keeping three tiles from enemy heads instead of the usual two. Against the first bot, that version lost. The chart shows it, along with every variant I tried while working out why, each as the share of changed games it gained in the paired verdict from [the statistics post](04-better-worse-or-undecided.md):

![Each change against the first bot, as the share of changed games it gained, out of 132 paired games. Roles, first try: 12 gained, 26 dropped, worse. No kamikazes: 10–25, worse. No kamikazes with a narrower champion berth: no game changed, undecided. Narrower champion berth: 3–4, undecided. Champion splits at length 10: 39–4, better. Splits, but children work instead: 35–8, better. Splits, and ignores its own echo: 39–5, better.](images/roles-experiments.svg)

When a change comes out worse, the useful thing is to test its pieces separately, and the verdict makes that cheap. Removing the kamikazes didn't help, so they weren't the problem. A control that removed them and gave the champion the normal two-tile berth played every one of its 132 games exactly as the first bot did, which showed the sonar itself cost nothing. That left the berth: keeping three tiles from enemy heads made the champion too timid to hold its ground. Narrowing it brought the roles bot level with the first bot.

A level result isn't an improvement, though, and the pairing showed why. Only 7 of the 132 games came out any differently, and counting role labels in the replays explained it: only 1.7% of dragon-turns were kamikaze turns. Short dragons with a longer teammate nearby were rare, so the role hardly ever came into play.

## Making kamikazes

If kamikazes are rare because short dragons are rare, the answer is to make short dragons on purpose. A dragon can split, turning the end of its body into a new dragon, so now a champion that reaches 10 segments splits off its last three. That's the champion's reflex from the assembly above:

![How a champion makes a kamikaze. A champion of length 10 splits off its last three segments, which become a new dragon running a fresh copy of the program. On its first turn the child hears the champion announce length 10 by sonar, so it knows a longer teammate exists and takes the kamikaze role.](images/split-makes-kamikaze.svg)

The child is a new dragon running a fresh copy of the program, with no memory. Nothing tells it to be a kamikaze. It hears the champion announce length 10, sees that it's only three segments long, and picks the role itself.

With splitting, the roles bot beat the first bot convincingly, as the chart above shows. But that mixes two changes, since there are more dragons now and the new ones hunt. To separate them, I tried a version that split in exactly the same way but made its children ordinary workers. That also beat the first bot, so having more dragons helps on its own. Playing the two versions directly against each other, weighting each game by the turns spent as a kamikaze, the one with kamikazes gained 30 and dropped 12. So splitting and the kamikaze role each earn their place.

## A bug in the replay

Here's one of those kamikazes on Arena, the turn before it drives into an enemy head and takes it down:

![Round 30 of a game on Arena. A kamikaze sits diagonally next to an enemy dragon's head, labelled Target. It collides head-on with it on the next turn and both die. Above them is our dragon that has just split, labelled Worker.](images/kamikaze-trade.svg)

The dragon at the top has just split off that kamikaze. It's still our longest dragon, so it should be the champion, but its indicator says Worker. Working out why took a closer look at how sonar travels. A ray stops at the first dragon segment it reaches, and nothing exempts the sender's own body. Rays also wrap around the edges of the board, so on a small map like Arena, 11 tiles across, a ray can travel all the way round and hit the dragon that sent it. This one had been 13 segments long before it split, so it heard its own old announcement of 13, concluded some teammate was longer than its current 10, and demoted itself for the 12 turns that message stayed in its memory.

The fix is to put the sender's ID in each message and ignore our own, which is the check in `decodeLength` above. The fixed version beat the one before it, 26 changed games to 14, and it's the one in [examples/roles-bot](../examples/roles-bot/strategy.nim):

![A terminal running just roles, which builds the roles bot from Nim and runs the verdict against the first bot. Of 132 paired games, roles-bot gained 39, dropped 5 and left 88 unchanged. Against the weak bots it lost one game on Trauma that the first bot won, and won 5 that it lost. Median rounds to win: 130 against 143, with 115 paired wins faster and 31 slower. The verdict is better.](images/roles-verdict.png)

## Friendly fire

The replays showed one more problem. Head-on collisions kill teammates as well as enemies, but movement only keeps clear of enemy heads, and once splitting fills the board with our own dragons, they start running into each other. In the version that split at length 10, most head-on collisions were between two of our own dragons:

![Head-on collisions in the version that split at length 10: 382 between two of our own dragons, and 78 with an enemy dragon.](images/friendly-fire.svg)

The obvious fix is to give friendly heads the same berth as enemy ones. Surprisingly, that came out undecided and leaned the wrong way: it gained 19 changed games, dropped 29, and lost 5 games to the weak bots that the version without it won. Finding out why will need a closer look at the games themselves.

## Next up

[Tactics](13-tactics.md): once a dragon knows its role, how to carry it out well, starting with a question from the competition Discord about coiling the champion and feeding it.
