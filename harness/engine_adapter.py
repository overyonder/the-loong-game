"""Thin pipe adapter to the organiser's Python-only engine API."""

import hashlib
import sys
from importlib.metadata import version
from pathlib import Path

from unswbc.engine import WASM_PATH, EngineModule

if sys.argv[1:] == ["--path"]:
    print(WASM_PATH)
else:
    map_path, seed, output, engine_path = sys.argv[1:]
    incoming = sys.stdin.buffer
    outgoing = sys.stdout.buffer

    def reply(dragon, block):
        outgoing.write(f"TURN {dragon} {len(block)}\n".encode())
        outgoing.write(block)
        outgoing.flush()
        length = int(incoming.readline())
        data = incoming.read(length)
        if len(data) != length:
            raise EOFError("reply pipe closed")
        return data

    # Older SDKs allocate only 32 bytes for results. Never feed one an
    # unverified replacement engine that may write the newer 48-byte result.
    sdk_version = tuple(int(part) for part in version("unswbc").split(".")[:3])
    if (
        sdk_version < (1, 2, 3)
        and hashlib.sha256(Path(engine_path).read_bytes()).digest()
        != hashlib.sha256(WASM_PATH.read_bytes()).digest()
    ):
        raise ValueError("Install unswbc >= 1.2.3 before selecting a different engine")
    engine = EngineModule(Path(engine_path))
    engine.run(Path(map_path).read_bytes(), reply, debug=0, seed=int(seed))
    Path(output).write_bytes(engine.replay("A", "B"))
    outgoing.write(b"DONE\n")
    outgoing.flush()
