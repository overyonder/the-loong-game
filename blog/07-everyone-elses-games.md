# Everyone else's games

> **Editor's note, 28 September 2026.** This post has been rewritten to be shorter and to show the sampler's current request code.

Every test so far has pitted our bots against our own. The opponents that matter are the other teams, and every game on the public ladder can be downloaded and watched, which makes its history the best record there is of what strong bots do. This post builds a sampler that downloads a useful slice of it, around one rule: the site belongs to the organisers, and fetching from it mustn't add noticeable load.

## Where the replays live

The toolkit's documented API only lists your own team's recent battles, but the public archive is reachable through the pages a browser uses. The [Battles page](https://game.battlecode.au/battles) lists every ladder series, 25 to a page, and `?sort=rating` puts the highest-rated first. Each series page lists its games, and each replay is one more request: the site's viewer loads it from `/api/matches/<game>/replay`, which redirects to the file in storage. The sampler starts at the top of the rating-sorted listing, since the best bots are the ones worth studying, and works down until it has enough.

## Being a good guest

All requests go through one small client in [replays/collection.py](../replays/collection.py). It checks robots.txt, waits at least the interval between requests to the site, two seconds by default, and follows redirects only over HTTPS. When the site pushes back with a 429 or a server error, it doubles the interval, up to a minute, honours any `Retry-After`, and gives up after six rejections in a row:

```python
def slow_down(self, status: int, retry_after: str | None) -> None:
    self.rejections += 1
    if self.rejections > MAX_CONSECUTIVE_REJECTIONS:
        raise RejectedRequest(status, retry_after)
    self.interval = min(MAX_INTERVAL, max(self.interval * 2, 1.0))
    pause = max(self.interval, retry_delay(retry_after))
    print(
        f"HTTP {status}; interval now {self.interval:.2f}s, pausing {pause:.0f}s",
        flush=True,
    )
    time.sleep(pause)
```

Requests go one at a time, never in parallel. Each download is recorded in a SQLite manifest beside the replays, so a later run carries on where the last one stopped instead of fetching anything twice.

## A first sample

From `examples/tooling`, `just sample-replays --count 5 --output public-replays` asks for five, plenty to try the decoder on in the next post:

![A terminal running just sample-replays. It downloads five games from four of the highest-rated series, between 44,000 and 511,000 bytes each, then eza lists the five replays and the manifest in public-replays.](images/replay-sampler.png)

Those five took about 15 seconds. Two came from the same series, which saved a page request. They range from 44 KB to half a megabyte, because a replay records every event, and a long game with a hundred dragons records a great many.

At two seconds a request, a few hundred replays take a quarter of an hour or so, which is fine to leave running. It's also a reason to sample instead of mirroring everything. Game numbers on the site are past 216,000, and the questions we'll ask can be answered from a well-chosen few hundred.

## Next up

A replay file is packed binary, so [the next post](08-reading-a-replay.md) works out how to read it and rebuild the game turn by turn.
