## Seeded games' seeds. A seed depends only on the map and its index, never
## on the bots, so every pairing and both sides meet the same pearl schedules
## and a rerun replays the same games: zlib's CRC-32 of `"<map file>:<index>"`.

proc makeTable(): array[256, uint32] =
  for index in 0 ..< 256:
    var value = uint32(index)
    for _ in 0 ..< 8:
      value = if (value and 1) != 0: 0xedb88320'u32 xor (value shr 1) else: value shr 1
    result[index] = value

const CrcTable = makeTable()

proc crc32*(text: string): uint32 =
  ## zlib's CRC-32 of `text`.
  result = 0xffffffff'u32
  for character in text:
    result = CrcTable[(result xor uint32(ord(character))) and 0xff] xor (result shr 8)
  result = not result

proc gameSeed*(mapName: string, index: int): int64 =
  ## The seed of game `index` on the map file named `mapName`.
  int64(crc32(mapName & ":" & $index))
