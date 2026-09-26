# Summarise recorded replay events, deaths or reconstructed observations.
[group("Inspection")]
decode *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    from pathlib import Path

    from src.viewer.inspection import inspect_replays

    parser = argparse.ArgumentParser(prog="decode")
    parser.add_argument("replays", nargs="+", type=Path)
    parser.add_argument("--deaths", action="store_true")
    parser.add_argument("--observations", action="store_true")
    args = parser.parse_args()
    inspect_replays(args.replays, deaths=args.deaths, observations=args.observations)

# Death causes from the viewer's canonical replay decoder.
[group("Inspection")]
deaths *replays:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$#" == 0 ]]; then
        set -- results/ladder/replays/*room-c-vs-room-pearls* results/ladder/replays/*room-pearls-vs-room-c*
    fi
    just decode --deaths "$@"

# Paced, resumable public replay sample. No collection starts unless invoked.
[group("Inspection")]
sample-replays *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import math
    from pathlib import Path

    from src.replays.collection import collect_public_replays

    parser = argparse.ArgumentParser(prog="sample-replays")
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--all", action="store_true", help="Collect the full archive")
    parser.add_argument("--output", type=Path, default=Path("public-replays"))
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--battles", nargs="+", type=int)
    parser.add_argument("--teams", nargs="+", type=int)
    parser.add_argument("--max-games", type=int, help="Maximum games per battle")
    parser.add_argument("--replays", type=Path)
    args = parser.parse_args()
    if args.count < 1 or not math.isfinite(args.interval) or args.interval < 0.2:
        parser.error(
            "Require a positive count and a finite interval of at least 0.2 seconds"
        )
    status = collect_public_replays(
        args.output,
        args.interval,
        args.battles,
        args.max_games,
        args.teams,
        args.replays,
        total_games=None if args.all else args.count,
    )
    raise SystemExit(
        0
        if status
        in ("completed_sample", "completed_discovered_snapshot", "completed_targeted_batch")
        else 2
    )

# Recorded observations; competitive source recovery stays private.
[private]
_viewer-export *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    from pathlib import Path

    from src.viewer.board import board_export
    from src.viewer.replay import read_replay

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

[group("Build")]
viewer-build:
    mkdir -p ../../build/bin
    odin build ../../src/viewer -vet -strict-style -warnings-as-errors -debug -out:../../build/bin/viewer

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
