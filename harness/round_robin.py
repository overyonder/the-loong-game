"""Play every pair of bots on every map, both sides, in parallel through `unswbc run`.

    python3 -m harness.round_robin --bots alpha bravo charlie --maps maps/*.map \\
        --seeds 2 --output results/first-round-robin

Each game runs in its own process group with a wall-clock timeout, so a hung
game is killed with every dragon it started. Its full output is kept as a log.
Execution errors (crashes, timeouts, dragons that ran out of time) are counted
apart from losses, and every game records its seed so it can be replayed.
"""

import argparse
import hashlib
import itertools
import json
import os
import re
import signal
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from pathlib import Path

GAME_RESULT = re.compile(r"^(?:team (?P<winner>[AB]) wins|draw) after (?P<rounds>\d+) rounds", re.M)
GAME_SEED = re.compile(r"^seed (?P<seed>0x[0-9a-f]+)", re.M)
# The toolkit prints a bot's execution error on the same kind of line as its deaths.
BOT_EXECUTION_ERROR = re.compile(r"^round \d+: bot \d+ \(team (?P<team>[AB])\) (?!died:|stdout:|stderr:|points )(?P<error>.+)$", re.M)


@dataclass
class ScheduledGame:
    team_a_bot: str
    team_b_bot: str
    map_path:   str
    seed:       str   # hex, passed to `unswbc run --seed`


@dataclass
class PlayedGame:
    team_a_bot: str
    team_b_bot: str
    map_path:   str
    seed:       str
    winner:     str | None   # "A", "B", or None for a draw or an error
    rounds:     int | None
    error:      str | None   # set when the game can't count as a win, draw or loss
    seconds:    float        # wall-clock time for the whole game
    log_path:   str


def seed_for_game(base_seed: str, team_a_bot: str, team_b_bot: str, map_path: str, repeat: int) -> str:
    """A fixed seed per game, so rerunning the same schedule plays the same games.

    Both side orders of a pairing share the seed, so each bot gets the same map
    and pearl schedule from each side."""
    pairing = "/".join(sorted((team_a_bot, team_b_bot)))
    digest = hashlib.sha256(f"{base_seed}/{pairing}/{map_path}/{repeat}".encode()).digest()
    return "0x" + digest[:8].hex()


def schedule_round_robin(bots: list[str], maps: list[str], seeds_per_pairing: int, base_seed: str) -> list[ScheduledGame]:
    schedule = []
    for first_bot, second_bot in itertools.combinations(bots, 2):
        for team_a_bot, team_b_bot in ((first_bot, second_bot), (second_bot, first_bot)):
            for map_path in maps:
                for repeat in range(seeds_per_pairing):
                    seed = seed_for_game(base_seed, team_a_bot, team_b_bot, map_path, repeat)
                    schedule.append(ScheduledGame(team_a_bot, team_b_bot, map_path, seed))
    return schedule


def build_each_bot_once(bots: list[str], map_path: str) -> None:
    """Compile every bot before the parallel games start, since concurrent first builds of one bot can collide."""
    for bot in bots:
        subprocess.run(["unswbc", "run", "--no-replay", "--seed", "0x0", map_path, bot, bot],
                       check=True, capture_output=True)


def play_game(game: ScheduledGame, output_directory: Path, timeout_seconds: float) -> PlayedGame:
    name = f"{game.team_a_bot}-vs-{game.team_b_bot}-on-{Path(game.map_path).stem}-{game.seed}"
    log_path = output_directory / "logs" / f"{name}.log"
    replay_path = output_directory / "replays" / f"{name}.replay"
    command = ["unswbc", "run", "--sandbox", "--seed", game.seed, "--replay", str(replay_path),
               game.map_path, game.team_a_bot, game.team_b_bot]
    timed_out = False
    started = time.monotonic()
    with log_path.open("w") as log:
        # A new session puts the match and every dragon process in one group we can kill together.
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env={**os.environ, "NO_COLOR": "1"}, start_new_session=True)
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    seconds = time.monotonic() - started
    text = log_path.read_text(errors="replace")
    result = GAME_RESULT.search(text)
    execution_error = BOT_EXECUTION_ERROR.search(text)
    error = None
    if timed_out:
        error = f"timed out after {timeout_seconds:.0f} s"
    elif process.returncode:
        error = f"unswbc exited with code {process.returncode}"
    elif execution_error:
        error = f"team {execution_error['team']}: {execution_error['error']}"
    elif result is None:
        error = "no result in the log"
    return PlayedGame(game.team_a_bot, game.team_b_bot, game.map_path, game.seed,
                      None if error or result is None else result["winner"],
                      None if result is None else int(result["rounds"]), error, seconds, str(log_path))


def summarise_standings(bots: list[str], games: list[PlayedGame]) -> list[dict]:
    standings = {bot: {"bot": bot, "wins": 0, "draws": 0, "losses": 0, "errors": 0} for bot in bots}
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
    return sorted(standings.values(), key=lambda row: (-(row["wins"] + row["draws"] / 2), row["bot"]))


def run_games_in_parallel(schedule: list[ScheduledGame], output_directory: Path, workers: int, timeout_seconds: float) -> list[PlayedGame]:
    (output_directory / "logs").mkdir(parents=True, exist_ok=True)
    (output_directory / "replays").mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        return list(executor.map(lambda game: play_game(game, output_directory, timeout_seconds), schedule))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bots", nargs="+", required=True)
    parser.add_argument("--maps", nargs="+", required=True)
    parser.add_argument("--seeds", type=int, default=1, help="games per map and side for each pairing")
    parser.add_argument("--base-seed", default="loong")
    parser.add_argument("--workers", type=int, default=os.cpu_count())
    parser.add_argument("--timeout", type=float, default=600, help="seconds before a game is killed")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    schedule = schedule_round_robin(arguments.bots, arguments.maps, arguments.seeds, arguments.base_seed)
    build_each_bot_once(arguments.bots, min(arguments.maps, key=lambda path: Path(path).stat().st_size))
    games = run_games_in_parallel(schedule, arguments.output, arguments.workers, arguments.timeout)
    standings = summarise_standings(arguments.bots, games)
    (arguments.output / "games.json").write_text(json.dumps([asdict(game) for game in games], indent=2) + "\n")
    print(f"{'bot':<16}{'wins':>6}{'draws':>7}{'losses':>8}{'errors':>8}")
    for row in standings:
        print(f"{row['bot']:<16}{row['wins']:>6}{row['draws']:>7}{row['losses']:>8}{row['errors']:>8}")
    print(f"{len(games)} games, {sum(game.seconds for game in games) / 60:.1f} minutes of games")
    for game in games:
        if game.error:
            print(f"error: {game.team_a_bot} vs {game.team_b_bot} on {game.map_path} seed {game.seed}: {game.error}")


if __name__ == "__main__":
    main()
