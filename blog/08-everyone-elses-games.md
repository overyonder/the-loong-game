# Everyone else's games

> **Editor's note, 2 October 2026.** The sampler now also maintains a capped replay store, keeping our games, recent games from strong teams and games pinned for study. Its manifest makes retention and deletion explicit. The five-game sample below was collected on 28 September.

Every test so far has pitted our bots against our own bots. But the opponents that matter are the other teams, and every game on the public ladder can be downloaded and watched, which makes the ladder's history the best record we have of what strong bots actually do. This post builds the fifth tool on the wishlist, a collector that keeps a useful slice of those replays. The site belongs to the organisers, so fetching from it mustn't add any noticeable load.

## The public archive

The toolkit can make replays of our own games, but it can't fetch anyone else's, since the documented API only lists your own team's recent battles. The public archive is reachable through its web pages.

The [Battles page](https://game.battlecode.au/battles) lists every ladder series, 25 to a page, and adding `?sort=at&dir=desc` puts the newest first. Each series has its own page listing its games, and each game's replay is one more request: the site's own viewer loads it from `/api/matches/<game>/replay`, which redirects to the file in storage. So one replay takes a request for the listing, one for the series page and one for the file, and the first two are shared by every game in the series. The collector starts from the newest series and works back, because teams upload new bots all the time and the newest games show how they play now. A small `--count` asks for a sample. `--all` walks the archive index, while the retention policy still decides which files belong in the store.

![The requests behind one replay. The Battles page, newest first with 25 series a page, leads to a series page listing its games, which leads to the replay API, which redirects to the packed, gzipped replay file. The first two requests are shared by every game in a series, and every request waits its turn.](images/replay-requests.svg)

## Being a good guest

The part that needs care is how the collector talks to the site. Archive requests go through one small client in [replays/collection.nim](https://github.com/overyonder/the-loong-game/blob/ca25234/replays/collection.nim), built as `loong-sample-replays`. It checks robots.txt first, makes one request at a time, waits at least two seconds between requests by default, and only follows redirects over HTTPS. The interesting part is what happens when the site pushes back. If it answers with a 429, meaning slow down, or a server error, the client doubles its interval up to a minute, honours any `Retry-After` the site sends, and stops after repeated rejections:

```nim
proc slowDown(client: var Client, status: int, retryAfter: string) =
  inc client.rejections
  if client.rejections > MaxConsecutiveRejections: raise rejected(status, retryAfter)
  client.interval = min(MaxInterval, max(client.interval * 2, 1.0))
  let pause = max(client.interval, retryDelay(retryAfter))
  say "HTTP " & $status & "; interval now " & formatFloat(client.interval, ffDecimal, 2) &
    "s, pausing " & $int(round(pause)) & "s"
  pause(pause)
```

When it does give up, it saves how long the site asked it to wait, and a rerun refuses to send a single request until that time has passed. It also records every series and download in a SQLite manifest beside the replays, with each series' teams and games, and keeps its place in `status.json`, so a later run carries on where the last one stopped instead of fetching anything twice.

## Keeping the games we study

A growing archive needs a rule for what to keep. Each run takes one leaderboard snapshot and applies the policy to the indexed games. The public tool takes the team we're studying as configuration. It doesn't contain our account identity.

| Priority, highest first | Games selected |
| --- | --- |
| Our team | Its indexed games |
| Top-rated teams | The newest 500 per team at or above 1,950 Elo |
| Pinned games | Games named for a particular review or experiment |
| Teams above us | The newest 40 per team above our current rating |

A game can qualify in several ways and gets the highest of those priorities. The store's default cap is 100 GB. Retention counts stored bytes, drops unselected files first, and then works from the least protected, oldest games upwards. A pin records who needs the game and why, and sets its retention priority within the hard cap.

![The replay collector's retention policy. Our indexed games, recent top-team games, pinned games and recent games from teams above us feed one selection. The manifest records membership and bytes. Files outside the selection are removed first; lower-priority, older selected files yield when the storage cap needs room.](images/collector-retention.svg)

The manifest keeps the battle index even when the file goes, so a later run knows what it has already seen. Pins have an owner role and a reason, which lets us release the claim when the review is done. For a manual deletion, `--prune-plan` writes exact replay filenames and reports counts and bytes by priority. It deletes nothing. After reviewing and removing those files, `--prune-drop` removes their manifest rows only if the files are gone. Pins remain until explicitly released.

Walking every archive page still costs requests and time, so start with a narrow sample:

```sh
just sample-replays --own-team YOUR_TEAM_ID --count 5 --output public-replays
```

The collector reads the user's toolkit API key for its leaderboard snapshot. A saved ratings file also lets it plan retention offline. The [README](https://github.com/overyonder/the-loong-game/blob/ca25234/replays/README.md) lists the pin and drop commands.

## A first sample

The original sample used `just sample-replays --count 5` from `examples/tooling`. The current collector also requires `--own-team`, as above. Five replays are plenty to try the decoder on in the next post:

![A terminal running just sample-replays --count 5. It downloads games 461859, 459149, 459151, 459020 and 459021, then eza shows public-replays holding a collector lock, manifest.sqlite, status.json and a replays folder with the five replays, from 18k to 187k each.](images/replay-sampler.png)

That 28 September sample took 24 seconds and 18 requests. The newest series on the site were still being played, so the sampler passed over their unfinished games and took finished ones from three series, two games each from two of them. The files vary a lot in size, from 18 KB to 187 KB, because a replay records every event in the game, and a long game with a hundred dragons records a great many.

At two seconds a request, shared listing requests help, but every selected file still has to be fetched in turn. The archive already ran to more than 9,000 pages of series at the time of that sample. Keeping a useful set under a cap is different from trying to mirror it all.

## Next up

Downloading a replay is the easy part. The file itself is packed binary, so [the next post](09-reading-a-replay.md) works out how to read it and rebuild the game turn by turn.
