## SHA-256, which identifies judge builds in the registry and replays in the
## public replay manifest.

import std/strutils

const RoundConstants = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32,
  0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32,
  0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32, 0xa2bfe8a1'u32, 0xa81a664b'u32,
  0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32,
  0x5b9cca4f'u32, 0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotateRight(value: uint32, bits: int): uint32 {.inline.} =
  (value shr bits) or (value shl (32 - bits))

proc sha256Hex*(data: string): string =
  ## The lowercase hexadecimal SHA-256 digest of `data`.
  var state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
               0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var message = data & '\x80'
  while message.len mod 64 != 56: message.add '\0'
  let bits = uint64(data.len) * 8
  for shift in countdown(56, 0, 8): message.add char((bits shr shift) and 0xff)
  var words: array[64, uint32]
  for chunk in countup(0, message.len - 1, 64):
    for i in 0 ..< 16:
      words[i] = (uint32(message[chunk + 4 * i]) shl 24) or
        (uint32(message[chunk + 4 * i + 1]) shl 16) or
        (uint32(message[chunk + 4 * i + 2]) shl 8) or uint32(message[chunk + 4 * i + 3])
    for i in 16 ..< 64:
      let s0 = rotateRight(words[i - 15], 7) xor rotateRight(words[i - 15], 18) xor (words[i - 15] shr 3)
      let s1 = rotateRight(words[i - 2], 17) xor rotateRight(words[i - 2], 19) xor (words[i - 2] shr 10)
      words[i] = words[i - 16] + s0 + words[i - 7] + s1
    var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3],
                                    state[4], state[5], state[6], state[7])
    for i in 0 ..< 64:
      let s1 = rotateRight(e, 6) xor rotateRight(e, 11) xor rotateRight(e, 25)
      let choice = (e and f) xor ((not e) and g)
      let first = h + s1 + choice + RoundConstants[i] + words[i]
      let s0 = rotateRight(a, 2) xor rotateRight(a, 13) xor rotateRight(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      (h, g, f, e, d, c, b, a) = (g, f, e, d + first, c, b, a, first + s0 + majority)
    for i, value in [a, b, c, d, e, f, g, h]: state[i] += value
  for value in state: result.add value.toHex(8).toLowerAscii
