"""Download a sample of public ladder replays, highest-rated battles first, gently.

    python3 -m replays.sample --count 20 --output public-replays

The public Battles page lists every ladder series, 25 to a page, and can sort
them by rating. Each series page lists its games, and each game's replay is one
download. The sampler walks that listing from the top, one request at a time
with a pause between requests, and stops once it has --count replays. It keeps
a manifest, so running it again carries on where it stopped instead of
downloading anything twice. If the site answers 429 or 5xx it waits and slows
down, and any other error stops it.
"""

import argparse
import html
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from pathlib import Path

SITE = "https://game.battlecode.au"
AGENT = "LoongGameReplaySampler/1.0 (+https://over-yonder.tech/games/loong/)"


class PoliteClient:
    """One request at a time, never faster than `interval` seconds apart."""

    def __init__(self, interval: float):
        self.interval = interval
        self.last_request = 0.0
        self.robots = urllib.robotparser.RobotFileParser()

    def get(self, path: str) -> bytes:
        url = urllib.parse.urljoin(SITE, path)
        if not self.robots.can_fetch(AGENT, url):
            raise SystemExit(f"robots.txt asks us not to fetch {path}")
        while True:
            time.sleep(max(0.0, self.last_request + self.interval - time.monotonic()))
            self.last_request = time.monotonic()
            request = urllib.request.Request(url, headers={"User-Agent": AGENT})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                if error.code == 429 or error.code >= 500:
                    # The server is busy: wait at least as long as it asks, and stay slower from now on.
                    self.interval = min(60.0, self.interval * 2)
                    time.sleep(max(self.interval, float(error.headers.get("Retry-After") or 0)))
                    continue
                raise SystemExit(f"{path}: HTTP {error.code}, stopping")

    def read_robots(self) -> None:
        try:
            self.robots.parse(self.get("/robots.txt").decode().splitlines())
        except SystemExit:
            self.robots.parse([])   # no robots.txt published
        self.interval = max(self.interval, self.robots.crawl_delay(AGENT) or 0)


def series_on_listing_page(page: str) -> list[int]:
    return list(dict.fromkeys(map(int, re.findall(r'href="/battles/(\d+)"', page))))


def games_in_series(page: str) -> list[dict]:
    """The games of one series, from the data the series page embeds for its viewer."""
    block = re.search(r"games:\[(.*?)\]", page, re.S)
    if not block:
        raise SystemExit("A series page no longer lists its games where we expect; stopping")
    return [{"id": int(identifier), "status": status, "has_replay": has_replay == "true"}
            for identifier, status, has_replay in re.findall(
                r'\{id:(\d+),status:"([^"]+)",winner:(?:null|"[^"]*"),hasReplay:(true|false)\}', block[1])]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, required=True, help="replays to have once finished")
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between requests")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    arguments.output.mkdir(parents=True, exist_ok=True)
    manifest_path = arguments.output / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"games": {}, "series_done": []}
    client = PoliteClient(arguments.interval)
    client.read_robots()

    page_number = 1
    while len(manifest["games"]) < arguments.count:
        listing = client.get(f"/battles?sort=rating&page={page_number}").decode()
        series = series_on_listing_page(html.unescape(listing))
        if not series:
            break
        for series_id in series:
            if len(manifest["games"]) >= arguments.count:
                break
            if series_id in manifest["series_done"]:
                continue
            # /battles/<id> redirects to the visualiser page, which carries the same data.
            page = client.get(f"/visualiser?match={series_id}").decode()
            for game in games_in_series(page):
                if len(manifest["games"]) >= arguments.count:
                    break
                if not game["has_replay"] or str(game["id"]) in manifest["games"]:
                    continue
                replay = client.get(f"/api/matches/{game['id']}/replay")
                (arguments.output / f"{game['id']}.replay").write_bytes(replay)
                manifest["games"][str(game["id"])] = {"series": series_id, "bytes": len(replay)}
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
                print(f"game {game['id']} from series {series_id}: {len(replay):,} bytes", flush=True)
            else:
                manifest["series_done"].append(series_id)
        page_number += 1
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(manifest['games'])} replays in {arguments.output}")


if __name__ == "__main__":
    main()
