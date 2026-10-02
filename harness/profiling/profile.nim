## Decode compiler name/remark sidecars and join them with a judge points TSV.
import std/[algorithm, os, strutils, tables]

proc unsignedLeb(bytes: string, at: var int): uint64 =
  var shift = 0
  while at < bytes.len and shift < 64:
    let value = uint8(bytes[at]); inc at
    result = result or ((uint64(value) and 127) shl shift)
    if value < 128: return
    shift += 7
  raise newException(ValueError, "Malformed WASM integer")

proc wasmNames(input, output: string) =
  let bytes = readFile(input)
  if not bytes.startsWith("\0asm\1\0\0\0"): raise newException(ValueError, "Not a WASM module")
  var at = 8
  var text = ""
  while at < bytes.len:
    let section = uint8(bytes[at]); inc at
    let size = int(unsignedLeb(bytes, at)); let finish = at + size
    if finish > bytes.len: raise newException(ValueError, "Malformed WASM section")
    if section == 0:
      let length = int(unsignedLeb(bytes, at))
      if at + length > finish: raise newException(ValueError, "Malformed custom section")
      let name = bytes[at ..< at + length]; at += length
      if name == "name":
        while at < finish:
          let kind = uint8(bytes[at]); inc at
          let length = int(unsignedLeb(bytes, at)); let ending = at + length
          if ending > finish: raise newException(ValueError, "Malformed name subsection")
          if kind == 1:
            let count = int(unsignedLeb(bytes, at))
            for index in 0 ..< count:
              let function = unsignedLeb(bytes, at)
              let length = int(unsignedLeb(bytes, at))
              if at + length > ending: raise newException(ValueError, "Malformed function name")
              text.add $function & "\t" & bytes[at ..< at + length].replace('\t', ' ').replace('\n',
                  ' ') & "\n"
              at += length
          at = ending
    at = finish
  writeFile(output, text)

proc unquote(value: string): string = value.strip.strip(chars = {'\'', '"'})

proc remarks(inputs: seq[string], output: string) =
  var rows = "function\tpass\tkind\tname\twhere\tmessage\n"
  for input in inputs:
    var fields: Table[string, string]
    var args = false
    proc flush() =
      if fields.len == 0: return
      for index, key in ["Function", "Pass", "Kind", "Name", "Where", "Message"]:
        if index > 0: rows.add '\t'
        rows.add fields.getOrDefault(key).replace('\t', ' ').replace('\n', ' ')
      rows.add '\n'
      fields.clear(); args = false
    for line in readFile(input).splitLines:
      if line.startsWith("--- !"):
        flush(); fields["Kind"] = line[5 .. ^1].strip
      elif line.startsWith("..."): flush()
      elif line.startsWith("Args:"): args = true
      elif line.startsWith("DebugLoc:"):
        let start = line.find("File:"); let ending = line.find(", Line:")
        if start >= 0 and ending > start:
          let after = ending + 7; let comma = line.find(',', after)
          fields["Where"] = line[start + 5 ..< ending].unquote & ":" & line[after ..< (if comma <
              0: line.len else: comma)].strip
      elif args and line.strip.startsWith("-"):
        let colon = line.find(':')
        if colon >= 0: fields.mgetOrPut("Message", "").add line[colon + 1 .. ^1].unquote
      else:
        let colon = line.find(':')
        if colon >= 0 and line[0 ..< colon] in ["Function", "Pass", "Name"]:
          fields[line[0 ..< colon]] = line[colon + 1 .. ^1].unquote
    flush()
  writeFile(output, rows)

proc joined(remarks, profile, team: string, top: int) =
  var byFunction: Table[string, seq[string]]
  for line in readFile(remarks).splitLines:
    let fields = line.split('\t')
    if fields.len == 6 and fields[0] != "function": byFunction.mgetOrPut(fields[0], @[]).add fields[
        2] & ": " & fields[5]
  var rows: seq[seq[string]]
  var header: seq[string]
  for line in readFile(profile).splitLines:
    let fields = line.split('\t')
    if header.len == 0: header = fields
    elif fields.len == header.len and fields[0] == team and fields[1].len > 0: rows.add fields
  rows.sort(proc(a, b: seq[string]): int = cmp(parseBiggestInt(b[^1]), parseBiggestInt(a[^1])))
  echo "function\tname\ttotal\tsimd\tremarks"
  let simd = header.find("simd")
  for row in rows[0 ..< min(top, rows.len)]:
    echo row[1], "\t", row[2], "\t", row[^1], "\t", (if simd >= 0: row[simd] else: ""), "\t",
        byFunction.getOrDefault(row[2]).join(" | ")

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args[0] == "--help":
    echo "loong-profile names NAMED.wasm OUTPUT.names"
    echo "loong-profile remarks OUTPUT.tsv INPUT.yaml..."
    echo "loong-profile join REMARKS.tsv PROFILE.tsv TEAM TOP"
    return
  case args[0]
  of "names":
    if args.len != 3: raise newException(ValueError, "names needs input and output")
    wasmNames(args[1], args[2])
  of "remarks":
    if args.len < 3: raise newException(ValueError, "remarks needs output and compiler records")
    remarks(args[2 .. ^1], args[1])
  of "join":
    if args.len != 5 or args[3] notin ["A", "B"] or parseInt(args[4]) < 1:
      raise newException(ValueError, "join needs remarks, profile, A|B and positive top count")
    joined(args[1], args[2], args[3], parseInt(args[4]))
  else: raise newException(ValueError, "Unknown profile command")
when isMainModule:
  try: main()
  except CatchableError as error: quit(error.msg, 2)
