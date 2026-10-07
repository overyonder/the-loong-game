## The TOML our manifests use, read into a JSON tree: `bot.toml`,
## `library.toml` and `pool.toml`. Tables (`[a.b]`), bare or quoted keys,
## basic and literal strings, integers, floats, booleans and arrays of them,
## which may span lines. Anything else is refused with its line number.

import std/[json, strutils, unicode]

type TomlReader = object
  text: string
  at:   int
  line: int

proc fail(reader: TomlReader, message: string) {.noreturn.} =
  raise newException(ValueError, "TOML line " & $reader.line & ": " & message)

proc peek(reader: TomlReader): char =
  if reader.at < reader.text.len: reader.text[reader.at] else: '\0'

proc skipBlank(reader: var TomlReader, newlines: bool) =
  ## Spaces and tabs, comments, and with `newlines` line breaks too.
  while reader.at < reader.text.len:
    case reader.text[reader.at]
    of ' ', '\t', '\r': inc reader.at
    of '#':
      while reader.at < reader.text.len and reader.text[reader.at] != '\n': inc reader.at
    of '\n':
      if not newlines: return
      inc reader.line
      inc reader.at
    else: return

proc basicString(reader: var TomlReader): string =
  inc reader.at
  while true:
    if reader.at >= reader.text.len or reader.text[reader.at] == '\n':
      reader.fail "unterminated string"
    let character = reader.text[reader.at]
    inc reader.at
    case character
    of '"': return
    of '\\':
      let escape = reader.peek
      inc reader.at
      case escape
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of '"': result.add '"'
      of '\\': result.add '\\'
      of 'u', 'U':
        let width = if escape == 'u': 4 else: 8
        if reader.at + width > reader.text.len: reader.fail "short unicode escape"
        let code = parseHexInt(reader.text[reader.at ..< reader.at + width])
        reader.at += width
        result.add $Rune(code)
      else: reader.fail "unknown escape \\" & escape
    else: result.add character

proc literalString(reader: var TomlReader): string =
  inc reader.at
  let start = reader.at
  while reader.at < reader.text.len and reader.text[reader.at] notin {'\'', '\n'}: inc reader.at
  if reader.peek != '\'': reader.fail "unterminated literal string"
  result = reader.text[start ..< reader.at]
  inc reader.at

proc key(reader: var TomlReader): string =
  case reader.peek
  of '"': reader.basicString
  of '\'': reader.literalString
  else:
    let start = reader.at
    while reader.peek in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}: inc reader.at
    if reader.at == start: reader.fail "expected a key"
    reader.text[start ..< reader.at]

proc keyPath(reader: var TomlReader): seq[string] =
  while true:
    reader.skipBlank(false)
    result.add reader.key
    reader.skipBlank(false)
    if reader.peek != '.': return
    inc reader.at

proc value(reader: var TomlReader): JsonNode =
  case reader.peek
  of '"': result = %reader.basicString
  of '\'': result = %reader.literalString
  of '[':
    inc reader.at
    result = newJArray()
    while true:
      reader.skipBlank(true)
      if reader.peek == ']':
        inc reader.at
        return
      result.add reader.value
      reader.skipBlank(true)
      case reader.peek
      of ',': inc reader.at
      of ']': discard
      else: reader.fail "expected , or ] in an array"
  else:
    let start = reader.at
    while reader.peek notin {'\0', '\n', ',', ']', '#', ' ', '\t', '\r'}: inc reader.at
    let word = reader.text[start ..< reader.at].replace("_", "")
    if word == "true": return %true
    if word == "false": return %false
    try:
      result = if word.contains({'.', 'e', 'E'}): %parseFloat(word) else: %parseBiggestInt(word)
    except ValueError: reader.fail "unsupported value " & word

proc table(root: JsonNode, path: seq[string], reader: TomlReader): JsonNode =
  result = root
  for part in path:
    if not result.hasKey(part): result[part] = newJObject()
    result = result[part]
    if result.kind != JObject: reader.fail part & " is not a table"

proc parseToml*(text: string): JsonNode =
  ## The document as a JSON object, keys in the order written.
  result = newJObject()
  var reader = TomlReader(text: text, line: 1)
  var current = result
  while true:
    reader.skipBlank(true)
    if reader.at >= text.len: return
    if reader.peek == '[':
      inc reader.at
      if reader.peek == '[': reader.fail "arrays of tables are unsupported"
      let path = reader.keyPath
      if reader.peek != ']': reader.fail "expected ] after a table name"
      inc reader.at
      current = table(result, path, reader)
    else:
      let path = reader.keyPath
      if reader.peek != '=': reader.fail "expected = after a key"
      inc reader.at
      reader.skipBlank(false)
      let parent = table(current, path[0 ..< ^1], reader)
      if parent.hasKey(path[^1]): reader.fail "duplicate key " & path[^1]
      parent[path[^1]] = reader.value
    reader.skipBlank(false)
    if reader.peek notin {'\n', '\0'}: reader.fail "unexpected text after a value"

proc readToml*(path: string): JsonNode = parseToml(readFile(path))
