#!/usr/bin/env bash
# One generic CPU or CUDA replay library; no installation or match execution.
set -euo pipefail
source_directory=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$source_directory/../.." && pwd)
build_directory=${1:?usage: build-native.sh OUTPUT_DIRECTORY [cpu|cuda]}
backend=${2:-cpu}
[[ $backend == cpu || $backend == cuda ]] || { echo 'backend must be cpu or cuda' >&2; exit 2; }
[[ -n ${CAPNP_PREFIX:-} ]] || { echo 'set CAPNP_PREFIX to the selected Capn Proto package' >&2; exit 2; }
if [[ $backend == cuda ]]; then
    [[ -n ${CUDART:-} ]] || { echo 'set CUDART to the selected CUDA runtime package' >&2; exit 2; }
    cuda_arch=${CUDA_ARCH:-120}
    [[ $cuda_arch =~ ^[0-9]+$ ]] || { echo 'CUDA_ARCH must be a numeric compute capability' >&2; exit 2; }
fi
[[ ! -e $build_directory ]] || { echo 'output directory already exists; select a new build directory' >&2; exit 2; }
mkdir -p "$build_directory"
build_directory=$(realpath "$build_directory")
"$CAPNP_PREFIX/bin/capnp" compile -I "$CAPNP_PREFIX/include" --src-prefix="$repo_root" \
    -o "$CAPNP_PREFIX/bin/capnpc-c++:$build_directory" "$repo_root/tools/gamedata/replay.capnp"
sources=(host.cc native.cc native_replay.cc)
objects=()
for source in "${sources[@]}"; do
    object="$build_directory/$source.o"
    "${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC \
        -I "$CAPNP_PREFIX/include" -I "$build_directory" -c "$source_directory/$source" -o "$object"
    objects+=("$object")
done
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -fPIC -I "$CAPNP_PREFIX/include" \
    -c "$build_directory/tools/gamedata/replay.capnp.c++" -o "$build_directory/replay.capnp.o"
objects+=("$build_directory/replay.capnp.o")
runtime_flags=()
if [[ $backend == cuda ]]; then
    "${NVCC:-nvcc}" -O3 -std=c++20 -gencode "arch=compute_$cuda_arch,code=sm_$cuda_arch" \
        -Werror all-warnings -Xcompiler=-fPIC,-Wall,-Wextra,-Werror \
        -I "$CUDART/include" -c "$source_directory/batch.cu" -o "$build_directory/batch.cu.o"
    objects+=("$build_directory/batch.cu.o")
    runtime_flags=(-L "$CUDART/lib" -L "$CUDART/lib64" -lcudart -pthread \
        -Wl,-rpath,"$CUDART/lib" -Wl,-rpath,"$CUDART/lib64")
    "${NVCC:-nvcc}" --version > "$build_directory/nvcc.txt"
fi
"${CXX:-c++}" -shared "${objects[@]}" "${runtime_flags[@]}" -L "$CAPNP_PREFIX/lib" -lcapnp -lkj \
    -Wl,-rpath,"$CAPNP_PREFIX/lib" -o "$build_directory/libloong-native-$backend.so"
sha256sum "$source_directory"/{engine.h,host.cc,replay_events.h,reply_replay.h,native.h,native.cc,native_replay.h,native_replay.cc,build-native.sh} \
    "$repo_root/tools/gamedata/replay.capnp" "$build_directory/tools/gamedata/replay.capnp".{h,c++} \
    "$build_directory/libloong-native-$backend.so" > "$build_directory/hashes.tsv"
if [[ $backend == cuda ]]; then
    sha256sum "$source_directory"/{batch.cu,native_batch.cuh} >> "$build_directory/hashes.tsv"
fi
"${CXX:-c++}" --version > "$build_directory/compiler.txt"
"$CAPNP_PREFIX/bin/capnp" --version > "$build_directory/capnp.txt"
printf '%s\n' 'Host: C++20 -O2 -Wall -Wextra -Werror -fPIC; shared libcapnp/libkj; C ABI 1' > "$build_directory/flags.txt"
if [[ $backend == cuda ]]; then
    printf 'CUDA: nvcc C++20 -O3 -Werror all-warnings; AOT sm_%s (no PTX image); cudart=%s; pthread\n' "$cuda_arch" "$CUDART" >> "$build_directory/flags.txt"
fi
