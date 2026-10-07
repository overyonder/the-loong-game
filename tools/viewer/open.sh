#!/usr/bin/env bash
# Convert a replay, then display it with optional registered decision recovery.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
replay=$(realpath "${1:?usage: open.sh REPLAY [VIEWER_OPTIONS]}")
shift
"$root/build/bin/loong-gamedata" "$replay"
game="${replay%.*}.cols"
arguments=("$game" --replay "$replay")
if [[ " $* " == *" --seat "* || " $* " == *" --build "* ]]; then
    arguments+=(--recover "$root/build/bin/loong-recover" --registry "${LOONG_BUILD_REGISTRY:-$root/assets/registry}" --judge "$root/build/zig-judge/bin/loong-judge")
fi
mkdir -p "$root/assets/review/viewer"
printf '%s\0' "${arguments[@]}" "$@" > "$root/assets/review/viewer/last.args"
exec "$root/build/bin/viewer" "${arguments[@]}" "$@"
