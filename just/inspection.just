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

# Build the Odin viewer, and the raygui library Odin's raylib binding links when it is missing.
[group("Build")]
viewer-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ../../build/bin ../../build/lib
    lib=$(realpath ../../build/lib)
    # raygui ships as a header only; Odin's raylib binding links a shared
    # library built from it with its implementation, against raylib.
    if [[ ! -f "$lib/libraygui.so" ]]; then
        echo '#include <raygui.h>' | cc -x c -O2 -fPIC -shared -DRAYGUI_IMPLEMENTATION - -lraylib -o "$lib/libraygui.so"
    fi
    odin build ../../replays/viewer -vet -strict-style -warnings-as-errors -o:speed -out:../../build/bin/viewer -extra-linker-flags:"-L$lib -Wl,-rpath,$lib"

# Write a replay's game columns (gamedata/format.md), beside it unless OUTPUT is given.
[group("Inspection")]
gamedata replay output="":
    ../../build/bin/loong-gamedata "$1" ${2:+"$2"}

# Open a replay in the viewer. The viewer starts `loong-recover` beside itself,
# which reruns each seated side's registered build over its dragons' recorded
# observations and streams their decisions into memory.
[group("Inspection")]
viewer *args:
    #!/usr/bin/env bash
    set -euo pipefail
    usage() {
        cat <<'USAGE'
    usage: just viewer REPLAY [OPTIONS]

      --seat A|B GUID         the registered build (just bot-build) that played that
                              side; its dragons' decisions are rebuilt
      --dragon N, --round R   where the viewer opens; the dragon's decisions are rebuilt first
      --turn T                open Turns mode at that turn index, overriding --round
      --whole-board           show the whole board; a --dragon with --round or --turn
                              otherwise opens zoomed on its area
      --rounds                open in Rounds mode instead of Turns
      --play, --speed S       start playback, at S turns (or rounds) per second
      --position FILE         restore a saved position (GAME.cols.position): round,
                              dragon, zoom, selection, tab and overlays
      --game FILE             where the game columns go (default build/viewer/<stem>.<hash>.cols)
      --no-display            only write the game columns
      --image FILE, --size WxH   render one frame to a PNG (needs a display)
      --no-recovery           show only what the replay recorded
      --registry DIR          the build registry (default $LOONG_BUILD_REGISTRY or build/registry)
      --inbox FILE            where comments are appended (default build/viewer/comments.md)
      --memory-share R        the share of the viewer's and recovery's own memory
                              its checkpoints may hold (default 1)
      --memory MB             or the megabytes they may hold (0 for none)
      --buffer N              rounds rebuilt whole either side of the current one (default 5)
    USAGE
    }
    root=$(realpath ../..)
    replay=''
    game=''
    display=true
    image=''
    size=1600x960
    recover=true
    registry=${LOONG_BUILD_REGISTRY:-$root/build/registry}
    judge=${LOONG_JUDGE:-$root/build/zig-judge/bin/loong-judge}
    inbox=$root/build/viewer/comments.md
    seats=()
    recovery_arguments=()
    viewer_arguments=()
    while (($#)); do
        case "$1" in
            -h|--help) usage; exit ;;
            --seat) seats+=(--seat "$2" "$3" "$2"); shift 2 ;;
            --game) game=$2; shift ;;
            --image) image=$2; display=false; shift ;;
            --size) size=$2; shift ;;
            --registry) registry=$2; shift ;;
            --inbox) inbox=$2; shift ;;
            --memory|--memory-share) recovery_arguments+=("$1" "$2"); shift ;;
            --no-display) display=false ;;
            --no-recovery) recover=false ;;
            --dragon|--round|--turn|--speed|--buffer) viewer_arguments+=("$1" "$2"); shift ;;
            --position) viewer_arguments+=(--position "$(realpath "$2")"); shift ;;
            --play|--whole-board|--rounds) viewer_arguments+=("$1") ;;
            -*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
            *) replay=$1 ;;
        esac
        shift
    done
    [[ -f "$replay" ]] || { usage >&2; exit 2; }
    just tools-build
    just viewer-build
    if [[ -z "$game" ]]; then
        hash=$(realpath "$replay" | sha1sum | cut -c1-8)
        game="$root/build/viewer/$(basename "${replay%.replay}").$hash.cols"
    fi
    mkdir -p "$(dirname "$game")" "$(dirname "$inbox")"
    if [[ ! "$game" -nt "$replay" ]]; then "$root/build/bin/loong-gamedata" "$replay" "$game" >&2; fi
    if ! "$display" && [[ -z "$image" ]]; then echo "wrote $game"; exit; fi
    arguments=("$(realpath "$game")" --inbox "$(realpath -m "$inbox")" --replay-name "$replay" "${viewer_arguments[@]}")
    if "$recover"; then
        [[ -x "$judge" ]] || { echo "No judge at $judge: run just zig-judge-build" >&2; exit 2; }
        arguments+=(--recover "$root/build/bin/loong-recover" --replay "$(realpath "$replay")" --registry "$(realpath "$registry")" --judge "$(realpath "$judge")" "${seats[@]}" "${recovery_arguments[@]}")
    fi
    if [[ -n "$image" ]]; then
        mkdir -p "$(dirname "$image")"
        exec "$root/build/bin/viewer" "${arguments[@]}" --image "$(realpath -m "$image")" --size "$size"
    fi
    exec "$root/build/bin/viewer" "${arguments[@]}"

# Print dragons' rebuilt decisions turn by turn, as text or JSON lines.
[group("Inspection")]
decisions *args:
    #!/usr/bin/env bash
    set -euo pipefail
    usage() {
        cat <<'USAGE'
    usage: just decisions REPLAY --seat A|B GUID... (--dragon D... | --team A|B | --all) [--rounds A-B] [--json] [--state]

    Rebuilds each dragon's decisions through its side's registered build, as the
    viewer does, and prints each turn in the rounds asked for, dragon by dragon:
    the Brain's breakdown and every option it weighed with its eligibility, score
    and reason, then the other records, and what changed in memory. Each dragon's
    turns follow a line giving its build and how many rebuilt turns match the
    replay, with the first divergence. --json prints one JSON object a turn.
    --state adds the state a bot exposes from memory, as tables.
      --registry DIR          the build registry (default $LOONG_BUILD_REGISTRY or build/registry)
    USAGE
    }
    root=$(realpath ../..)
    replay=''
    options=()
    registry=${LOONG_BUILD_REGISTRY:-$root/build/registry}
    judge=${LOONG_JUDGE:-$root/build/zig-judge/bin/loong-judge}
    while (($#)); do
        case "$1" in
            -h|--help) usage; exit ;;
            --seat) options+=(--seat "$2" "$3" "$2"); shift 2 ;;
            --dragon|--rounds|--team) options+=("$1" "$2"); shift ;;
            --json|--all|--state) options+=("$1") ;;
            --registry) registry=$2; shift ;;
            -*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
            *) replay=$1 ;;
        esac
        shift
    done
    [[ -f "$replay" ]] || { usage >&2; exit 2; }
    [[ -x "$judge" ]] || { echo "No judge at $judge: run just zig-judge-build" >&2; exit 2; }
    just tools-build >&2
    hash=$(realpath "$replay" | sha1sum | cut -c1-8)
    game="$root/build/viewer/$(basename "${replay%.replay}").$hash.cols"
    mkdir -p "$(dirname "$game")"
    if [[ ! "$game" -nt "$replay" ]]; then "$root/build/bin/loong-gamedata" "$replay" "$game" >&2; fi
    exec "$root/build/bin/loong-recover" decisions --replay "$(realpath "$replay")" --game "$game" --registry "$registry" --judge "$judge" "${options[@]}"

# Fit or select a pearl-gap table from locally supplied seeded replays.
[group("Inspection")]
map-variants *args:
    ../../build/bin/loong-map-variants "$@"

# Restore a supplied replay only when its map and physical state are resolved.
[group("Inspection")]
regenerate *args:
    ../../build/bin/loong-regenerate "$@"

# Profile one seeded game in judge CPU points, beside its replay.
[group("Profiling")]
points-profile a b map seed replay:
    #!/usr/bin/env bash
    set -euo pipefail
    engine=$({{quote(python)}} -c 'from unswbc.engine import WASM_PATH; print(WASM_PATH)')
    exec nice -n 19 ../../build/zig-judge/bin/loong-judge --engine "$engine" --timeout 300 run --sandbox --profile --seed "$4" -o "$5" "$3" "$1" "$2"

# Read a registered build's compiler remarks, optionally beside its hot functions.
[group("Profiling")]
vector-remarks guid profile="" team="A" top="25":
    #!/usr/bin/env bash
    set -euo pipefail
    registry=${LOONG_BUILD_REGISTRY:-$(realpath ../../build/registry)}
    remarks="$registry/$1/judge.remarks.tsv"
    [[ -f "$remarks" ]] || { echo 'Build has no remarks: run just bot-build for its source' >&2; exit 2; }
    if [[ -z "$2" ]]; then cat "$remarks"; else ../../build/bin/loong-profile join "$remarks" "$2" "$3" "$4"; fi
