## Gzip decompression through zlib's inflate, linked statically so the binary
## still runs on fleet workers (`just tools-build` passes its archive).

type
  ZlibStream* {.bycopy.} = object
    ## zlib.h's z_stream, in its field order.
    nextIn*:   ptr uint8
    availIn*:  cuint
    totalIn*:  culong
    nextOut*:  ptr uint8
    availOut*: cuint
    totalOut*: culong
    message:  cstring
    state:    pointer
    zalloc:   pointer
    zfree:    pointer
    opaque:   pointer
    dataType: cint
    adler:    culong
    reserved: culong

const
  ZlibOk        = 0
  ZlibStreamEnd = 1
  ZlibNoFlush   = 0
  GzipWindow    = 15 + 16   ## a 32 KiB window, expecting a gzip header

proc zlibVersion*(): cstring {.importc, cdecl.}
proc inflateInit2(stream: ptr ZlibStream, windowBits: cint, version: cstring,
    streamSize: cint): cint {.importc: "inflateInit2_", cdecl.}
proc inflate(stream: ptr ZlibStream, flush: cint): cint {.importc, cdecl.}
proc inflateEnd(stream: ptr ZlibStream): cint {.importc, cdecl.}

proc isGzip*(bytes: string): bool =
  bytes.len >= 2 and bytes[0] == '\x1f' and bytes[1] == '\x8b'

proc gunzip*(compressed: string): string =
  ## The whole decompressed content of one gzip member.
  var stream: ZlibStream
  doAssert inflateInit2(addr stream, GzipWindow, zlibVersion(), cint(sizeof(ZlibStream))) == ZlibOk
  stream.nextIn = cast[ptr uint8](unsafeAddr compressed[0])
  stream.availIn = cuint(compressed.len)
  result = newString(max(compressed.len * 4, 4096))
  while true:
    if int(stream.totalOut) == result.len: result.setLen(result.len * 2)
    stream.nextOut = cast[ptr uint8](addr result[int(stream.totalOut)])
    stream.availOut = cuint(result.len - int(stream.totalOut))
    let status = inflate(addr stream, ZlibNoFlush)
    if status == ZlibStreamEnd: break
    if status != ZlibOk:
      discard inflateEnd(addr stream)
      raise newException(IOError, "gzip data is corrupt: " & $stream.message)
  result.setLen(int(stream.totalOut))
  discard inflateEnd(addr stream)
