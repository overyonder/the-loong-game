"""Thin adapter to the toolkit's WASM clang, with compiled sidecar decoding."""

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def compile_with_sidecars(source: Path, output: Path) -> Path:
    from unswbc import clangtool

    decoder = ROOT / "build/bin/loong-profile"
    if not decoder.is_file():
        raise FileNotFoundError("Run just tools-build before just bot-build")
    units = clangtool.sources(source)
    if not units:
        raise clangtool.BuildError(f"{source}: no C or C++ units")
    home = clangtool.toolchain()
    with tempfile.TemporaryDirectory(prefix="loong-compiler-") as temporary:
        work = Path(temporary)
        (work / "out").mkdir()
        (work / "tmp").mkdir()
        mounts = {"/src": source, "/out": work / "out", "/tmp": work / "tmp"}
        objects = []
        records = []
        for index, unit in enumerate(units):
            name = f"/tmp/{index}.o"
            record = work / "tmp" / f"{index}.yaml"
            language = (
                ["-xc", "-std=c17"]
                if unit.suffix == clangtool.C_SUFFIX
                else ["-xc++", "-std=c++20", "-stdlib=libc++"]
            )
            clangtool._step(
                home / "clang.wasm",
                home,
                [
                    "/bin/clang-20",
                    *clangtool.DRIVER_FLAGS,
                    "-fsave-optimization-record=yaml",
                    "-foptimization-record-passes=loop-vectorize|slp-vectorizer",
                    f"-foptimization-record-file=/tmp/{index}.yaml",
                    "-c",
                    "-o",
                    name,
                    *language,
                    unit.as_posix(),
                ],
                mounts,
                f"compiling {unit}",
            )
            objects.append(name)
            records.append(record)
        libraries = (
            ["-lc++", "-lc++abi"]
            if any(unit.suffix in clangtool.CXX_SUFFIXES for unit in units)
            else []
        )
        for name, flags in (
            ("bot.wasm", clangtool.LINK_FLAGS),
            (
                "named.wasm",
                [flag for flag in clangtool.LINK_FLAGS if flag != "--strip-all"],
            ),
        ):
            clangtool._step(
                home / "root/bin/wasm-ld",
                home,
                [
                    "/bin/wasm-ld",
                    *flags,
                    *libraries,
                    *objects,
                    *clangtool.LINK_TAIL[:-1],
                    f"/out/{name}",
                ],
                mounts,
                "linking",
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(work / "out/bot.wasm", output)
        subprocess.run(
            [
                str(decoder),
                "names",
                str(work / "out/named.wasm"),
                str(output.with_suffix(".names")),
            ],
            check=True,
        )
        subprocess.run(
            [
                str(decoder),
                "remarks",
                str(output.with_suffix(".remarks.tsv")),
                *map(str, records),
            ],
            check=True,
        )
    return output
