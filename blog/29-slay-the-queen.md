# Slay the Queen

After the Sprint on 1 October, the organisers announced [Slay the Queen](https://game.battlecode.au/updates). Dragons 0 and 1 are now their teams' queens. If neither team has been eliminated after 500 rounds, the longer queen wins. A dead queen counts as length zero, and ties still go to the longest dragon, then total team length.

Movement changed too. A dragon now gets `ceil(length / 4)` free steps instead of one, so growing a dragon changes how far it can move without spending its body.

> The strategy and training described earlier in this series were developed under the previous rules. Those results belong to that version of the game.

I'm revisiting the designs in [Planning to play](26-planning-to-play.md) and [Learning to play](27-learning-to-play.md) as we adapt to the new rules. [A tour of our bot](28-a-tour-of-our-bot.md) records the pre-Queen design and its unfinished integration. The new version in development uses a different architecture.
