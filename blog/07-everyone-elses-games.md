# Everyone else's games

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to describe the released sampler, now written in Nim, which walks the archive from the newest series back. I reran the sample with it.

Every test so far has pitted our bots against our own bots. But the opponents that matter are the other teams, and every game on the public ladder can be downloaded and watched, which makes the ladder's history the best record we have of what strong bots actually do. This post builds the fifth tool on the wishlist, a sampler that downloads a useful slice of those replays, and it's built around one rule above all: the site belongs to the organisers, and fetching from it mustn't add any noticeable load.

## Where the replays live

The toolkit can make replays of our own games, but it can't fetch anyone else's, since the documented API only lists your own team's recent battles. The public archive is reachable another way, through the same pages a browser uses.

The [Battles page](https://game.battlecode.au/battles) lists every ladder series, 25 to a page, and adding `?sort=at&dir=desc` puts the newest first. Each series has its own page listing its games, and each game's replay is one more request: the site's own viewer loads it from `/api/matches/<game>/replay`, which redirects to the file in storage. So one replay takes a request for the listing, one for the series page and one for the file, and the first two are shared by every game in the series. The sampler starts from the newest series and works back, because teams upload new bots all the time and the newest games show how they play now. It stops when it has as many replays as we asked for, or carries on through the whole archive with `--all`.

![The requests behind one replay. The Battles page, newest first with 25 series a page, leads to a series page listing its games, which leads to the replay API, which redirects to the packed, gzipped replay file. The first two requests are shared by every game in a series, and every request waits its turn.](images/replay-requests.svg)

## Being a good guest

The part that needs care is how the sampler talks to the site. Every request goes through one small client in [replays/collection.nim](../replays/collection.nim), built as `loong-sample-replays`. It checks robots.txt first, makes one request at a time, waits at least two seconds between requests by default, and only follows redirects over HTTPS. The interesting part is what happens when the site pushes back. If it answers with a 429, meaning slow down, or a server error, the client doubles its interval up to a minute, honours any `Retry-After` the site sends, and gives up entirely after six rejections in a row:

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

## A first sample

From `examples/tooling`, `just sample-replays --count 5` asks for five replays, which is plenty to try the decoder on in the next post:

![A terminal running just sample-replays --count 5. It downloads games 461859, 459149, 459151, 459020 and 459021, then eza shows public-replays holding a collector lock, manifest.sqlite, status.json and a replays folder with the five replays, from 18k to 187k each.](images/replay-sampler.png)

Those five took 24 seconds and 18 requests. The newest series on the site were still being played, so the sampler passed over their unfinished games and took finished ones from three series, two games each from two of them. The files vary a lot in size, from 18 KB to 187 KB, because a replay records every event in the game, and a long game with a hundred dragons records a great many.

At two seconds a request, a sample of a few hundred replays takes a quarter of an hour or so, which is a reasonable thing to leave running in the background. It's also a good reason to sample rather than mirror everything. The archive already runs to more than 9,000 pages of series, with game numbers past 461,000, and the questions we'll ask of them can be answered from a well-chosen few hundred.

## Next up

Downloading a replay is the easy part. The file itself is packed binary, so [the next post](08-reading-a-replay.md) works out how to read it and rebuild the game turn by turn.
