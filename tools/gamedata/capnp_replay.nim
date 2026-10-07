## A reader for packed Cap'n Proto messages, enough for the game's replay
## schema (tools/gamedata/replay.capnp): structs, lists, text and far
## pointers. Field offsets come from that schema's layout, which pycapnp
## reports; each accessor names the field it reads.

type
  CapnpMessage* = object
    words:        seq[uint64]    ## every segment, end to end
    segmentStart: seq[int]       ## first word of each segment in `words`

  CapnpStruct* = object
    dataWord*:     int           ## first data word, as an index into `words`
    dataWords*:    int
    pointerWord*:  int           ## first pointer word
    pointerCount*: int

  CapnpList* = object
    firstWord*:    int           ## first element's first word
    count*:        int
    elementSize*:  int           ## Cap'n Proto size code: 2 byte, 3 two bytes, 4 four, 5 eight, 7 struct
    structWords*:  int           ## composite: words per element
    dataWords*:    int           ## composite: data words per element
    pointerCount*: int           ## composite: pointers per element

proc unpackCapnpPacked(packed: openArray[byte]): seq[byte] =
  ## Cap'n Proto packing: a tag byte says which of the next word's bytes are
  ## stored; tag 0 is followed by a count of extra zero words, and tag 0xFF by
  ## a count of words stored verbatim.
  result = newSeqOfCap[byte](packed.len * 4)
  var at = 0
  while at < packed.len:
    let tag = packed[at]
    inc at
    for bit in 0 .. 7:
      if (tag and (1'u8 shl bit)) != 0:
        result.add packed[at]
        inc at
      else:
        result.add 0
    if tag == 0:
      let zeros = int(packed[at]) * 8
      inc at
      result.setLen(result.len + zeros)
    elif tag == 0xFF:
      let verbatim = int(packed[at]) * 8
      inc at
      let copyStart = result.len
      result.setLen(copyStart + verbatim)
      if verbatim > 0: copyMem(addr result[copyStart], unsafeAddr packed[at], verbatim)
      at += verbatim

proc readCapnpPackedMessage*(packed: openArray[byte]): CapnpMessage =
  let bytes = unpackCapnpPacked(packed)
  var segmentCount: uint32
  copyMem(addr segmentCount, unsafeAddr bytes[0], 4)
  let segments = int(segmentCount) + 1
  let headerBytes = ((1 + segments) * 4 + 7) and not 7
  result.words = newSeq[uint64]((bytes.len - headerBytes) div 8)
  if result.words.len > 0:
    copyMem(addr result.words[0], unsafeAddr bytes[headerBytes], result.words.len * 8)
  var start = 0
  for segment in 0 ..< segments:
    var size: uint32
    copyMem(addr size, unsafeAddr bytes[4 + segment * 4], 4)
    result.segmentStart.add start
    start += int(size)

proc resolvePointer(message: CapnpMessage, word: int): tuple[pointerWord: uint64, target: int] =
  ## The struct or list pointer at `word`, following far pointers, and the
  ## index of the word it points at. A null pointer has target -1.
  let value = message.words[word]
  if value == 0: return (0'u64, -1)
  if (value and 3) == 2:
    let landing = message.segmentStart[int(value shr 32)] + int((value shr 3) and 0x1FFFFFFF)
    if ((value shr 2) and 1) == 0:
      let pad = message.words[landing]
      let offset = int(cast[int32](uint32(pad and 0xFFFFFFFF'u64)) shr 2)
      return (pad, landing + 1 + offset)
    let content = message.words[landing]
    let tag = message.words[landing + 1]
    return (tag, message.segmentStart[int(content shr 32)] + int((content shr 3) and 0x1FFFFFFF))
  let offset = int(cast[int32](uint32(value and 0xFFFFFFFF'u64)) shr 2)
  (value, word + 1 + offset)

proc root*(message: CapnpMessage): CapnpStruct =
  let (pointerWord, target) = message.resolvePointer(0)
  CapnpStruct(dataWord: target, dataWords: int((pointerWord shr 32) and 0xFFFF),
    pointerWord: target + int((pointerWord shr 32) and 0xFFFF),
    pointerCount: int((pointerWord shr 48) and 0xFFFF))

proc hasPointer*(message: CapnpMessage, parent: CapnpStruct, index: int): bool =
  ## Whether pointer field `index` is set.
  index < parent.pointerCount and message.resolvePointer(parent.pointerWord + index).target >= 0

proc structField*(message: CapnpMessage, parent: CapnpStruct, index: int): CapnpStruct =
  ## Pointer field `index` as a struct; an empty struct when null or absent.
  if index >= parent.pointerCount: return
  let (pointerWord, target) = message.resolvePointer(parent.pointerWord + index)
  if target < 0: return
  let dataWords = int((pointerWord shr 32) and 0xFFFF)
  CapnpStruct(dataWord: target, dataWords: dataWords, pointerWord: target + dataWords,
    pointerCount: int((pointerWord shr 48) and 0xFFFF))

proc listField*(message: CapnpMessage, parent: CapnpStruct, index: int): CapnpList =
  ## Pointer field `index` as a list; empty when null or absent.
  if index >= parent.pointerCount: return
  let (pointerWord, target) = message.resolvePointer(parent.pointerWord + index)
  if target < 0: return
  result.elementSize = int((pointerWord shr 32) and 7)
  result.count = int(pointerWord shr 35)
  result.firstWord = target
  if result.elementSize == 7:
    let tag = message.words[target]
    result.count = int((tag shr 2) and 0x3FFFFFFF)
    result.dataWords = int((tag shr 32) and 0xFFFF)
    result.pointerCount = int((tag shr 48) and 0xFFFF)
    result.structWords = result.dataWords + result.pointerCount
    result.firstWord = target + 1

proc listStruct*(list: CapnpList, index: int): CapnpStruct =
  let at = list.firstWord + index * list.structWords
  CapnpStruct(dataWord: at, dataWords: list.dataWords, pointerWord: at + list.dataWords,
    pointerCount: list.pointerCount)

proc dataBytes(message: CapnpMessage, parent: CapnpStruct, byteOffset, size: int): uint64 =
  ## `size` bytes at `byteOffset` into the data section; 0 past its end.
  if byteOffset + size > parent.dataWords * 8: return 0
  let word = message.words[parent.dataWord + byteOffset div 8]
  let shift = (byteOffset mod 8) * 8
  (word shr shift) and (if size == 8: high(uint64) else: (1'u64 shl (size * 8)) - 1)

proc uint16Field*(message: CapnpMessage, parent: CapnpStruct, slot: int): uint16 =
  uint16(message.dataBytes(parent, slot * 2, 2))
proc int32Field*(message: CapnpMessage, parent: CapnpStruct, slot: int): int32 =
  cast[int32](uint32(message.dataBytes(parent, slot * 4, 4)))
proc uint32Field*(message: CapnpMessage, parent: CapnpStruct, slot: int): uint32 =
  uint32(message.dataBytes(parent, slot * 4, 4))
proc uint64Field*(message: CapnpMessage, parent: CapnpStruct, slot: int): uint64 =
  message.dataBytes(parent, slot * 8, 8)
proc boolField*(message: CapnpMessage, parent: CapnpStruct, bit: int): bool =
  ((message.dataBytes(parent, bit div 8, 1) shr (bit mod 8)) and 1) == 1

proc textField*(message: CapnpMessage, parent: CapnpStruct, index: int): string =
  ## Pointer field `index` as text, without its NUL terminator.
  let list = message.listField(parent, index)
  if list.count <= 1: return ""
  result = newString(list.count - 1)
  copyMem(addr result[0], unsafeAddr cast[ptr UncheckedArray[byte]](
    unsafeAddr message.words[list.firstWord])[0], list.count - 1)

proc uint16Element*(message: CapnpMessage, list: CapnpList, index: int): uint16 =
  ## Element `index` of a list of 16-bit values, such as enums.
  let bytes = cast[ptr UncheckedArray[uint16]](unsafeAddr message.words[list.firstWord])
  bytes[index]

type UnreadableReplay* = object of ValueError
  ## A replay this reader can't decode as pycapnp would.

proc structElement*(message: CapnpMessage, list: CapnpList, index: int): CapnpStruct =
  ## Element `index` of a struct list: composite, or one word an element.
  case list.elementSize
  of 7: list.listStruct(index)
  of 5: CapnpStruct(dataWord: list.firstWord + index, dataWords: 1)
  else: raise newException(UnreadableReplay, "struct list of element size " & $list.elementSize)

proc enumElement*(message: CapnpMessage, list: CapnpList, index: int): uint16 =
  ## Element `index` of an enum list: two bytes, or a composite's first field.
  case list.elementSize
  of 3: message.uint16Element(list, index)
  of 7: message.uint16Field(list.listStruct(index), 0)
  else: raise newException(UnreadableReplay, "enum list of element size " & $list.elementSize)
