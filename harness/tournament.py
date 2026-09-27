"""Run the pinned Battlecode CLI and retain each game's evidence."""

import fcntl
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

from harness import toolkit
from harness.rating import fit_ratings

ROOT = Path(__file__).resolve().parents[1]
RESULT_PATTERN = re.compile(
    r"^(?:team (?P<winner>[AB]) wins|(?P<draw>draw)) after "
    r"(?P<rounds>\d+) rounds \((?P<reason>[^)]+)\)",
    re.MULTILINE,
)
FAILURE_PATTERN = re.compile(
    r"^round \d+: bot \d+ \(team [AB]\) "
    r"(?:ran out of time|exited|.*(?:fuel|trap|memory limit))|"
    r"died: no valid action",
    re.MULTILINE,
)


def discover_bots(names: list[str]) -> dict:
    """Bot directories named relative to the working directory, each with a bot.toml."""
    bots = {}
    for name in names:
        directory = Path(name)
        if not (directory / "bot.toml").is_file():
            raise ValueError(f"Not a bot directory: {name}")
        bots[name] = {"directory": str(directory.resolve())}
    return bots


GAME_CACHE = ROOT / "build/game-cache"
BUILD_OUTPUTS = {".unswbc-build", "__pycache__", "gen-native"}


def content_hash(path: Path) -> str:
    """Hash of a map file, or of every file in a bot directory except build outputs."""
    digest = hashlib.sha256()
    files = (
        [path]
        if path.is_file()
        else sorted(
            file
            for file in path.rglob("*")
            if file.is_file() and not BUILD_OUTPUTS & set(file.relative_to(path).parts)
        )
    )
    for file in files:
        digest.update(
            file.relative_to(path.parent).as_posix().encode()
            + b"\0"
            + file.read_bytes()
        )
    return digest.hexdigest()


def game_key(command: list[str]) -> str | None:
    """A key for a match that always plays out the same way, or None if it might not.

    Only seeded sandbox matches are deterministic: the seed fixes pearls and both bots'
    random numbers, and the sandbox runs on a virtual clock. The key covers every
    argument except the replay path, with each map or bot path replaced by its
    name and content, plus the toolkit version, so an edited bot, map or toolkit
    never reuses an old result. The toolkit's interpreter, the command's first
    argument, is covered by that version and its repair script by its content.
    """
    if "--sandbox" not in command or "--seed" not in command:
        return None
    parts, skip = [toolkit_version()], False
    for argument in command[1:]:
        if skip:
            skip = False
        elif argument == "-o":
            skip = True
        elif Path(argument).exists():
            path = Path(argument).resolve()
            bot = path.parent if path.is_file() and path.suffix == ".py" else path
            parts.append(f"{bot.name}:{content_hash(bot)}")
        else:
            parts.append(argument)
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()


def toolkit_version() -> str:
    """Version of the organiser's toolkit used for every game."""
    found = sorted(
        toolkit.toolkit_interpreter().parent.parent.glob(
            "lib/python*/site-packages/unswbc-*.dist-info"
        )
    )
    return (
        found[-1].name.removeprefix("unswbc-").removesuffix(".dist-info")
        if found
        else "unknown"
    )


def _result_hash(path: Path | None) -> str | None:
    if path is None or not path.is_file():
        return None
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run_game(command: list[str], log_path: Path, timeout: float) -> tuple[int, bool]:
    """Play one match, or reuse a finished identical one from the game cache.

    Several threads or processes may ask for the same match at once, for example two
    tournaments sharing a pairing. A lock per match makes the others wait for the first
    and then read its result instead of playing it again. Only completed matches are
    cached (`read_outcome`), so timeouts, toolkit failures and bot execution
    failures are always played again.
    """
    key = game_key(command)
    if key is None:
        return play_match(command, log_path, timeout)
    replay_path = Path(command[command.index("-o") + 1]) if "-o" in command else None
    entry = GAME_CACHE / f"{key}.json"
    GAME_CACHE.mkdir(parents=True, exist_ok=True)
    with (GAME_CACHE / f"{key}.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if entry.is_file():
            cached = json.loads(entry.read_text())
            previous_log = Path(cached["log"])
            previous_replay = Path(cached["replay"]) if cached.get("replay") else None
            if (
                previous_log.is_file()
                and cached.get("log_sha256") == _result_hash(previous_log)
                and read_outcome(previous_log, 0, False)["status"] == "completed"
                and (
                    not replay_path
                    or previous_replay is not None
                    and previous_replay.is_file()
                    and cached.get("replay_sha256") == _result_hash(previous_replay)
                )
            ):
                log_path.parent.mkdir(parents=True, exist_ok=True)
                if log_path.resolve() != previous_log.resolve():
                    log_path.unlink(missing_ok=True)
                    log_path.symlink_to(os.path.relpath(previous_log, log_path.parent))
                if replay_path and replay_path.resolve() != previous_replay.resolve():
                    replay_path.parent.mkdir(parents=True, exist_ok=True)
                    replay_path.unlink(missing_ok=True)
                    replay_path.symlink_to(
                        os.path.relpath(previous_replay, replay_path.parent)
                    )
                return 0, False
        returncode, timed_out = play_match(command, log_path, timeout)
        if read_outcome(log_path, returncode, timed_out)["status"] != "completed":
            return returncode, timed_out
        entry.write_text(
            json.dumps(
                {
                    "log": str(log_path.resolve()),
                    "log_sha256": _result_hash(log_path),
                    "replay_sha256": _result_hash(replay_path),
                    "replay": str(replay_path.resolve())
                    if replay_path and replay_path.is_file()
                    else None,
                }
            )
            + "\n"
        )
        return returncode, timed_out


def play_match(command: list[str], log_path: Path, timeout: float) -> tuple[int, bool]:
    """Run the Just-owned organiser adapter; caching remains tournament policy."""
    # Rerunning into a reused result must not overwrite another game's evidence.
    outputs = [log_path]
    if "-o" in command:
        outputs.append(Path(command[command.index("-o") + 1]))
    for output in outputs:
        if output.is_symlink():
            output.unlink()
    completed = subprocess.run(
        ["just", "--quiet", "_match", str(log_path.resolve()), str(timeout), *command],
        capture_output=True,
        text=True,
        check=True,
    )
    code, timed_out = json.loads(completed.stdout)
    return code, timed_out


def read_outcome(log_path: Path, returncode: int, timed_out: bool) -> dict:
    text = log_path.read_text(errors="replace")
    outcomes = list(RESULT_PATTERN.finditer(text))
    failure = FAILURE_PATTERN.search(text)
    outcome = outcomes[-1] if outcomes else None
    error = None
    if timed_out:
        error = "Match exceeded the harness timeout"
    elif returncode:
        error = f"Battlecode exited with code {returncode}"
    elif failure:
        error = f"Bot execution failure: {failure.group(0)}"
    elif outcome is None:
        error = "No engine result found"
    return {
        "status": "error" if error else "completed",
        "error": error,
        "winner_side": outcome["winner"] if outcome else None,
        "rounds": int(outcome["rounds"]) if outcome else None,
        "reason": outcome["reason"] if outcome else None,
    }


def game_id(game: dict) -> tuple:
    """A scheduled game's identity within a result set: sides, map and seed."""
    return game["A"], game["B"], Path(game["map"]).name, game.get("seed")


def reusable_games(directory: Path) -> dict[tuple, dict]:
    """A result set's completed games by `game_id`, the ones a resume keeps.

    Errored games are left out, so a resumed set plays them again rather than
    judging on them, and so does every game a run never reached.
    """
    path = directory / "results.json"
    if not path.is_file():
        return {}
    games = json.loads(path.read_text())["games"]
    return {game_id(game): game for game in games if game["status"] == "completed"}


def settled(directory: Path) -> bool:
    """Whether a result set finished with every game completed, so it can be reused."""
    path = directory / "results.json"
    return path.is_file() and json.loads(path.read_text())["status"] == "completed"


def forget_game(directory: Path, log: str) -> None:
    """Delete a game's evidence and what was derived from it before it is replayed."""
    for path in directory.glob(f"{Path(log).stem}.*"):
        path.unlink()


def save_results(directory: Path, report: dict) -> str:
    standings = {
        name: {
            "bot": name,
            "wins": 0,
            "draws": 0,
            "losses": 0,
            "errors": 0,
            "points": 0.0,
        }
        for name in report["bots"]
    }
    for game in report["games"]:
        for side in ("A", "B"):
            row = standings[game[side]]
            if game["status"] == "error":
                row["errors"] += 1
            elif game["winner_side"] is None:
                row["draws"] += 1
                row["points"] += 0.5
            elif game["winner_side"] == side:
                row["wins"] += 1
                row["points"] += 1
            else:
                row["losses"] += 1
    ratings = fit_ratings(list(report["bots"]), report["games"])
    for name, row in standings.items():
        row["rating"] = ratings[name]
    report["standings"] = sorted(
        standings.values(), key=lambda row: (-row["points"], row["bot"])
    )
    (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [
        "# Round-robin results",
        "",
        f"Mode: {report['mode']}. Finished {len(report['games'])} of "
        f"{report['scheduled_games']} scheduled games. State: {report['status']}.",
        "",
        "Each pair plays both sides on each map. Win = 1 point; draw = 0.5.",
        "Execution failures are unscored and count as errors for both participants.",
        "Ratings are a Bradley–Terry fit to every game, on the Elo scale: "
        "400 points is ten-to-one odds, and the pool averages 1500.",
        "",
        "| Bot | W | D | L | Errors | Points | Rating |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in report["standings"]:
        lines.append(
            f"| {row['bot']} | {row['wins']} | {row['draws']} | "
            f"{row['losses']} | {row['errors']} | {row['points']:g} | "
            f"{row['rating']:.1f} |"
        )
    lines += ["", "## Games", ""]
    for game in report["games"]:
        winner = game[game["winner_side"]] if game["winner_side"] else "draw"
        result = (
            game["error"] or f"{winner}, {game['rounds']} rounds ({game['reason']})"
        )
        lines.append(
            f"- {game['A']} (A) vs {game['B']} (B), {game['map']}: {result}. "
            f"[Log]({game['log']})"
            + (f" · [Replay]({game['replay']})" if game["replay"] else "")
        )
    lines.append("")
    summary = "\n".join(lines)
    (directory / "summary.md").write_text(summary)
    return summary
