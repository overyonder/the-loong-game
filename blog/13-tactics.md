# Tactics

> **Editor's note, 28 September 2026.** This post has been rewritten to be shorter and to show the tactics bot as it's now built, from behaviour modules in a shared repertoire. It plays exactly the same games as before, so the results stand.

Strategy decides what each dragon is for, and [roles](12-roles.md) made that choice: one dragon stays long for round 500, others hunt enemy heads. Tactics is doing the job well once a dragon has it. The question changes from "who should be the champion?" to "I'm the champion, so how do I do it well?"

## A note on secret sauce

I'm competing too, so I can't walk through everything I'm working on. I can share the questions that shaped my thinking, none of which have obvious answers:

- Which of your dragons would it hurt most to lose, and does your plan survive losing it?
- How much of your 100 million points a turn do you use, and what would the rest buy?
- What does your bot do differently when it's winning than when it's losing?

Winners of other Battlecode competitions have written up their thinking, and it carries over. The MIT 2025 champions, Just Woke Up, [built units around explicit state machines](https://battlecode.org/assets/files/postmortem-2025-just-woke-up.pdf) with compact typed messages, and compared every version across many maps. The MIT 2026 runners-up, Generalized Stroke's Theorem, [put watching replays ahead of shaving instructions](https://battlecode.org/assets/files/postmortem-2026-generalized-strokes-theorem.pdf). And the Cambridge 2026 novice champion, Austen Wayne, [explains how his bot remembered what it had seen](https://github.com/AustenWayne/battlecode-bot/blob/main/Cambridge_Battlecode_Postmortem.pdf) and planned routes over that memory.

## A question from Discord

A good tactical question came up on the competition Discord:

> Does anyone have any ideas for mimicking the self-coil + self sacrificing mini to feed the big one? As seen by the number 1 on the leaderboard?
>
> — Dearest You [IU]

That's two tactics together. The champion curls up tight against its own body, and smaller dragons die next to it to feed it. When a dragon dies, every other segment of its body becomes a pearl, so a mini that grew elsewhere can pass about half its length to the champion by dying where the champion can eat the remains.

Both fit the roles bot as new behaviour modules, so nothing else changes. The champion gains Coil, and workers become feeders with Forage, plus an optional Deliver for the sacrifice:

![The tactics bot's structure. The state machine enters a role: Champion with Split, Evade, Coil and Roam; Kamikaze with Hunt and Roam; Feeder with Evade and Forage. Deliver, a feeder's sacrifice, is left out because it made the bot worse. Movement drops deadly steps and takes the best by the behaviour's objective. The dragon moves or splits and announces its team tag, ID, role, length and position.](images/tactics-architecture.svg)

The assembly is the roles bot's with two lines changed:

![examples/tactics-bot/strategy.nim. The champion's children are evade.hsmState(within = 2), coil.hsmState(clearOf = 3) and roam.hsmState(), with the split reflex. The kamikaze keeps hunt and roam. roles.other names the Feeder role and holds evade and forage.hsmState(). The sonar protocol is champion_radio.create(memoryTurns = 12), and indicate = 2 shows both the role and the behaviour.](images/tactics-bot-strategy.png)

Across the three example bots, most of the repertoire is shared, and each new bot adds a few modules:

![The example bots' repertoire with a column per bot. All three use the hierarchical state machine, the controller, window, turn, movement, radio and hsm modules, and the evade and roam behaviours. The roles and tactics bots add roles, hunt and split. The roles bot uses length_radio, and the tactics bot uses champion_radio, coil and forage. No bot uses deliver.](images/examples-repertoire.svg)

## Coiling

A long dragon stretched across the board is an easy target, since every segment is somewhere an enemy can cut in. Curled into a knot, most of its body is out of reach, and it stays in one place, which matters if teammates are bringing it food. So a champion with no enemy head within three tiles coils.

Curling up needs one preference: like steps that touch your own body. A dragon that keeps hugging itself winds into a spiral:

![How the coil scores a move. A champion is curled into a U, with two of its possible moves. Moving into the gap inside the curl touches two of its own segments and scores highest. Moving out of the curl touches none. Touching its own body only counts while the move still leaves at least 10 tiles of room.](images/coil-scoring.svg)

Left unchecked, that would wall the dragon in, so hugging only counts while the step leaves at least 10 tiles of room. A pearl beside the head is always worth taking, since a coiled champion still needs to grow:

![examples/repertoire/games/loong/behaviours/coil.nim. The objective adds 100 if the step eats a pearl, 20 for each of our own segments touching the step when it leaves at least 10 tiles of room, and the room itself. The hsmState factory builds a Coil state that applies when no enemy head is within the given distance.](images/tactics-bot-coil.png)

Here's a champion from a test game, nine segments packed into a three-by-three square:

![A game on Colosseum at round 76. Our champion, nine segments long, is coiled into a tight three-by-three square at the edge of the board.](images/champion-coil.svg)

On its own, coiling was undecided against the roles bot: 31 changed games gained and 25 dropped, weighted by the turns spent coiled. A champion that stays put only pays off if something brings it food.

## Feeding the champion

A feeder looks for pearls, keeping reasonable room:

![The forage behaviour across two files. window.nim's nearestPearl finds the distance to the closest visible pearl. forage.nim's objective returns the room left, capped at 10 and multiplied by 4, minus 6 times the distance to the nearest pearl.](images/tactics-bot-forage.png)

Delivering has two parts. While the champion is far away, the objective scores each step by how far it heads towards where the champion was last heard from. Once the champion's head is within two tiles and one of its segments is beside the feeder, a reflex drives into it. Only the dragon that moves dies in a body collision, so the champion is unharmed:

![examples/repertoire/games/loong/behaviours/deliver.nim. The objective adds 8 points for each step towards the champion's last known position on top of the capped room. The sacrifice reflex returns a move straight into the champion's body when its head is within two tiles. The hsmState factory builds a Deliver state that applies once the feeder is long enough and the champion was heard recently.](images/tactics-bot-deliver.png)

That needs the champion's position, which is usually out of sight, so sonar messages now carry each dragon's head. To make room in 64 bits, the team tag shrinks to 16:

![examples/repertoire/games/loong/champion_radio.nim. encode packs a 16-bit tag, the 16-bit sender ID, a 4-bit role, a 12-bit length and the head position. listen skips messages without our tag and our own echoes, and remembers the longest teammate heard with its ID and position.](images/tactics-bot-sonar.png)

Each version against the roles bot, weighted by the turns its new behaviours ran:

![Each tactic against the roles bot, as the share of changed games it gained. Coil only: 31 gained and 25 dropped of 132 paired games, undecided. Coil, forage and sacrifice: 24–42, worse. Forage and sacrifice, no coil: 16–40, worse. Sacrifice without foraging: 25–39, worse. Sacrifice only near the champion's head: 24–41, worse. Forage, no coil: 32–21, undecided. Coil and forage, four seeds: 80–45 of 264, undecided.](images/tactics-experiments.svg)

Every version with the sacrifice came out worse. Feeders that only foraged were fine, so the damage came from the sacrifice itself. Restricting it to within two tiles of the champion's head made no difference, 24 to 41 against 25 to 39. Whatever the number one team does, it's more careful than this. Perhaps feeders sacrifice only when the champion is short of food, or the champion positions itself to collect. I'd love to hear from anyone who cracks it.

The closest to working was the two pieces that hadn't hurt: a coiling champion with feeders that forage but never sacrifice. On four seeds they gained 80 changed games against the roles bot and dropped 45, which random signs match less than half a percent of the time.

## What the weak bots found

Against the starter bots, though, the tactics bot lost three games the roles bot won and won back one, so the overall verdict is undecided:

![A terminal running just tactics, which builds the tactics bot and runs the verdict against the roles bot on four seeds, weighted by Coil and Forage activation. Of 264 paired games, tactics-bot gained 80, dropped 45 and left 139 unchanged, and random signs do this well 0.36% of the time. Against the weak bots it lost 3 games to starter-py that roles-bot won, all listed, and won back one. The verdict is undecided.](images/tactics-verdict.png)

A bot this much stronger than a starter shouldn't lose to one at all. Two losses were on the same 40-tile generated map, both at round 500: the starter wandered and grew while our coiled champion waited for food that came too slowly on a board that big. The third was on a small 16×10 map, where both our dragons died head-on in round 22. Coiling suits a crowded board and not an empty one, and teaching the champion when not to coil is the obvious next step. The code is in [examples/tactics-bot](../examples/tactics-bot/strategy.nim). To try the sacrifice, add `deliver.hsmState(atLength = 6, memoryTurns = 12)` before `forage` in the feeder's list.

## Every version on one ladder

The [ladder](06-a-ladder-of-our-own.md) checks that the chain of verdicts adds up and nothing went round in a circle. Here are the saved versions from the flood-fill bot on, with the rejected pearl chaser and the C starter for reference:

![A terminal running just ladder-all, which rates six bots from 990 games with no errors. tactics-bot 1791, roles-bot 1739, first-bot 1547, room-c 1485, room-pearls 1377, starter-c 1060. tactics-bot scored 34.5 of 66 against roles-bot and 57 against first-bot. first-bot scored 39.5 against room-c.](images/ladder-all.png)

The ratings line up in the order the versions were saved, and each has a winning record against every earlier one. The roles bot's jump of nearly 200 points over the first bot is the largest step. The tactics bot's lead over the roles bot is real but small, 34.5 games to 31.5, which fits a change that matters in some games and not others.

## Next up

Next is the mechanic all of this rests on: [sonar](14-sonar.md), and what else it could be used for.
