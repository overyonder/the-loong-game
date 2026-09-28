# Summarise replays: sides, map, result and event counts, or deaths by cause with --deaths.
[group("Inspection")]
decode +replays:
    ../../build/bin/loong-gamedata decode "$@"

# Each bot's deaths by the engine's cause, over replays.
[group("Inspection")]
deaths *replays:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$#" == 0 ]]; then
        set -- results/ladder/games/*-room-c-vs-room-pearls.replay results/ladder/games/*-room-pearls-vs-room-c.replay
    fi
    just decode --deaths "$@"

# Paced, resumable public replay sample. No collection starts unless invoked.
[group("Inspection")]
sample-replays *args:
    ../../build/bin/loong-sample-replays "$@"

# Recorded observations; competitive source recovery stays private.
[private]
_viewer-export *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    from pathlib import Path

    from replays.viewer.board import board_export
    from replays.viewer.replay import read_replay

    parser = argparse.ArgumentParser(prog="viewer")
    parser.add_argument("replay", type=Path)
    parser.add_argument("--dragon", type=int)
    parser.add_argument("--round", type=int, default=0)
    parser.add_argument("--play", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--speed", type=float, default=4)
    parser.add_argument("--no-display", action="store_true")
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument(
        "--image",
        type=Path,
        help="Save PNG using the Odin viewer; requires a display/OpenGL context",
    )
    args = parser.parse_args()
    if args.image and args.image.suffix.lower() != ".png":
        parser.error("--image writes PNG; use a .png output path")
    replay = read_replay(args.replay)
    export = board_export(
        args.replay, replay["botA"] or "team A", replay["botB"] or "team B"
    )
    export.update(
        version=4,
        team="A",
        build={
            "identified": False,
            "notes": ["Recorded observations; bot state unavailable"],
        },
        dragons={},
        pings=[],
        annotation_path=str(args.replay.resolve()) + ".annotations.jsonl",
        selected_dragon=-1 if args.dragon is None else args.dragon,
        start_frame=args.round,
        start_playing=args.play,
        start_frames_per_second=args.speed,
    )
    for turn in export["turns"]:
        turn["memory_source"] = "observed"
    args.export.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.export.with_suffix(".tmp")
    temporary.write_text(json.dumps(export) + "\n")
    temporary.replace(args.export)
    print(f"wrote {args.export}")

# Build the Odin viewer, and the raygui library it links when it is missing.
[group("Build")]
viewer-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ../../build/bin ../../build/lib
    lib=$(realpath ../../build/lib)
    # raygui ships as a header only; Odin's raygui binding links a shared
    # library built from it with its implementation, against raylib.
    if [[ ! -f "$lib/libraygui.so" ]]; then
        echo '#include <raygui.h>' | cc -x c -O2 -fPIC -shared -DRAYGUI_IMPLEMENTATION - -lraylib -o "$lib/libraygui.so"
    fi
    odin build ../../replays/viewer -vet -strict-style -warnings-as-errors -debug -out:../../build/bin/viewer -extra-linker-flags:"-L$lib -Wl,-rpath,$lib"

[group("Inspection")]
viewer *args:
    #!/usr/bin/env bash
    set -euo pipefail
    for argument in "$@"; do
        case "$argument" in -h|--help) just _viewer-export "$@"; exit ;; esac
    done
    mkdir -p build/viewer
    export_path=$(mktemp "$PWD/build/viewer/export.XXXXXXXX.json")
    temporary_export="$export_path"
    display=true
    watch=false
    previous=''
    image_path=''
    for argument in "$@"; do
        if [[ "$previous" == '--export' ]]; then export_path="$argument"; fi
        if [[ "$previous" == '--image' ]]; then image_path="$argument"; fi
        case "$argument" in
            --export=*) export_path="${argument#--export=}" ;;
            --no-display|--image) display=false ;;
            --image=*) image_path="${argument#--image=}"; display=false ;;
            --watch) watch=true ;;
        esac
        previous="$argument"
    done
    trap 'if [[ "$temporary_export" != "$export_path" ]]; then rm -f "$temporary_export"; fi' EXIT
    just _viewer-export --export "$export_path" "$@"
    if [[ -n "$image_path" ]]; then
        just viewer-build
        mkdir -p "$(dirname "$image_path")"
        ../../build/bin/viewer "$export_path" --image "$image_path"
    elif "$display"; then
        just viewer-build
        if "$watch"; then ../../build/bin/viewer "$export_path" --watch; else ../../build/bin/viewer "$export_path"; fi
    fi
