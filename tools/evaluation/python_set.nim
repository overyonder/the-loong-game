## CPython 3.13's `set`, slot for slot, for keys whose hashes don't depend on
## the process (integers and tuples of them). Code ported from Python that
## iterates a set, or draws random numbers while iterating one, has to visit
## the elements in CPython's table order to give the same result, so this
## keeps CPython's open-addressing table, probe sequence, resize rule and the
## fast paths of `set(other)`, `|`, `&`, `-` and `-=` that change the order.
## A `PySet` is a reference, as a Python set is.

const
  LinearProbes = 9
  PerturbShift = 5
  MinimumSize  = 8

type
  SlotState = enum Empty, Active, Dummy
  SetSlot[K] = object
    key:   K
    hash:  int64      # CPython's Py_hash_t; -1 marks a dummy
    state: SlotState
  PySet*[K] = ref object
    table: seq[SetSlot[K]]  # length is a power of two, mask + 1
    fill:  int              # active and dummy slots
    used:  int              # active slots

const
  XxPrime1 = 11400714785074694791'u64
  XxPrime2 = 14029467366897019727'u64
  XxPrime5 = 2870177450012600261'u64
  ModulusBits = 61
  Modulus = (1'u64 shl ModulusBits) - 1

proc pyHash*(value: int): int64 =
  ## `hash(n)` for an int: its residue modulo 2**61 - 1, signed, -1 as -2.
  let magnitude = int64(uint64(abs(value)) mod Modulus)
  result = if value < 0: -magnitude else: magnitude
  if result == -1: result = -2

proc tupleHash(lanes: openArray[int64]): int64 =
  var accumulator = XxPrime5
  for lane in lanes:
    accumulator += cast[uint64](lane) * XxPrime2
    accumulator = (accumulator shl 31) or (accumulator shr 33)
    accumulator *= XxPrime1
  accumulator += uint64(lanes.len) xor (XxPrime5 xor 3527539'u64)
  if accumulator == high(uint64): return 1546275796
  cast[int64](accumulator)

proc pyHash*(value: (int, int)): int64 =
  ## `hash((a, b))`.
  tupleHash([pyHash(value[0]), pyHash(value[1])])

proc pyHash*(value: ((int, int), (int, int))): int64 =
  ## `hash(((a, b), (c, d)))`.
  tupleHash([pyHash(value[0]), pyHash(value[1])])

proc newPySet*[K](): PySet[K] =
  PySet[K](table: newSeq[SetSlot[K]](MinimumSize))

proc len*[K](s: PySet[K]): int = s.used

proc mask[K](s: PySet[K]): int = s.table.len - 1

iterator items*[K](s: PySet[K]): K =
  ## The elements in table order, as iterating a Python set visits them.
  for slot in s.table:
    if slot.state == Active: yield slot.key

proc insertClean[K](table: var seq[SetSlot[K]], key: K, hash: int64) =
  let mask = uint64(table.len - 1)
  var perturb = cast[uint64](hash)
  var i = cast[uint64](hash) and mask
  while true:
    if table[i].state == Empty:
      table[i] = SetSlot[K](key: key, hash: hash, state: Active)
      return
    if i + LinearProbes <= mask:
      for j in 1'u64 .. LinearProbes:
        if table[i + j].state == Empty:
          table[i + j] = SetSlot[K](key: key, hash: hash, state: Active)
          return
    perturb = perturb shr PerturbShift
    i = (i * 5 + 1 + perturb) and mask

proc resize[K](s: PySet[K], minimumUsed: int) =
  var size = MinimumSize
  while size <= minimumUsed: size = size shl 1
  if size == MinimumSize and s.table.len == MinimumSize and s.fill == s.used: return
  let old = move s.table
  s.table = newSeq[SetSlot[K]](size)
  s.fill = s.used
  for slot in old:
    if slot.state == Active: s.table.insertClean(slot.key, slot.hash)

proc lookup[K](s: PySet[K], key: K, hash: int64): int =
  ## The slot holding `key`, or the empty slot that ends its probe sequence.
  let mask = uint64(s.mask)
  var perturb = cast[uint64](hash)
  var i = cast[uint64](hash) and mask
  while true:
    var probes = if i + LinearProbes <= mask: LinearProbes else: 0
    var index = i
    while true:
      let slot = s.table[index].addr
      if slot.state == Empty: return int(index)
      if slot.state == Active and slot.hash == hash and slot.key == key: return int(index)
      inc index
      if probes == 0: break
      dec probes
    perturb = perturb shr PerturbShift
    i = (i * 5 + 1 + perturb) and mask

proc addEntry[K](s: PySet[K], key: K, hash: int64) =
  let mask = uint64(s.mask)
  var perturb = cast[uint64](hash)
  var i = cast[uint64](hash) and mask
  var free = -1
  while true:
    var probes = if i + LinearProbes <= mask: LinearProbes else: 0
    var index = i
    while true:
      let slot = s.table[index].addr
      if slot.state == Empty:
        if free >= 0:
          s.table[free] = SetSlot[K](key: key, hash: hash, state: Active)
          inc s.used
          return
        slot[] = SetSlot[K](key: key, hash: hash, state: Active)
        inc s.fill
        inc s.used
        if s.fill * 5 < int(mask) * 3: return
        s.resize(if s.used > 50000: s.used * 2 else: s.used * 4)
        return
      if slot.state == Active and slot.hash == hash and slot.key == key: return
      if slot.state == Dummy: free = int(index)
      inc index
      if probes == 0: break
      dec probes
    perturb = perturb shr PerturbShift
    i = (i * 5 + 1 + perturb) and mask

proc incl*[K](s: PySet[K], key: K) =
  ## `s.add(key)`.
  s.addEntry(key, pyHash(key))

proc contains*[K](s: PySet[K], key: K): bool =
  s.table[s.lookup(key, pyHash(key))].state == Active

proc discardEntry[K](s: PySet[K], key: K, hash: int64): bool =
  let index = s.lookup(key, hash)
  if s.table[index].state != Active: return false
  s.table[index].state = Dummy
  s.table[index].hash = -1
  dec s.used
  true

proc excl*[K](s: PySet[K], key: K) =
  ## `s.discard(key)`.
  discard s.discardEntry(key, pyHash(key))

proc merge[K](s, other: PySet[K]) =
  ## `s |= other` for a set `other` (CPython's set_merge).
  if s == other or other.used == 0: return
  if (s.fill + other.used) * 5 >= s.mask * 3: s.resize((s.used + other.used) * 2)
  if s.fill == 0 and s.mask == other.mask and other.fill == other.used:
    for index, slot in other.table:
      if slot.state == Active: s.table[index] = slot
    s.fill = other.fill
    s.used = other.used
    return
  if s.fill == 0:
    s.fill = other.used
    s.used = other.used
    for slot in other.table:
      if slot.state == Active: s.table.insertClean(slot.key, slot.hash)
    return
  for slot in other.table:
    if slot.state == Active: s.addEntry(slot.key, slot.hash)

proc toPySet*[K](values: openArray[K]): PySet[K] =
  ## `set(values)` from a list, a tuple or a generator.
  result = newPySet[K]()
  for value in values: result.incl value

proc copy*[K](s: PySet[K]): PySet[K] =
  ## `set(s)` or `s.copy()`.
  result = newPySet[K]()
  result.merge(s)

proc `|`*[K](a, b: PySet[K]): PySet[K] =
  result = a.copy
  result.merge(b)

proc `|=`*[K](a, b: PySet[K]) = a.merge(b)

proc `&`*[K](a, b: PySet[K]): PySet[K] =
  ## `a & b`: iterates the smaller set, the second on a tie.
  if a == b: return a.copy
  result = newPySet[K]()
  var (larger, smaller) = (a, b)
  if smaller.len > larger.len: swap(larger, smaller)
  for slot in smaller.table:
    if slot.state == Active and larger.table[larger.lookup(slot.key, slot.hash)].state == Active:
      result.addEntry(slot.key, slot.hash)

proc `-=`*[K](s, other: PySet[K]) =
  ## `s -= other` (CPython's set_difference_update_internal).
  if s == other:
    s.table = newSeq[SetSlot[K]](MinimumSize)
    s.fill = 0
    s.used = 0
    return
  let source = if (other.len shr 3) > s.len: s & other else: other
  for slot in source.table:
    if slot.state == Active: discard s.discardEntry(slot.key, slot.hash)
  if s.fill - s.used <= s.mask div 4: return
  s.resize(if s.used > 50000: s.used * 2 else: s.used * 4)

proc `-`*[K](a, b: PySet[K]): PySet[K] =
  ## `a - b`: a copy with `b` removed when `a` is much larger, else the
  ## elements of `a` not in `b` in `a`'s order.
  if (a.len shr 2) > b.len:
    result = a.copy
    result -= b
    return
  result = newPySet[K]()
  for slot in a.table:
    if slot.state == Active and b.table[b.lookup(slot.key, slot.hash)].state != Active:
      result.addEntry(slot.key, slot.hash)


proc sameElements*[K](a, b: PySet[K]): bool =
  ## Python's `a == b` for sets.
  if a.len != b.len: return false
  for key in a:
    if key notin b: return false
  true

proc `<=`*[K](a, b: PySet[K]): bool =
  ## `a <= b`, subset.
  if a.len > b.len: return false
  for key in a:
    if key notin b: return false
  true

proc toSeq*[K](s: PySet[K]): seq[K] =
  ## `list(s)`.
  for key in s: result.add key

proc shuffleBits(h: uint64): uint64 = ((h xor 89869747'u64) xor (h shl 16)) * 3644798167'u64

proc frozensetHash*[K](s: PySet[K]): int64 =
  ## `hash(frozenset(s))`, from the hashes in every slot of the table.
  var hash = 0'u64
  for slot in s.table: hash = hash xor shuffleBits(cast[uint64](slot.hash))
  if ((s.table.len - s.fill) and 1) != 0: hash = hash xor shuffleBits(0)
  if ((s.fill - s.used) and 1) != 0: hash = hash xor shuffleBits(high(uint64))
  hash = hash xor ((uint64(s.used) + 1) * 1927868237'u64)
  hash = hash xor ((hash shr 11) xor (hash shr 25))
  hash = hash * 69069'u64 + 907133923'u64
  if hash == high(uint64): hash = 590923713'u64
  cast[int64](hash)
