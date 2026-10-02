## Restore a locally supplied replay with a supplied match seed and one uniquely
## compatible gap table. Recorded actions drive the other side; optional own
## code is resolved from the immutable build registry. Physical state must match.
import std/[os, osproc, streams, strutils, tables, tempfiles]
import map_variants
import ../gamedata/[board, capnp_replay, gzip_inflate, replay_board, sha256]
import ../replays/recovery/registry

type RecordedTurn = object
  round, dragon: int
  team: char
  reply: string

proc replayMessage(path: string): CapnpMessage =
  var packed = readFile(path)
  if packed.isGzip: packed = packed.gunzip
  result = readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))
  if result.uint32Field(result.root, 0) != 2:
    raise newException(ValueError, "Unsupported replay format version")

proc action(message: CapnpMessage, member: CapnpStruct): string =
  if not message.hasPointer(member, 0): return ""
  let value = message.structField(member, 0)
  case message.uint16Field(value, 0)
  of 0:
    result = "MOVE "
    let list = message.listField(value, 0)
    for index in 0 ..< list.count: result.add Directions[int(message.uint16Element(list, index))]
  of 1: result = "SPLIT " & $message.int32Field(value, 1)
  of 2: result = ""
  else: raise newException(ValueError, "Unsupported recorded action")

proc recordedTurns(message: CapnpMessage): seq[RecordedTurn] =
  let replay = message.root
  var state = initialBoard(message.textField(replay, 0), false)
  var rows: Table[(int, int), int]
  let events = message.listField(replay, 3)
  for index in 0 ..< events.count:
    let event = events.listStruct(index); let kind = message.eventKind(event)
    let member = message.structField(event, 0)
    if kind > 12: raise newException(ValueError, "Unsupported replay event " & $kind)
    if kind == 1:
      let dragon = int(message.int32Field(member, 0))
      if int32(dragon) notin state.dragons: raise newException(ValueError, "Turn of unknown dragon")
      rows[(int(state.round), dragon)] = result.len
      result.add RecordedTurn(round: int(state.round), dragon: dragon, team: state.dragons[int32(dragon)].team)
    elif kind == 4:
      let dragon = int(message.int32Field(member, 0))
      if (int(state.round), dragon) notin rows: raise newException(ValueError, "Action without recorded turn")
      result[rows[(int(state.round), dragon)]].reply = message.action(member)
    elif kind == 12:
      let dragon = message.int32Field(member, 0)
      if (int(state.round), int(dragon)) notin rows or dragon notin state.dragons:
        raise newException(ValueError, "Sonar without a living sender's turn")
      let sender = state.dragons[dragon]
      let origin = state.cellOf(message, message.structField(member, 0))
      let direction = if origin == sender.body[^1] and origin != sender.body[0]:
        Directions[(Directions.find(sender.directions[0]) + 2) mod 4]
        else: Directions[int(message.uint16Field(member, 2))]
      let wide = message.uint64Field(member, 2)
      let value = if wide != 0: wide else: uint64(message.uint32Field(member, 2))
      result[rows[(int(state.round), int(dragon))]].reply.add "|SONAR " & direction & " " & $value
    state.applyReplayEvent(message, event)

proc point(message: CapnpMessage, value: CapnpStruct): string =
  $message.int32Field(value, 0) & "," & $message.int32Field(value, 1)

proc stateEvents(message: CapnpMessage): seq[string] =
  let events = message.listField(message.root, 3)
  for index in 0 ..< events.count:
    let event = events.listStruct(index); let kind = message.eventKind(event)
    let value = message.structField(event, 0)
    if kind > 12: raise newException(ValueError, "Unsupported replay event " & $kind)
    if kind in [2, 5, 6, 7, 8]: continue # countdowns and observational output omitted by site
    var line = $kind & ":"
    case kind
    of 0, 1: line.add $message.int32Field(value, 0)
    of 3: line.add message.point(message.structField(value, 0)) & ":" & $message.boolField(value, 0)
    of 4: line.add $message.int32Field(value, 0) & ":" & message.action(value)
    of 9:
      line.add $message.int32Field(value, 0) & ":" & $message.uint16Field(value, 2) & ":" &
        message.point(message.structField(value, 0)) & ":" & message.point(message.structField(
            value, 1))
    of 10:
      line.add $message.int32Field(value, 0) & ":" & $message.int32Field(value, 1) & ":" &
        $message.uint16Field(value, 4) & ":" & $message.uint16Field(value, 5)
      for pointer in 0 .. 1:
        let body = message.listField(value, pointer); line.add ":"
        for index in 0 ..< body.count: line.add message.point(body.listStruct(index)) & ";"
    of 11: line.add $message.int32Field(value, 0) & ":" & $message.uint16Field(value, 2)
    of 12:
      let wide = message.uint64Field(value, 2)
      line.add $message.int32Field(value, 0) & ":" & $message.uint16Field(value, 2) & ":" &
        $(if wide != 0: wide else: uint64(message.uint32Field(value, 2))) & ":" &
        message.point(message.structField(value, 0)) & ":" & message.point(message.structField(
            value, 1)) & ":" &
        $message.uint16Field(value, 3) & ":" & $message.int32Field(value, 3) & ":" &
            $message.uint16Field(value, 12)
    else: discard
    result.add line

proc compareState(recorded, played: CapnpMessage) =
  let original = recorded.stateEvents; let regenerated = played.stateEvents
  if original != regenerated:
    for index in 0 ..< max(original.len, regenerated.len):
      let a = if index < original.len: original[index] else: "END"
      let b = if index < regenerated.len: regenerated[index] else: "END"
      if a != b: raise newException(ValueError, "State differs at event " & $index & ": " & a &
          " / " & b)
  let a = recorded.structField(recorded.root, 4); let b = played.structField(played.root, 4)
  for field in [0, 1, 2, 3]:
    if recorded.uint16Field(a, field) != played.uint16Field(b, field):
      raise newException(ValueError, "Regenerated game result differs")
  for side in 0 .. 1:
    let aa = recorded.structField(a, side); let bb = played.structField(b, side)
    for field in 0 .. 2:
      if recorded.int32Field(aa, field) != played.int32Field(bb, field):
        raise newException(ValueError, "Regenerated final standing differs")

proc main() =
  let arguments = commandLineParams()
  if arguments.len == 0 or arguments[0] in ["-h", "--help"]:
    echo "loong-regenerate --replay FILE --seed UINT64 --maps DIR [--variants DIR] --output FILE"
    echo "  [--engine WASM] [--build GUID --side A|B] [--registry DIR] [--judge FILE] [--python FILE]"
    echo "Offline only. Missing/ambiguous tables and any physical-state divergence are refused."
    return
  var options: Table[string, string]
  var at = 0
  while at < arguments.len:
    if at + 1 >= arguments.len or not arguments[at].startsWith("--"): raise newException(ValueError, "Expected --option VALUE")
    if arguments[at] notin ["--replay", "--seed", "--maps", "--variants", "--output", "--engine",
        "--build", "--side", "--registry", "--judge", "--python"]:
      raise newException(ValueError, "Unknown option " & arguments[at])
    options[arguments[at]] = arguments[at + 1]; at += 2
  proc required(name: string): string =
    if name notin options: raise newException(ValueError, "Missing " & name)
    options[name]
  let input = required("--replay"); let output = required("--output")
  if fileExists(output): raise newException(ValueError, "Output exists; choose a new path")
  let seed = parseSeed(required("--seed"))
  let restored = restoredMap(input, seed, @[required("--maps"), options.getOrDefault("--variants",
      getEnv("MAP_VARIANTS"))])
  let recorded = replayMessage(input); let turns = recorded.recordedTurns
  let root = getAppDir().parentDir.parentDir
  let python = options.getOrDefault("--python", getEnv("LOONG_PYTHON", "python3"))
  let adapter = root / "harness/engine_adapter.py"
  let engine = options.getOrDefault("--engine", execProcess(python, args = @[adapter, "--path"],
      options = {poUsePath}).strip)
  let work = createTempDir("loong-regenerate-", "")
  defer: removeDir(work)
  writeFile(work / "map.map", restored)
  let target = work / "game.replay"
  if "--build" in options:
    let side = required("--side")
    if side notin ["A", "B"]: raise newException(ValueError, "Side must be A or B")
    let (directory, _) = resolveBuild(options.getOrDefault("--registry", root / "build/registry"),
        options["--build"])
    var script = ""
    for turn in turns:
      if $turn.team != side: script.add $turn.round & "\t" & $turn.dragon & "\t" & turn.reply & "\n"
    writeFile(work / "opponent.tsv", script)
    let command = options.getOrDefault("--judge", root / "build/zig-judge/bin/loong-judge")
    let scriptOption = if side == "A": "--script-b" else: "--script-a"
    let played = execCmdEx(quoteShellCommand(@[command, "--engine", engine, "--timeout", "300",
      "run", "--sandbox",
      "--seed", $seed, scriptOption, work / "opponent.tsv", "-o", target, work / "map.map",
      directory / "judge.wasm", directory / "judge.wasm"]))
    if played.exitCode != 0: raise newException(ValueError, "Judge failed: " & played.output)
  else:
    let child = startProcess(python, args = @[adapter, work / "map.map", $seed, target, engine],
        options = {poUsePath, poParentStreams} - {poParentStreams})
    defer: child.close()
    var position = 0
    while true:
      let header = child.outputStream.readLine()
      if header == "DONE": break
      let fields = header.splitWhitespace
      if fields.len != 3 or fields[0] != "TURN":
        child.terminate(); raise newException(ValueError, "Engine adapter failed: " &
            child.errorStream.readAll())
      let dragon = parseInt(fields[1]); let length = parseInt(fields[2])
      let observation = child.outputStream.readStr(length)
      if observation.len != length or position >= turns.len or dragon != turns[position].dragon or
          not observation.startsWith("ROUND " & $turns[position].round & "\n"):
        child.terminate(); raise newException(ValueError, "Engine turn order differs from the recorded game")
      let reply = "PROTOCOL 3\n" & turns[position].reply.replace('|', '\n') & "\nENDTURN\n"
      child.inputStream.write($reply.len & "\n" & reply); child.inputStream.flush()
      inc position
    if child.waitForExit() != 0 or position != turns.len: raise newException(ValueError, "Engine failed or ended early")
  compareState(recorded, replayMessage(target))
  writeFile(output & ".partial", readFile(target)); moveFile(output & ".partial", output)
  writeFile(output.changeFileExt("regeneration.tsv"),
      "source_sha256\tengine_sha256\tseed\tturns\n" &
    sha256Hex(readFile(input)) & "\t" & sha256Hex(readFile(engine)) & "\t" & $seed & "\t" &
        $turns.len & "\n")
  echo output

when isMainModule:
  try: main()
  except CatchableError as error: quit(error.msg, 2)
