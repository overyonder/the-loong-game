"""The pinned competition toolkit as every runner uses it, with its park race closed.

In unswbc 1.1 and 1.2, `SandboxBot._write` reads the guest's stdin park count and then
feeds the turn. A dragon's fresh sandbox is not frozen between turns, so when its
guest reaches its first read between those two steps the turn counts as parked: the
reply is empty and the dragon dies of "no valid action" with no error line. Busy
workers lost a freshly split child this way in 2 of 384 games. Doing both steps
under the pipe's lock closes the window.

Run matches with `toolkit_match_command() + ["run", ...]` instead of
`unswbc run ...`, and take sandbox classes from `repaired_toolkit_sandbox()`.
"""

import shutil
import sys
from pathlib import Path

# 1.2.2 carries the same `SandboxBot._write`, so the repair covers the 1.2 series.
REPAIRED_TOOLKIT_SERIES = ("1.1.", "1.2.")


def toolkit_interpreter() -> Path:
    """The Python that `uv tool install` gave the `unswbc` launcher."""
    launcher = shutil.which("unswbc")
    if launcher is None:
        raise FileNotFoundError(
            "unswbc is not on PATH: install the organiser's toolkit"
        )
    shebang = Path(launcher).read_bytes().split(b"\n", 1)[0]
    interpreter = Path(shebang.removeprefix(b"#!").decode().strip())
    if not shebang.startswith(b"#!") or not interpreter.name.startswith("python"):
        raise RuntimeError(f"{launcher} does not name its Python interpreter")
    return interpreter


def toolkit_match_command() -> list[str]:
    """Replaces the `unswbc` executable in a match command."""
    # -P keeps harness/ off sys.path, where its modules could shadow others.
    return [str(toolkit_interpreter()), "-P", str(Path(__file__).resolve())]


def write_turn_without_park_race(self, data: bytes) -> bool:
    if self._stdout.closed:
        return False
    self._box.budget = sandbox_module().MAX_TURN_POINTS
    with self._stdin.cv:
        self._parks = self._stdin.parks
        self._stdin.feed(data)
    self._box.frozen.set()
    return True


def sandbox_module():
    try:
        from unswbc import sandbox
    except ModuleNotFoundError:
        # Runners outside the toolkit's own Python borrow its packages.
        interpreter = toolkit_interpreter()
        sys.path.append(
            str(next(interpreter.parent.parent.glob("lib/python*/site-packages")))
        )
        from unswbc import sandbox
    return sandbox


def repaired_toolkit_sandbox():
    """`unswbc.sandbox` with the park race closed; take sandbox classes from here."""
    from importlib import metadata

    sandbox = sandbox_module()
    if sandbox.SandboxBot._write is not write_turn_without_park_race:
        version = metadata.version("unswbc")
        if not version.startswith(REPAIRED_TOOLKIT_SERIES):
            raise RuntimeError(
                f"unswbc {version} is outside {REPAIRED_TOOLKIT_SERIES}: check whether "
                "SandboxBot._write still races the guest's first read, then update "
                "harness/toolkit.py"
            )
        sandbox.SandboxBot._write = write_turn_without_park_race
    return sandbox


if __name__ == "__main__":
    repaired_toolkit_sandbox()
    from unswbc import cli

    sys.exit(cli.main(sys.argv[1:]))
