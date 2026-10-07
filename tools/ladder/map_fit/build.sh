#!/usr/bin/env bash
# Builds build/bin/loong-map-fit, which map_variants.nim runs. Run from the
# repository root inside `nix develop`.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
mkdir -p "$root/build/bin"
"${CXX:-clang++}" -std=c++20 -O3 -Wall -Wextra -Werror \
  "$root/tools/ladder/map_fit/map_fit.cc" -o "$root/build/bin/loong-map-fit"
