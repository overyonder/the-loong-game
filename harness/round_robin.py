"""Play every pair of bots on every map, both sides, in parallel through `unswbc run`.

    just round-robin --bots alpha bravo charlie --maps maps/*.map \\
        --seeds 2 --output results/first-round-robin

Each game runs in its own process group with a wall-clock timeout, so a hung
game is killed with every dragon it started. Its full output is kept as a log.
Execution errors (crashes, timeouts, dragons that ran out of time) are counted
apart from losses, and every game records its seed so it can be replayed.
"""

import hashlib
import itertools
import json
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

GAME_RESULT = re.compile(
    r"^(?:team (?P<winner>[AB]) wins|draw) after (?P<rounds>\d+) rounds", re.MULTILINE
)
GAME_SEED = re.compile(r"^seed (?P<seed>0x[0-9a-f]+)", re.MULTILINE)
# The toolkit prints a bot's execution error on the same kind of line as its deaths.
BOT_EXECUTION_ERROR = re.compile(
    r"^round \d+: bot \d+ \(team (?P<team>[AB])\) (?!died:|stdout:|stderr:|points )(?P<error>.+)$",
    re.MULTILINE,
)


@dataclass
class ScheduledGame:
    team_a_bot: str
    team_b_bot: str
    map_path: str
    seed: str  # hex, passed to `unswbc run --seed`


@dataclass
class PlayedGame:
    team_a_bot: str
    team_b_bot: str
    map_path: str
    seed: str
    winner: str | None  # "A", "B", or None for a draw or an error
    rounds: int | None
    error: str | None  # set when the game can't count as a win, draw or loss
    seconds: float  # wall-clock time for the whole game
    log_path: str


def seed_for_game(
    base_seed: str, team_a_bot: str, team_b_bot: str, map_path: str, repeat: int
) -> str:
    """A fixed seed per game, so rerunning the same schedule plays the same games.

    Both side orders of a pairing share the seed, so each bot gets the same map
    and pearl schedule from each side."""
    pairing = "/".join(sorted((team_a_bot, team_b_bot)))
    digest = hashlib.sha256(
        f"{base_seed}/{pairing}/{map_path}/{repeat}".encode()
    ).digest()
    return "0x" + digest[:8].hex()


def schedule_round_robin(
    bots: list[str], maps: list[str], seeds_per_pairing: int, base_seed: str
) -> list[ScheduledGame]:
    schedule = []
    for first_bot, second_bot in itertools.combinations(bots, 2):
        for team_a_bot, team_b_bot in (
            (first_bot, second_bot),
            (second_bot, first_bot),
        ):
            for map_path in maps:
                for repeat in range(seeds_per_pairing):
                    seed = seed_for_game(
                        base_seed, team_a_bot, team_b_bot, map_path, repeat
                    )
                    schedule.append(
                        ScheduledGame(team_a_bot, team_b_bot, map_path, seed)
                    )
    return schedule


def play_game(
    game: ScheduledGame,
    output_directory: Path,
    timeout_seconds: float,
    verbose: bool = False,
) -> PlayedGame:
    name = f"{game.team_a_bot}-vs-{game.team_b_bot}-on-{Path(game.map_path).stem}-{game.seed}"
    log_path = output_directory / "logs" / f"{name}.log"
    replay_path = output_directory / "replays" / f"{name}.replay"
    # Verbose logs keep every dragon's output, including the indicator naming its behaviour.
    command = [
        "unswbc",
        "run",
        "--sandbox",
        *(["-v"] if verbose else []),
        "--seed",
        game.seed,
        "--replay",
        str(replay_path),
        game.map_path,
        game.team_a_bot,
        game.team_b_bot,
    ]
    timed_out = False
    started = time.monotonic()
    completed = subprocess.run(
        [
            "just",
            "--quiet",
            "_match",
            str(log_path.resolve()),
            str(timeout_seconds),
            *command,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    returncode, timed_out = json.loads(completed.stdout)
    seconds = time.monotonic() - started
    text = log_path.read_text(errors="replace")
    result = GAME_RESULT.search(text)
    execution_error = BOT_EXECUTION_ERROR.search(text)
    error = None
    if timed_out:
        error = f"timed out after {timeout_seconds:.0f} s"
    elif returncode:
        error = f"unswbc exited with code {returncode}"
    elif execution_error:
        error = f"team {execution_error['team']}: {execution_error['error']}"
    elif result is None:
        error = "no result in the log"
    return PlayedGame(
        game.team_a_bot,
        game.team_b_bot,
        game.map_path,
        game.seed,
        None if error or result is None else result["winner"],
        None if result is None else int(result["rounds"]),
        error,
        seconds,
        str(log_path),
    )


def summarise_standings(bots: list[str], games: list[PlayedGame]) -> list[dict]:
    standings = {
        bot: {"bot": bot, "wins": 0, "draws": 0, "losses": 0, "errors": 0}
        for bot in bots
    }
    for game in games:
        for side, bot in (("A", game.team_a_bot), ("B", game.team_b_bot)):
            row = standings[bot]
            if game.error:
                row["errors"] += 1
            elif game.winner is None:
                row["draws"] += 1
            elif game.winner == side:
                row["wins"] += 1
            else:
                row["losses"] += 1
    return sorted(
        standings.values(),
        key=lambda row: (-(row["wins"] + row["draws"] / 2), row["bot"]),
    )


def run_games_in_parallel(
    schedule: list[ScheduledGame],
    output_directory: Path,
    workers: int,
    timeout_seconds: float,
    verbose: bool = False,
) -> list[PlayedGame]:
    (output_directory / "logs").mkdir(parents=True, exist_ok=True)
    (output_directory / "replays").mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        return list(
            executor.map(
                lambda game: play_game(
                    game, output_directory, timeout_seconds, verbose
                ),
                schedule,
            )
        )
