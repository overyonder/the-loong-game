"""Decode the official viewer's packed Cap'n Proto replay format (versions 0–2)."""

import gzip
from pathlib import Path

import capnp

SCHEMA = capnp.load(str(Path(__file__).with_name("replay.capnp")))

# A `dragonDeath` event's `reason` is a bare UInt16. These codes were read off
# the engine by pairing every death event with the cause the toolkit's game log
# names for the same dragon in the same round: 3,096,412 deaths over 12,308 local
# games, all matched, with no code outside this set. See README.md.
DEATH_REASONS = {
    0: "hit a wall",
    1: "hit itself",
    2: "hit another dragon",
    3: "lost a head-to-head",
    4: "no valid action",
}
# The same causes as identifier fragments, for metric and column names.
DEATH_REASON_SLUGS = {
    0: "wall",
    1: "self",
    2: "body",
    3: "headon",
    4: "no_action",
}


def death_reason(code: int) -> str:
    """The engine's own wording for a death reason code."""
    return DEATH_REASONS.get(code, f"unknown reason {code}")


def death_reason_slug(code: int) -> str:
    """A death reason code as an identifier fragment."""
    return DEATH_REASON_SLUGS.get(code, f"reason_{code}")


def read_replay(path: Path) -> dict:
    raw = path.read_bytes()
    packed = gzip.decompress(raw) if raw.startswith(b"\x1f\x8b") else raw
    reader = SCHEMA.Replay.from_bytes_packed(
        packed, traversal_limit_in_words=128 * 1024 * 1024
    )
    if reader.formatVersion > 2:
        raise ValueError(f"Unsupported replay format {reader.formatVersion}")
    result = {
        "map": reader.map,
        "botA": reader.botA,
        "botB": reader.botB,
        "formatVersion": reader.formatVersion,
        "result": reader.result.to_dict(),
    }
    result["events"] = [
        dict(type=event.which(), **getattr(event, event.which()).to_dict())
        for event in reader.events
    ]
    return result
