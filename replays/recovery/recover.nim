## Exact-build recovery of one dragon's diagnostics through the inspection
## judge: the dragon's recorded observations replay through its registered build, each
## turn's gizmo records are validated, and the dragon stays reliable only while
## its actions and sonar match the recording. Which build ran is the caller's
## word (replays/viewer/recovery/serve.nim); the registry's hashes pin the
## artifact, and the builds announce no identity during play.

import std/[json, os, osproc, posix, sets, streams, strutils, tables, times]
import brain, gizmos, state

const
  InspectionTimeout = 120   ## seconds one dragon's inspection may take
  ## The line a judge with the inspection server writes first
  ## (zig_judge/src/inspection.zig); the client and judge ship as one build.
  ServerGreeting = "inspection-server 1"

type
  Sample* = object
    ## One recorded decision: the dragon, its round, the blocks it was sent,
    ## and the action the recording shows.
    dragon*: int32
    round*: int32
    team*: char
    init*, observation*: string
    action*: string

  RecoveredTurn* = object
    gizmos*: seq[JsonNode]
    ## The kept records as the bot emitted them, retained ones still as their
    ## changes: what the viewer holds and expands itself.
    emitted*: seq[JsonNode]
    errors*: seq[string]
    rejectedSlots*: HashSet[string]
    inputProtocol*, outputProtocol*: int
    ## This turn's rebuilt action and sonar match the replay's; `reliable`
    ## also needs every earlier turn to have matched.
    matches*: bool
    reliable*: bool
    ## The bot showed its state from its memory this turn, whether or not it
    ## was captured (state.nim).
    offersState*: bool
    ## The turn played with diagnostics on (zig_judge's `traced`).
    traced*: bool

  ## Called with each turn as soon as it is recovered, in the dragon's order.
  TurnCallback* = proc (sample: Sample, turn: RecoveredTurn) {.closure.}

  InspectionServer = object
    process: Process
    input: Stream
    output: Stream
    errors: string      ## the file holding the judge's standard error
    busy: bool          ## answering an inspection

  ## One dragon's inspection in flight on a judge server, or on a worker
  ## resumed from a checkpoint (`serving` nil), which replies on its own FIFO.
  ## `advance` takes whatever the judge has written; `done` once every record
  ## has arrived.
  Inspection* = ref object
    serving: ref InspectionServer
    directory: string
    records: cint       ## the response FIFO, read without blocking
    replies: cint       ## a resumed worker's reply FIFO, -1 for a server's
    worker: Pid         ## the resumed worker, once it has said
    replied: string     ## a resumed worker's reply so far
    pending: string
    count, observations: int
    onRecord: proc (record: JsonNode) {.closure.}
    deadline: float     ## when silence from the judge times the inspection out
    done*: bool

## Each build's judge servers, idle or busy; several run at once when several
## dragons of one build are recovered together.
var servers: Table[string, seq[ref InspectionServer]]
var inspections = 0

proc stopServers*(kill = false) =
  ## End every judge server; `kill` ends one still answering a request that
  ## was abandoned, rather than waiting for it.
  for pool in servers.mvalues:
    for server in pool:
      server.input.close()
      if kill: server.process.kill()
      discard server.process.waitForExit(10_000)
      server.process.close()
      removeFile(server.errors)
  servers.clear()

proc judgeError(serving: ref InspectionServer, what: string, ending = false): ref IOError =
  ## What went wrong, with the judge's standard error. A judge that died of a
  ## signal on its own is reported as killed (SIGKILL usually means the host
  ## ran out of memory), apart from one this client stopped. An `ending` judge
  ## closed its output, so it gets a moment to exit before being stopped.
  if ending: discard serving.process.waitForExit(10_000)
  let exited = not serving.process.running
  if not exited: serving.process.kill()
  let code = serving.process.waitForExit()
  let status =
    if not exited: "stopped the judge"
    elif code > 128: "the judge was killed by signal " & $(code - 128)
    else: "judge exit " & $code
  var detail = ""
  try: detail = readFile(serving.errors).strip
  except IOError: discard
  if detail.len > 2000: detail = detail[^2000 .. ^1]
  newException(IOError, what & " (" & status & "): " & detail)

proc readReply(serving: ref InspectionServer, what: string): string =
  var ready: TFdSet
  FD_ZERO(ready)
  let handle = serving.process.outputHandle
  FD_SET(cint(handle), ready)
  # Linux's select leaves the remaining time in `timeout`, so an interrupted
  # wait resumes rather than restarting.
  var timeout = Timeval(tv_sec: posix.Time(InspectionTimeout), tv_usec: 0)
  while true:
    let waiting = select(cint(handle) + 1, addr ready, nil, nil, addr timeout)
    if waiting > 0: break
    if waiting == 0: raise judgeError(serving, what & " timed out")
    if errno != EINTR: raise judgeError(serving, what & ": " & $strerror(errno))
    FD_ZERO(ready)
    FD_SET(cint(handle), ready)
  if not serving.output.readLine(result): raise judgeError(serving, what & ": the judge exited", ending = true)
  result = result.strip

proc server(judge, wasm: string): ref InspectionServer =
  ## An idle `loong-judge --inspect -` for this build, started if every one
  ## running is busy; a judge without the server mode is refused.
  var pool = servers.mgetOrPut(wasm, @[])
  for index in countdown(pool.high, 0):
    if not pool[index].process.running:
      pool[index].process.close()
      removeFile(pool[index].errors)
      pool.delete(index)
  servers[wasm] = pool
  for serving in pool:
    if not serving.busy:
      serving.busy = true
      return serving
  let errors = getTempDir() / "loong-inspection-server-" & $getCurrentProcessId() & "-" &
    $inspections & "-" & $pool.len & ".stderr"
  let process = startProcess("/bin/sh", args = ["-c", "exec \"$0\" --inspect - --a \"$1\" 2>\"$2\"",
    judge, wasm, errors], options = {})
  result = (ref InspectionServer)(process: process, input: process.inputStream,
    output: process.outputStream, errors: errors, busy: true)
  servers[wasm].add result
  if result.readReply("The judge did not start its inspection server; a judge built before it needs rebuilding") != ServerGreeting:
    raise judgeError(result, "The judge has no inspection server; rebuild it")

proc serverPids*(): seq[Pid] =
  ## The judge servers' processes, for measuring what they hold.
  for pool in servers.values:
    for serving in pool: result.add Pid(serving.process.processID)

proc release(inspection: Inspection) =
  ## Free the FIFOs and hand the server back to its pool.
  if inspection.records >= 0: discard posix.close(inspection.records)
  inspection.records = -1
  if inspection.replies >= 0: discard posix.close(inspection.replies)
  inspection.replies = -1
  removeDir(inspection.directory)
  if inspection.serving != nil: inspection.serving.busy = false

proc fifo(path: string): cint =
  ## A FIFO opened read-write, so it never blocks and never reads end-of-file
  ## before its writer opens it, and close-on-exec, so no judge inherits it
  ## and one whose client has gone gets an error writing to it rather than
  ## waiting for a reader forever.
  if mkfifo(path.cstring, 0o600) != 0: raise newException(IOError, "mkfifo: " & $strerror(errno))
  result = posix.open(path.cstring, O_RDWR or O_NONBLOCK or O_CLOEXEC)
  if result < 0: raise newException(IOError, "open " & path & ": " & $strerror(errno))

proc startInspection*(judge, wasm: string, request: JsonNode, observations: int,
    onRecord: proc (record: JsonNode) {.closure.}): Inspection =
  ## Send one dragon's inspection to an idle server of its build, each record
  ## handed on as `advance` reads it: the response path is a FIFO, which the
  ## judge fills one unbuffered record per observation.
  inc inspections
  let directory = getTempDir() / "loong-inspection-" & $getCurrentProcessId() & "-" & $inspections
  createDir(directory)
  writeFile(directory / "request.json", $request)
  # The judge's reply says when every record is written.
  let records = fifo(directory / "response.fifo")
  let serving = server(judge, wasm)
  serving.input.write(directory / "request.json" & "\t" & directory / "response.fifo" & "\n")
  serving.input.flush()
  Inspection(serving: serving, directory: directory, records: records, replies: -1, count: 0,
    observations: observations, onRecord: onRecord, deadline: epochTime() + InspectionTimeout)

proc resumeInspection(checkpoint: string, request: JsonNode, observations: int,
    onRecord: proc (record: JsonNode) {.closure.}): Inspection =
  ## Send the rest of one dragon's inspection to a checkpoint the judge left,
  ## which answers it in a worker of its own, each record handed on as
  ## `advance` reads it. Fails when the checkpoint has gone.
  inc inspections
  let directory = getTempDir() / "loong-inspection-" & $getCurrentProcessId() & "-" & $inspections
  createDir(directory)
  try:
    writeFile(directory / "request.json", $request)
    let records = fifo(directory / "response.fifo")
    let replies = fifo(directory / "reply.fifo")
    result = Inspection(directory: directory, records: records, replies: replies, count: 0,
      observations: observations, onRecord: onRecord, deadline: epochTime() + InspectionTimeout)
    # A checkpoint holds its FIFO open, so opening it without blocking fails
    # only once the checkpoint has gone.
    let control = posix.open(checkpoint.cstring, O_WRONLY or O_NONBLOCK or O_CLOEXEC)
    if control < 0: raise newException(IOError, "checkpoint " & checkpoint & ": " & $strerror(errno))
    let line = directory / "request.json" & "\t" & directory / "response.fifo" & "\t" &
      directory / "reply.fifo" & "\n"
    let wrote = posix.write(control, line.cstring, line.len)
    discard posix.close(control)
    if wrote != line.len: raise newException(IOError, "checkpoint " & checkpoint & ": the request didn't fit")
  except CatchableError:
    if result != nil: result.release()
    else: removeDir(directory)
    raise

proc handles*(inspection: Inspection): array[2, cint] =
  ## The FIFO and the judge's reply stream, for a caller's `select`.
  [inspection.records, if inspection.serving != nil: cint(inspection.serving.process.outputHandle)
    else: inspection.replies]

proc resumedReply(inspection: Inspection): string =
  ## A resumed worker's verdict once it has written one, else "". Its first
  ## line names the worker.
  var buffer: array[256, char]
  while true:
    let got = posix.read(inspection.replies, addr buffer[0], buffer.len)
    if got <= 0: break
    for index in 0 ..< got: inspection.replied.add buffer[index]
  while true:
    let newline = inspection.replied.find('\n')
    if newline < 0: return ""
    let line = inspection.replied[0 ..< newline].strip
    inspection.replied = inspection.replied[newline + 1 .. ^1]
    if line.startsWith("pid "): inspection.worker = Pid(parseInt(line[4 .. ^1]))
    else: return line

proc abandon*(inspection: Inspection) =
  ## Stop an inspection nobody wants any more. Its judge server or resumed
  ## worker would answer every observation regardless, so it is killed; the
  ## pool starts another server when one is needed, and a checkpoint stays.
  if inspection.serving != nil:
    inspection.serving.process.kill()
    discard inspection.serving.process.waitForExit()
  else:
    discard inspection.resumedReply()
    if inspection.worker > 0: discard posix.kill(inspection.worker, SIGKILL)
  inspection.release()

proc advance*(inspection: Inspection) =
  ## Take the records the judge has written, and finish once it replies. An
  ## inspection that fails is released before the error is raised.
  try:
    var buffer: array[65536, char]
    var progressed = false
    proc drain() =
      while true:
        let got = posix.read(inspection.records, addr buffer[0], buffer.len)
        if got <= 0: break
        progressed = true
        let size = inspection.pending.len
        inspection.pending.setLen(size + got)
        copyMem(addr inspection.pending[size], addr buffer[0], got)
      var start = 0
      while true:
        let newline = inspection.pending.find('\n', start)
        if newline < 0: break
        inspection.onRecord(parseJson(inspection.pending[start ..< newline]))
        inc inspection.count
        start = newline + 1
      inspection.pending = inspection.pending[start .. ^1]
    drain()
    var reply = ""
    if inspection.serving == nil:
      reply = inspection.resumedReply()
    else:
      let replies = cint(inspection.serving.process.outputHandle)
      var ready: TFdSet
      FD_ZERO(ready)
      FD_SET(replies, ready)
      var now = Timeval(tv_sec: posix.Time(0), tv_usec: 0)
      if select(replies + 1, addr ready, nil, nil, addr now) > 0:
        if not inspection.serving.output.readLine(reply):
          raise judgeError(inspection.serving, "Inspection: the judge exited", ending = true)
        reply = reply.strip
    if reply.len > 0:
      drain()
      if reply != "ok":
        if inspection.serving == nil: raise newException(IOError, "Inspection resumed from a checkpoint replied " & reply)
        raise judgeError(inspection.serving, "Inspection replied " & reply)
      if inspection.count != inspection.observations:
        raise newException(ValueError, "Inspection did not return every observation")
      inspection.done = true
      inspection.release()
      return
    if progressed: inspection.deadline = epochTime() + InspectionTimeout
    elif epochTime() > inspection.deadline:
      if inspection.serving == nil: raise newException(IOError, "Inspection resumed from a checkpoint timed out")
      raise judgeError(inspection.serving, "Inspection timed out")
  except CatchableError:
    inspection.release()
    raise

proc wait*(inspection: Inspection) =
  ## Advance until the inspection is done, blocking between records.
  while not inspection.done:
    let fds = inspection.handles
    var ready: TFdSet
    FD_ZERO(ready)
    for fd in fds: FD_SET(fd, ready)
    var timeout = Timeval(tv_sec: posix.Time(1), tv_usec: 0)
    discard select(max(fds[0], fds[1]) + 1, addr ready, nil, nil, addr timeout)
    inspection.advance()

proc observationBlock*(sample: Sample, protocol: int): string =
  ## The reconstructed input in the bot's negotiated protocol version.
  var text = sample.observation.multiReplace(("FACING ", "DIR "), ("SONAR ", "NUM_MSGS "),
    ("DRAGONS ", "DRAGON_BODIES "))
  if protocol >= 3: return text
  var lines = text.splitLines
  if lines.len > 0 and lines[^1] == "": lines.setLen(lines.len - 1)
  var header = -1
  for index, line in lines:
    if line.startsWith("NUM_MSGS "):
      header = index
      break
  let count = parseInt(lines[header].split()[1])
  var messages: seq[string]
  for line in lines[header + 1 .. header + count]:
    if parseBiggestUInt(line) < (1'u64 shl 32): messages.add line
  var rebuilt = lines[0 ..< header] & @["NUM_MSGS " & $messages.len] & messages & lines[header + 1 + count .. ^1]
  var kept: seq[string]
  for line in rebuilt:
    if not line.startsWith("ECHOES "): kept.add line
  kept.join("\n") & "\n"

proc responseAction(output: string): string =
  result = "SUICIDE"
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 2 and fields[0] == "MOVE" and fields[1].len > 0 and fields[1].allCharsInSet({'N', 'E', 'S', 'W'}):
      result = "MOVE " & fields[1]
    elif fields.len == 2 and fields[0] == "SPLIT":
      try: result = "SPLIT " & $parseInt(fields[1].replace("_", ""))
      except ValueError: discard

proc responseSonar(output, facing: string): Table[string, uint64] =
  for line in output.splitLines:
    var fields = line.splitWhitespace
    if fields.len == 0 or fields[0] != "SONAR": continue
    var limit = high(uint64)
    var wide = true
    if fields.len == 2:
      fields = @["SONAR", facing, fields[1]]
      wide = false
    if fields.len == 3 and fields[1] in ["N", "E", "S", "W"]:
      try:
        let value = parseBiggestUInt(fields[2])
        if wide or value < (1'u64 shl 32): result[fields[1]] = value
      except ValueError: discard
    discard limit

proc keptAsEmitted(emitted, kept: seq[JsonNode]): seq[JsonNode] =
  ## The emitted records that survived pruning, in order, retained ones still as
  ## changes. A retained record survives when its expanded snapshot did.
  var keptRecords: HashSet[pointer]
  var keptRetained: HashSet[(string, string)]
  for record in kept:
    keptRecords.incl cast[pointer](record)
    if truthy(record{"retain"}): keptRetained.incl (record["kind"].getStr, record["label"].getStr)
  for record in emitted:
    if (if truthy(record{"retain"}): (record["kind"].getStr, record["label"].getStr) in keptRetained
        else: cast[pointer](record) in keptRecords):
      result.add record

proc inspectionArtifact*(directory: string, manifest: JsonNode): tuple[wasm: string, marked: bool] =
  ## What inspects a registered build: a build with runtime diagnostics is its
  ## own judge artifact, started with the LOONG_INSPECT marker
  ## (runtime/gizmos.h); an older build has a separate inspection
  ## artifact. ("", false) when it has neither.
  if manifest{"settings"}{"diagnostics"}.getStr == "runtime": return (directory / "judge.wasm", true)
  if manifest{"extra_artifacts"} != nil and manifest["extra_artifacts"].hasKey("inspection.wasm"):
    return (directory / "inspection.wasm", false)
  ("", false)

type
  CheckpointAt* = object
    ## A checkpoint for the judge to leave after the sample at `index`, its
    ## FIFO at `path`.
    index*: int
    path*: string

proc requested(checkpoints: openArray[CheckpointAt], start, played: int): JsonNode =
  ## The checkpoints among samples `start` ..< `played`, by their index there.
  result = newJArray()
  for checkpoint in checkpoints:
    if checkpoint.index >= start and checkpoint.index < played:
      result.add %*{"index": checkpoint.index - start, "path": checkpoint.path}

proc follower(samples: seq[Sample], start, area: int, sonarOutputs: Table[(int32, int32), seq[uint64]],
    protocol: int, diverged: bool, onTurn: TurnCallback): proc (record: JsonNode) {.closure.} =
  ## Each inspection record in turn from sample `start`, whose input protocol
  ## is `protocol` and which follows a divergence when `diverged`: its records
  ## validated, its state and Brain rendered, its action and sonar checked
  ## against the replay, and the turn handed to `onTurn`.
  var retained: Table[(string, string), JsonNode]
  var diverged = diverged
  var protocol = protocol
  var image: Image                 # the state at each turn.s start
  var ending = Image(ending: true) # what each turn decided, at its end
  var index = start
  result = proc (record: JsonNode) =
    let sample = samples[index]
    inc index
    let inputProtocol = protocol
    let output = record["reply"].getStr & record["annotations"].getStr
    let failed = record{"failure"} != nil and record["failure"].kind != JNull
    var primitives, stubs: seq[JsonNode]
    var errors: seq[string]
    if failed: errors.add "The bot failed this turn: " & record["failure"].getStr
    for line in output.splitLines:
      try:
        if line.startsWith("LOG " & GizmoPrefix):
          if primitives.len >= MaxGizmos: raise newException(ValueError, "More than 1024 primitives in one turn")
          let parsed = parseJson(line[4 + GizmoPrefix.len .. ^1])
          validatePrimitive(parsed, area)
          primitives.add parsed
      except ValueError, KeyError:
        if line.startsWith("LOG " & GizmoPrefix):
          let stub = rejectedStub(line[4 + GizmoPrefix.len .. ^1])
          errors.add "Rejected " & $stub{"label"} & ": " & getCurrentExceptionMsg()
          stubs.add stub
        else: errors.add getCurrentExceptionMsg()
    # The state the bot showed from its memory, as records like its own
    # (state.nim), and the Brain rebuilt from what it decided (brain.nim).
    if record{"state"} != nil:
      try:
        image.update(record["state"])
        if record{"trace"} != nil: ending.update(record["trace"])
        let rendered = brain.render(image, ending, int(sample.round), area, primitives)
        for shown in rendered: validatePrimitive(shown, area)
        if rendered.len > 0:
          # The Brain root grew by the rendered nodes.
          for primitive in primitives:
            if primitive{"slot"} == %"brain": validatePrimitive(primitive, area)
          primitives.add rendered
        # The Memory slot has one root: a bot's own goes first, and the
        # state sits beneath it.
        var root = ""
        for primitive in primitives:
          if primitive{"slot"} == %"memory": root = primitive{"id"}.getStr
        for shown in image.records(area):
          if root.len > 0 and shown{"slot"} != nil:
            shown.delete("slot")
            shown["parent"] = %root
          validatePrimitive(shown, area)
          primitives.add shown
      except ValueError, KeyError:
        errors.add "State: " & getCurrentExceptionMsg()
    var rejected: HashSet[string]
    let emitted = primitives
    try:
      primitives = expandRetained(primitives, retained)
      var pruned: seq[string]
      (primitives, pruned, rejected) = pruneHierarchy(primitives, stubs)
      errors.add pruned
    except ValueError:
      errors.add getCurrentExceptionMsg()
      primitives = @[]
      rejected = ["brain", "memory"].toHashSet
      retained.clear()
    let recorded = sample.action
    var matches = responseAction(output) == recorded and not failed
    let key = (sample.dragon, sample.round)
    if key in sonarOutputs:
      var facing = ""
      for line in sample.observation.splitLines:
        if line.startsWith("FACING "):
          facing = line.splitWhitespace[1]
          break
      var sent: CountTable[uint64]
      for value in responseSonar(output, facing).values: sent.inc value
      var observed: CountTable[uint64]
      for value in sonarOutputs[key]: observed.inc value
      for value, count in observed:
        if count > sent.getOrDefault(value): matches = false
    for line in output.splitLines:
      if line.strip == "PROTOCOL 3": protocol = 3
    diverged = diverged or not matches
    let turn = RecoveredTurn(gizmos: primitives, emitted: keptAsEmitted(emitted, primitives),
      errors: errors, rejectedSlots: rejected, inputProtocol: inputProtocol,
      outputProtocol: protocol, matches: matches, reliable: not diverged,
      offersState: record{"state"} != nil or record{"state_offered"}.getBool,
      traced: record{"traced"}.getBool(true))
    onTurn(sample, turn)

proc startDiagnostics*(samples: seq[Sample], judge, wasm: string, marked: bool, area: int,
    sonarOutputs: Table[(int32, int32), seq[uint64]], initialProtocol: int,
    onTurn: TurnCallback, showState = false, loudFrom = 0'i32,
    loudUntil = high(int32), stopAfter = high(int32), checkpoints: openArray[CheckpointAt] = [],
    owner = 0): Inspection =
  ## Start one dragon's recovery: each turn's validated records and whether
  ## the dragon is still reliable go to `onTurn` as `advance` reads them.
  ## `marked` starts the bot with LOONG_INSPECT, which turns its diagnostics on.
  ## `showState` has the judge capture the state the bot shows from its memory,
  ## which becomes records beside its own (state.nim). Turns outside rounds
  ## `loudFrom` .. `loudUntil` play with the bot's diagnostics off where it
  ## lets the judge switch them (zig_judge's `loud_from` and `loud_until`):
  ## their actions are still checked, and they carry only the bot's summary.
  ## Turns after round `stopAfter` aren't played. The judge leaves each of
  ## `checkpoints` after its sample if that turn was untraced, reparented to
  ## `owner`, a child subreaper (zig_judge's inspection.zig).
  var observations = newJArray()
  # The first and last observations wanted with diagnostics, and how many
  # are played.
  var (loud, last) = (samples.len, -1)
  var played = samples.len
  for index, sample in samples:
    if sample.round > stopAfter:
      played = index
      break
    observations.add %*{"v1": observationBlock(sample, 1), "v3": observationBlock(sample, 3)}
    if sample.round >= loudFrom and loud == samples.len: loud = index
    if sample.round <= loudUntil: last = index
  let request = %*{"init": (if marked: "LOONG_INSPECT\n" else: "") & samples[0].init,
    "initial_protocol": initialProtocol, "state": showState,
    "name": samples[0].dragon, "loud_from": (if last < 0: samples.len else: loud), "loud_until": max(last, 0),
    "checkpoints": requested(checkpoints, 0, played), "owner": owner, "observations": observations}
  startInspection(judge, wasm, request, played,
    follower(samples, 0, area, sonarOutputs, initialProtocol, false, onTurn))

proc resumeDiagnostics*(samples: seq[Sample], start: int, checkpoint: string, protocol: int,
    diverged: bool, area: int, sonarOutputs: Table[(int32, int32), seq[uint64]],
    onTurn: TurnCallback, showState = false, loudFrom = 0'i32, loudUntil = high(int32),
    stopAfter = high(int32), checkpoints: openArray[CheckpointAt] = []): Inspection =
  ## Resume one dragon's recovery at sample `start` from the checkpoint the
  ## judge left after the sample before it, as `startDiagnostics` starts one:
  ## `protocol` is that turn's output protocol, and `diverged` whether the
  ## dragon had diverged by then. Fails when the checkpoint has gone.
  var observations = newJArray()
  var (loud, last) = (-1, -1)
  var played = samples.len
  for index in start ..< samples.len:
    let sample = samples[index]
    if sample.round > stopAfter:
      played = index
      break
    observations.add %*{"v1": observationBlock(sample, 1), "v3": observationBlock(sample, 3)}
    if sample.round >= loudFrom and loud < 0: loud = index - start
    if sample.round <= loudUntil: last = index - start
  let count = played - start
  let request = %*{"state": showState, "loud_from": (if last < 0 or loud < 0: count else: loud),
    "loud_until": max(last, 0), "checkpoints": requested(checkpoints, start, played),
    "observations": observations}
  resumeInspection(checkpoint, request, count,
    follower(samples, start, area, sonarOutputs, protocol, diverged, onTurn))

proc recoverDiagnostics*(samples: seq[Sample], judge, wasm: string, marked: bool, area: int,
    sonarOutputs: Table[(int32, int32), seq[uint64]], initialProtocol: int,
    onTurn: TurnCallback = nil): Table[(int32, int32), RecoveredTurn] =
  ## Each turn's validated records and whether the dragon is still reliable,
  ## handed to `onTurn` as each is recovered, waiting until all are.
  var recovered: Table[(int32, int32), RecoveredTurn]
  startDiagnostics(samples, judge, wasm, marked, area, sonarOutputs, initialProtocol,
    proc (sample: Sample, turn: RecoveredTurn) =
      recovered[(sample.dragon, sample.round)] = turn
      if onTurn != nil: onTurn(sample, turn)).wait()
  recovered
