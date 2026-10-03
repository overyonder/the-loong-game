// Complete games and replay capture on CUDA. No training tensors or exports.
#include <cuda_runtime.h>
#include "native_replay.h"
#include <algorithm>
#include <cstdio>
#include <cstring>

using namespace loong;
#include "native_batch.cuh"
