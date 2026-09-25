# Tactics

<!-- draft: 16ce51c717, stage: Advanced tactics -->

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

The last two posts were about strategy. Roles, like the champion and the kamikaze, are strategic ideas, and so are deception, redundancy and supply lines. They decide what each dragon is for.

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

A coiled champion covers very little ground. It exposes less of its body to enemies, and it stays close to wherever food is being delivered. In the tactics bot, a champion with no enemy head within three tiles switches to a new **Coil** mode.

The geometry comes down to a simple preference: move to tiles that touch our own body. Each own segment next to the new tile adds to the move's score. A dragon that keeps hugging its own body curls into a spiral.

![How the coil scores a move. A champion is curled into a U, with two of its possible moves. Moving into the gap inside the curl touches two of its own segments and scores highest. Moving out of the curl touches none. Touching its own body only counts while the move still leaves at least 10 tiles of room.](images/coil-scoring.svg)

There's a catch, though. A snake that curls too tightly traps itself. So the preference only applies while the move still leaves at least 10 tiles of room to move into, measured with the same flood fill as before. The coil also always takes a pearl if one is right next to it.

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

On its own, coiling didn't change the result: against the roles bot it came out level, 60–62. A tight champion is only half of the idea.

## Feeding the champion

The other half is the minis. The roles bot's workers became **feeders**. A feeder goes looking for pearls, and once it has grown to six segments, it travels back to the champion and drives into the champion's body. Only the mover dies when it hits another dragon's body, so the champion is safe, and the feeder's segments turn into pearls beside it.

A feeder has to know where the champion is, and the champion is usually far out of sight. So the sonar message changed. The team tag shrank to 16 bits to make room, and every dragon now includes its head's position. A feeder remembers where the longest teammate it heard from was, and heads there.

Here's how each version did against the roles bot:

![Each tactic against the roles bot. Coil only: 60 wins, 62 losses, undecided. Coil, forage and sacrifice: 43–78, worse. Forage and sacrifice, no coil: 32–88, worse. Sacrifice without foraging: 40–81, worse. Sacrifice only near the champion's head: 50–72, worse. Forage, no coil: 63–57, undecided. Coil and forage, four seeds: 138–106, better.](images/tactics-experiments.svg)

Every version with the sacrifice in it came out worse, and splitting the tactic apart showed why. Foraging on its own was fine. The sacrifice was what hurt. My first guess was that feeders were dying against the champion's tail, far from its head, so the champion never came back for the pearls. So one version only sacrificed when the champion's head was within two tiles. That helped a little, but it was still clearly worse.

So whatever the number one team is doing, it's more careful than this. Perhaps their feeders sacrifice only when the champion is short of food. Or perhaps the champion is positioned to collect the pearls, not the feeder. It's a good open question, and I'd love to hear from anyone who cracks it.

What did work was the combination of the two halves that survived. Feeders that forage but don't sacrifice, with a champion that coils, beat the roles bot. Foraging without the coil was only level, and the coil on its own was only level, so the two work together.

## Checking the result properly

That combination first came out better, 73–51, in a run of 132 games. When I ran it again as the final version, the harness drew a different set of seeds, because each game's seed is derived from the bots' names. The same bot came out 66–56, undecided.

That's a useful reminder of what a 5% threshold means. A result that just clears it can fail to clear it on the next sample. So the final check doubled the sample to four seeds per map and side:

![A terminal running just tactics, which builds the tactics bot and runs the verdict against the roles bot on four seeds. tactics-bot wins 138 games, loses 106 and draws 20, with no errors. The chance an even match does this well is 0.0235, and the verdict is better.](images/tactics-verdict.png)

Over 264 games the tactics bot is better, 138 wins to 106. The code is in [examples/tactics-bot](../examples/tactics-bot/strategy.nim), with the sacrifice behind a `-d:deliver` switch for anyone who wants to try making it work.

## Next up

That finishes the implementation section. We have tools to test ideas, a structure to put them in, roles that give each dragon a job, and tactics that carry those jobs out. The next stage is espionage: what we can learn about other teams from their public replays and their sonar messages.
