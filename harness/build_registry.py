"""Immutable local builds, addressed by GUID, for the viewer's recovery.

`just bot-build` compiles a bot directory with the judge's clang and registers
the result as `build/registry/GUID/`: a snapshot of the sources the judge
compiled under `source/`, the compiled `judge.wasm`, and `manifest.json` with
every file's SHA-256. The viewer's recovery (replays/recovery/registry.nim)
checks those hashes before it reruns the build, and never rebuilds from the
current source.

A build's GUID hashes its source snapshot and `build_settings`: the organiser's
compiler flags and the hash of its compiler driver. Registering the same
sources again finds the same GUID.
"""

import hashlib
import json
import os
import shutil
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = Path(os.environ.get("LOONG_BUILD_REGISTRY", ROOT / "build/registry"))

SOURCE_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".cxx", ".c++", ".hpp", ".hh", ".inc"}


def snapshot_sources(source: Path, destination: Path) -> dict:
    """Copy the files the judge compiles into `destination/source/`, by hash."""
    files = {}
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        target = destination / "source" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_bytes()
        target.write_bytes(data)
        files[f"source/{relative.as_posix()}"] = hashlib.sha256(data).hexdigest()
    return files


def build_settings() -> dict:
    """Everything besides the sources that decides what a build compiles to."""
    from unswbc import clangtool

    return {
        "contract": 1,
        # Every judge build is inspected by rerunning it with the LOONG_INSPECT
        # marker, which switches on the diagnostics a bot compiled in
        # (runtime/gizmos.h). A bot without them shows the replay alone.
        "diagnostics": "runtime",
        "driver_flags": clangtool.DRIVER_FLAGS,
        "clangtool_sha256": hashlib.sha256(
            Path(clangtool.__file__).read_bytes()
        ).hexdigest(),
    }


def build_identity(files: dict, settings: dict) -> str:
    """The GUID, as registry.nim's `buildIdentity` recomputes it."""
    digest = hashlib.sha256(
        json.dumps([files, settings], sort_keys=True).encode()
    ).hexdigest()
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "loong-build-v1:" + digest))


def register(source: Path, wasm: Path, registry: Path = REGISTRY) -> tuple[str, Path]:
    """Register `wasm`, the judge's build of `source`; returns its GUID and
    the registered copy. A GUID already registered is kept as it is."""
    registry.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pending-", dir=registry) as temporary:
        pending = Path(temporary) / "build"
        files = snapshot_sources(source, pending)
        settings = build_settings()
        guid = build_identity(files, settings)
        destination = registry / guid
        if not destination.exists():
            shutil.copyfile(wasm, pending / "judge.wasm")
            artifacts = {
                "judge": hashlib.sha256(
                    (pending / "judge.wasm").read_bytes()
                ).hexdigest()
            }
            manifest = {
                "version": 1,
                "guid": guid,
                "files": files,
                "settings": settings,
                "artifacts": artifacts,
            }
            (pending / "manifest.json").write_text(
                json.dumps(manifest, indent=2) + "\n"
            )
            try:
                pending.rename(destination)
            except OSError:
                # Another process registered the same build first.
                if not destination.exists():
                    raise
    resolve_build(registry, guid)
    return guid, destination / "judge.wasm"


def resolve_build(registry: Path, guid: str) -> tuple[Path, dict]:
    """The build's directory and manifest, checked against every recorded hash."""
    if str(uuid.UUID(guid)) != guid:
        raise ValueError("Noncanonical build GUID")
    directory = registry / guid
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["version"] != 1 or manifest["guid"] != guid:
        raise ValueError("Build manifest identity/version mismatch")
    if build_identity(manifest["files"], manifest["settings"]) != guid:
        raise ValueError("Build manifest content identity mismatch")
    expected = dict(manifest["files"])
    expected.update(
        {f"{variant}.wasm": digest for variant, digest in manifest["artifacts"].items()}
    )
    for name, digest in expected.items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Build snapshot hash mismatch: {name}")
    return directory, manifest
