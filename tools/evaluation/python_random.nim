## CPython's `random.Random`, draw for draw: the Mersenne Twister seeded from
## an integer as `random.seed(n)` seeds it, and the sampling methods built on
## it with CPython's algorithms. Recorded schedules (the sequential test's map
## order) and generated maps were drawn this way, so the same seed gives the
## same games and maps.

import std/[bitops, math, sets]

const
  StateWords = 624
  ShiftWords = 397
  MatrixA    = 0x9908b0df'u32
  UpperMask  = 0x80000000'u32
  LowerMask  = 0x7fffffff'u32

type PythonRandom* = object
  state: array[StateWords, uint32]
  index: int

proc initGenrand(generator: var PythonRandom, seed: uint32) =
  generator.state[0] = seed
  for i in 1 ..< StateWords:
    let previous = generator.state[i - 1]
    generator.state[i] = 1812433253'u32 * (previous xor (previous shr 30)) + uint32(i)
  generator.index = StateWords

proc initByArray(generator: var PythonRandom, key: openArray[uint32]) =
  generator.initGenrand(19650218'u32)
  var (i, j) = (1, 0)
  for _ in 0 ..< max(StateWords, key.len):
    let previous = generator.state[i - 1]
    generator.state[i] = (generator.state[i] xor ((previous xor (previous shr 30)) * 1664525'u32)) +
      key[j] + uint32(j)
    inc i
    inc j
    if i >= StateWords:
      generator.state[0] = generator.state[StateWords - 1]
      i = 1
    if j >= key.len: j = 0
  for _ in 0 ..< StateWords - 1:
    let previous = generator.state[i - 1]
    generator.state[i] = (generator.state[i] xor ((previous xor (previous shr 30)) * 1566083941'u32)) -
      uint32(i)
    inc i
    if i >= StateWords:
      generator.state[0] = generator.state[StateWords - 1]
      i = 1
  generator.state[0] = 0x80000000'u32

proc initPythonRandom*(seed: int64): PythonRandom =
  ## `random.Random(seed)` for an integer seed: the absolute value's 32-bit
  ## words, least significant first, key the generator.
  var magnitude = if seed < 0: uint64(-(seed + 1)) + 1 else: uint64(seed)
  var key: seq[uint32]
  while magnitude > 0:
    key.add uint32(magnitude and 0xffffffff'u64)
    magnitude = magnitude shr 32
  if key.len == 0: key.add 0
  result.initByArray(key)

proc nextWord*(generator: var PythonRandom): uint32 =
  ## The next 32 random bits (`genrand_uint32`).
  if generator.index >= StateWords:
    for k in 0 ..< StateWords:
      let y = (generator.state[k] and UpperMask) or (generator.state[(k + 1) mod StateWords] and LowerMask)
      generator.state[k] = generator.state[(k + ShiftWords) mod StateWords] xor (y shr 1) xor
        (if (y and 1) != 0: MatrixA else: 0'u32)
    generator.index = 0
  var y = generator.state[generator.index]
  inc generator.index
  y = y xor (y shr 11)
  y = y xor ((y shl 7) and 0x9d2c5680'u32)
  y = y xor ((y shl 15) and 0xefc60000'u32)
  y xor (y shr 18)

proc random*(generator: var PythonRandom): float =
  ## A float in [0, 1) with 53 random bits.
  let a = generator.nextWord shr 5
  let b = generator.nextWord shr 6
  (float(a) * 67108864.0 + float(b)) * (1.0 / 9007199254740992.0)

proc getrandbits*(generator: var PythonRandom, bits: int): uint64 =
  ## `getrandbits(k)` for k up to 64: whole words least significant first,
  ## the last one's top bits.
  if bits <= 32: return uint64(generator.nextWord shr (32 - bits))
  let low = uint64(generator.nextWord)
  let high = uint64(generator.nextWord shr (64 - bits))
  low or (high shl 32)

proc randbelow*(generator: var PythonRandom, n: int): int =
  ## A uniform integer in [0, n), by rejection over `n`'s bit length.
  if n <= 0: return 0
  let bits = 64 - countLeadingZeroBits(uint64(n))
  var r = generator.getrandbits(bits)
  while r >= uint64(n): r = generator.getrandbits(bits)
  int(r)

proc randrange*(generator: var PythonRandom, start, stop: int, step = 1): int =
  if step == 1:
    if stop <= start: raise newException(ValueError, "empty range for randrange")
    return start + generator.randbelow(stop - start)
  let count = if step > 0: (stop - start + step - 1) div step else: (stop - start + step + 1) div step
  if count <= 0: raise newException(ValueError, "empty range for randrange")
  start + step * generator.randbelow(count)

proc randrange*(generator: var PythonRandom, stop: int): int = generator.randrange(0, stop)

proc randint*(generator: var PythonRandom, low, high: int): int =
  generator.randrange(low, high + 1)

proc uniform*(generator: var PythonRandom, low, high: float): float =
  low + (high - low) * generator.random

proc choice*[T](generator: var PythonRandom, items: openArray[T]): T =
  if items.len == 0: raise newException(ValueError, "Cannot choose from an empty sequence")
  items[generator.randbelow(items.len)]

proc shuffle*[T](generator: var PythonRandom, items: var openArray[T]) =
  for i in countdown(items.high, 1):
    let j = generator.randbelow(i + 1)
    swap(items[i], items[j])

proc sample*[T](generator: var PythonRandom, population: openArray[T], k: int): seq[T] =
  ## `sample(population, k)`: CPython picks from a shrinking pool for small
  ## populations and by rejection against the chosen set otherwise.
  let n = population.len
  if k < 0 or k > n: raise newException(ValueError, "Sample larger than population or is negative")
  result = newSeq[T](k)
  var setSize = 21
  if k > 5: setSize += 4 ^ int(ceil(ln(float(k * 3)) / ln(4.0)))
  if n <= setSize:
    var pool = @population
    for i in 0 ..< k:
      let j = generator.randbelow(n - i)
      result[i] = pool[j]
      pool[j] = pool[n - i - 1]
  else:
    var selected = initHashSet[int]()
    for i in 0 ..< k:
      var j = generator.randbelow(n)
      while j in selected: j = generator.randbelow(n)
      selected.incl j
      result[i] = population[j]

proc choices*[T](generator: var PythonRandom, population: openArray[T], k = 1): seq[T] =
  ## `choices(population, k=k)` without weights.
  let n = float(population.len)
  for _ in 0 ..< k: result.add population[int(floor(generator.random * n))]

proc choices*[T](generator: var PythonRandom, population: openArray[T],
                 weights: openArray[float], k = 1): seq[T] =
  ## `choices(population, weights, k=k)`: a bisection into the cumulative
  ## weights.
  var cumulative = newSeq[float](weights.len)
  var total = 0.0
  for i, weight in weights:
    total += weight
    cumulative[i] = total
  let high = population.len - 1
  for _ in 0 ..< k:
    let target = generator.random * total
    var (low, top) = (0, high)
    while low < top:
      let middle = (low + top) div 2
      if target < cumulative[middle]: top = middle else: low = middle + 1
    result.add population[low]
