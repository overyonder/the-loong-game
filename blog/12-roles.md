# Roles

> **Editor's note, 28 September 2026.** This post has been rewritten to be shorter and to show the roles bot as it's now built, from behaviour modules in a shared repertoire. It plays exactly the same games as before, so the results stand.

The [first strategy bot](11-the-shape-of-the-problem.md) treats every dragon the same. But one dragon may be long and carrying the team's chance of winning at round 500, while another is two segments long and worth little alive. This post gives dragons different roles, so the same program behaves differently depending on who's running it, and uses sonar to let each dragon work out its own role.

## Three jobs

Two rules pull our dragons in opposite directions. If neither team is wiped out, the winner at round 500 is the team with the longest living dragon, so our longest dragon should grow and stay out of trouble. And when two heads meet, both dragons die, however long each was, so a short dragon has little to lose by driving into an enemy head. That suggests three roles:

- The **champion** is the team's longest dragon. It plays for length.
- A **kamikaze** is a short dragon, three segments or fewer, with a longer teammate. It hunts enemy heads.
- A **worker** is everyone else, and plays exactly like the first bot.

Every dragon is a separate process with its own memory, and nothing tells a dragon it's the champion. So each turn every dragon announces its length by sonar, and remembers the longest teammate it has heard from in the last 12 turns:

![How a dragon picks its role. It listens for the longest teammate heard in the last 12 turns. If it is at least that long, it is the champion. Otherwise, if it has three segments or fewer, it is a kamikaze, and if not, a worker.](images/roles-rule.svg)

## Roles as parent states

Roles slot into the first bot's state machine as a new layer. Each role is a parent state with a guard, and its children are the behaviours that role may use. The champion also gets a reflex, a check that runs before its children and can take the turn: splitting, which comes up below.

![The roles bot's structure. Each turn the dragon listens to sonar and reads its window. The state machine enters a role from its length and the longest teammate heard: Champion with Split, Evade and Roam; Kamikaze with Hunt and Roam; Worker with Evade and Roam. Then the first behaviour whose guard holds; Split and Hunt's strike act as reflexes. Movement drops deadly steps, only Hunt may step next to an enemy head, and the best remaining step by the objective is taken. The dragon moves or splits, then announces its team tag, ID, role and length.](images/roles-architecture.svg)

The assembly says all of that in one call. The same `evade` and `roam` modules the first bot used appear under several roles, with a new `hunt` behaviour for kamikazes and a sonar protocol passed alongside:

![examples/roles-bot/strategy.nim. hsm.run is given a root with three roles. roles.champion holds evade.hsmState(within = 2) and roam.hsmState(), with split.reflex(atLength = 10, childSize = 3). roles.kamikaze holds hunt.hsmState() and roam.hsmState(). roles.other names the Worker role and holds evade and roam. The call also passes sonar = length_radio.create(memoryTurns = 12) and indicate = 1.](images/roles-bot-strategy.png)

The roles themselves are three small factories, each a guard on a parent state:

![examples/repertoire/games/loong/roles.nim. champion builds a state named Champion that applies when the dragon's length is at least the longest teammate heard, with an optional reflex. kamikaze builds a state that applies at three segments or fewer. other builds an unguarded state under the name of the job its dragons do.](images/roles-bot-roles.png)

Hunt keeps just enough room to stay alive and scores a step higher the closer it gets to an enemy head. Its reflex skips the scoring when a head is right beside it and drives straight in. It's also the one behaviour that movement lets step next to an enemy head:

![examples/repertoire/games/loong/behaviours/hunt.nim. The objective returns the room left, capped at 6, minus ten times the gap to the nearest enemy head. The strike reflex returns a move into an adjacent, open enemy head. The hsmState factory builds a Hunt state that applies when an enemy head is in sight, with strike as its reflex, and acts by the best step under its objective with enemy reach allowed.](images/roles-bot-hunt.png)

## Talking by sonar

A sonar message is a single 64-bit number, sent as a ray that stops at the first kelp or dragon segment it meets. Whoever it hits receives the number, with nothing to say who sent it or which team they're on, so an enemy in the way hears it as clearly as a teammate. Every message we send therefore starts with a team tag, and a dragon ignores anything without it:

![One sonar message, 64 bits. The top 32 bits hold the team tag 0x4C4F4F4E, which spells LOON. Bits 31 to 16 hold the sender's ID, bits 15 to 12 its role, and bits 11 to 0 its length.](images/sonar-message.svg)

The tag stops random enemy traffic being mistaken for a teammate's. It won't stop an opponent who decodes our messages and copies it. Packing and unpacking take a couple of shifts each way, and decoding also drops our own messages, for a reason the replays turned up:

![examples/repertoire/games/loong/length_radio.nim. encode puts the team tag in the top 32 bits, then the sender's ID, its role and its length. decodeLength returns -1 when the tag is wrong or the sender is this dragon, and the length otherwise.](images/roles-bot-sonar.png)

## Finding what works

Each change was judged against the first bot with the paired verdict from [the statistics post](04-better-worse-or-undecided.md). Each row below is the share of changed games a variant gained:

![Each change against the first bot, as the share of changed games it gained, out of 132 paired games. Roles, first try: 12 gained, 26 dropped, worse. No kamikazes: 10–25, worse. No kamikazes with a narrower champion berth: no game changed, undecided. Narrower champion berth: 3–4, undecided. Champion splits at length 10: 39–4, better. Splits, but children work instead: 35–8, better. Splits, and ignores its own echo: 39–5, better.](images/roles-experiments.svg)

The first try came out worse. It gave the champion a wider berth, three tiles from enemy heads instead of two, to protect it. Testing the pieces separately found the fault. Removing kamikazes didn't help. A control with no kamikazes and the normal berth played all 132 games exactly as the first bot did, which showed the sonar itself cost nothing. That left the berth: the timid champion couldn't hold its ground. With the normal berth the roles bot drew level, but only 7 of 132 games changed at all. Counting role labels in the replays showed why. Only 1.7% of dragon-turns were kamikaze turns, because short dragons with a longer teammate nearby were rare.

## Making kamikazes

If short dragons are rare, make them. A dragon can split, turning the end of its body into a new dragon, so a champion that reaches 10 segments now splits off its last three:

![How a champion makes a kamikaze. A champion of length 10 splits off its last three segments, which become a new dragon running a fresh copy of the program. On its first turn the child hears the champion announce length 10 by sonar, so it knows a longer teammate exists and takes the kamikaze role.](images/split-makes-kamikaze.svg)

The child runs a fresh copy of the program with no memory. It hears the champion announce length 10, sees that it's only three segments long, and picks the kamikaze role itself.

With splitting, the roles bot gained 39 changed games and dropped 4 against the first bot. That mixes two changes, more dragons and hunting ones, so a version that split the same way but made its children workers served as a control. It also beat the first bot, 35 to 8, so more dragons help on their own. Played directly against that control, weighting each game by its kamikaze turns, the version with kamikazes gained 30 and dropped 12. Splitting and the kamikaze role each earn their place.

## A bug in the replay

Here's one of those kamikazes on Arena, the turn before it drives into an enemy head:

![Round 30 of a game on Arena. A kamikaze sits diagonally next to an enemy dragon's head, labelled Target. It collides head-on with it on the next turn and both die. Above them is our dragon that has just split, labelled Worker.](images/kamikaze-trade.svg)

The dragon at the top has just split off that kamikaze. It's still our longest dragon, but its indicator says Worker. A sonar ray stops at the first segment it reaches, the sender's own body included, and rays wrap round the board. On Arena, 11 tiles across, a ray can go all the way round and hit its sender. This dragon had been 13 segments before splitting, heard its own old announcement of 13, concluded a teammate was longer than its current 10, and demoted itself for 12 turns. Putting the sender's ID in each message and ignoring our own fixed it. The fixed version beat the one before, 26 changed games to 14, and it's the one in [examples/roles-bot](../examples/roles-bot/strategy.nim):

![A terminal running just roles, which builds the roles bot from Nim and runs the verdict against the first bot. Of 132 paired games, roles-bot gained 39, dropped 5 and left 88 unchanged. Against the weak bots it lost one game on Trauma that the first bot won, and won 5 that it lost. Median rounds to win: 130 against 143, with 115 paired wins faster and 31 slower. The verdict is better.](images/roles-verdict.png)

## Friendly fire

Head-on collisions kill teammates too, and movement only keeps clear of enemy heads. With splitting filling the board with our own dragons, the version that split at length 10 had 382 head-on collisions between two of our own dragons, against 78 with the enemy. Giving friendly heads the same berth came out undecided and leaned the wrong way, 19 changed games gained and 29 dropped, with 5 more losses to the weak bots. Why needs a closer look at the games.

## Next up

[Tactics](13-tactics.md): once a dragon knows its role, carrying it out well, starting with a question from the competition Discord about coiling the champion and feeding it.
