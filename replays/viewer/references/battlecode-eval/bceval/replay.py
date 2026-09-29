"""Read an unswbc engine replay (gzip + packed Cap'n Proto)."""
import gzip
import os

import capnp

capnp.remove_import_hook()
SCHEMA = capnp.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "replay.capnp"))


def load(path):
    """The Replay message of a .replay file."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return SCHEMA.Replay.from_bytes_packed(raw, traversal_limit_in_words=1 << 30)
