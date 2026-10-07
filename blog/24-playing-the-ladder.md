# Playing the ladder

A strong bot is only half of a good placing. The rest is how you play the ladder: which bot is live, who it plays, and when you change it. Tournament seeds come from the ladder rating, and every tournament is a single-elimination knockout, so a rating point is worth something and one lost series ends a run. This post is how we played the ladder during the 2026 season. It applies the statistics from two earlier posts: Elo ratings from [A ladder of our own](07-a-ladder-of-our-own.md), and how far a difference between two bots can be trusted from [Better, worse or undecided](05-better-worse-or-undecided.md).

Our team started at 1500 on 26 September, fell as low as 1492 (rank 258) on the 28th, and reached 1830 (rank 40 of about 900 teams) early on the 30th:

![Our ladder rating every half hour from 26 September to 1 October, Sydney time, labelled with five stages. The basic flood-fill bot ranged from 1500 to 1550. A basic planning agent jumped to about 1625, then decayed towards 1550 as the field improved. A more complex planning agent first dropped to 1492, then reached 1830 and rank 40 after replay review, revised logic and hand-crafted human heuristics. A dashed line shows a proposed RL-bot trial dipping to 1750, while the Sprint checkpoint records our 54th seed and round-of-64 finish. A final question mark represents the holdout over|yonder bot, combining classical AI and planning with machine-learning optimisations, to be published after the Grand Final.](images/ladder-rating.svg)

The climb on the 29th came from a string of stronger releases, and the rules below decided when each went live. The solid line is ladder history. The dashed RL-bot dip and final question mark show what comes next: the RL bot has not yet played a rated ladder game. Our planning bot entered the Sprint as the 54th seed and reached the round of 64.

## The ladder's rules

A few rules shape everything else:

- A ranked battle is five games on random maps. Each team's rating then moves by K × (S − E), where S is its score and E is what the two ratings predicted, the formula from [A ladder of our own](07-a-ladder-of-our-own.md#ratings).
- K is 96 for a new bot and falls by 7.2 with each ranked battle it plays, to a floor of 24 after ten.
- A new bot doesn't always start fresh. If another of the team's bots started from zero in the last 12 hours, the new one inherits the count of the bot last played, capped at ten, so it starts at the floor. K resets once per 12 hours, for one bot.
- Every hour the site draws each team one ranked battle against a team within eight places, using whichever bot is active when the battle is queued. On top of that, a team can challenge any team rated no more than 50 below it, up to 60 games an hour, with several challenges pending against one team at once.
- Reactivating an old submission carries on from its own count.

## Choosing opponents

A ranked battle is worth K × (p − E) on average, where p is our true chance of winning a game against that opponent and E is the chance the two ratings predict. If our bot is stronger than our rating says, p beats E against most opponents, and the question is where the gap is widest. It's widest against an opponent rated about halfway between our rating and our true strength:

![The average rating a game gains at K = 24 for a bot rated 1700, against opponents rated from 1450 to 2050. For a bot whose true strength is 1800, the gain is positive everywhere and peaks at +3.4 a game against an opponent rated 1750, halfway between. For a bot whose true strength is 1650, the gain is negative everywhere, about −1.7 at its worst.](images/ladder-expected-gain.svg)

The other curve matters as much. When a bot is weaker than its rating, every challenge loses rating on average, so our challenger sent nothing at all, and the hourly draws were the only games played.

That needs two numbers we don't know directly: our true strength and each opponent's. For ours, we used the live bot's performance rating, the rating at which its results over its recent games would have been expected. For theirs, the live rating is only a start, and working out which way it was wrong took us four tries.

### Rising and falling teams

Our first challenger looked for teams on a losing run. The idea was that a falling team had shown some weakness, or had been lucky early and was now being found out, so we wanted to be the opponent it lost to next. It excluded rising teams outright, as improving opponents. It also looked for teams whose live rating sat above a rating we fitted to their games in the public archive, on the same logic: that team was carrying rating it hadn't earned, and would give it back.

On 28 September we dropped the falling-teams signal, because mean reversion, Galton's [regression towards mediocrity](https://doi.org/10.2307/2841583) (1886), runs the other way. A falling rating is mostly bad luck, so a falling team is more likely below its strength than above it, and it reverts upward, against whoever plays it. If mean reversion is the lesson, the teams to play are the ones that have risen unusually far lately on the same bot, since they've been lucky and should drift back to where they belong. The next afternoon, that was the proposal: challenge teams sitting above their recent stable baseline.

Both ideas treat a rating's wobbles as well-behaved noise around a fixed strength, and I had reason to doubt that. Two papers I wrote for my finance courses, *Buy the Tulip* and its sequel *Gild the Tulip*, tested market returns for more than skew, heteroscedasticity and non-stationarity, in the tradition of Nassim Nicholas Taleb and Richard Thaler. The first found returns fat-tailed, closer to a stable distribution than a normal one, as Mandelbrot found for cotton prices in [The Variation of Certain Speculative Prices](https://doi.org/10.1086/294632) (1963). The second asked what fat tails do to an investor who lives through one path rather than the average of many, which is ergodicity. It compared portfolios built for that, including the barbell of Taleb's *Antifragile* (2012), which keeps most of the money safe and puts a small part in bets that gain most from large moves. No portfolio came out best everywhere, but the barbell's protection paid in exactly the breaks that a model with finite variance doesn't expect.

So we measured the ladder's tails. Across 12,960 six-hour rating moves in the leaderboard's history, the spread was about ±50, skewed upward (+0.87), with a kurtosis of 16, where a normal curve has 3. Those tails are jumps: a team uploads a new bot and moves 100 points or more within hours of its fresh K. Our own 191 recent battles, scored against the rating prediction, were 1.21 times as spread as independent games would be, because games within a five-game battle move together. That's why our standard errors carry the factor of 1.2 [below](#estimates-before-release). Against teams 50 to 150 above us, we scored 0.11 a game below prediction, about three standard errors, with the spread wide and skewed by occasional upsets. Those teams were usually stronger than their rating, and the rare win was what made them look beatable. The battles mixed five of our bots, so the split by band is a hint rather than a measurement.

Then we tested the proposal directly, and found both kinds of mover were against us. We took the site's rating history for 557 teams and asked how each team's next twelve hours went, given how far its rating sat from the median of its previous six readings, relative to steady teams:

| Rating against its recent median | Next 12 hours, against steady teams |
| --- | ---: |
| 60 or more above | +17 |
| 25 to 60 above | +14 |
| 8 to 25 above | +10 |
| 8 to 25 below | +9 |
| 25 to 60 below | +15 |
| 60 or more below | +21 |

Risers kept rising, because a rise usually meant a new, stronger bot rather than a lucky run on the old one. Fallers partly recovered their luck. Both were stronger than their rating, and the archive signal had the same flaw: over our last 200 ranked battles, the opponents it picked scored us 0.316 a game against 0.380 predicted, which cost 127 rating over 740 games, while the hourly draws against teams near our rank scored 0.600 against 0.532 and gained 103 over 210. The teams it favoured had improved since the games it judged them on. So the challenger dropped the archive signal, added this drift to every mover's estimate, and preferred steady teams.

In hindsight, logic alone could have told us. A rating only estimates strength while the bot behind it stays the same, and a large move in either direction mostly says the bot has changed. A change isn't luck, and it doesn't revert.

One strategy we never tried follows from the barbell: keep a steady, strong bot live most of the time, and now and then swap in a wild one whose results swing hard, to profit from the swings rather than hope they don't come. It would be an interesting comparison for another season. Looking for exactly those wild bots in the middle of the ladder became the [cheese screen](#knockout-tournaments).

One more idea didn't work: pressing a good matchup. In 85 cases where one of our bots met the same team twice running, the first battle's score against prediction foretold the second's with a correlation of 0.085. After the seven clearly good first battles, the second came in below prediction. Matchup edges may exist, but five-game battles can't show one in time to use it.

A new bot has no measured strength, so for its first 40 games the challenger played the steady teams nearest our rating instead. Against an even opponent a game costs nothing in expectation, and an even game says the most about a bot.

## Estimates before release

The foil, our second bot line, was developed during the season in a loop: study live games, make one upgrade, check it, release it. At first each release was checked with a local series against the release before it. That misled us twice. foil-2026-09-29l beat 29k 52–36 locally and then performed about 1733 live, against 29k's 1800. foil-2026-09-29n beat 29m 48–40 locally and performed about 1741. Close versions of one line mostly play each other, so a series between them measures how they differ from each other, and on the ladder they meet everyone else.

So we moved the check to the cloud, with more games against both live incumbents rather than one, and a non-inferiority test instead of a test for improvement, the margin form of the verdict in [Better, worse or undecided](05-better-worse-or-undecided.md). foil-2026-09-30c shows why. Against 30b on the ladder maps it came out worse, 36–57, about −80 Elo with an interval from −157 to −10. Live, it performed about 1770 over 40 games against 30b's 1794, and 30b went back.

After upload, the live numbers take over. A performance rating over n games has a standard error of about 380/√n: the binomial value, widened by a factor of 1.2 we measured in our own battles, since five games against one opponent share a lot. That's about ±60 at 40 games and ±49 at 60. It's why we never judged a bot on one battle, or on how its rating moved in an afternoon.

## Swapping bots

Which bot is live changed three times as the season went on, because what we wanted from the ladder changed.

### Growth

At first the only aim was a higher rating. The strongest measured bot stayed live, and a queued release replaced it once the live bot plateaued: when its edge over its last 40 games, its score less what the ratings predicted, fell below +0.05. A release that performed below the bot it replaced after 40 to 50 games was rolled back. That's how foil-2026-09-29a, 29b and 29c each went live and came back off in favour of the old control bot.

### Keeping a release

On 30 September we changed the question. A release that has calibrated stays live unless it's measurably worse than the bot it replaced, by more than 1.28 standard errors of the difference, a one-sided 90% test. It needn't be shown better. The reasoning is that a new release is usually the line being improved, and its live games feed the replay reviews that improve it. What a slightly weaker release costs is only what the stronger one would win back within a few hours of being restored. foil-2026-09-30b stayed live under this rule at 1794 over 45 games, against 30a's 1805 over 65.

### Snapshots

The tournaments take a snapshot: the Sprint plays whatever is active at 9:00 AM on 1 October, and the Qualifiers take each team's rating and active submission as of 10 October. Close to a snapshot there's no time left to win rating back, so the rule changes again. Within 12 hours of a snapshot, the best point estimate decides, and the highest measured bot goes live and stays. For the Sprint that switch was at 1:00 AM, eight hours before the cutoff.

We also kept a cover plan that we never needed. Every battle and replay on the site is public, so a release that reached the top ten would have been swapped for an older, weaker bot, to show the top teams fewer of its games. None of ours got that high.

## The K window

K 96 moves rating four times as fast as K 24, in either direction. That's worth having for a bot that's much stronger than its rating, and dangerous for any other. With one fresh window per 12 hours, we treated it as something to spend deliberately.

Most releases were timed to play their first ranked battle within 12 hours of the previous fresh start, so they inherited the count and calibrated at floor K. When the window reopened at five past midnight on 30 September, we decided a new release would get it only on better evidence than a local win, after 29l and 29n. foil-2026-09-30a had that evidence from the cloud: a build one fix short of it beat 29o by about 41 Elo on the ladder maps, with an interval from +8 to +75. It went live at 3:36 AM and took our rating from 1748 at rank 73 to 1830 at rank 40 in under half an hour of K 96 battles, 30 games against the steady teams nearest our rating. It then settled near 1800 as K fell to the floor.

The window cut the other way on 28 September. The main line's release mainline-2026-09-28-02 was live for a few minutes that evening, and two ranked battles were queued with it at K 96. It scored 0 and 2 out of 5, and we pulled it for replay review. That evening our rating reached its low of 1492.

## Knockout tournaments

Every tournament is a seeded single-elimination bracket, and the Sprint and the Qualifiers play best-of-7 matches. A drawn match sends the higher seed through. So a bot that wins big but occasionally loses to a weak team is worse in a tournament than its rating says, and upsets matter more than margins.

We counted, for each release, the battles it lost to teams rated below its own measured strength. Our rating lags a new bot and flatters a weak one, so we counted against each bot's own performance rather than our rating:

![Each release's performance rating over its rated games, from 1508 for foil 09-29a to 1822 for foil 09-30d, and the battles from 29 September it lost to teams rated below that performance. The early bots near 1550 lost few such battles, 1 of 12 to 1 of 28. The stronger bots from 09-29g on lost more: 5 of 26 for 09-29k, 6 of 26 for 09-29j and 9 of 28 for 09-29o, then 1 of 13 for 09-30a and 1 of 10 for 09-30b. foil 09-30d had lost 3 of its first 7.](images/ladder-releases.svg)

Between two bots with level performance, we kept the one that lost fewer of those battles.

## Opponent styles

Some opponents played in ways that went beyond good or bad, and we gave their styles labels so we could talk about them. The teams stay anonymous here.

We found them in three ways. The first was a cheese screen: among teams rated 1350 to 1800, we looked for wins over teams rated 150 or more above them since 29 September, and found eight teams. In 10 of their 76 upset games the stronger team had failed 20 or more turns, so those wins involved a broken bot. The second was the list of our own upsets, counted against each bot's measured strength as above. The third was replaying our own losses exactly: our judge can replay a ladder game from its seed, with the opponent's recorded moves, while our bot runs with its diagnostics on, so [the viewer](11-through-one-dragons-eyes.md) shows why each of our dragons did what it did. Of our 19 newest games at one point, 16 reproduced every one of our turns.

To keep watching them, the replay collector pins every game of a style under study, so later pruning keeps them: 934 games for the two ram rushers and 285 for the cheese candidates. Its regular refresh keeps each team rated above us to its newest 40 games, and we tracked which teams upset us more than once. One team took 18 of 25 games from us while rated below us.

To improve against them, our second bot line, the foil, reviewed their games in cycles, and wrote sparring bots that copy a style, so a defence could be measured in the cloud before it went live.

### The swarm

The top teams fielded far more dragons than we did: at round 400 of two games our opponents were at the 64-dragon cap with 243 and 194 of total length, against our 28 and 39 dragons. One, Swarm Lord 1, reached about 60 dragons by round 150. The foil's first sparring bot copies this: every dragon splits at length four, chases the nearest pearl it remembers and trades heads while small.

### Endgame feeders

The same teams concentrate before round 500, when the longest dragon decides the game. On one map, Feeder 1's champion grew from 14 to 31 between rounds 330 and 390 while its team fell from 24 dragons to 5, most of them dying beside its route and leaving their pearls for it. We already fed late, but only about a third of our feeds reached our champion. The rest died beside whichever long teammate the feeder had last heard of. After the review, feeders fed only the elected champion, and in one local test 110 of 120 feeds reached it.

### Champion hunters

Short dragons converge on a long one and ram it, trading two or three segments for the dragon that decides the game. In 7 of 16 of our live games that we replayed exactly, a rival killed our longest dragon head-on after round 300, and we lost 6 of those 7. The foil answered with an escort, a small dragon's ram on an enemy head near our champion counting for half the champion's length, and with room for the champion to keep away from hunters. In the next 22 replayed games a rival killed our longest after round 250 only once. Many of those games ended early, so that suggests the fix works rather than showing it. Later came Shadow 1, a single small head that sat two to five cells from our champion for six to eight rounds and then moved into it, three times in one game. Its answer, sending one of our small dragons after the shadow, waits for live evidence, because our own releases never shadow a champion and so a test between them can't show it.

### Tail strikes

A dragon that splits leaves a new dragon at its old tail, which acts after everyone alive that round. Tail Biter 1 used this on our champion: it split beside it, and the new dragon's first move was a ram. Across 60 of our games, a rival's newborn dragon killed 74 of ours head-on, and ours did the same to 69 of theirs. The foil learned to treat an enemy's tail as a place a new head can appear, and adopted the move itself: a dragon of four or more splits off a two-segment child when the head of an enemy of six or more, which has already moved that round, sits beside its tail.

### The ramming swarm

Swarm Lord 2 combined numbers with rams. Its dragons moved into ours head-on from the opening: in three of its games against us, 16 of our 22, 33 of 39 and 60 of 121 deaths were head-on collisions it started, and on one map it had 22 dragons to our 9 by round 60. An even trade costs each side a dragon, and the side with more dragons wins that attrition. Over 15 games against it and one other team, a release that had been winning three games in four went 8–7, and 7 of the losses were eliminations. The obvious defence, keeping our small dragons out of reach of equal heads while outnumbered, made things worse: it trailed in the cloud, and lost all three local games against the swarm sparring bot, because stepping away in cramped ground gave the swarm the initiative and it caught our dragons anyway.

### Ram rushers

Two mid-pack teams, Rammer 1 and Rammer 2, sent their dragons straight at enemy heads, accepting heavy losses of their own, and eliminated much stronger teams early. Rammer 2's own dragons died almost only of turns with no valid action. We took the 450 games they lost to teams rated no more than 50 above them. The defenders didn't avoid the trades. They lost more heads in head-on collisions than the rushers did, 26,645 against 22,587, and 332 of the 450 games went the full 500 rounds, where the longest dragon wins. So a rush is absorbed with numbers and beaten on length. A strong economy supplies both, as the ramming swarm had already taught us. The foil wrote a rush sparring bot to measure it. Our live release beat it 4–0 locally, so it's weaker than the live rushers, whose strength is their numbers.

### The wall

One low-rated team, The Wall 1, won three games against teams rated more than 500 above it in which the stronger team lost 147 to 215 dragons to walls while The Wall 1 lost 10 or fewer in all. That looks like a bot that herds opponents into dead ends. It may equally have been a broken build on the other side, and we never confirmed it from the replays.
