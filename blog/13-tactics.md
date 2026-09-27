# Tactics

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to show the tactics bot as it's built now, from behaviour modules in a shared repertoire. It plays exactly the same games as before, so the results stand.

The last two posts were about strategy, which is deciding what each dragon is for. Giving one dragon the job of staying long for round 500 and another the job of hunting enemy heads is a strategic choice. Tactics is the other half: once a dragon knows its job, doing that job precisely and efficiently. The question changes from "who should be the champion?" to "given I'm the champion right now, how do I do it well?" Two bots with the same strategy can play very differently depending on how well each carries it out.

## A note on secret sauce

I'm competing in this tournament too, so I can't walk through every idea I'm working on without handing it to everyone else. What I can share are the questions that shaped my own thinking, none of which have obvious answers:

- Which of your dragons would it hurt most to lose, and does your plan survive losing it?
- How much of your 100 million points a turn do you actually use, and what would the rest buy?
- What does your bot do differently when it's winning than when it's losing?

It's also worth reading how winners of other Battlecode competitions thought about the problem, because the thinking carries over even where the games differ. The MIT 2025 champions, Just Woke Up, [built their units around explicit state machines](https://battlecode.org/assets/files/postmortem-2025-just-woke-up.pdf) with compact, typed messages, and compared every version across many maps. The MIT 2026 runners-up, Generalized Stroke's Theorem, [put more weight on watching replays](https://battlecode.org/assets/files/postmortem-2026-generalized-strokes-theorem.pdf) than on shaving instructions. And the Cambridge 2026 novice champion, Austen Wayne, [explains how his bot remembered what it had seen](https://github.com/AustenWayne/battlecode-bot/blob/main/Cambridge_Battlecode_Postmortem.pdf) and planned routes over that memory, and is candid that he spent too long on his economy.

## A question from Discord

A good tactical question came up on the competition Discord recently:

> Does anyone have any ideas for mimicking the self-coil + self sacrificing mini to feed the big one? As seen by the number 1 on the leaderboard?
>
> — Dearest You [IU]

That's two tactics working together. The champion curls up tight against its own body, and smaller dragons deliberately die next to it to feed it. The second is less strange than it sounds. When a dragon dies, every other segment of its body turns into a pearl, so a mini that has grown by eating elsewhere can pass about half its length to the champion by dying where the champion can eat the remains. Since the longest dragon decides the game at round 500, funnelling the team's length into one dragon makes sense.

Let's try building both. Each one fits into the roles bot as new behaviour modules, so nothing else changes. The champion gains Coil, and the workers become feeders, with Forage for finding food and an optional Deliver for the sacrifice:

![The tactics bot's structure. The state machine enters a role: Champion with Split, Evade, Coil and Roam; Kamikaze with Hunt and Roam; Feeder with Evade and Forage. Deliver, a feeder's sacrifice, is left out because it made the bot worse. Movement drops deadly steps and takes the best by the behaviour's objective. The dragon moves or splits and announces its team tag, ID, role, length and position.](images/tactics-architecture.svg)

The assembly is the roles bot's with two lines changed, and `indicate = 2` makes each dragon's indicator show its behaviour as well as its role:

![examples/tactics-bot/strategy.nim. The champion's children are evade.hsmState(within = 2), coil.hsmState(clearOf = 3) and roam.hsmState(), with the split reflex. The kamikaze keeps hunt and roam. roles.other names the Feeder role and holds evade and forage.hsmState(). The sonar protocol is champion_radio.create(memoryTurns = 12), and indicate = 2 shows both the role and the behaviour.](images/tactics-bot-strategy.png)

Across the three example bots, most of the repertoire is shared, and each new bot only adds a few modules:

![The example bots' repertoire with a column per bot. All three use the hierarchical state machine, the controller, window, turn, movement, radio and hsm modules, and the evade and roam behaviours. The roles and tactics bots add roles, hunt and split. The roles bot uses length_radio, and the tactics bot uses champion_radio, coil and forage. No bot uses deliver.](images/examples-repertoire.svg)

## Coiling

The reason to coil is that a long dragon stretched across the board is an easy target. Every segment is somewhere an enemy can cut in, and the further it roams, the more of them it meets. Curled into a tight knot, most of its body is out of reach, and it stays in one place, which matters if teammates are going to bring it food. So a champion with no enemy head within three tiles coils.

Getting a dragon to curl up turns out to need only one simple preference: it should like moving onto tiles that touch its own body. A dragon that keeps choosing to hug itself naturally winds into a spiral:

![How the coil scores a move. A champion is curled into a U, with two of its possible moves. Moving into the gap inside the curl touches two of its own segments and scores highest. Moving out of the curl touches none. Touching its own body only counts while the move still leaves at least 10 tiles of room.](images/coil-scoring.svg)

Left unchecked, that preference would have the dragon curl so tightly that it walls itself in, so hugging only counts while the move still leaves at least 10 tiles of room. And since a coiled champion still needs to grow, a pearl right next to its head is always worth taking:

![examples/repertoire/games/loong/behaviours/coil.nim. The objective adds 100 if the step eats a pearl, 20 for each of our own segments touching the step when it leaves at least 10 tiles of room, and the room itself. The hsmState factory builds a Coil state that applies when no enemy head is within the given distance.](images/tactics-bot-coil.png)

Here's a champion from one of the test games, nine segments packed into a three-by-three square:

![A game on Colosseum at round 76. Our champion, nine segments long, is coiled into a tight three-by-three square at the edge of the board.](images/champion-coil.svg)

On its own, coiling didn't clearly change the result against the roles bot: of the games that changed, the coiling bot gained 31 and dropped 25, weighted by how much of each game the champion spent coiled. That isn't surprising, since a champion that stays put only pays off if something brings it food, and that's the other half of the idea.

## Feeding the champion

A feeder goes looking for pearls, keeping a reasonable amount of room, and heads for the nearest one it can see:

![The forage behaviour across two files. window.nim's nearestPearl finds the distance to the closest visible pearl. forage.nim's objective returns the room left, capped at 10 and multiplied by 4, minus 6 times the distance to the nearest pearl.](images/tactics-bot-forage.png)

Once it has grown to six segments, Deliver takes over. While the champion is far away, its objective scores each move by how far it heads towards where the champion was last heard from. Once the champion's head is within two tiles and one of its segments is right beside the feeder, a reflex skips the scoring and drives into it. When a dragon runs into another dragon's body, only the one that moved dies, so the champion comes to no harm, and half the feeder's segments turn into pearls right beside it:

![examples/repertoire/games/loong/behaviours/deliver.nim. The objective adds 8 points for each step towards the champion's last known position on top of the capped room. The sacrifice reflex returns a move straight into the champion's body when its head is within two tiles. The hsmState factory builds a Deliver state that applies once the feeder is long enough and the champion was heard recently.](images/tactics-bot-deliver.png)

For that to work, a feeder has to know where the champion is, and the champion is usually far out of sight. The roles bot's sonar only carried each dragon's length, so the message needed a position too. To make room in the 64 bits, the team tag shrank to 16 bits, and every dragon now includes where its head is:

![examples/repertoire/games/loong/champion_radio.nim. encode packs a 16-bit tag, the 16-bit sender ID, a 4-bit role, a 12-bit length and the head position. listen skips messages without our tag and our own echoes, and remembers the longest teammate heard with its ID and position.](images/tactics-bot-sonar.png)

Here's how each version did against the roles bot, weighted by the turns its new behaviours were active:

![Each tactic against the roles bot, as the share of changed games it gained. Coil only: 31 gained and 25 dropped of 132 paired games, undecided. Coil, forage and sacrifice: 24–42, worse. Forage and sacrifice, no coil: 16–40, worse. Sacrifice without foraging: 25–39, worse. Sacrifice only near the champion's head: 24–41, worse. Forage, no coil: 32–21, undecided. Coil and forage, four seeds: 80–45 of 264, undecided.](images/tactics-experiments.svg)

Every version with the sacrifice in it came out worse. Testing the pieces separately again, feeders that only foraged were fine, so the damage came from the sacrifice itself. My first guess was that feeders were dying against the champion's tail, far from its head, so the champion never came back for the pearls. So one version only sacrificed when the champion's head was within two tiles, and that made no difference: 24 changed games gained and 41 dropped, against 25 and 39 without the restriction.

Whatever the number one team is doing, it's more careful than this. Perhaps their feeders only sacrifice when the champion is short of food, or perhaps the champion positions itself to collect. It's a good open question, and I'd love to hear from anyone who cracks it.

What came closest to working was putting together the two pieces that hadn't hurt: a coiling champion with feeders that forage but never sacrifice. Each was undecided on its own. Together, on four seeds, they gained 80 changed games against the roles bot and dropped 45, and random signs do that well less than half a percent of the time.

## What the weak bots found

Head to head isn't the whole verdict, though. The tactics bot also played the starters on the same maps and seeds as the roles bot, and it lost three games to them that the roles bot won while winning back only one, so the verdict is undecided:

![A terminal running just tactics, which builds the tactics bot and runs the verdict against the roles bot on four seeds, weighted by Coil and Forage activation. Of 264 paired games, tactics-bot gained 80, dropped 45 and left 139 unchanged, and random signs do this well 0.36% of the time. Against the weak bots it lost 3 games to starter-py that roles-bot won, all listed, and won back one. The verdict is undecided.](images/tactics-verdict.png)

Three games out of hundreds sounds like bad luck, but a bot this much stronger than a starter shouldn't lose to one at all, so each is worth a look. Two were on the same generated map, 40 tiles square, and both went to round 500. The starter wandered and grew, while our coiled champion sat in its knot waiting for food that the feeders brought too slowly on a board that big, and lost on length. The third was on a small 16×10 map, where both our dragons died head-on in round 22.

Those failures are exactly what a head-to-head test between two versions of our own bot can't show, because the roles bot never coils and the starters never hunt. Coiling is a good idea on a crowded board and a bad one on an empty one, so teaching the champion when not to coil is the obvious next step. The code is in [examples/tactics-bot](../examples/tactics-bot/strategy.nim), and if you want to try making the sacrifice work, add `deliver.hsmState(atLength = 6, memoryTurns = 12)` before `forage` in the feeder's list.

## Every version on one ladder

Each verdict in the last three posts compared a new version with the one before it. The [ladder](06-a-ladder-of-our-own.md) can check that the chain of improvements adds up and that nothing went round in a circle. Here are the saved versions from the flood-fill bot onwards, with the rejected pearl chaser and the C starter for reference, over 990 games on the same 33 maps. Each head-to-head column is the points the row's bot scored against that bot, out of 66:

| Bot | Rating | Won | Drawn | Lost | vs tactics-bot | vs roles-bot | vs first-bot | vs room-c | vs room-pearls | vs starter-c |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tactics-bot | 1791 | 265 | 16 | 49 | | 34.5 | 57 | 60 | 55.5 | 66 |
| roles-bot | 1739 | 247 | 16 | 67 | 31.5 | | 51 | 51 | 55.5 | 66 |
| first-bot | 1547 | 170 | 17 | 143 | 9 | 15 | | 39.5 | 49 | 66 |
| room-c | 1485 | 145 | 16 | 169 | 6 | 15 | 26.5 | | 44.5 | 61 |
| room-pearls | 1377 | 106 | 9 | 215 | 10.5 | 10.5 | 17 | 21.5 | | 51 |
| starter-c | 1060 | 20 | 0 | 310 | 0 | 0 | 0 | 5 | 15 | |

The ratings line up in the order the versions were saved, and every version has a winning record against every version before it, so the verdicts weren't going round in a circle. The gaps also say something the verdicts couldn't. The roles bot's jump over the first bot, nearly 200 points, is the biggest step among the strategy bots, while the tactics bot's lead over the roles bot is real but small, 34.5 games to 31.5, which fits a change that matters in some games and not others.

## Next up

Next in the series is the mechanic all of this rests on: [sonar](14-sonar.md), and what else it could be used for.
