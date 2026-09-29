## `loong-recover`: the viewer's recovery, over pipes. It writes nothing to disk
## but the replay's game columns when they aren't cached yet. The viewer (replays/viewer) starts it
## beside itself and reads its standard output; closing its standard input
## ends it and the judge servers it started.
##
##   loong-recover --replay R --game G.cols --registry DIR --judge PATH [--focus D]
##     [--workers N] [--seat SIDE GUID BOT]... [--build GUID [--build-team A|B]]
##
## Each team's build comes from the caller, first found: `--seat` (`just viewer
## --seat SIDE GUID`), then `--build`. A GUID the replay itself recorded is only
## the fallback, for replays made while builds announced one. Each dragon's
## status says where its build came from; recovery checks each rebuilt action
## against the replay, and a divergence marks that turn and every later one
## unreliable.
##
## It writes, one message a line:
##   dragon ID TEAM RECOVERABLE GUID VARIANT STATUS   for every dragon, first
##   turn ROW BYTES, then BYTES of the turn's record (JSON, diagnostics.md)
##     and a newline
##   breakdown ROW JSON                                a turn's Brain breakdown
##   queue CURRENT WAITING...                          the dragons being rebuilt,
##     comma-separated, or `-` when idle
##   done ID  or  failed ID REASON                     per dragon asked for
## ROW is the turn's row in the game columns, `-` an absent GUID or variant.
## Turns a dragon's own log recorded come first; recovered turns follow as the
## judge answers. It reads `recover ID...` lines: a single ID, a newly focused
## dragon, goes to the front of the queue, several wait behind it. `--workers`
## dragons (half the processor's threads by default) are rebuilt at once, each
## whole on its own judge server, a child only after its parent, from its
## parent's protocol.
##
##   loong-recover decisions --replay R --game G.cols --registry DIR --judge PATH
##     (--dragon D... | --team A|B | --all) [--rounds A-B] [--json]
##
## prints those dragons' recovered turns in those rounds instead, dragon by
## dragon, as readable text (decisions.nim) or one JSON object a turn, and
## stops each dragon once past them (`just decisions`).

import std/[algorithm, cpuinfo, json, os, posix, sets, strutils, tables]
import ../../gamedata/columns
import decisions as describing, game_facts, gizmos, recover, registry

type
  ## Where each recovered turn goes: its game turn row, dragon, round and
  ## action, its record as streamed, and its records with retained ones
  ## rebuilt whole.
  TurnSink = proc (row: int, dragon, round: int32, action: string, record: JsonNode,
    gizmos: seq[JsonNode]) {.closure.}

  Recovery = object
    judge, registry: string
    ## Serving the viewer over pipes; otherwise messages and requests are off.
    serving: bool
    sink: TurnSink
    actions: Table[int, string]           ## game turn row -> its recorded action
    facts: GameFacts
    rows: Table[(int32, int32), int]      ## (dragon, round) -> game turn row
    teams: Table[int32, int]
    builds: Table[int32, (string, JsonNode)]
    statuses: Table[int32, string]
    attempted: HashSet[int32]
    ## The last turn of a parent: whether it was still reliable, and its protocol.
    parents: Table[(int32, int32), tuple[reliable: bool, protocol: int]]
    waiting: seq[int32]
    queueChanged: bool   ## a request changed `waiting` since it was last sent
    failures: Table[int32, string]        ## why each attempted dragon failed, or ""
    input: string

proc send(recovery: Recovery, line: string) =
  if not recovery.serving: return
  stdout.write line & "\n"
  stdout.flushFile()

proc streamTurn(row: int, dragon, round: int32, action: string, record: JsonNode,
    gizmos: seq[JsonNode]) =
  ## The viewer's `turn` and `breakdown` messages.
  let text = $record
  stdout.write "turn " & $row & " " & $text.len & "\n" & text & "\n"
  for gizmo in gizmos:
    if gizmo{"slot"} == %"brain" and gizmo{"breakdown"} != nil:
      stdout.write "breakdown " & $row & " " & $gizmo["breakdown"] & "\n"
  stdout.flushFile()

proc sendTurn(recovery: Recovery, dragon, round: int32, record: JsonNode, gizmos: seq[JsonNode]) =
  let row = recovery.rows.getOrDefault((dragon, round), -1)
  if row < 0: return
  recovery.sink(row, dragon, round, recovery.actions.getOrDefault(row), record, gizmos)

proc recoverable(recovery: Recovery, dragon: int32): bool =
  dragon in recovery.builds and recovery.facts.identities[dragon]{"variant"}.getStr == "judge" and
    dragon in recovery.facts.samples

proc sendQueue(recovery: var Recovery, current: openArray[int32]) =
  ## The dragons being rebuilt, comma-separated, then those waiting.
  recovery.queueChanged = false
  var line = "queue " & (if current.len == 0: "-" else: current.join(","))
  for dragon in recovery.waiting: line.add " " & $dragon
  recovery.send line

proc readRequests(recovery: var Recovery, wait: bool): bool =
  ## Takes whatever request lines are waiting on standard input, blocking for
  ## them when `wait`; false once the viewer has closed it.
  if not recovery.serving: return true
  var ready: TFdSet
  FD_ZERO(ready)
  FD_SET(0, ready)
  var timeout = Timeval(tv_sec: posix.Time(0), tv_usec: 0)
  if select(1, addr ready, nil, nil, if wait: nil else: addr timeout) <= 0: return true
  var buffer: array[4096, char]
  let got = posix.read(0, addr buffer[0], buffer.len)
  if got <= 0: return false
  for index in 0 ..< got: recovery.input.add buffer[index]
  while true:
    let newline = recovery.input.find('\n')
    if newline < 0: break
    let fields = recovery.input[0 ..< newline].splitWhitespace
    recovery.input = recovery.input[newline + 1 .. ^1]
    if fields.len < 2 or fields[0] != "recover": continue
    var asked: seq[int32]
    for field in fields[1 .. ^1]:
      try:
        let dragon = int32(parseInt(field))
        if recovery.recoverable(dragon) and dragon notin recovery.attempted: asked.add dragon
      except ValueError: discard
    if asked.len > 0: recovery.queueChanged = true
    if fields.len == 2:
      var rest: seq[int32]
      for dragon in recovery.waiting:
        if dragon notin asked: rest.add dragon
      recovery.waiting = asked & rest
    else:
      for dragon in asked:
        if dragon notin recovery.waiting: recovery.waiting.add dragon
  true

proc launch(recovery: var Recovery, dragon: int32): (Inspection, string) =
  ## Start rebuilding a dragon's whole life, a child only once its parent is
  ## done: its inspection, or why it can't start.
  recovery.attempted.incl dragon
  if not recovery.recoverable(dragon): return (nil, recovery.statuses.getOrDefault(dragon))
  var protocol = 1
  if dragon in recovery.facts.births:
    let (parent, round) = recovery.facts.births[dragon]
    if (parent, round) notin recovery.parents or not recovery.parents[(parent, round)].reliable:
      return (nil, "Parent protocol could not be recovered")
    protocol = recovery.parents[(parent, round)].protocol
  let (directory, manifest) = recovery.builds[dragon]
  let (wasm, marked) = inspectionArtifact(directory, manifest)
  if wasm.len == 0: return (nil, "Its build has no inspection artifact")
  let status = "Action/radio-matched WASM inspection; annotation CPU excluded"
  var births: HashSet[(int32, int32)]
  for parent in recovery.facts.births.values: births.incl parent
  let this = addr recovery
  try:
    let inspection = startDiagnostics(recovery.facts.samples[dragon], recovery.judge, wasm, marked,
      recovery.facts.area, recovery.facts.sonar, protocol, proc (sample: Sample, turn: RecoveredTurn) =
        if (sample.dragon, sample.round) in births:
          this.parents[(sample.dragon, sample.round)] = (turn.reliable, turn.outputProtocol)
        var slots: seq[string]
        for slot in turn.rejectedSlots: slots.add slot
        slots.sort
        this[].sendTurn(sample.dragon, sample.round, %*{"gizmos": turn.emitted,
          "gizmo_errors": turn.errors, "gizmo_rejected_slots": slots, "gizmo_source": "rerun",
          "gizmo_input_protocol": turn.inputProtocol, "gizmo_output_protocol": turn.outputProtocol,
          "gizmo_reliable": turn.reliable, "action_matches": turn.matches,
          "gizmo_status": (if turn.reliable: status
            else: "UNRELIABLE: the rebuilt actions diverged from the replay")},
          turn.gizmos))
    (inspection, "")
  except CatchableError:
    (nil, getCurrentExceptionMsg().replace('\n', ' '))

proc finish(recovery: var Recovery, dragon: int32, failure: string) =
  ## Say how a dragon's rebuild went.
  recovery.failures[dragon] = failure
  recovery.send(if failure.len == 0: "done " & $dragon else: "failed " & $dragon & " " & failure)

proc recoverDragon(recovery: var Recovery, dragon: int32) =
  ## Recover one dragon, its ancestors first, waiting for each.
  if dragon in recovery.attempted: return
  if dragon in recovery.facts.births: recovery.recoverDragon(recovery.facts.births[dragon][0])
  var (inspection, failure) = recovery.launch(dragon)
  if inspection != nil:
    try: inspection.wait()
    except CatchableError: failure = getCurrentExceptionMsg().replace('\n', ' ')
  recovery.finish(dragon, failure)

proc sendRecorded(recovery: Recovery, game: var ColumnsFileReader) =
  ## Turns whose own log recorded gizmos, as a diagnostic build played them.
  var retained: Table[int32, Table[(string, string), JsonNode]]
  for row in 0 ..< game.rowCount("turn.dragon"):
    let log = game.stringRow("turn.log", row)
    if GizmoPrefix notin log: continue
    let dragon = int32(game.numberAt("turn.dragon", row))
    let round = int32(game.numberAt("turn.round", row))
    var primitives, stubs: seq[JsonNode]
    var errors: seq[string]
    for line in log.splitLines:
      if not line.startsWith(GizmoPrefix): continue
      try:
        if primitives.len >= MaxGizmos: raise newException(ValueError, "More than 1024 primitives in one turn")
        let parsed = parseJson(line[GizmoPrefix.len .. ^1])
        validatePrimitive(parsed, recovery.facts.area)
        primitives.add parsed
      except ValueError, KeyError:
        let stub = rejectedStub(line[GizmoPrefix.len .. ^1])
        errors.add "Rejected " & $stub{"label"} & ": " & getCurrentExceptionMsg()
        stubs.add stub
    var rejected: HashSet[string]
    var kept: seq[JsonNode]
    try:
      var pruned: seq[string]
      (kept, pruned, rejected) = pruneHierarchy(expandRetained(primitives,
        retained.mgetOrPut(dragon, initTable[(string, string), JsonNode]())), stubs)
      errors.add pruned
    except ValueError:
      errors.add getCurrentExceptionMsg()
      rejected = ["brain", "memory"].toHashSet
    var slots: seq[string]
    for slot in rejected: slots.add slot
    slots.sort
    recovery.sendTurn(dragon, round, %*{"gizmos": kept, "gizmo_errors": errors,
      "gizmo_rejected_slots": slots, "gizmo_source": "recorded", "gizmo_reliable": true,
      "gizmo_status": "Recorded diagnostics"}, kept)

type
  ## A team's build as the caller gives it: `--seat` or `--build`.
  AssumedBuild = object
    guid: string
    team: int             ## 0 A, 1 B; -1 none
    source: string        ## where it came from, for the dragons' status
    bot: string           ## the record's name for the team's bot, if any

  ## Each team's build, by team.
  TeamBuilds = array[2, AssumedBuild]

proc prepare(replay, game, registryPath, judge: string, serving: bool,
    sink: TurnSink, assumed: TeamBuilds): Recovery =
  ## The replay's facts and every dragon's build, announced when serving, and
  ## the turns the dragons' own logs recorded. A team's dragons take its build
  ## from `assumed`; a GUID the replay recorded is only the
  ## fallback, for replays made while builds announced one.
  var recovery = Recovery(judge: judge, registry: registryPath, serving: serving, sink: sink)
  # The decisions' inputs are needed only while they load, so their columns
  # go to memory-backed storage and are gone once read.
  let memory = if dirExists("/dev/shm"): "/dev/shm" else: getTempDir()
  let observations = memory / "loong-recover-" & $getCurrentProcessId() & ".observations.cols"
  try: recovery.facts = readGameFacts(replay, game, observations, "AB")
  finally: removeFile(observations)
  var columns = openColumnsFile(game)
  var dragons: seq[int32]
  for row in 0 ..< columns.rowCount("turn.dragon"):
    let dragon = int32(columns.numberAt("turn.dragon", row))
    recovery.rows[(dragon, int32(columns.numberAt("turn.round", row)))] = row
    recovery.actions[row] = columns.stringRow("turn.action", row)
    if dragon notin recovery.teams:
      recovery.teams[dragon] = int(columns.numberAt("turn.team", row))
      dragons.add dragon
  # Each dragon's build, resolved once per GUID.
  var resolved: Table[string, (bool, string, JsonNode, string)]
  for dragon in dragons:
    let team = recovery.teams[dragon]
    let planned = assumed[team and 1]
    let assumedHere = planned.guid.len > 0
    if assumedHere:
      recovery.facts.identities[dragon] = %*{"version": 1, "guid": planned.guid, "variant": "judge"}
    let identity = recovery.facts.identities.getOrDefault(dragon)
    var guid, variant = "-"
    var status = "No build recorded for its team"
    if identity != nil and identity{"invalid"}.getBool: status = "Invalid build identity"
    elif identity != nil:
      guid = identity["guid"].getStr
      variant = identity["variant"].getStr
      if guid notin resolved:
        try:
          let (directory, found) = resolveBuild(registryPath, guid)
          resolved[guid] = (true, directory, found, "Verified immutable build pair")
        except CatchableError:
          resolved[guid] = (false, "", nil, "Build unavailable or invalid: " & getCurrentExceptionMsg())
      let (ok, directory, found, note) = resolved[guid]
      status = note
      if ok: recovery.builds[dragon] = (directory, found)
      if assumedHere:
        status = (if ok: "Build taken from " & planned.source &
          "; each rebuilt action is checked against the replay" else: note & " (taken from " & planned.source & ")")
    recovery.statuses[dragon] = status
    recovery.send "dragon " & $dragon & " " & $team & " " & $int(recovery.recoverable(dragon)) & " " &
      guid & " " & variant & " " & status
  recovery.sendRecorded(columns)
  columns.closeColumnsFile()
  recovery

proc serve(replay, game, registryPath, judge: string, focus: int32, assumed: TeamBuilds,
    workers: int) =
  ## Rebuild the queue's dragons `workers` at a time, each on its own judge
  ## server, taking requests and records as they come.
  var recovery = prepare(replay, game, registryPath, judge, serving = true, streamTurn, assumed)
  if focus >= 0 and recovery.recoverable(focus): recovery.waiting.add focus
  var active: seq[(int32, Inspection)]
  proc running(active: seq[(int32, Inspection)]): seq[int32] =
    for (dragon, _) in active: result.add dragon
  recovery.sendQueue([])
  while true:
    # Start waiting dragons in queue order until every worker is busy. A child
    # needs its parent done: a parent not yet asked for goes in ahead of it,
    # and a child whose parent is running waits its turn.
    var position = 0
    while active.len < workers and position < recovery.waiting.len:
      let dragon = recovery.waiting[position]
      if dragon in recovery.attempted:
        recovery.waiting.delete(position)
        recovery.queueChanged = true
        continue
      if dragon in recovery.facts.births:
        let parent = recovery.facts.births[dragon][0]
        if parent notin recovery.attempted and recovery.recoverable(parent):
          let at = recovery.waiting.find(parent)
          if at >= 0 and at < position:
            inc position
            continue
          if at >= 0: recovery.waiting.delete(at)
          recovery.waiting.insert(parent, position)
          recovery.queueChanged = true
          continue
        if parent in active.running:
          inc position
          continue
      recovery.waiting.delete(position)
      recovery.queueChanged = true
      let (inspection, failure) = recovery.launch(dragon)
      if inspection == nil: recovery.finish(dragon, failure)
      else: active.add((dragon, inspection))
    if recovery.queueChanged: recovery.sendQueue(active.running)
    if active.len == 0:
      if not recovery.readRequests(wait = recovery.waiting.len == 0): break
      continue
    # Wait for any judge's records or reply, or a request.
    var ready: TFdSet
    FD_ZERO(ready)
    FD_SET(0, ready)
    var highest: cint = 0
    for (_, inspection) in active:
      for handle in inspection.handles:
        FD_SET(handle, ready)
        highest = max(highest, handle)
    var timeout = Timeval(tv_sec: posix.Time(1), tv_usec: 0)
    discard select(highest + 1, addr ready, nil, nil, addr timeout)
    if not recovery.readRequests(wait = false): break
    var index = 0
    while index < active.len:
      let (dragon, inspection) = active[index]
      var failure = ""
      try: inspection.advance()
      except CatchableError: failure = getCurrentExceptionMsg().replace('\n', ' ')
      if inspection.done or failure.len > 0:
        active.delete(index)
        recovery.finish(dragon, failure)
        recovery.queueChanged = true
      else: inc index
  stopServers(kill = true)

type RoundsDone = object of CatchableError

proc decisions(replay, game, registryPath, judge: string, wanted: seq[int32], team: string,
    first, last: int32, asJson: bool, assumed: TeamBuilds): int =
  ## Print the recovered turns in `first` .. `last` of each dragon asked for,
  ## or of a team's or both teams' dragons, one dragon after another, each led
  ## by its build and how far its rebuilt actions match the replay; 1 when none
  ## can be shown.
  var width = 0
  block:
    var columns = openColumnsFile(game)
    width = int(columns.numberAt("meta.width", 0))
    columns.closeColumnsFile()
  type Life = object
    blocks: seq[string]
    turns, mismatches: int
    divergence: int32   ## the round of its first unreliable turn, or -1
  var lives: Table[int32, Life]
  var chosen: HashSet[int32]
  var shown = 0
  var stopped = false
  let sink = proc (row: int, turnDragon, round: int32, action: string, record: JsonNode,
      gizmos: seq[JsonNode]) =
    if turnDragon notin chosen: return
    if round > last:
      stopped = true
      raise newException(RoundsDone, "")
    let life = addr lives.mgetOrPut(turnDragon, Life(divergence: -1))
    inc life.turns
    if not record{"action_matches"}.getBool(true): inc life.mismatches
    if not record{"gizmo_reliable"}.getBool(true) and life.divergence < 0: life.divergence = round
    if round < first: return
    inc shown
    life.blocks.add(if asJson: $(%*{"dragon": turnDragon, "round": round, "row": row,
        "action": action, "record": record, "gizmos": gizmos})
      else: describeTurn(turnDragon, round, action, record, gizmos, width))
  var recovery = prepare(replay, game, registryPath, judge, serving = false, sink, assumed)
  var dragons = wanted
  if team.len > 0:
    for dragon, side in recovery.teams:
      if team == "all" or "AB"[side and 1] == team[0]: dragons.add dragon
    dragons.sort
  for dragon in dragons:
    if dragon notin recovery.teams: quit "No dragon " & $dragon & " in this game"
    chosen.incl dragon
  for dragon in dragons:
    let side = "AB"[recovery.teams[dragon] and 1]
    if not recovery.recoverable(dragon):
      stderr.writeLine "D" & $dragon & " (team " & side & "): " & recovery.statuses.getOrDefault(dragon)
      continue
    # A dragon born after the last round has nothing to show.
    if recovery.facts.samples[dragon][0].round > last: continue
    recovery.recoverDragon(dragon)
    # A recovery stopped past the last round leaves its judge mid-answer.
    if stopped: stopServers(kill = true)
    stopped = false
    let life = lives.getOrDefault(dragon, Life(divergence: -1))
    let failure = recovery.failures.getOrDefault(dragon)
    let status = recovery.statuses.getOrDefault(dragon)
    let through = if life.turns > 0: "through round " & $min(last, recovery.facts.samples[dragon][^1].round) else: ""
    if asJson:
      echo $(%*{"dragon": dragon, "team": $side, "status": status, "failure": failure,
        "turns": life.turns, "mismatches": life.mismatches, "first_divergence": life.divergence})
    else:
      echo "## D" & $dragon & " (team " & side & "): " & status & "."
      if failure.len > 0: echo "## Recovery failed: " & failure
      if life.turns > 0:
        echo "## " & $(life.turns - life.mismatches) & " of " & $life.turns & " rebuilt turns " & through &
          " match the replay" & (if life.divergence < 0: "; none diverged."
            else: "; the first divergence is at round " & $life.divergence &
              ", and turns from there on are not the bot's decisions (marked UNRELIABLE).")
    for text in life.blocks: echo text
    stdout.flushFile()
  if shown == 0:
    stderr.writeLine "No decisions in rounds " & $first & "-" & $last
    return 1

proc main() =
  var replay, game, registryPath, judge: string
  var focus = -1'i32
  var dragons: seq[int32]
  var team, build, buildTeam = ""
  var seats: TeamBuilds
  for side in 0 .. 1: seats[side].team = -1
  var first, last = -1'i32
  var asJson = false
  # Half the processor by default, leaving the rest for the viewer and desktop.
  var workers = max(1, countProcessors() div 2)
  var arguments = commandLineParams()
  let mode = if arguments.len > 0 and arguments[0] == "decisions": "decisions" else: "serve"
  if mode == "decisions": arguments.delete(0)
  var index = 0
  while index < arguments.len:
    let value = if index + 1 < arguments.len: arguments[index + 1] else: ""
    case arguments[index]
    of "--replay": replay = value
    of "--game": game = value
    of "--registry": registryPath = value
    of "--judge": judge = value
    of "--focus": focus = int32(parseInt(value))
    of "--workers": workers = max(1, parseInt(value))
    of "--build": build = value
    of "--build-team":
      buildTeam = value.toUpperAscii
      if buildTeam notin ["A", "B"]: quit "--build-team takes A or B"
    of "--seat":
      # --seat SIDE GUID BOT: this team's build, and a name for its bot.
      if index + 3 >= arguments.len or arguments[index + 1] notin ["A", "B"]:
        quit "--seat takes SIDE GUID BOT"
      seats[(if arguments[index + 1] == "A": 0 else: 1)] = AssumedBuild(guid: arguments[index + 2],
        team: (if arguments[index + 1] == "A": 0 else: 1), bot: arguments[index + 3],
        source: "--seat (" & arguments[index + 3] & ")")
      index += 4
      continue
    of "--dragon": dragons.add int32(parseInt(value))
    of "--team":
      team = value.toUpperAscii
      if team notin ["A", "B"]: quit "--team takes A or B"
    of "--all":
      team = "all"
      index += 1
      continue
    of "--rounds":
      let bounds = value.split('-')
      first = int32(parseInt(bounds[0]))
      last = if bounds.len > 1 and bounds[1].len > 0: int32(parseInt(bounds[1])) else: first
    of "--json":
      asJson = true
      index += 1
      continue
    else: quit "unknown option " & arguments[index]
    index += 2
  if replay.len == 0 or game.len == 0 or registryPath.len == 0 or judge.len == 0 or
      mode == "decisions" and dragons.len == 0 and team.len == 0:
    quit "usage: loong-recover --replay R --game G.cols --registry DIR --judge PATH [--focus D]\n" &
      "         [--seat SIDE GUID BOT]... [--build GUID [--build-team A|B]]\n" &
      "       loong-recover decisions --replay R --game G.cols --registry DIR --judge PATH " &
      "(--dragon D... | --team A|B | --all) [--rounds A-B] [--json]"
  # Each team's build, first found: --seat, then --build.
  var assumed = seats
  if build.len > 0:
    if buildTeam.len == 0 and team in ["A", "B"]: buildTeam = team
    if buildTeam.len == 0: quit "--build needs --build-team A|B (or --team)"
    let side = if buildTeam == "A": 0 else: 1
    if assumed[side].guid.len == 0: assumed[side] = AssumedBuild(guid: build, team: side, source: "--build")
  if mode == "serve": serve(replay, game, registryPath, judge, focus, assumed, workers)
  else: quit decisions(replay, game, registryPath, judge, dragons, team,
    if first < 0: 0'i32 else: first, if last < 0: high(int32) else: last, asJson, assumed)

main()
