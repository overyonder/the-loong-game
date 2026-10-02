# Replay collector

`sample-replays` collects a paced, resumable sample of public replays. It runs
only when invoked and ends after its sample or discovered snapshot completes.

- Inputs: the user's toolkit API key in `~/.unswbc/keys.json`, public battle
  pages, and a leaderboard snapshot. `--own-team ID` selects the user's team and is required for collection and planning.
  `--ratings FILE` uses a saved `ratings.json` or API leaderboard array.
- Outputs: `manifest.sqlite`, `status.json`, `ratings.json`, and
  `replays/ID.replay` under `--output DIR`; `--replays DIR` changes the replay
  directory. The SQLite tables are `battles(id, teams, games, match)`,
  `replays(id, battle, sha256, bytes, downloaded_at, source)` and
  `pins(game, role, reason, pinned_at)`. API payloads remain JSON at the boundary.
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
