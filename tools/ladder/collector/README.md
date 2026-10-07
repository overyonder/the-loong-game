# Replay collector

`sample-replays` collects a paced, resumable sample of public replays. It runs
only when invoked and ends after its sample or discovered snapshot completes.

- Inputs: the user's toolkit API key in `~/.unswbc/keys.json`, public battle
  pages, and a leaderboard snapshot. `--own-team ID` selects the user's team.
  `--ratings FILE` uses a saved `ratings.json` or API leaderboard array.
- Outputs: `manifest.sqlite`, `status.json`, `ratings.json`, and
  `replays-manifest.json` under `--output DIR`. Replay files use
  `gamedata.store.publicReplays`: `$LOONG_PUBLIC_REPLAYS`, otherwise
  `$LOONG_STORAGE_ROOT/public-replays`, whose default is
  `assets/public-replays`. `--replays DIR`
  overrides that directory. The SQLite tables are `battles(id, teams, games, match)`,
  `replays(id, battle, sha256, bytes, downloaded_at, source)`,
  `pins(game, role, reason, pinned_at)` and `seeds(game, seed)`. A battle's
  page gives only its own game's seed, so each other stored game's seed comes
  from its own page (`/visualiser?match=GAME`), fetched once when the game is
  downloaded or found already stored, through the same paced requests; a page
  that fails leaves the seed to a later run. `tools/ladder/map_variants.nim`
  and `just regenerate` read `seeds` before asking the site. API payloads
  remain JSON at the boundary.
- Commands: `just sample-replays --own-team ID --count 5 --output DIR`, or
  `--all` for the discovered archive. Requests start two seconds apart,
  respect robots rules and slow down on throttling. A rejection saves a
  cooldown; a network outage saves progress for the next invocation.

Retention protects, in descending order, every game of the selected team,
the newest 500 games of each team rated at least 1950, explicit pins, and the
newest 40 games of each team above the selected team's rating. The replay
files have a 100 GB decimal cap. Both the estimated and actual incoming size
must fit; eviction takes the least protected, oldest game first and cannot
displace a more protected game. A missing selected-team rating is refused.

`--pin-games LIST --pin-role ROLE --pin-reason TEXT` pins game IDs listed one
per line. `--release-pins --pin-role ROLE [--pin-reason TEXT]` releases them.
These operations make no requests. A targeted `--battles ID...` or
`--teams ID...` collection with the pin options pins its discovered games.

`--prune-plan LIST` writes the replay names retention would delete and prints
the counts and bytes by class. It deletes nothing. Use `--ratings FILE` to
plan offline. Remove only the reviewed files yourself, then use
`--prune-drop LIST` to drop the manifest rows for files that are gone. Files
still present keep their rows. Pins remain until explicitly released.

The ladder keeps metadata in `results/online` and deletes reviewed replay
files locally. After reviewing `/tmp/loong-prune-replays.list`, produced by
`--prune-plan`, use the same replay root for deletion and manifest cleanup:

```sh
export LOONG_PUBLIC_REPLAYS=assets/public-replays
(cd "$LOONG_PUBLIC_REPLAYS" && xargs -r -d '\n' rm -- < /tmp/loong-prune-replays.list)
just sample-replays --output results/online --replays "$LOONG_PUBLIC_REPLAYS" \
    --prune-drop /tmp/loong-prune-replays.list
```
