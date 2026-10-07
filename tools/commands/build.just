# The two recipes that compile a bot. A build's GUID hashes this file, so edit it
# only to change how bots compile (tools/evaluation/bot_build/settings.nim).

# Compile bot logic for the official judge. Generated C stays in a build cache.
[private]
[no-exit-message]
_build-bot source output mode:
    #!/usr/bin/env bash
    set -euo pipefail
    source="$1"
    output="$2"
    mode="$3"
    runtime="${LOONG_BUILD_RUNTIME:-$PWD/bots/common/runtime}"
    # Diagnostics are compiled in and switched on only by our inspection harness
    # (bots/common/runtime/gizmos.h), so one build both plays and is inspected.
    nim_flags=(-d:loongDiagnostics -d:loongRuntimeMain)
    [[ "$mode" == judge || "$mode" == native ]] || { echo 'Mode must be judge or native' >&2; exit 2; }
    # A bot that pins versioned library pieces (library.toml) builds from its
    # assembled copy (loong-build materialize).
    if [[ -f "$source/library.toml" ]]; then
        source=$(cd "{{justfile_directory()}}" && build/bin/loong-build materialize "$(realpath "$source")")
    fi
    if [[ -f "$source/strategy.nim" && "$mode" == native ]]; then
        mkdir -p "$(dirname "$output")"
        native_diagnostics="$(dirname "$output")/native-diagnostics.txt"
        if ! nim c --skipUserCfg --skipParentCfg --noMain --mm:arc -d:danger "${nim_flags[@]}" --hints:off --path:"$runtime" --passC:"-I$runtime" --compile:"$runtime/helper.c" --compile:"$runtime/entry.c" --nimcache:"$(dirname "$output")/nim-native" --out:"$output" "$source/strategy.nim" 2> "$native_diagnostics"; then
            cat "$native_diagnostics" >&2
            exit 1
        fi
        cat "$native_diagnostics" >&2
        if grep -q 'Warning:' "$native_diagnostics"; then exit 1; fi
    elif [[ -f "$source/strategy.nim" ]]; then
        mkdir -p build
        generated=$(mktemp -d "$PWD/build/nim-bot.XXXXXXXX")
        trap 'rm -rf "$generated"' EXIT
        # Nim hashes each module's absolute path into the C names it generates, so
        # every build generates from this one path, in turn: the same sources then
        # give the same C, and the same objects, on any machine.
        fixed=/tmp/loong-nim-build
        exec {lock}> "$fixed.lock"
        flock "$lock"
        rm -rf "$fixed"
        mkdir -p "$fixed"
        cp -r "$source" "$fixed/source"
        if [[ -d "$source/../repertoire" ]]; then cp -r "$source/../repertoire" "$fixed/repertoire"; fi
        cp -r "$runtime" "$fixed/runtime"
        if ! nim c --skipUserCfg --skipParentCfg --compileOnly --noMain --cpu:wasm32 --os:any --mm:arc --threads:off --exceptions:goto --panics:on -d:useMalloc -d:danger -d:noSignalHandler "${nim_flags[@]}" --hints:off --path:"$fixed/runtime" --nimcache:"$generated" "$fixed/source/strategy.nim" 2> "$generated/nim-diagnostics"; then
            cat "$generated/nim-diagnostics" >&2
            exit 1
        fi
        cat "$generated/nim-diagnostics" >&2
        # Nim has no all-warnings-as-errors switch; reject every emitted warning.
        if grep -q 'Warning:' "$generated/nim-diagnostics"; then exit 1; fi
        # C and C++ units the bot names with {.compile.} (library bridges): Nim's
        # --compileOnly lists but doesn't copy them, so they join the generated C
        # here, with every header beside them in the source's and repertoire's
        # layout, so their relative includes resolve.
        jq -r '.compile[]?[0]' "$generated/strategy.json" | while IFS= read -r unit; do
            [[ -n "$unit" && "$unit" != "$generated"/* ]] || continue
            relative=${unit#"$fixed"/}
            mkdir -p "$generated/$(dirname "$relative")"
            cp "$unit" "$generated/$relative"
        done
        header_roots=(source)
        if [[ -d "$fixed/repertoire" ]]; then header_roots+=(repertoire); fi
        (cd "$fixed" && find "${header_roots[@]}" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.hh' -o -name '*.inc' \) -exec cp --parents -t "$generated" {} +)
        nim_library=$(nim dump --skipUserCfg --skipParentCfg --dump.format:json --hints:off "$fixed/source/strategy.nim" | jq -r .libpath)
        # Rake kernels: each kernel's C header, emitted when the build was staged
        # (loong-build emit-kernels) or now for an unstaged source, joins the
        # generated C, since C is what the judge takes.
        kernel_roots=("$fixed/source")
        if [[ -d "$fixed/repertoire" ]]; then kernel_roots+=("$fixed/repertoire"); fi
        while IFS= read -r header; do
            [[ -n "$header" ]] || continue
            name=$(basename "$header")
            if [[ -e "$generated/$name" || -e "$runtime/$name" || "$name" == nimbase.h ]]; then
                echo "The Rake kernel header $name clashes with another file" >&2
                exit 1
            fi
            cp "$header" "$generated/"
        done < <("{{justfile_directory()}}/build/bin/loong-build" emit-kernels "${kernel_roots[@]}")
        # Files the generated C `#embed`s, such as weights, join it from the bot
        # or its repertoire (loong-build stage-embeds).
        "{{justfile_directory()}}/build/bin/loong-build" stage-embeds "$generated" "${kernel_roots[@]}"
        rm -rf "$fixed"
        flock -u "$lock"
        cp "$nim_library/nimbase.h" "$runtime"/*.c "$runtime"/*.h "$generated/"
        just _compile-bot "$generated" "$output" "$mode"
    else
        just _compile-bot "$source" "$output" "$mode"
    fi

# The judge clang adapter: stages the C as the judge receives it and builds it
# with the organisers' clang (`loong-build compile-c`). Only the judge mode
# compiles C; a native build is a Nim bot's.
[private]
_compile-bot source output mode:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$3" == judge ]] || { echo "A native build compiles a Nim bot; $1 is C" >&2; exit 2; }
    exec "{{justfile_directory()}}/build/bin/loong-build" compile-c "$1" "$2"
