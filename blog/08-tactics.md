# Tactics

<!-- draft: 16ce51c717, stage: Tactical ideas -->

This is the last of the implementation posts. The earlier posts built the tools and gave the bot a structure and some roles. This one is about carrying those roles out well. First, though, a note on how much of this I'm going to share.

## A note on secret sauce

I'm competing in this tournament too, so I can't walk through every strategy I'm working on without handing it to everyone else. What I can do is share the questions that shaped my own thinking. None of them have obvious answers.

- Sonar reaches whoever a ray hits, enemies included. What could you learn from the other team's messages, and what could you make them believe from yours?
- Which of your dragons would it hurt most to lose, and does your plan survive losing it?
- Every map is symmetric. What does your own starting position tell you about the enemy's?
- Pearls respawn on a schedule for each tile. Who controls the tiles that feed the most?
- Length decides round 500, but numbers decide fights. When is it worth trading one for the other?
- A head-on collision kills both dragons. When is a small dragon worth more dead than alive?
- How much of your 100 million points a turn do you actually use, and what would the rest buy?
- What does your bot do differently when it's winning than when it's losing?

It's also worth reading how winners of other Battlecode competitions thought about the problem. The games differ, but the thinking carries over.

- The MIT Battlecode 2025 champions, Just Woke Up, [wrote up their approach](https://battlecode.org/assets/files/postmortem-2025-just-woke-up.pdf). They built their units around explicit state machines, and designed compact, typed messages for sharing locations. They also compared every version across many maps and studied their losses against a range of opponents.
- The MIT Battlecode 2026 runners-up, Generalized Stroke's Theorem, [cover navigation, communication and close-quarters fighting](https://battlecode.org/assets/files/postmortem-2026-generalized-strokes-theorem.pdf). Their report puts more weight on watching replays and experimenting with the big picture than on shaving instructions off the code.
- The Cambridge Battlecode 2026 novice champion, Austen Wayne, [explains how his bot remembered what it had seen](https://github.com/AustenWayne/battlecode-bot/blob/main/Cambridge_Battlecode_Postmortem.pdf) and planned routes over that memory. He's candid that he spent too long on his economy and not enough on attack and defence.

## From strategy to tactics

The last two posts were about strategy, which is deciding what each dragon is for. Giving one dragon the job of staying long for round 500 and another the job of hunting enemy heads is a strategic choice. So is anything else that shapes the plan for the whole team, like deceiving the enemy or keeping a spare champion in case the first one dies.

Tactics is the other half. Once a dragon knows its job, tactics is about doing that job precisely and efficiently. The question changes from "who should be the champion?" to "given I'm the champion right now, how do I do that well?" Two bots with the same strategy can play very differently depending on how well each one carries it out.

## A question from Discord

A good tactical question came up on the competition Discord recently:

> Does anyone have any ideas for mimicking the self-coil + self sacrificing mini to feed the big one? As seen by the number 1 on the leaderboard?
>
> — Dearest You [IU]

That's two tactics working together. The big dragon, the champion, curls up tight against its own body. And smaller dragons deliberately die next to it to feed it.

The second one is less strange than it sounds. When a dragon dies, every other segment of its body turns into a pearl. So a mini that has grown by eating pearls elsewhere can pass about half its length on to the champion by dying where the champion can eat the remains. Since the longest dragon decides the game at round 500, funnelling the team's length into one dragon makes sense.

Let's try building both.

## Coiling

The reason to coil is that a long dragon stretched across the board is an easy target. Every segment is somewhere an enemy can cut in front of it, and the further it roams the more of them it meets. A champion curled up in a tight knot keeps most of its body out of reach, and it stays in one place, which matters if teammates are going to bring food to it. So in the tactics bot, when a champion has no enemy head within three tiles, it switches to a new **Coil** mode.

Getting a dragon to curl up turns out to need only one simple preference: it should like moving onto tiles that touch its own body. Each of our own segments next to a candidate tile adds to that move's score, and a dragon that keeps choosing to hug itself this way naturally winds into a spiral.

![How the coil scores a move. A champion is curled into a U, with two of its possible moves. Moving into the gap inside the curl touches two of its own segments and scores highest. Moving out of the curl touches none. Touching its own body only counts while the move still leaves at least 10 tiles of room.](images/coil-scoring.svg)

Left unchecked, that preference would have the dragon curl so tightly that it walls itself in and dies on its own body. So hugging only counts while the move still leaves at least 10 tiles of room, measured with the same flood fill the bot already uses for safety. And since a coiled champion still needs to grow, it always takes a pearl that's right next to it.

```nim
proc ownBodyAround(w: Window, i: int): int =
  ## How many of our own segments touch this tile. A coil keeps this high.
  for side in 0 .. 3:
    let next = neighbour(i, side)
    if next >= 0 and w.ownBody[next]: inc result
```

```nim
  of Coil:
    # Hug our own body, but never so tightly that we box ourselves in.
    (if w.pearl[first]: 100 else: 0) + (if room >= 10: 20 * w.ownBodyAround(first) else: 0) + room
```

Here's a champion from one of the test games, nine segments packed into a three-by-three square:

![A game on Colosseum at round 76. Our champion, nine segments long, is coiled into a tight three-by-three square at the edge of the board.](images/champion-coil.svg)

On its own, coiling didn't change the result. Against the roles bot it came out level, winning 60 games and losing 62. That isn't surprising, because a champion that stays put only pays off if something is bringing it food, and that's the other half of the idea.

## Feeding the champion

To bring the champion food, the roles bot's workers became **feeders**. A feeder goes looking for pearls, and once it has grown to six segments, it travels back to the champion and deliberately drives into the champion's body. When a dragon runs into another dragon's body, only the one that moved dies, so the champion comes to no harm, and half the feeder's segments turn into pearls right beside it.

For that to work, a feeder has to know where the champion is, and the champion is usually far out of sight. The roles bot's sonar message only carried each dragon's length, so it needed to carry a position as well. To make room in the 64 bits, the team tag shrank to 16 bits, and every dragon now includes where its head is. A feeder remembers the position of the longest teammate it has heard from, and heads there when it's ready to deliver.

Here's how each version did against the roles bot:

![Each tactic against the roles bot. Coil only: 60 wins, 62 losses, undecided. Coil, forage and sacrifice: 43–78, worse. Forage and sacrifice, no coil: 32–88, worse. Sacrifice without foraging: 40–81, worse. Sacrifice only near the champion's head: 50–72, worse. Forage, no coil: 63–57, undecided. Coil and forage, four seeds: 138–106, better.](images/tactics-experiments.svg)

Every version with the sacrifice in it came out worse. To find out which part was hurting, I tested the pieces separately, the same way as in the roles post. Feeders that only foraged were fine, so the damage came from the sacrifice itself. My first guess was that feeders were dying against the champion's tail, far from its head, so the champion never came back for the pearls. So one version only sacrificed when the champion's head was within two tiles. That helped a little, but it was still clearly worse.

So whatever the number one team is doing, it's more careful than this. Perhaps their feeders sacrifice only when the champion is short of food. Or perhaps the champion is positioned to collect the pearls, not the feeder. It's a good open question, and I'd love to hear from anyone who cracks it.

What did work was putting together the two pieces that hadn't hurt. Feeders that forage but never sacrifice, alongside a champion that coils, beat the roles bot. Each of those pieces was only level on its own, so they're helping each other.

## Checking the result properly

That combination first came out better, 73 games to 51, in a run of 132 games. When I ran it again under its final name, the harness drew a different set of seeds, because each game's seed is derived from the bots' names, and the very same bot came out 66 to 56, which is undecided.

That's worth understanding rather than brushing aside. A 5% threshold means that a result near the edge is only just distinguishable from luck, so a fresh sample of games can easily land on the other side of it. The honest response is to collect more evidence, so the final check doubled the sample to four seeds for every map and side:

![A terminal running just tactics, which builds the tactics bot and runs the verdict against the roles bot on four seeds. tactics-bot wins 138 games, loses 106 and draws 20, with no errors. The chance an even match does this well is 0.0235, and the verdict is better.](images/tactics-verdict.png)

Over 264 games the tactics bot is better, 138 wins to 106. The code is in [examples/tactics-bot](../examples/tactics-bot/strategy.nim), with the sacrifice behind a `-d:deliver` switch for anyone who wants to try making it work.

## Next up

That finishes the implementation section. We started with tools that tell us whether an idea works, used them to give the bot a structure and then roles, and in this post made the champion better at its job. The next stage is performance: finding out where the bot's CPU budget goes, and fitting more thinking into it.
