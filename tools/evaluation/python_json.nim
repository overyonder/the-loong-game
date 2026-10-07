## JSON text exactly as Python's `json.dumps` writes it, for the records
## the Python tools wrote before (build manifests, result sets, plans), so
## files and the hashes taken over them stay byte for byte the same.
##
## `indent < 0` is the compact form with `, ` and `: ` separators; otherwise
## each item sits on its own line, indented by `indent` spaces a level, with
## `,` and `: `. Non-ASCII is escaped, and floats print as Python's `repr`.

import std/[algorithm, json, math, strutils, unicode]

const RawNumberMark = "\0number:"

proc rawNumber*(value: uint64): JsonNode =
  ## An unsigned 64-bit integer, which JSON's signed integers can't hold,
  ## written as its digits by `pythonDumps`.
  if value <= uint64(high(int64)): %int64(value) else: %(RawNumberMark & $value)

proc pythonFloat*(value: float): string =
  ## Python's `repr(float)`: the shortest round-trip digits, positional for
  ## decimal exponents -4 to 15, otherwise scientific with a signed exponent
  ## of at least two digits.
  if value.isNaN: return "NaN"
  if value == Inf: return "Infinity"
  if value == NegInf: return "-Infinity"
  let text = $value                       # shortest round-trip digits
  var negative = text.startsWith('-')
  var body = if negative: text[1 .. ^1] else: text
  var exponent = 0
  let mark = body.find('e')
  if mark >= 0:
    exponent = parseInt(body[mark + 1 .. ^1])
    body = body[0 ..< mark]
  let point = body.find('.')
  var digits = if point >= 0: body[0 ..< point] & body[point + 1 .. ^1] else: body
  var pointAt = (if point >= 0: point else: body.len) + exponent
  # Strip leading zeros, moving the point; strip trailing zeros.
  var leading = 0
  while leading < digits.len - 1 and digits[leading] == '0':
    inc leading
    dec pointAt
  digits = digits[leading .. ^1]
  while digits.len > 1 and digits[^1] == '0': digits.setLen(digits.len - 1)
  if digits == "0": return (if negative: "-0.0" else: "0.0")
  let decimalExponent = pointAt - 1
  result = if negative: "-" else: ""
  if decimalExponent >= -4 and decimalExponent < 16:
    if pointAt <= 0:
      result.add "0." & repeat('0', -pointAt) & digits
    elif pointAt >= digits.len:
      result.add digits & repeat('0', pointAt - digits.len) & ".0"
    else:
      result.add digits[0 ..< pointAt] & "." & digits[pointAt .. ^1]
  else:
    result.add digits[0]
    if digits.len > 1: result.add "." & digits[1 .. ^1]
    result.add "e" & (if decimalExponent < 0: "-" else: "+")
    result.add align($abs(decimalExponent), 2, '0')

proc addPythonString*(output: var string, text: string, ensureAscii = true) =
  ## A JSON string as Python's json.dumps writes it: with `ensureAscii`,
  ## every character outside space to tilde as \u escapes; without, only the
  ## control characters.
  output.add '"'
  for rune in text.runes:
    let code = int(rune)
    case code
    of 0x22: output.add "\\\""
    of 0x5c: output.add "\\\\"
    of 0x0a: output.add "\\n"
    of 0x0d: output.add "\\r"
    of 0x09: output.add "\\t"
    of 0x08: output.add "\\b"
    of 0x0c: output.add "\\f"
    else:
      if code < 0x20 or (ensureAscii and code > 0x7e):
        if code > 0xffff:
          let reduced = code - 0x10000
          output.add "\\u" & toHex(0xd800 + (reduced shr 10), 4).toLowerAscii
          output.add "\\u" & toHex(0xdc00 + (reduced and 0x3ff), 4).toLowerAscii
        else: output.add "\\u" & toHex(code, 4).toLowerAscii
      else: output.add rune.toUTF8
  output.add '"'

proc addPython(output: var string, node: JsonNode, indent, depth: int, sortKeys, ensureAscii: bool) =
  proc newline(output: var string, level: int) =
    output.add '\n'
    output.add repeat(' ', indent * level)
  case node.kind
  of JNull: output.add "null"
  of JBool: output.add(if node.getBool: "true" else: "false")
  of JInt: output.add $node.getBiggestInt
  of JFloat: output.add pythonFloat(node.getFloat)
  of JString:
    if node.getStr.startsWith(RawNumberMark): output.add node.getStr[RawNumberMark.len .. ^1]
    else: output.addPythonString(node.getStr, ensureAscii)
  of JArray:
    if node.len == 0:
      output.add "[]"
      return
    output.add '['
    for index, item in node.elems:
      if index > 0: output.add(if indent < 0: ", " else: ",")
      if indent >= 0: output.newline(depth + 1)
      output.addPython(item, indent, depth + 1, sortKeys, ensureAscii)
    if indent >= 0: output.newline(depth)
    output.add ']'
  of JObject:
    if node.len == 0:
      output.add "{}"
      return
    var keys: seq[string]
    for key in node.keys: keys.add key
    if sortKeys: keys.sort   # UTF-8 byte order is code point order, as Python sorts
    output.add '{'
    for index, key in keys:
      if index > 0: output.add(if indent < 0: ", " else: ",")
      if indent >= 0: output.newline(depth + 1)
      output.addPythonString(key, ensureAscii)
      output.add ": "
      output.addPython(node[key], indent, depth + 1, sortKeys, ensureAscii)
    if indent >= 0: output.newline(depth)
    output.add '}'

proc pythonDumps*(node: JsonNode, indent = -1, sortKeys = false, ensureAscii = true): string =
  result.addPython(node, indent, 0, sortKeys, ensureAscii)

proc sameFields*(a, b: JsonNode): bool =
  ## Python's equality of JSON values: objects compare without regard to key
  ## order, and an integer equals the float of the same value.
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}: return a.getFloat == b.getFloat
  if a.kind != b.kind: return false
  case a.kind
  of JObject:
    if a.len != b.len: return false
    for key, value in a:
      if not b.hasKey(key) or not sameFields(value, b[key]): return false
    true
  of JArray:
    if a.len != b.len: return false
    for index in 0 ..< a.len:
      if not sameFields(a[index], b[index]): return false
    true
  else: a == b

proc snprintf(buffer: cstring, size: csize_t, format: cstring): cint {.importc, header: "<stdio.h>", varargs.}

proc pythonG*(value: float): string =
  ## Python's `format(value, "g")`, which is C's `%g`.
  var buffer: array[64, char]
  discard snprintf(cast[cstring](buffer[0].addr), 64, "%g", value)
  $cast[cstring](buffer[0].addr)

proc truthy*(node: JsonNode): bool =
  ## Python's truth value of a JSON value: false for a missing value, null,
  ## false, zero and empty strings, arrays and objects.
  if node.isNil: return false
  case node.kind
  of JNull: false
  of JBool: node.getBool
  of JInt: node.getBiggestInt != 0
  of JFloat: node.getFloat != 0
  of JString: node.getStr.len > 0
  of JArray, JObject: node.len > 0
