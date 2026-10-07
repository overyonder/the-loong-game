## The members of a fleet run's `bundle.tar.gz`.

import std/[strutils, tables]
import ../../gamedata/gzip_inflate

proc tarMembers*(path: string): Table[string, string] =
  ## Regular file name to content, from a gzip-compressed ustar archive.
  let archive = readFile(path).gunzip
  var at = 0
  var longName = ""
  while at + 512 <= archive.len and archive[at] != '\0':
    let name = archive[at ..< at + 100].strip(leading = false, chars = {'\0'})
    let prefix = archive[at + 345 ..< at + 500].strip(leading = false, chars = {'\0'})
    let size = parseOctInt("0o" & archive[at + 124 ..< at + 136].strip(chars = {'\0', ' '}))
    let kind = archive[at + 156]
    var full = if longName.len > 0: longName elif prefix.len > 0: prefix & "/" & name else: name
    longName = ""
    full.removePrefix("./")
    if kind == 'L': longName = archive[at + 512 ..< at + 512 + size].strip(leading = false, chars = {'\0'})
    elif kind in {'0', '\0'}: result[full] = archive[at + 512 ..< at + 512 + size]
    at += 512 + (size + 511) div 512 * 512
