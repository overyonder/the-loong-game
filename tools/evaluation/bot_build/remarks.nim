## What the judge clang's loop and SLP vectorisers did in each function of a
## registered build (`just vector-remarks`): one row per optimisation remark,
## joined with a points profile's costliest functions when one is given.

import std/[algorithm, os, osproc, sequtils, strformat, strutils, tables, tempfiles]
import ../paths
import judge_clang

type Remark = object
  function, pass, kind, name, where, message: string

proc unitRemarks(home, staged, unit: string, index: int): string =
  ## One unit's vectoriser optimisation record, compiled as a build compiles
  ## it with the record switched on.
  let work = createTempDir("remarks-", "", Root / "build/cache/judge-clang")
  defer: removeDir(work)
  createDir(work / "out")
  createDir(work / "tmp")
  var command = @[getEnv("LOONG_WASMER", Root / "build/toolkit/wasmer/bin/wasmer"), "run",
    "--volume", home / "root" & ":/", "--volume", staged & ":/src",
    "--volume", work / "out" & ":/out", "--volume", work / "tmp" & ":/tmp", "--cwd", "/src",
    "--env", "TERM=dumb", "--env", "PATH=/bin", "--env", "TMPDIR=/tmp", home / "clang.wasm", "--"]
  command.add DriverFlags
  command.add ["-fsave-optimization-record=yaml",
    "-foptimization-record-passes=loop-vectorize|slp-vectorizer",
    "-foptimization-record-file=/tmp/" & $index & ".yaml", "-c", "-o", "/tmp/" & $index & ".o"]
  command.add(if unit.endsWith(".c"): @["-xc", "-std=c17"] else: @["-xc++", "-std=c++20", "-stdlib=libc++"])
  command.add unit
  let (output, code) = execCmdEx(quoteShellCommand(command), options = {poStdErrToStdOut})
  if code != 0: raise newException(OSError, "compiling " & unit & "\n" & output)
  readFile(work / "tmp" / $index & ".yaml")

proc parseRemarks(text: string): seq[Remark] =
  ## The records of one optimisation record file: its `--- !Kind` documents.
  var documents: seq[string]
  var current = -1
  for line in text.split('\n'):
    if line.startsWith("--- !"):
      documents.add line[5 .. ^1] & "\n"
      current = documents.high
    elif current >= 0:
      documents[current].add line & "\n"
  for document in documents:
    let newline = document.find('\n')
    let body = document[newline + 1 .. ^1]
    var remark = Remark(kind: document[0 ..< newline].strip)
    for line in body.split('\n'):
      for field in ["Pass", "Name", "Function"]:
        if line.startsWith(field & ":"):
          let value = line[field.len + 1 .. ^1].strip(trailing = false)
          case field
          of "Pass": remark.pass = value
          of "Name": remark.name = value
          else: remark.function = value.strip(chars = {'\'', '"'})
    let location = body.find("DebugLoc:")
    if location >= 0:
      let tail = body[location + 9 .. ^1].strip(trailing = false)
      if tail.startsWith('{'):
        let inner = tail[1 .. ^1].strip(trailing = false)
        if inner.startsWith("File:"):
          var file = inner[5 .. ^1].strip(trailing = false)
          if file.startsWith('\''): file = file[1 .. ^1]
          let stop = file.find({'\'', ','})
          if stop >= 0:
            var rest = file[stop .. ^1]
            file = file[0 ..< stop]
            if rest.startsWith('\''): rest = rest[1 .. ^1]
            if rest.startsWith(','):
              rest = rest[1 .. ^1].strip(trailing = false)
              if rest.startsWith("Line:"):
                let digits = rest[5 .. ^1].strip(trailing = false)
                var count = 0
                while count < digits.len and digits[count].isDigit: inc count
                if count > 0: remark.where = file & ":" & digits[0 ..< count]
    let arguments = body.find("\nArgs:")
    if arguments >= 0:
      for line in body[arguments + 6 .. ^1].split('\n'):
        let item = line.strip(trailing = false)
        if not item.startsWith('-'): continue
        let entry = item[1 .. ^1].strip(trailing = false)
        var key = 0
        while key < entry.len and (entry[key].isAlphaNumeric or entry[key] == '_'): inc key
        if key == 0 or key >= entry.len or entry[key] != ':': continue
        remark.message.add entry[key + 1 .. ^1].strip.strip(chars = {'\'', '"'})
    result.add remark

proc readable(name: string): string =
  ## Nim's C names: the proc, then its module's path in ROT13 with Z between
  ## directories and 95 for an underscore, then a unique number.
  var start = name.find("__", 1)
  while start >= 1:
    let rest = name[start + 2 .. ^1]
    let underscore = rest.find('_')
    if underscore >= 1 and rest[0 ..< underscore].allCharsInSet(Letters + Digits) and
        rest.continuesWith("_u", underscore) and rest.len > underscore + 2 and
        rest[underscore + 2 .. ^1].allCharsInSet(Digits):
      var parts: seq[string]
      for part in rest[0 ..< underscore].split('Z'):
        var decoded = ""
        for character in part:
          decoded.add(case character
            of 'a' .. 'z': char((ord(character) - ord('a') + 13) mod 26 + ord('a'))
            of 'A' .. 'Z': char((ord(character) - ord('A') + 13) mod 26 + ord('A'))
            else: character)
        parts.add decoded.replace("95", "_")
      return parts.join("/") & "." & name[0 ..< start]
    start = name.find("__", start + 1)
  name

proc grouped(value: int): string =
  ## An integer with thousands separators, as Python's `{:,}`.
  let digits = $abs(value)
  for index, digit in digits:
    if index > 0 and (digits.len - index) mod 3 == 0: result.add ','
    result.add digit
  if value < 0: result = "-" & result

proc vectorRemarks*(guid, profile, team: string, top: int) =
  let staged = Registry / guid / "judge-source"
  let home = toolchainHome()
  let units = sources(staged)
  createDir(Root / "build/cache/judge-clang")
  var remarks: seq[Remark]
  for index, unit in units: remarks.add parseRemarks(unitRemarks(home, staged, unit, index))
  let output = Root / "build/profiling" / guid & ".remarks.tsv"
  createDir(output.parentDir)
  var table = "function\tpass\tkind\tname\twhere\tmessage\n"
  for remark in remarks:
    table.add [remark.function, remark.pass, remark.kind, remark.name, remark.where,
               remark.message].mapIt(it.replace("\t", " ")).join("\t") & "\n"
  writeFile(output, table)
  echo &"wrote {output.relativePath(Root)}: {remarks.len} remarks"
  if profile.len == 0: return
  var byFunction = initTable[string, seq[Remark]]()
  for remark in remarks: byFunction.mgetOrPut(remark.function, @[]).add remark
  let lines = readFile(profile).splitLines
  let header = lines[0].split('\t')
  var rows: seq[Table[string, string]]
  for line in lines[1 .. ^1]:
    if line.len == 0: continue
    var row = initTable[string, string]()
    let fields = line.split('\t')
    for index, value in fields:
      if index < header.len: row[header[index]] = value
    if row.getOrDefault("team") == team: rows.add row
  proc number(row: Table[string, string], key: string): int =
    let text = row.getOrDefault(key)
    if text.len == 0: 0 else: parseInt(text)
  var whole, simdTotal = 0
  for row in rows:
    whole += row.number("total")
    simdTotal += row.number("simd")
  echo &"\nteam {team}: {grouped(whole)} points, {simdTotal * 100 div max(whole, 1)}% in SIMD operators\n"
  for row in rows[0 ..< min(top, rows.len)]:
    let points = row.number("total")
    let simd = row.number("simd")
    let found = byFunction.getOrDefault(row.getOrDefault("name"))
    var passed, missed, slp = 0
    var reasons = initOrderedTable[(string, string), int]()
    for remark in found:
      if remark.pass == "loop-vectorize" and remark.name in ["Vectorized", "MissedDetails"]:
        if remark.kind == "Passed": inc passed
        elif remark.kind == "Missed": inc missed
      if remark.pass == "slp-vectorizer" and remark.kind == "Passed": inc slp
      if remark.pass == "loop-vectorize" and remark.kind.startsWith("Analysis"):
        reasons.mgetOrPut((remark.where, remark.message), 0) += 1
    let share = formatFloat(points.float * 100 / max(whole, 1).float, ffDecimal, 1).align(5)
    let name = readable(row.getOrDefault("name"))
    echo &"{share}%  {grouped(points):>14}  SIMD {simd * 100 div max(points, 1):>3}%  " &
      &"loops vectorised {passed}, scalar {missed}, SLP groups {slp}  " &
      (if name.len > 0: name else: row.getOrDefault("function"))
    var keys: seq[(string, string)]
    for key in reasons.keys: keys.add key
    keys.sort
    for key in keys:
      let count = reasons[key]
      echo "        " & key[0] & ": " & key[1] & (if count > 1: &" (x{count})" else: "")
