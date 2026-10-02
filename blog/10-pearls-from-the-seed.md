# Pearls from the seed

The replay reader in the last post can rebuild where every dragon was, but a replay downloaded from the competition site no longer records pearl countdown events. Its copy of the map also sets every tile's minimum and maximum spawn gaps to zero. The bot still saw the current countdown in its 7×7 window while it played, yet someone opening the replay later can't tell when an empty spawning tile is due to try again.

There is a second complication. The site serves several maps in variants under the published map name. Their kelp, portals and starting bodies can look identical while their pearl timings differ, and one version of Prisoners Dilemma starts with ten dragons instead of the six in the public file. Loading the named file can therefore rebuild a perfectly plausible game that isn't the game the ladder played.

## Every attempt is deterministic

A match record gives us the missing ingredient: its seed. The engine uses it to initialise [`mt19937_64`](https://math.sci.hiroshima-u.ac.jp/m-mat/MT/emt64.html), a deterministic random-number generator. For a tile with minimum gap `lo` and maximum gap `hi`, each draw chooses a countdown:

```text
countdown = lo + draw % (hi - lo + 1)
```

On a symmetric map, reflected tiles share a countdown. The first tile encountered in the engine's scan owns that group, so initialisation takes one draw per group, not one per tile. When the group attempts to spawn it takes another draw to set its next countdown. An occupied tile still makes its attempt and consumes that draw even though no pearl appears.

Spawn attempts happen at the start of a round, before the dragons act. An initial countdown of `c` first attempts in round `c - 1`; a fresh countdown of `c` drawn on an attempt in round `r` next attempts in round `r + c`. A pearl left by a dying dragon is a different event, not evidence of a spawn countdown.

![A site replay and match seed constrain a reconstruction. Seeded engine draws produce shared countdowns and spawn attempts, including attempts blocked by occupancy. A candidate table must explain both appearances and their absence. Reconstruction compares state and our bot's actions, stopping at the first difference.](images/pearl-reconstruction.svg)

## Finding a table that explains the replay

The published map is the first candidate. If its seeded attempts agree with the replay, we can use it to reconstruct that game. Otherwise the fitting tool searches bounded ranges of minimum and maximum gaps. Early appearances narrow the choices; later appearances reject them. Hidden attempts on occupied cells still have to be accounted for, or every later random draw shifts to the wrong tile.

Matching the pearls that appeared isn't enough. A candidate that predicts a pearl on a free spawning tile where none appeared is wrong too. The check needs the board's occupancy at the start of each round, and keeps spawn events separate from pearls dropped by deaths. It must also agree with the replay's geometry and starting dragons: the right schedule on the wrong map is still the wrong game.

| Candidate predicts | Replay records | Verdict |
| --- | --- | --- |
| Attempt on a free tile | A spawn there | Consistent |
| Attempt on a free tile | No spawn there | Reject |
| No attempt | A spawn there | Reject |
| Attempt on an occupied tile | No spawn there | Consistent; the draw was still consumed |

Several gap tables can explain the same finite replay, especially for tiles that stayed occupied or never tried to spawn within 500 rounds. A fit is a compatible reconstruction, not proof that we've recovered the organisers' unique hidden table. Checking several games with different seeds gives it more constraints. A game outside the search bounds, or one no candidate explains, stays unresolved.

## Variants behind familiar labels

I ran that check over 40 stored games for each current map on 1 October. Four maps had one repeatable variant beyond the published file. Slithery Fight still had 19 games that neither its public table nor a fitted table explained, so those stay unresolved rather than being forced into a bad fit.

![Out of 40 stored games per map, the published gap table failed to explain 20 Prisoners Dilemma games, 14 Queen Of Spades games, 16 Devil games, 23 Schooltime games and 19 unresolved Slithery Fight games. Trauma, Default, Trophy, Portals and Autarky had none.](images/map-variant-counts.svg)

| Published name | Games not explained by the published gaps | Result |
| --- | ---: | --- |
| Prisoners Dilemma | 20 of 40 | One fitted variant, also with four extra starting dragons |
| Queen Of Spades | 14 of 40 | One fitted gap table |
| Devil | 16 of 40 | One fitted gap table |
| Schooltime | 23 of 40 | One fitted gap table |
| Slithery Fight | 19 of 40 | Unresolved |
| Trauma, Default, Trophy, Portals and Autarky | 0 of 40 each | The published table explained all 40 |

Those are aggregate counts from our stored games, not a new census of the live ladder. The fitted gaps themselves stay out of the release because tournament maps are unseen and a bot shouldn't be taught to identify a familiar layout. The variants are reconstruction evidence, not a strategy input.

## Rebuilding a game

The public tools take a downloaded replay, its match seed, a candidate map and explicit map directories. They don't contain our fitted tables or need our ladder account. Fitting requires at least three seeded replays and refuses to write a map if its search leaves unresolved spawning tiles. Lookup requires exactly one compatible table among the supplied maps; missing or ambiguous matches are errors.

From `examples/tooling`, after `just tools-build`, the fitting input is a TSV with a seed and replay path on each row:

```sh
just map-variants fit \
  --map maps/published.map --games seeded-replays.tsv \
  --output variants/fitted.map

just regenerate --replay game.replay --seed MATCH_SEED \
  --maps maps --variants variants --output rebuilt.replay
```

Without a bot build, regeneration drives both teams from the recorded actions. Adding `--build BUILD_GUID --side A` reruns that registered bot on side A, with the other side scripted. The [reconstruction README](../harness/README.md#regeneration) gives the formats and refusal conditions. Use the engine version that played the original game; a newer rule set can make the rerun differ.

There are two different reruns. In a local evaluation we have both registered builds, the exact map and the seed. Playing both again in the [Zig judge](19-the-machine-inside-the-judge.md) lets us compare actions, the result and charged points, with the same accounting settings.

In a ladder game we don't have the other team's program. We can rerun our registered build while a scripted opponent sends the other team's recorded actions, including splits and sonar. That can check our actions and the resulting game state. It cannot recover how many CPU points the other team's original program spent choosing those actions. The check reports the first state or action difference, and only writes the reconstructed replay after the comparisons pass.

This also limits what can be discarded. A local game can be regenerated from its compact result and frozen builds; a ladder reconstruction still needs the recorded opponent actions. And an unresolved map must not turn into a supposedly exact rerun just because its name matches a bundled file.

Recovered countdowns give the [viewer](11-through-one-dragons-eyes.md) a way to show the Spawn gaps overlay and to check what a bot remembered about pearl timing. Unknown countdowns should remain unknown until a checked reconstruction supplies them. Zeroes in the downloaded replay aren't evidence that the ground never grows food.

## Next up

[Through one dragon's eyes](11-through-one-dragons-eyes.md): rerunning a bot on the observations in a replay, then drawing what it saw, believed and decided.
