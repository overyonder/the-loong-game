# Roles

<!-- draft: 504c335716, stage: Grand strategy -->

The [first strategy bot](06-the-shape-of-the-problem.md) treats every dragon the same. But dragons on the same team aren't in the same position. One is long and carries the team's chance of winning at round 500. Another is two segments long and not worth much alive. This post uses the architecture from last time to give dragons different roles, so the same program behaves differently depending on who's running it, and uses sonar to let each dragon work out its role.

## Why dragons need different jobs

Two of the game's rules pull our dragons in opposite directions, and that's what makes roles worth having.

The first is how the game ends. If neither team is wiped out, the winner at round 500 is the team with the longest living dragon. So whichever of our dragons is longest is carrying the whole team's result, and it should spend the game growing and staying out of trouble.

The second is what happens in a head-on collision. When two heads meet, both dragons die, however long each of them was. For a long dragon that's a disaster, but for a dragon with only two or three segments it's the best trade on the board, because it can take an enemy champion down with it.

A long dragon should avoid enemy heads and a short one should seek them out, so the plan is three roles:

- The **champion** is the team's longest dragon. It plays for length.
- A **kamikaze** is a short dragon, three segments or fewer, with a longer teammate to protect. It hunts enemy heads.
- A **worker** is everyone else. It plays exactly like the first bot.

## One program, three roles

Every dragon runs the same program, and each one is a separate process with its own memory. Nothing tells a dragon it's the champion. It has to work that out from what it knows, and the only way to learn about teammates out of sight is sonar.

Each turn, every dragon announces its length in all four directions. Each dragon remembers the longest teammate it has heard from in the last 12 turns, and picks its role from that:

```nim
proc chooseRole(length: int): Role =
  if length >= longestTeammateHeard: Champion
  elif length <= 3: Kamikaze
  else: Worker
```

![How a dragon picks its role. It listens for the longest teammate heard in the last 12 turns. If it is at least that long, it is the champion. Otherwise, if it has three segments or fewer, it is a kamikaze, and if not, a worker.](images/roles-rule.svg)

The role doesn't replace the architecture. It slots in above it and decides which modes a dragon may use. The champion and workers roam and evade like the first bot, and a kamikaze roams until it sees an enemy head, then hunts it. The safety layer stays in charge of every role, with one exception: a hunting kamikaze may step next to an enemy head, because that's the point.

![The roles bot's structure. Each turn the dragon reads its sonar and its window, picks a role, and the role limits its modes: the champion roams, evades and splits off kamikazes, a worker roams or evades, and a kamikaze roams or hunts. The safety layer removes deadly moves, the chosen mode scores the rest, the best move is sent, and the dragon announces its role and length on sonar.](images/roles-architecture.svg)

## Talking by sonar

Sonar is simple, and that simplicity is what makes it tricky to use. A message is a single 64-bit number, sent out as a ray that travels in a straight line until it hits kelp or a dragon segment, and whichever dragon it hits receives the number. The message carries nothing else, not even who sent it or which team they're on, so an enemy in the way hears it just as clearly as a teammate would.

That means a dragon needs some way to tell our messages from everyone else's. So every message we send starts with a fixed team tag, and a dragon ignores anything without it:

![One sonar message, 64 bits. The top 32 bits hold the team tag 0x4C4F4F4E, which spells LOON. Bits 31 to 16 hold the sender's ID, bits 15 to 12 its role, and bits 11 to 0 its length.](images/sonar-message.svg)

The tag stops a dragon from mistaking random enemy traffic for a teammate. It won't stop an opponent who decodes our messages and copies the tag.

## The first try was worse

Since the champion carries the team's hopes for round 500, the first version played it extra carefully, keeping three tiles away from enemy heads instead of the usual two. Against the first bot, on the bundled and generated maps, that version lost. The chart below shows it, along with every variant I tried while working out why:

![Each change against the first bot. Roles, first try: 46 wins, 72 losses, worse. No kamikazes: 49–68, worse. No kamikazes with a narrower champion berth: 58–58, undecided. Narrower champion berth: 55–58, undecided. Champion splits at length 10: 91–29, better. Splits, but children work instead: 86–31, better. Splits, and ignores its own echo: 90–30, better.](images/roles-experiments.svg)

When a change comes out worse, the useful thing to do is test its pieces separately, and the verdict tool makes that cheap. Removing the kamikazes didn't help, so they weren't the problem. A control that removed them and gave the champion the first bot's two-tile berth came out dead even, 58–58, which showed the sonar messages themselves cost nothing. That left the champion's berth. Keeping three tiles from enemy heads made it too timid to hold its ground, and narrowing it brought the roles bot level with the first bot.

A level result isn't an improvement, and counting role labels in the replays showed why. Each dragon shows its role as an indicator, and across the games, only 1.7% of dragon-turns were kamikaze turns. Short dragons with a longer teammate nearby were rare, so the role hardly ever came into play.

## Making kamikazes

If kamikazes are rare because short dragons are rare, the answer is to make short dragons on purpose. The game already has a way to do that: a dragon can split, turning the end of its body into a new dragon. So now a champion that reaches 10 segments splits off its last three:

![How a champion makes a kamikaze. A champion of length 10 splits off its last three segments, which become a new dragon running a fresh copy of the program. On its first turn the child hears the champion announce length 10 by sonar, so it knows a longer teammate exists and takes the kamikaze role.](images/split-makes-kamikaze.svg)

The child is a new dragon running a fresh copy of the same program, with no memory. Nothing tells it to be a kamikaze. It hears the champion announce length 10, sees that it's only three segments long, and picks the role itself.

With splitting, the roles bot beat the first bot convincingly, 91 games to 29. But that result mixes two changes: there are more dragons now, and the new ones hunt. To separate them, I tried a version that split in exactly the same way but made its children ordinary workers. That version also beat the first bot, 86 to 31, so having more dragons helps on its own. Then I played the two versions directly against each other, and the one with kamikazes won 84 games to 38. So the splitting and the kamikaze role each earn their place.

## A bug in the replay

Here's one of those kamikazes at work, on Arena, the turn before it drives into an enemy head and takes it down:

![Round 30 of a game on Arena. A kamikaze sits diagonally next to an enemy dragon's head, labelled Target. It collides head-on with it on the next turn and both die. Above them is our dragon that has just split, labelled Worker.](images/kamikaze-trade.svg)

The dragon at the top is the one that just split off that kamikaze. It's still our longest dragon, so it should be the champion, but its indicator says Worker. Working out why took a closer look at how sonar travels. A ray stops at the first dragon segment it reaches, and nothing exempts the sender's own body. Rays also wrap around the edges of the board, so on a small map like Arena, which is 11 tiles across, a ray can travel all the way round and come back to hit the dragon that sent it. This dragon had been 13 segments long before it split, so it heard its own old announcement of 13, concluded that some teammate was longer than its current 10, and demoted itself for the 12 turns that message stayed in its memory.

The fix is to put the sender's ID in each message and ignore our own. The fixed version beat the one before it 80–38, and it's the version in [examples/roles-bot](../examples/roles-bot/strategy.nim):

![A terminal running just roles, which builds the roles bot from Nim and runs the verdict against the first bot. roles-bot wins 90 games, loses 30 and draws 12, with no errors, and the verdict is better.](images/roles-verdict.png)

## Friendly fire

The replays showed one more problem. Head-on collisions kill teammates as well as enemies, but the safety layer only keeps clear of enemy heads. Once splitting fills the board with our own dragons, they start running into each other. In the version that split at length 10, there were 382 head-on collisions between two of our own dragons, against 78 with the enemy.

The obvious fix is to give friendly heads the same berth as enemy ones. Surprisingly, that came out undecided against the version without it, 55 games to 66, so it isn't clearly an improvement. Finding out why will need a closer look at the games themselves.

## Next up

Next is [tactics](08-tactics.md): once a dragon knows its role, how to carry it out well, starting with a question from the competition Discord about coiling the champion and feeding it.
