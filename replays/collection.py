"""Paced public archive collection, with durable progress and participant indexes."""

import fcntl
import hashlib
import html
import json
import os
import re
import shutil
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from pathlib import Path

BASE = "https://game.battlecode.au"
AGENT = "LoongReplayResearch/1.0"
STRING = r'"(?:\\.|[^"\\])*"'
NUMBER = r"-?\d+(?:\.\d+)?"


def ratings_from_page(page: str) -> dict:
    pattern = (
        r"\{rank:(?:null|\d+),ranked:(?:true|false),id:(\d+),name:("
        + STRING
        + r"),hasImage:(?:true|false),elo:("
        + NUMBER
        + ")"
    )
    ratings = {
        identifier: {"id": int(identifier), "name": json.loads(name), "elo": float(elo)}
        for identifier, name, elo in re.findall(pattern, page)
    }
    if not ratings:
        raise ValueError("Leaderboard schema changed or page was rejected")
    return ratings


def listing_from_page(page: str) -> tuple[list[int], int]:
    identifiers = list(
        dict.fromkeys(map(int, re.findall(r'href="/battles/(\d+)"', page)))
    )
    pages = [int(value) for value in re.findall(r"[?&]page=(\d+)", html.unescape(page))]
    if not identifiers:
        raise ValueError("No battle links; refusing to assume archive complete")
    return identifiers, max(pages, default=1)


def battle_from_page(page: str) -> tuple[list[dict], list[dict]]:
    teams = []
    for side in ("A", "B"):
        identifier = re.search(r"team" + side + r"Id:(\d+)", page)
        name = re.search(r"team" + side + "Name:(" + STRING + ")", page)
        if not identifier or not name:
            raise ValueError("Battle participant schema changed")
        teams.append(
            {
                "id": int(identifier[1]),
                "name": json.loads(name[1]),
                "side": side,
                "submission_id": (
                    int(match[1])
                    if (match := re.search(r"submission" + side + r"Id:(\d+)", page))
                    else None
                ),
            }
        )
    block = re.search(r"games:\[(.*?)\]", page, re.DOTALL)
    if not block:
        raise ValueError("Battle game list missing")
    games = [
        {
            "id": int(identifier),
            "status": status,
            "winner": json.loads(winner),
            "has_replay": replay == "true",
        }
        for identifier, status, winner, replay in re.findall(
            r'\{id:(\d+),status:"([^"\n]+)",winner:(null|"[^"\n]*"),hasReplay:(true|false)\}',
            block[1],
        )
    ]
    if not games:
        raise ValueError("Battle game schema changed")
    return teams, games


class RejectedRequest(Exception):
    def __init__(self, status, retry_after=None):
        self.status = status
        self.retry_after = retry_after
        super().__init__(f"HTTP {status}; collector halted")


class NoAutomaticRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


SLOW_DOWN = (429, 500, 502, 503, 504, 520, 521, 522, 523, 524)
MAX_INTERVAL = 60.0
MAX_CONSECUTIVE_REJECTIONS = 6


def retry_delay(value: str | None) -> float:
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        try:
            return parsedate_to_datetime(value).timestamp() - time.time()
        except (ValueError, TypeError):
            return 0.0


class GentleClient:
    """Paces requests to the site; slows down on throttling instead of halting.

    Cross-host redirects (replay objects in Cloudflare R2) are not paced, since
    they do not load the site's own server.
    """

    def __init__(self, interval: float):
        self.interval = interval
        self.last_request = 0.0
        self.requests = 0
        self.rejections = 0
        self.opener = urllib.request.build_opener(NoAutomaticRedirect())
        self.robots = None

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

    def fetch(self, resource: str, optional_robots=False) -> bytes:
        url = urllib.parse.urljoin(BASE, resource)
        site = urllib.parse.urlsplit(BASE).netloc
        redirects = 0
        while redirects < 6:
            on_site = urllib.parse.urlsplit(url).netloc == site
            if self.robots and on_site and not self.robots.can_fetch(AGENT, url):
                raise ValueError("robots.txt disallows " + resource)
            if on_site:
                time.sleep(
                    max(0, self.interval - (time.monotonic() - self.last_request))
                )
                self.last_request = time.monotonic()
            self.requests += 1
            request = urllib.request.Request(url, headers={"User-Agent": AGENT})
            try:
                with self.opener.open(request, timeout=60) as response:
                    self.rejections = 0
                    return response.read()
            except urllib.error.HTTPError as error:
                if optional_robots and error.code in (404, 410):
                    return b""  # No robots policy is published at this optional URL.
                if error.code in (301, 302, 303, 307, 308):
                    url = urllib.parse.urljoin(url, error.headers.get("Location", ""))
                    if urllib.parse.urlsplit(url).scheme != "https":
                        raise ValueError("Refusing non-HTTPS redirect") from error
                    redirects += 1
                    continue
                if error.code in SLOW_DOWN and on_site:
                    self.slow_down(error.code, error.headers.get("Retry-After"))
                    url = urllib.parse.urljoin(BASE, resource)
                    redirects = 0
                    continue
                raise RejectedRequest(
                    error.code, error.headers.get("Retry-After")
                ) from error
        raise ValueError("Too many redirects")


def participant_name(team: dict, ratings: dict) -> str:
    current = ratings.get(str(team["id"]))
    prefix = f"{current['elo']:07.1f}" if current else "unrated"
    name = current["name"] if current else team["name"]
    safe = re.sub(r"[^\w.-]+", "_", name, flags=re.UNICODE).strip("._")[:70] or "team"
    safe = safe.encode("utf-8")[:80].decode("utf-8", errors="ignore")
    return f"{prefix}__{safe}__team-{team['id']}"


def organize(destination: Path, game_id: int, teams: list[dict], ratings: dict) -> None:
    replay = destination / "replays" / f"{game_id}.replay"
    for team, opponent in (teams, teams[::-1]):
        folder = destination / "participants" / participant_name(team, ratings)
        folder.mkdir(parents=True, exist_ok=True)
        name = f"game-{game_id:09d}__vs__{participant_name(opponent, ratings)}"
        link = folder / f"{name}__{team['side']}.replay"
        if not link.is_symlink():
            link.symlink_to(os.path.relpath(replay, folder))


def collect_public_replays(
    destination: Path,
    interval: float = 0.5,
    battles: list[int] | None = None,
    max_games: int | None = None,
    teams: list[int] | None = None,
    replays: Path | None = None,
    *,
    total_games: int | None = None,
) -> str:
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / "collector.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _collect(
            destination, interval, battles, max_games, teams, replays, total_games
        )


def link_replay_store(destination: Path, replays: Path) -> None:
    """Keep `<destination>/replays` as the path consumers use, linked to the store."""
    store = destination / "replays"
    replays = replays.resolve()
    replays.mkdir(parents=True, exist_ok=True)
    if store.is_symlink():
        if store.resolve() != replays:
            raise ValueError(f"{store} already links to {store.resolve()}")
    elif store.exists():
        raise ValueError(f"{store} is a local directory; move it to {replays} first")
    else:
        store.symlink_to(replays)


def _collect(
    destination: Path,
    interval: float,
    battles: list[int] | None,
    max_games: int | None,
    teams: list[int] | None,
    replays: Path | None,
    total_games: int | None,
) -> str:
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    if replays:
        link_replay_store(destination, replays)
    (destination / "replays").mkdir(exist_ok=True)
    state_path = destination / "status.json"
    state = (
        json.loads(state_path.read_text())
        if state_path.exists()
        else {"page": 1, "status": "new"}
    )
    if time.time() < state.get("retry_not_before", 0):
        raise ValueError("Saved rejection cooldown has not elapsed; no requests sent")
    db = sqlite3.connect(destination / "manifest.sqlite")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS battles (id INTEGER PRIMARY KEY, teams TEXT, games TEXT);
    CREATE TABLE IF NOT EXISTS replays (id INTEGER PRIMARY KEY,
        battle INTEGER, sha256 TEXT,
        bytes INTEGER, downloaded_at TEXT, source TEXT);
    """)
    client = GentleClient(interval)
    state["status"] = "running"
    state.pop("error", None)
    state["started_at"] = datetime.now(UTC).isoformat()

    def save():
        state["updated_at"] = datetime.now(UTC).isoformat()
        state["requests_this_run"] = client.requests
        state["interval"] = client.interval
        state["downloaded_games"] = db.execute(
            "SELECT COUNT(*) FROM replays"
        ).fetchone()[0]
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(state_path)

    def sample_complete():
        return (
            total_games is not None
            and db.execute("SELECT COUNT(*) FROM replays").fetchone()[0] >= total_games
        )

    def process_battle(identifier):
        cached = db.execute(
            "SELECT teams,games FROM battles WHERE id=?", (identifier,)
        ).fetchone()
        if cached:
            teams, games = map(json.loads, cached)
        else:
            teams, games = battle_from_page(
                client.fetch(f"/visualiser?match={identifier}").decode()
            )
            db.execute(
                "INSERT INTO battles VALUES (?,?,?)",
                (identifier, json.dumps(teams), json.dumps(games)),
            )
            db.commit()
        available = [g for g in games if g["has_replay"] and g["status"] == "completed"]
        for game in available[:max_games]:
            if sample_complete():
                return True
            if not game["has_replay"] or game["status"] != "completed":
                continue
            game_id = game["id"]
            if db.execute("SELECT 1 FROM replays WHERE id=?", (game_id,)).fetchone():
                organize(destination, game_id, teams, ratings)
                continue
            if shutil.disk_usage(destination / "replays").free < 5 * 1024**3:
                raise OSError("Less than 5 GiB free for replays; collection paused")
            state["current_game"] = game_id
            save()
            source = f"/api/matches/{game_id}/replay"
            payload = client.fetch(source)
            if not payload or payload.lstrip().startswith((b"<", b'{"error"')):
                raise ValueError(
                    "Replay response was empty, HTML, or an error document"
                )
            target = destination / "replays" / f"{game_id}.replay"
            temporary = target.with_suffix(".partial")
            temporary.write_bytes(payload)
            temporary.replace(target)
            db.execute(
                "INSERT INTO replays VALUES (?,?,?,?,?,?)",
                (
                    game_id,
                    identifier,
                    hashlib.sha256(payload).hexdigest(),
                    len(payload),
                    datetime.now(UTC).isoformat(),
                    BASE + source,
                ),
            )
            db.commit()
            organize(destination, game_id, teams, ratings)
            save()
            print(
                f"Downloaded {game_id}; total={state['downloaded_games']}", flush=True
            )

    try:
        if sample_complete():
            state["status"] = "completed_sample"
            return state["status"]
        robots = client.fetch("/robots.txt", optional_robots=True).decode()
        client.robots = urllib.robotparser.RobotFileParser()
        client.robots.parse(robots.splitlines())
        client.interval = max(interval, client.robots.crawl_delay(AGENT) or 0)
        ratings_path = destination / "ratings.json"
        if ratings_path.exists():
            snapshot = json.loads(ratings_path.read_text())
        else:
            snapshot = {
                "observed_at": datetime.now(UTC).isoformat(),
                "source": BASE + "/leaderboard",
                "teams": ratings_from_page(client.fetch("/leaderboard").decode()),
            }
            ratings_path.write_text(
                json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n"
            )
        ratings = snapshot["teams"]
        state["ratings_observed_at"] = snapshot["observed_at"]
        save()
        if teams:
            # Every series each team played, via the listing's team filter.
            battles = list(battles or [])
            for team in teams:
                page, last_page = 1, 1
                while page <= last_page:
                    identifiers, last_page = listing_from_page(
                        client.fetch(f"/battles?teams={team}&page={page}").decode()
                    )
                    battles += identifiers
                    page += 1
                print(f"Team {team}: {len(set(battles))} series so far", flush=True)
            battles = list(dict.fromkeys(battles))
        if battles:
            for identifier in battles:
                if process_battle(identifier):
                    state["status"] = "completed_sample"
                    return state["status"]
            state["status"] = "completed_targeted_batch"
            return state["status"]
        if state.get("order") != "rating":
            state.update(order="rating", page=1)
            state.pop("last_page", None)
        while state.get("last_page") is None or state["page"] <= state["last_page"]:
            identifiers, last_page = listing_from_page(
                client.fetch(f"/battles?sort=rating&page={state['page']}").decode()
            )
            state["last_page"] = max(state.get("last_page", 0), last_page)
            save()
            for identifier in identifiers:
                if process_battle(identifier):
                    state["status"] = "completed_sample"
                    return state["status"]
            state["page"] += 1
            save()
        # Revisit unfinished series once; this is not an endless live feed.
        pending = [
            identifier
            for identifier, games in db.execute("SELECT id,games FROM battles")
            if any(g["status"] != "completed" for g in json.loads(games))
        ]
        for identifier in pending:
            db.execute("DELETE FROM battles WHERE id=?", (identifier,))
            db.commit()
            if process_battle(identifier):
                state["status"] = "completed_sample"
                return state["status"]
        state["unavailable_games"] = sum(
            not game["has_replay"] or game["status"] != "completed"
            for (games,) in db.execute("SELECT games FROM battles")
            for game in json.loads(games)
        )
        state["status"] = "completed_discovered_snapshot"
    except RejectedRequest as error:
        delay = max(3600.0, retry_delay(error.retry_after))
        state.update(
            status="halted_on_rejection",
            http_status=error.status,
            retry_after=error.retry_after,
            retry_not_before=time.time() + delay,
        )
        print(str(error), flush=True)
    except (Exception, KeyboardInterrupt) as error:
        state.update(status="paused", error=str(error))
        raise
    finally:
        save()
        db.close()
    return state["status"]
