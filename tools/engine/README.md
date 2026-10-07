# Native game engine

The C++ engine implements the game rules and serializes observations and
packed replays. `host.cc` exposes the text-protocol interface used by the
judge's lockstep comparison. `native.h` defines ABI 1 for complete CPU and
CUDA matches.

Build one library with `just zig-native-build OUTPUT cpu` or
`just zig-native-build OUTPUT cuda`. The output directory needs to be new.
Both builds need a C++20 compiler and `CAPNP_PREFIX`. CUDA also needs
`NVCC`, `CUDART` and `CUDA_ARCH` (120 by default). With a split CUDA
installation, put its CRT and CCCL include directories on `CPATH`.

The build writes the shared library, generated schema bindings, compiler
versions and hashes. It neither installs the library nor runs games.
Select the library explicitly with the judge's
`--native-library OUTPUT/libloong-native-cpu.so` option, or the CUDA
library and `--cuda-batch N`.

The released rules and observation builder are extracted from the frozen
shared library. The policy, belief model and learner interfaces remain in
the private repository. `native_profile.h` provides optional aggregate
timing records for complete matches.
