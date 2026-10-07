import "tools/commands/build.just"
set positional-arguments
export LOONG_STORAGE_ROOT := env("LOONG_STORAGE_ROOT", justfile_directory() / "assets")
export LOONG_BUILD_REGISTRY := env("LOONG_BUILD_REGISTRY", justfile_directory() / "assets/registry")

default:
    @just --list

build-dir:
    mkdir -p build/bin build/tmp

toolkit_version := "1.2.9"
toolkit_wheel_sha256 := "0f80169067a62a2ca3d082780320bfc67f9d63f17e0c1c12b6e50ead7bad65a0"
# The engine the judge plays, which 1.2.7 to 1.2.9 ship byte for byte.
toolkit_engine_sha256 := "26e68680e45eb0f221db702aead9eefde776c2ad2ba066f4ddf8c12500c6a546"
# The metering the judge reimplements, which 1.2.7 to 1.2.9 ship byte for byte.
toolkit_metering_sha256 := "175193a973585d2e10d920b1d0b97c9d4f1577b4050829564be45a6e16fbee8d"
toolkit_sandbox_sha256 := "a318cb556a2b8419e2bf246dbed68a718eb8d6ff24b7189aad3929d169b262fe"
toolkit_python_metered_sha256 := "48342178e7ca73775b90aacd0899efed906d79bff79b961360aefe76b5f78125"

# Unpack the pinned toolkit's engine, judge clang and metering files into
# build/toolkit/unswbc, checking each pinned hash, and link wasmer, which runs
# the judge clang, beside them.
[group('Setup')]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    version={{quote(toolkit_version)}}
    # Refuse while the pin is behind the latest unswbc on PyPI; only warn when
    # PyPI can't be reached.
    if latest=$(curl -fsS --max-time 10 https://pypi.org/pypi/unswbc/json | jq -er .info.version); then
        if [[ "$(printf '%s\n%s\n' "$version" "$latest" | sort -V | tail -1)" != "$version" ]]; then
            echo "unswbc $latest is out and the shared pin is $version: review its metering diff against tools/judge and pass the training-engine lockstep gate, then update toolkit_version and its hashes in the justfile" >&2
            exit 1
        fi
    else
        echo "warning: can't check the latest unswbc on PyPI" >&2
    fi
    mkdir -p build/toolkit
    wheel="build/toolkit/unswbc-$version-py3-none-any.whl"
    if ! echo {{quote(toolkit_wheel_sha256)}}"  $wheel" | sha256sum --check --status 2>/dev/null; then
        url=$(curl -fsS --max-time 30 "https://pypi.org/pypi/unswbc/$version/json" | jq -er '.urls[] | select(.packagetype == "bdist_wheel") | .url')
        partial=$(mktemp "$wheel.XXXXXXXX")  # one a run, so concurrent setups can't mix their downloads
        curl -fsSL --max-time 600 -o "$partial" "$url"
        echo {{quote(toolkit_wheel_sha256)}}"  $partial" | sha256sum --check --status || { rm -f "$partial"; echo "the downloaded wheel's SHA-256 isn't the pinned one" >&2; exit 1; }
        mv "$partial" "$wheel"
    fi
    unzip=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#unzip)/bin/unzip
    unpacked=$(mktemp -d build/toolkit/.unpacking-XXXXXXXX)
    trap 'rm -rf "$unpacked"' EXIT
    "$unzip" -q "$wheel" 'unswbc/unswbc_engine.wasm' 'unswbc/clang/*' 'unswbc/metering.py' 'unswbc/sandbox.py' 'unswbc/python-metered.wasm' -d "$unpacked"
    printf '%s  %s\n' {{quote(toolkit_engine_sha256)}} "$unpacked/unswbc/unswbc_engine.wasm" {{quote(toolkit_metering_sha256)}} "$unpacked/unswbc/metering.py" {{quote(toolkit_sandbox_sha256)}} "$unpacked/unswbc/sandbox.py" {{quote(toolkit_python_metered_sha256)}} "$unpacked/unswbc/python-metered.wasm" | sha256sum --check --quiet || { echo "the wheel's engine or metering isn't the pinned one: review its metering diff against tools/judge" >&2; exit 1; }
    echo "$version" > "$unpacked/unswbc/version"
    rm -rf build/toolkit/unswbc
    mv "$unpacked/unswbc" build/toolkit/unswbc
    nix build --out-link build/toolkit/wasmer --inputs-from . nixpkgs#wasmer

tools-build: build-dir
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/zigcc
    printf '#!/usr/bin/env bash\nexec zig cc -target x86_64-linux-gnu.2.28 "$@"\n' > build/zigcc/zigcc
    chmod +x build/zigcc/zigcc
    zlib=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#zlib.static)
    ssl=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#openssl.out)
    sqlite=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#sqlite.out)
    nim c -d:release --hints:off --cc:clang --clang.exe="$PWD/build/zigcc/zigcc" --clang.linkerexe="$PWD/build/zigcc/zigcc" --passL:"$zlib/lib/libz.a" --nimcache:build/nimcache/gamedata -o:build/bin/loong-gamedata.partial tools/gamedata/gamedata.nim
    mv -f build/bin/loong-gamedata.partial build/bin/loong-gamedata
    nim c -d:release --hints:off --cc:clang --clang.exe="$PWD/build/zigcc/zigcc" --clang.linkerexe="$PWD/build/zigcc/zigcc" --nimcache:build/nimcache/build-stage -o:build/bin/loong-build.partial tools/evaluation/bot_build/bot_build.nim
    mv -f build/bin/loong-build.partial build/bin/loong-build
    nim c -d:release -d:ssl --hints:off --passL:"$zlib/lib/libz.a" --passL:-L$ssl/lib --passL:-Wl,-rpath,$ssl/lib --passL:-L$sqlite/lib --passL:-Wl,-rpath,$sqlite/lib --nimcache:build/nimcache/tournament -o:build/bin/loong-tournament.partial tools/evaluation/tournament_cli.nim
    mv -f build/bin/loong-tournament.partial build/bin/loong-tournament
    nim c -d:release --hints:off --nimcache:build/nimcache/mapgen -o:build/bin/loong-mapgen.partial tools/evaluation/mapgen/mapgen.nim
    mv -f build/bin/loong-mapgen.partial build/bin/loong-mapgen
    nim c -d:release --hints:off --passL:"$zlib/lib/libz.a" --nimcache:build/nimcache/report -o:build/bin/loong-report.partial tools/evaluation/report/report.nim
    mv -f build/bin/loong-report.partial build/bin/loong-report
    nim c -d:release -d:ssl --hints:off --passL:"$zlib/lib/libz.a" --passL:-L$ssl/lib --passL:-Wl,-rpath,$ssl/lib --passL:-L$sqlite/lib --passL:-Wl,-rpath,$sqlite/lib --nimcache:build/nimcache/map-variants -o:build/bin/loong-map-variants.partial tools/ladder/map_variants.nim
    mv -f build/bin/loong-map-variants.partial build/bin/loong-map-variants
    nim c -d:release -d:ssl --hints:off --passL:-L$ssl/lib --passL:-Wl,-rpath,$ssl/lib --passL:-L$sqlite/lib --passL:-Wl,-rpath,$sqlite/lib --nimcache:build/nimcache/sample-replays -o:build/bin/loong-sample-replays.partial tools/ladder/collector/collection.nim
    mv -f build/bin/loong-sample-replays.partial build/bin/loong-sample-replays
    nim c -d:release --hints:off --passL:"$zlib/lib/libz.a" --nimcache:build/nimcache/recover -o:build/bin/loong-recover.partial tools/viewer/recovery/serve.nim
    mv -f build/bin/loong-recover.partial build/bin/loong-recover

bot-build +args:
    build/bin/loong-build bot-build "$@"

round-robin *args:
    build/bin/loong-tournament round-robin "$@"

batch *args:
    build/bin/loong-tournament batch "$@"

ladder *args:
    build/bin/loong-tournament ladder "$@"

freeze *args:
    build/bin/loong-tournament freeze "$@"

trial *args:
    build/bin/loong-tournament trial "$@"

regenerate *args:
    build/bin/loong-tournament regenerate "$@"

report +args:
    build/bin/loong-report summary "$@"

verdict *args:
    build/bin/loong-report verdict "$@"

mapgen *args:
    build/bin/loong-mapgen "$@"

map-variants *args:
    build/bin/loong-map-variants "$@"

sample-replays *args:
    build/bin/loong-sample-replays "$@"

decode +args:
    build/bin/loong-gamedata decode "$@"

deaths +args:
    build/bin/loong-gamedata decode --deaths "$@"

gamedata +args:
    build/bin/loong-gamedata "$@"

decisions *args:
    build/bin/loong-recover decisions "$@"

zig-judge-build:
    zig build --build-file tools/judge/build.zig --cache-dir "$PWD/build/zig-cache" --global-cache-dir "$PWD/build/zig-global-cache" --prefix "$PWD/build/zig-judge" -Doptimize=ReleaseFast

zig-judge +args:
    build/zig-judge/bin/loong-judge "$@"

zig-native-build output backend="cpu":
    bash tools/engine/build-native.sh "{{output}}" "{{backend}}"

map-fit-build:
    bash tools/ladder/map_fit/build.sh

viewer-build: build-dir
    odin build tools/viewer -vet -strict-style -warnings-as-errors -o:speed -out:build/bin/viewer

viewer +args:
    bash tools/viewer/open.sh "$@"


viewer-restart:
    #!/usr/bin/env bash
    set -euo pipefail
    binary="$PWD/build/bin/viewer"
    last=assets/review/viewer/last.args
    [[ -f "$last" ]] || { echo "no saved viewer launch"; exit 0; }
    for pid in $(pgrep -f "^$binary " || true); do kill "$pid"; done
    mapfile -d '' -t arguments < "$last"
    exec "$binary" "${arguments[@]}"

vector-remarks guid profile team="A" top="20":
    build/bin/loong-build vector-remarks "{{guid}}" "{{profile}}" "{{team}}" "{{top}}"
