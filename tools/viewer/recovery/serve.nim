## `loong-recover`: the viewer's recovery, over pipes. It writes nothing to disk
## but the replay's game columns when they aren't cached yet. The viewer (tools/viewer) starts it
## beside itself and reads its standard output; closing its standard input
## ends it and the judge servers it started.
##
##   loong-recover --replay R --game G.cols --registry DIR --judge PATH [--focus D]
##     [--rounds A-B] [--workers N] [--memory MB | --memory-share R] [--seat SIDE GUID BOT]...
##     [--ladder DIR]
##     [--build GUID [--build-team A|B]]
##
## Each team's build comes from our records, first found: the game's result
## record (`--seat`, from `just viewer RESULT_DIR GAME`), the ladder's records
## for our side of a ladder game (`--ladder` holding replays-manifest.json and
## releases.json), then `--build`. A GUID the replay itself recorded is only the
## fallback, for replays made while builds announced one. Each dragon's status
## says where its build came from; recovery checks each rebuilt action against
## the replay, and a divergence marks that turn and every later one unreliable.
##
## It writes, one message a line:
##   dragon ID TEAM RECOVERABLE GUID VARIANT STATUS   for every dragon, first
##   turn ROW BYTES, then BYTES of the turn's record (JSON, diagnostics.md)
##     and a newline
##   breakdown ROW RELIABLE JSON                       a turn's Brain breakdown, and
##     whether the rebuilt turn matched the replay (1) or not (0)
##   queue CURRENT WAITING...                          the dragons being rebuilt,
##     comma-separated, or `-` when idle
##   window FIRST LAST                                 a `window` line taken: what
##     follows is about that window
##   kept ID                                           the dragon's bot keeps its
##     diagnostics on, so every turn of it comes whole, to keep for the game
##   done ID  or  failed ID REASON                     per dragon asked for
## ROW is the turn's row in the game columns, `-` an absent GUID or variant.
## Turns a dragon's own log recorded come first; recovered turns follow as the
## judge answers. Only the turns in the window, rounds A to B of `--rounds`
## (every round by default) or of the last `window A B` line, are rebuilt with
## diagnostics and sent whole. The others play with diagnostics off where the
## bot lets the judge switch them (diagnostics.md, "State from memory"), and
## send only their breakdown. A dragon's first rebuild runs its whole life, so
## every turn's breakdown comes once. After a new window, the dragons asked for
## again are rebuilt only as far as its last round, and one with no turn in it
## is done at once. A rebuild for an earlier window that goes no further than
## that window stops. It reads `recover ID...` lines: a single ID, a newly
## focused dragon, goes to the front of the queue, several wait behind it.
## `--workers` dragons (half the processor's threads by default) are rebuilt
## at once, each on its own judge server, a child only after its parent, from
## its parent's protocol. A bot that can't switch its diagnostics off plays
## every turn traced anyway: its dragons are `kept`, sending every turn whole
## once, and aren't rebuilt again for a window.
##
## Rebuilds leave checkpoints after untraced turns (zig_judge's
## inspection.zig): forks of the paused bot, reparented to the recovery as a
## child subreaper. A dragon's first rebuild leaves one every so many rounds,
## and every rebuild leaves one just before its window, so the next window
## forward resumes there. A rebuild resumes from the latest checkpoint before
## its window instead of replaying the dragon's life, and replays it only when
## there is none or it has gone. The checkpoints may hold together a share of
## what the viewer, the recovery and its judge servers hold at most
## (`--memory-share`, 1 by default), or `--memory` megabytes (0 for none),
## counted as each checkpoint's measured proportional set size times their
## number. Over that, those farthest from the window end first, each dragon's
## latest before the window last, and one a running rebuild resumed from
## never. The rounds between a dragon's checkpoints spread the budget over
## every recoverable dragon's turns.
##
## A focused dragon's turns also carry the state its bot
## shows from its memory (state.nim); `state ID` asks for a dragon already
## rebuilt without it to be rebuilt again with it, and its turns come again.
##
##   loong-recover decisions --replay R --game G.cols --registry DIR --judge PATH
##     (--dragon D... | --team A|B | --all) [--rounds A-B] [--json] [--state] [--workers N]
##
## prints those dragons' recovered turns in those rounds instead, dragon by
## dragon, as readable text (decisions.nim) or one JSON object a turn, and
## stops each dragon once past them (`just decisions`). It rebuilds `--workers`
## dragons at once, as serving does. Its turns before the
## first round play with diagnostics off where the bot lets the judge switch
## them (diagnostics.md, "State from memory"). `--state` adds the state each
## shows from its memory (state.nim), as the viewer's focused dragon has.
##
##   loong-recover work --replay R --game G.cols --registry DIR --judge PATH --team A|B [--workers N]
##   loong-recover costs [--fix KIND=COST]... WORK.tsv...
##
## `work` prints each rebuilt turn's counted work beside its judge points, and
## `costs` fits each kind's cost to them (costs.nim, `just work-costs`).

import std/[algorithm, cpuinfo, json, options, os, posix, sets, strutils, tables, times]
import ../../gamedata/columns
import costs as fitting, decisions as describing, game_facts, gizmos, recover, registry

type
  ## A checkpoint the judge left after a dragon's turn (recover.nim's
  ## `CheckpointAt`): the turn's round and sample, its FIFO, the protocol
  ## and reliability its rest starts from, and its process once known.
  Checkpoint = object
    round: int32
    index: int
    path: string
    protocol: int
    reliable: bool
    pid: Pid

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
    ## Dragons whose state is shown from their memory (state.nim): the ones
    ## focused when they are rebuilt, since every dragon's would be too much
    ## to hold.
    shown: HashSet[int32]
    offered: HashSet[int32]               ## Dragons whose bot shows its state.
    ## The window: turns outside these rounds are rebuilt with diagnostics off.
    loudFrom, loudUntil: int32
    ## The window each running rebuild started with.
    launched: Table[int32, (int32, int32)]
    ## Dragons rebuilt over their whole life, so every breakdown was sent, and
    ## those being rebuilt so now.
    charted, whole: HashSet[int32]
    kept: HashSet[int32]  ## Dragons whose bot traced turns outside the window.
    ## Each dragon's checkpoints in round order, once their turns came back
    ## untraced, and the directory their FIFOs go in; none without one.
    checkpoints: Table[int32, seq[Checkpoint]]
    checkpointDirectory: string
    spacing: int32  ## rounds between a dragon's checkpoints
    budget: int     ## bytes the checkpoints may hold together
    ## When above 0, the budget is this share of what the viewer, the recovery
    ## and its judge servers hold, measured every few seconds.
    share: float
    sharedAt: float
    turns: int      ## every recoverable dragon's turns, which the spacing spreads them over
    average: int    ## a checkpoint's bytes, as last measured
    measuredAt: float  ## when the checkpoints were last measured
    cursor: int     ## where measuring resumes, round-robin
    ending: seq[Pid]   ## checkpoints ended and not yet reaped
    ## The checkpoint each running rebuild resumed from, by its dragon: ending
    ## it would end the rebuild's worker too.
    resumed: Table[int32, int32]
    input: string

proc send(recovery: Recovery, line: string) =
  if not recovery.serving: return
  stdout.write line & "\n"
  stdout.flushFile()

proc streamBreakdown(row: int, record: JsonNode, gizmos: seq[JsonNode]) =
  ## The viewer's `breakdown` message.
  let reliable = if record{"gizmo_reliable"}.getBool(true): " 1 " else: " 0 "
  for gizmo in gizmos:
    if gizmo{"slot"} == %"brain" and gizmo{"breakdown"} != nil:
      stdout.write "breakdown " & $row & reliable & $gizmo["breakdown"] & "\n"
  stdout.flushFile()

proc streamTurn(row: int, dragon, round: int32, action: string, record: JsonNode,
    gizmos: seq[JsonNode]) =
  ## The viewer's `turn` and `breakdown` messages.
  let text = $record
  stdout.write "turn " & $row & " " & $text.len & "\n" & text & "\n"
  streamBreakdown(row, record, gizmos)

proc sendTurn(recovery: Recovery, dragon, round: int32, record: JsonNode, gizmos: seq[JsonNode],
    brief = false) =
  ## A turn to its sink, or only its breakdown to the viewer when `brief`.
  let row = recovery.rows.getOrDefault((dragon, round), -1)
  if row < 0: return
  if brief: streamBreakdown(row, record, gizmos)
  else: recovery.sink(row, dragon, round, recovery.actions.getOrDefault(row), record, gizmos)

proc inWindow(recovery: Recovery, dragon: int32): bool =
  ## Whether the dragon has a turn in the window.
  for sample in recovery.facts.samples.getOrDefault(dragon):
    if sample.round >= recovery.loudFrom and sample.round <= recovery.loudUntil: return true

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
    if fields.len == 3 and fields[0] == "window":
      # A new window: the viewer asks again for the dragons it wants.
      try:
        recovery.loudFrom = int32(parseInt(fields[1]))
        recovery.loudUntil = int32(parseInt(fields[2]))
        recovery.attempted.clear()
        recovery.waiting.setLen(0)
        recovery.queueChanged = true
        recovery.send "window " & fields[1] & " " & fields[2]
      except ValueError: discard
      continue
    if fields.len == 2 and fields[0] == "state":
      # A dragon rebuilt without its state is rebuilt again with it, first.
      try:
        let dragon = int32(parseInt(fields[1]))
        if dragon in recovery.offered and dragon notin recovery.shown:
          recovery.shown.incl dragon
          recovery.attempted.excl dragon
          let at = recovery.waiting.find(dragon)
          if at >= 0: recovery.waiting.delete(at)
          recovery.waiting.insert(dragon, 0)
          recovery.queueChanged = true
      except ValueError: discard
      continue
    if fields.len < 2 or fields[0] != "recover": continue
    var asked: seq[int32]
    for field in fields[1 .. ^1]:
      try:
        let dragon = int32(parseInt(field))
        if recovery.recoverable(dragon) and dragon notin recovery.attempted: asked.add dragon
      except ValueError: discard
    if asked.len > 0: recovery.queueChanged = true
    if fields.len == 2:
      # A single dragon is the viewer's new focus, so its state is shown.
      for dragon in asked: recovery.shown.incl dragon
      var rest: seq[int32]
      for dragon in recovery.waiting:
        if dragon notin asked: rest.add dragon
      recovery.waiting = asked & rest
    else:
      for dragon in asked:
        if dragon notin recovery.waiting: recovery.waiting.add dragon
  true

proc checkpointPid(checkpoint: var Checkpoint): Pid =
  ## The checkpoint's process, once it has written its pid file; 0 before.
  if checkpoint.pid == 0:
    try: checkpoint.pid = Pid(parseInt(readFile(checkpoint.path & ".pid").strip))
    except IOError, OSError, ValueError: discard
  checkpoint.pid

proc forget(recovery: var Recovery, dragon: int32, round: int32) =
  ## End a dragon's checkpoint and remove its files; it is reaped later.
  var held = recovery.checkpoints.getOrDefault(dragon)
  for position, checkpoint in held.mpairs:
    if checkpoint.round != round: continue
    let pid = checkpoint.checkpointPid
    if pid > 0:
      discard posix.kill(pid, SIGKILL)
      recovery.ending.add pid
    removeFile(checkpoint.path)
    removeFile(checkpoint.path & ".pid")
    held.delete(position)
    recovery.checkpoints[dragon] = held
    return

proc proportional(pid: Pid): int =
  ## A process's proportional set size in bytes, its shared pages split
  ## among the processes sharing them; 0 once it has gone.
  try:
    for line in lines("/proc/" & $pid & "/smaps_rollup"):
      if line.startsWith("Pss:"): return parseInt(line.splitWhitespace[1]) * 1024
  except IOError, OSError, ValueError: discard

const
  CheckpointGuess = 32 * 1024 * 1024  ## a checkpoint's bytes until some are measured
  JudgeGuess = 150 * 1024 * 1024      ## a judge server's bytes until they are measured
  Spacing = 5'i32 .. 250'i32

proc space(recovery: var Recovery, each: int) =
  ## Spread the budget over every recoverable dragon's life: a checkpoint
  ## every so many rounds, each of `each` bytes.
  let spacing = (recovery.turns * each + recovery.budget - 1) div max(recovery.budget, 1)
  recovery.spacing = int32(clamp(spacing, Spacing.a.int, Spacing.b.int))

proc keepWithinBudget(recovery: var Recovery) =
  ## At most once a second: measure eight checkpoints, round-robin, for the
  ## size of one, which sets the spacing for dragons not yet charted; end the
  ## checkpoints farthest from the window while their number at that size is
  ## over the budget, and those whose process has gone; and reap the ended.
  ## Measuring walks a process's page tables, so measuring every checkpoint
  ## after every rebuild held the rebuilds up.
  let now = epochTime()
  if now - recovery.measuredAt < 1.0: return
  recovery.measuredAt = now
  if recovery.share > 0 and now - recovery.sharedAt >= 5.0:
    recovery.sharedAt = now
    var held = proportional(getppid()) + proportional(getpid())
    for pid in serverPids(): held += proportional(pid)
    # The most they have held, since they hold little between rebuilds.
    recovery.budget = max(recovery.budget, int(recovery.share * float(held)))
  var index = 0
  while index < recovery.ending.len:
    var status: cint
    if waitpid(recovery.ending[index], status, WNOHANG) != 0: recovery.ending.delete(index)
    else: inc index
  var held: seq[tuple[dragon, round: int32, distance: int, pid: Pid]]
  for dragon, checkpoints in recovery.checkpoints.mpairs:
    for checkpoint in checkpoints.mitems:
      let pid = checkpoint.checkpointPid
      if pid > 0: held.add((dragon, checkpoint.round, int(abs(checkpoint.round - recovery.loudFrom)), pid))
  if held.len == 0: return
  var gone: HashSet[Pid]
  var (measured, total) = (0, 0)
  for step in 0 ..< min(8, held.len):
    let pid = held[(recovery.cursor + step) mod held.len].pid
    let bytes = proportional(pid)
    if bytes == 0: gone.incl pid
    else: (measured, total) = (measured + 1, total + bytes)
  var inUse: HashSet[Pid]
  for checkpoint in held:
    if recovery.resumed.getOrDefault(checkpoint.dragon, -1) == checkpoint.round: inUse.incl checkpoint.pid
  recovery.cursor = (recovery.cursor + 8) mod held.len
  if measured > 0:
    recovery.average = total div measured
    recovery.space(recovery.average)
  # Each dragon's latest checkpoint before the window is the one its next
  # rebuild resumes from, so those go last; the rest go farthest first.
  var latest: Table[int32, int32]
  for checkpoint in held:
    if checkpoint.round < recovery.loudFrom and checkpoint.round > latest.getOrDefault(checkpoint.dragon, -1):
      latest[checkpoint.dragon] = checkpoint.round
  for checkpoint in held.mitems:
    if latest.getOrDefault(checkpoint.dragon, -1) == checkpoint.round: checkpoint.distance = -1
  held.sort(proc (a, b: tuple[dragon, round: int32, distance: int, pid: Pid]): int = cmp(b.distance, a.distance))
  var count = held.len - gone.len
  for checkpoint in held:
    if checkpoint.pid in inUse: continue
    if checkpoint.pid in gone: recovery.forget(checkpoint.dragon, checkpoint.round)
    elif count * recovery.average > recovery.budget:
      recovery.forget(checkpoint.dragon, checkpoint.round)
      dec count

proc launch(recovery: var Recovery, dragon: int32): (Inspection, string) =
  ## Start rebuilding a dragon, a child only once its parent is done: its
  ## inspection, or why it can't start. A dragon charted already, or rebuilt
  ## for `decisions` or `work`, stops past the window.
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
  let (first, last) = (recovery.loudFrom, recovery.loudUntil)
  let charted = dragon in recovery.charted
  let samples = recovery.facts.samples[dragon]
  # A window run resumes from the latest checkpoint before the window, or
  # replays from birth when there is none or it has gone.
  var resumeFrom = -1
  if charted:
    let held = recovery.checkpoints.getOrDefault(dragon)
    for position in countdown(held.high, 0):
      if held[position].round < first:
        resumeFrom = position
        break
  let start = if resumeFrom < 0: 0 else: recovery.checkpoints[dragon][resumeFrom].index + 1
  # Checkpoints to leave: every `spacing` rounds on a first run, for windows
  # anywhere later, and just before this window, so the next window forward
  # resumes there.
  var asked: seq[CheckpointAt]
  var askedAt: Table[int32, int]
  if recovery.serving and recovery.checkpointDirectory.len > 0:
    var held: HashSet[int32]
    for checkpoint in recovery.checkpoints.getOrDefault(dragon): held.incl checkpoint.round
    let directory = recovery.checkpointDirectory
    template ask(at: int) =
      let index = at
      let round = samples[index].round
      if index >= start and index < samples.len - 1 and round notin held and round notin askedAt:
        askedAt[round] = asked.len
        asked.add CheckpointAt(index: index, path: directory / $dragon & "-" & $round)
    if not charted:
      for index in 0 ..< samples.len - 1:
        if samples[index].round mod recovery.spacing == 0: ask(index)
    var head = -1
    for index, sample in samples:
      if sample.round < first: head = index
    if head >= 0: ask(head)
    asked.sort(proc (a, b: CheckpointAt): int = cmp(a.index, b.index))
    for position, checkpoint in asked: askedAt[samples[checkpoint.index].round] = position
  let onTurn = proc (sample: Sample, turn: RecoveredTurn) =
        # The judge left the checkpoint asked for after an untraced turn.
        if not turn.traced and sample.round in askedAt:
          let at = asked[askedAt[sample.round]]
          let held = addr this.checkpoints.mgetOrPut(sample.dragon, @[])
          var position = held[].len
          while position > 0 and held[][position - 1].round > sample.round: dec position
          held[].insert(Checkpoint(round: sample.round, index: at.index, path: at.path,
            protocol: turn.outputProtocol, reliable: turn.reliable), position)
        if (sample.dragon, sample.round) in births:
          this.parents[(sample.dragon, sample.round)] = (turn.reliable, turn.outputProtocol)
        if turn.offersState: this.offered.incl sample.dragon
        # Outside the window only the breakdown goes, and only once. A bot
        # that traced such a turn after its first can't switch, so every turn
        # of it goes whole.
        var brief = this.serving and (sample.round < first or sample.round > last)
        if brief and turn.traced and sample.round > this.facts.samples[sample.dragon][0].round:
          if sample.dragon notin this.kept:
            this.kept.incl sample.dragon
            this[].send "kept " & $sample.dragon
          brief = false
        if brief and charted: return
        var slots: seq[string]
        for slot in turn.rejectedSlots: slots.add slot
        slots.sort
        this[].sendTurn(sample.dragon, sample.round, %*{"gizmos": turn.emitted,
          "gizmo_errors": turn.errors, "gizmo_rejected_slots": slots, "gizmo_source": "rerun",
          "gizmo_input_protocol": turn.inputProtocol, "gizmo_output_protocol": turn.outputProtocol,
          "gizmo_reliable": turn.reliable, "action_matches": turn.matches,
          "wasm_linear_memory_bytes": (if turn.linearMemoryBytes.isSome:
            %turn.linearMemoryBytes.get else: newJNull()),
          "gizmo_status": (if turn.reliable: status
            else: "UNRELIABLE: the rebuilt actions diverged from the replay")},
          turn.gizmos, brief)
  let stopAfter = if charted or not recovery.serving: last else: high(int32)
  try:
    var inspection: Inspection
    if resumeFrom >= 0:
      let held = recovery.checkpoints[dragon][resumeFrom]
      try:
        inspection = resumeDiagnostics(samples, start, held.path, held.protocol, not held.reliable,
          recovery.facts.area, recovery.facts.sonar, onTurn, showState = dragon in recovery.shown,
          loudFrom = first, loudUntil = last, stopAfter = stopAfter, checkpoints = asked)
        recovery.resumed[dragon] = held.round
      except CatchableError: recovery.forget(dragon, held.round)
    if inspection == nil:
      inspection = startDiagnostics(samples, recovery.judge, wasm, marked, recovery.facts.area,
        recovery.facts.sonar, protocol, onTurn, showState = dragon in recovery.shown,
        loudFrom = first, loudUntil = last, stopAfter = stopAfter, checkpoints = asked,
        owner = int(getCurrentProcessId()))
    recovery.launched[dragon] = (first, last)
    if not charted: recovery.whole.incl dragon
    (inspection, "")
  except CatchableError:
    (nil, getCurrentExceptionMsg().replace('\n', ' '))

proc finish(recovery: var Recovery, dragon: int32, failure: string) =
  ## Say how a dragon's rebuild went. One started before the window moved and
  ## asked for again says nothing until it is rebuilt for the new window.
  recovery.failures[dragon] = failure
  recovery.resumed.del dragon
  if failure.len == 0 and dragon in recovery.whole: recovery.charted.incl dragon
  recovery.whole.excl dragon
  var launched: (int32, int32)
  if recovery.launched.pop(dragon, launched) and failure.len == 0 and
      launched != (recovery.loudFrom, recovery.loudUntil) and dragon in recovery.waiting: return
  recovery.send(if failure.len == 0: "done " & $dragon else: "failed " & $dragon & " " & failure)

proc recoverAll(recovery: var Recovery, dragons: openArray[int32], workers: int,
    finished: proc (dragon: int32)) =
  ## Rebuild these dragons and the ancestors each needs, `workers` at a time,
  ## each on its own judge server, a child only once its parent is done.
  ## `finished` hears of each dragon asked for once it and every dragon asked
  ## for before it are done, so output keeps the order asked.
  var queue: seq[int32]
  proc enqueue(recovery: Recovery, dragon: int32, queue: var seq[int32]) =
    if dragon in queue or dragon in recovery.attempted: return
    if dragon in recovery.facts.births:
      let parent = recovery.facts.births[dragon][0]
      if recovery.recoverable(parent): recovery.enqueue(parent, queue)
    queue.add dragon
  for dragon in dragons: recovery.enqueue(dragon, queue)
  var active: seq[(int32, Inspection)]
  var reported = 0
  while true:
    var position = 0
    while active.len < workers and position < queue.len:
      let dragon = queue[position]
      if dragon in recovery.facts.births:
        let parent = recovery.facts.births[dragon][0]
        var busy = parent in queue
        for (running, _) in active: busy = busy or running == parent
        if busy:
          inc position
          continue
      queue.delete(position)
      let (inspection, failure) = recovery.launch(dragon)
      if inspection == nil: recovery.finish(dragon, failure)
      else: active.add((dragon, inspection))
    while reported < dragons.len and dragons[reported] in recovery.failures:
      finished(dragons[reported])
      inc reported
    if active.len == 0 and queue.len == 0: break
    # Wait for any judge's records or reply.
    var ready: TFdSet
    FD_ZERO(ready)
    var highest: cint = 0
    for (_, inspection) in active:
      for handle in inspection.handles:
        FD_SET(handle, ready)
        highest = max(highest, handle)
    var timeout = Timeval(tv_sec: posix.Time(1), tv_usec: 0)
    discard select(highest + 1, addr ready, nil, nil, addr timeout)
    var index = 0
    while index < active.len:
      let (dragon, inspection) = active[index]
      var failure = ""
      try: inspection.advance()
      except CatchableError: failure = getCurrentExceptionMsg().replace('\n', ' ')
      if inspection.done or failure.len > 0:
        active.delete(index)
        recovery.finish(dragon, failure)
      else: inc index

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
  ## A team's build from our records: the game's result record, the ladder's
  ## records for our side of a ladder game, or `--build`.
  AssumedBuild = object
    guid: string
    team: int             ## 0 A, 1 B; -1 none
    source: string        ## where it came from, for the dragons' status
    bot: string           ## the record's name for the team's bot, if any

  ## Each team's build, by team.
  TeamBuilds = array[2, AssumedBuild]

proc manifestBuild(ladder, registryPath, replay: string): AssumedBuild =
  ## Our side's build in a ladder game, from the ladder's records: the replay
  ## manifest names the game's submission and our side, and releases.json the
  ## submission's registered build and the WASM submitted. Never for a game
  ## that isn't ours.
  result.team = -1
  if ladder.len == 0: return
  let manifestPath = ladder / "replays-manifest.json"
  let releasesPath = ladder / "releases.json"
  if not fileExists(manifestPath) or not fileExists(releasesPath): return
  let entry = parseFile(manifestPath){extractFilename(replay)}
  if entry == nil or not entry{"ours"}.getBool or entry{"side"}.getStr notin ["A", "B"]: return
  let release = parseFile(releasesPath){$entry{"submission"}.getInt}
  if release == nil or release{"build_guid"}.getStr.len == 0: return
  result = AssumedBuild(guid: release["build_guid"].getStr, team: (if entry["side"].getStr == "A": 0 else: 1),
    source: "the ladder manifest (submission " & $entry["submission"].getInt & ", " &
      release{"name"}.getStr & ")")
  # The registered judge WASM should be the one submitted.
  let submitted = release{"wasm_sha256"}.getStr
  try:
    let (_, registered) = resolveBuild(registryPath, result.guid)
    let judge = registered{"artifacts"}{"judge"}.getStr
    if submitted.len > 0 and judge.len > 0:
      result.source.add(if judge == submitted: ", whose registered judge WASM is the one submitted"
        else: ", whose registered judge WASM differs from the one submitted")
  except CatchableError: discard

proc prepare(replay, game, registryPath, judge: string, serving: bool,
    sink: TurnSink, assumed: TeamBuilds): Recovery =
  ## The replay's facts and every dragon's build, announced when serving, and
  ## the turns the dragons' own logs recorded. A team's dragons take its build
  ## from `assumed`, our records; a GUID the replay recorded is only the
  ## fallback, for replays made while builds announced one.
  var recovery = Recovery(judge: judge, registry: registryPath, serving: serving, sink: sink,
    loudUntil: high(int32))
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
    var manifest: JsonNode
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
      manifest = found
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

proc prctl(option: cint, value: culong): cint {.importc, header: "<sys/prctl.h>", varargs.}

proc serve(replay, game, registryPath, judge: string, focus: int32, assumed: TeamBuilds,
    workers: int, first, last: int32, budget: int, share: float) =
  ## Rebuild the queue's dragons `workers` at a time, each on its own judge
  ## server, taking requests and records as they come.
  var recovery = prepare(replay, game, registryPath, judge, serving = true, streamTurn, assumed)
  (recovery.loudFrom, recovery.loudUntil) = (first, last)
  # Checkpoints are reparented here, as a child subreaper, and end with it.
  if (budget > 0 or share > 0) and prctl(36, 1) == 0:  # PR_SET_CHILD_SUBREAPER
    recovery.checkpointDirectory = getTempDir() / "loong-checkpoints-" & $getCurrentProcessId()
    createDir(recovery.checkpointDirectory)
    # Until the judge servers are measured, each is taken to hold JudgeGuess.
    recovery.share = share
    recovery.budget = if share > 0: int(share * float(proportional(getppid()) +
      proportional(getpid()) + workers * JudgeGuess)) else: budget
    for dragon, samples in recovery.facts.samples:
      if recovery.recoverable(dragon): recovery.turns += samples.len
    recovery.average = CheckpointGuess
    recovery.space(CheckpointGuess)
  if focus >= 0 and recovery.recoverable(focus):
    recovery.waiting.add focus
    recovery.shown.incl focus
  var active: seq[(int32, Inspection)]
  proc running(active: seq[(int32, Inspection)]): seq[int32] =
    for (dragon, _) in active: result.add dragon
  recovery.sendQueue([])
  # The viewer closing its end mid-message ends the recovery as closing its
  # input does, and the judge servers stop either way.
  try:
    while true:
      # Start waiting dragons in queue order until every worker is busy. A child
      # needs its parent done: a parent not yet asked for goes in ahead of it,
      # and a child whose parent is running waits its turn.
      var position = 0
      while active.len < workers and position < recovery.waiting.len:
        let dragon = recovery.waiting[position]
        # One asked to show its state while being rebuilt waits for that rebuild.
        if dragon in active.running:
          inc position
          continue
        if dragon in recovery.attempted:
          recovery.waiting.delete(position)
          recovery.queueChanged = true
          continue
        # A charted parent's protocol at each birth is known already.
        if dragon in recovery.facts.births and recovery.facts.births[dragon][0] notin recovery.charted:
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
        if dragon in recovery.charted and not recovery.inWindow(dragon):
          recovery.attempted.incl dragon
          recovery.finish(dragon, "")
          continue
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
      # A rebuild that only covers an earlier window has nothing left to give.
      var stale = 0
      while stale < active.len:
        let (dragon, inspection) = active[stale]
        if dragon in recovery.whole or recovery.launched.getOrDefault(dragon) ==
            (recovery.loudFrom, recovery.loudUntil):
          inc stale
          continue
        inspection.abandon()
        active.delete(stale)
        recovery.finish(dragon, "")
        recovery.queueChanged = true
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
      if recovery.checkpointDirectory.len > 0: recovery.keepWithinBudget()
  except IOError: discard
  finally:
    stopServers(kill = true)
    for dragon, held in recovery.checkpoints.mpairs:
      for checkpoint in held.mitems:
        let pid = checkpoint.checkpointPid
        if pid > 0: discard posix.kill(pid, SIGKILL)
    if recovery.checkpointDirectory.len > 0: removeDir(recovery.checkpointDirectory)

proc work(replay, game, registryPath, judge, team: string, assumed: TeamBuilds, workers: int): int =
  ## Print each rebuilt turn of a team's dragons that emitted a "Turn work"
  ## table: its dragon, round and judge points, then each kind's units as
  ## KIND=UNITS, tab-separated, for `costs` to fit. A turn is left out when the
  ## game has no judge points for it, its clock braked, it diverged, or it is
  ## its process's first, whose start-up counted work doesn't price; standard
  ## error counts each. 1 when no turn is printed.
  var points: seq[float]
  var metered: seq[bool]
  block:
    var columns = openColumnsFile(game)
    for row in 0 ..< columns.rowCount("turn.dragon"):
      metered.add columns.numberAt("turn.points?", row) != 0
      points.add columns.numberAt("turn.points", row)
    columns.closeColumnsFile()
  var printed, unmetered, braked, diverged, starts = 0
  var started: HashSet[int32]
  let sink = proc (row: int, dragon, round: int32, action: string, record: JsonNode,
      gizmos: seq[JsonNode]) =
    for gizmo in gizmos:
      if gizmo{"label"}.getStr != "Turn work": continue
      if dragon notin started:
        started.incl dragon
        inc starts
      elif not metered[row]: inc unmetered
      elif "braked" in gizmo{"reason"}.getStr: inc braked
      elif not record{"gizmo_reliable"}.getBool(true): inc diverged
      else:
        var units: seq[string]
        for entry in gizmo{"rows"}.getElems:
          if entry.len >= 2 and entry[1].getStr.len > 0:
            units.add entry[0].getStr & "=" & entry[1].getStr
        echo $dragon & "\t" & $round & "\t" & $int64(points[row]) & "\t" & units.join(" ")
        inc printed
      break
  var recovery = prepare(replay, game, registryPath, judge, serving = false, sink, assumed)
  var dragons: seq[int32]
  for dragon, side in recovery.teams:
    if "AB"[side and 1] == team[0]: dragons.add dragon
  dragons.sort
  var rebuilt: seq[int32]
  for dragon in dragons:
    if not recovery.recoverable(dragon):
      stderr.writeLine "D" & $dragon & ": " & recovery.statuses.getOrDefault(dragon)
      continue
    # A bot that keeps its accounts in memory shows them with its state.
    recovery.shown.incl dragon
    rebuilt.add dragon
  let this = addr recovery
  recovery.recoverAll(rebuilt, workers, proc (dragon: int32) =
    let failure = this.failures.getOrDefault(dragon)
    if failure.len > 0: stderr.writeLine "D" & $dragon & ": recovery failed: " & failure)
  stdout.flushFile()
  stderr.writeLine $printed & " turns printed; left out: " & $starts & " first turns, " &
    $unmetered & " without judge points, " & $braked & " braked, " & $diverged & " diverged"
  if printed == 0: 1 else: 0

proc decisions(replay, game, registryPath, judge: string, wanted: seq[int32], team: string,
    first, last: int32, asJson, showState: bool, assumed: TeamBuilds, workers: int): int =
  ## Print the recovered turns in `first` .. `last` of each dragon asked for,
  ## or of a team's or both teams' dragons, one dragon after another, each led
  ## by its build and how far its rebuilt actions match the replay; 1 when none
  ## can be shown. `workers` dragons are rebuilt at once, each stopping past
  ## `last`.
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
  let sink = proc (row: int, turnDragon, round: int32, action: string, record: JsonNode,
      gizmos: seq[JsonNode]) =
    if turnDragon notin chosen: return
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
  # Only the rounds asked for are traced: the bot plays its other turns with
  # diagnostics off.
  recovery.loudFrom = first
  recovery.loudUntil = last
  var dragons = wanted
  if team.len > 0:
    for dragon, side in recovery.teams:
      if team == "all" or "AB"[side and 1] == team[0]: dragons.add dragon
    dragons.sort
  for dragon in dragons:
    if dragon notin recovery.teams: quit "No dragon " & $dragon & " in this game"
    chosen.incl dragon
    if showState: recovery.shown.incl dragon
  var rebuilt: seq[int32]
  for dragon in dragons:
    let side = "AB"[recovery.teams[dragon] and 1]
    if not recovery.recoverable(dragon):
      stderr.writeLine "D" & $dragon & " (team " & side & "): " & recovery.statuses.getOrDefault(dragon)
      continue
    # A dragon born after the last round has nothing to show.
    if recovery.facts.samples[dragon][0].round <= last: rebuilt.add dragon
  let this = addr recovery
  recovery.recoverAll(rebuilt, workers, proc (dragon: int32) =
    let side = "AB"[this.teams[dragon] and 1]
    let life = lives.getOrDefault(dragon, Life(divergence: -1))
    let failure = this.failures.getOrDefault(dragon)
    let status = this.statuses.getOrDefault(dragon)
    let through = if life.turns > 0: "through round " & $min(last, this.facts.samples[dragon][^1].round) else: ""
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
    stdout.flushFile())
  stopServers()
  if shown == 0:
    stderr.writeLine "No decisions in rounds " & $first & "-" & $last
    return 1

proc main() =
  var replay, game, registryPath, judge: string
  var focus = -1'i32
  var dragons: seq[int32]
  var team, build, buildTeam, ladder = ""
  var seats: TeamBuilds
  for side in 0 .. 1: seats[side].team = -1
  var first, last = -1'i32
  var asJson, showState = false
  # Half the processor by default, leaving the rest for the viewer and desktop.
  var workers = max(1, countProcessors() div 2)
  # What the checkpoints may hold together: megabytes, or else a share of what
  # the viewer, the recovery and its judges hold.
  var memory = 0
  var share = 1.0
  var arguments = commandLineParams()
  if arguments.len > 0 and arguments[0] == "costs": quit fitting.costs(arguments[1 .. ^1])
  let mode = if arguments.len > 0 and arguments[0] in ["decisions", "work"]: arguments[0] else: "serve"
  if mode != "serve": arguments.delete(0)
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
    of "--memory":
      memory = max(0, parseInt(value))
      share = 0
    of "--memory-share": share = max(0.0, parseFloat(value))
    of "--build": build = value
    of "--build-team":
      buildTeam = value.toUpperAscii
      if buildTeam notin ["A", "B"]: quit "--build-team takes A or B"
    of "--ladder": ladder = value
    of "--seat":
      # --seat SIDE GUID BOT: the game's result record names this team's build.
      if index + 3 >= arguments.len or arguments[index + 1] notin ["A", "B"]:
        quit "--seat takes SIDE GUID BOT"
      seats[(if arguments[index + 1] == "A": 0 else: 1)] = AssumedBuild(guid: arguments[index + 2],
        team: (if arguments[index + 1] == "A": 0 else: 1), bot: arguments[index + 3],
        source: "the result record (" & arguments[index + 3] & ")")
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
    of "--state":
      showState = true
      index += 1
      continue
    else: quit "unknown option " & arguments[index]
    index += 2
  if replay.len == 0 or game.len == 0 or registryPath.len == 0 or judge.len == 0 or
      mode == "decisions" and dragons.len == 0 and team.len == 0 or
      mode == "work" and team notin ["A", "B"]:
    quit "usage: loong-recover --replay R --game G.cols --registry DIR --judge PATH [--focus D]\n" &
      "         [--rounds A-B] [--workers N] [--memory MB | --memory-share R] [--seat SIDE GUID BOT]...\n" &
      "         [--ladder DIR]\n" &
      "         [--build GUID [--build-team A|B]]\n" &
      "       loong-recover decisions --replay R --game G.cols --registry DIR --judge PATH " &
      "(--dragon D... | --team A|B | --all) [--rounds A-B] [--json] [--state] [--workers N]\n" &
      "       loong-recover work --replay R --game G.cols --registry DIR --judge PATH --team A|B [--workers N]\n" &
      "       loong-recover costs [--fix KIND=COST]... WORK.tsv..."
  # Each team's build from our records, first found: the game's result record,
  # the ladder's records for our side of a ladder game, then --build.
  var assumed = seats
  let ladderBuild = manifestBuild(ladder, registryPath, replay)
  if ladderBuild.team >= 0 and assumed[ladderBuild.team].guid.len == 0: assumed[ladderBuild.team] = ladderBuild
  if build.len > 0:
    if buildTeam.len == 0 and team in ["A", "B"]: buildTeam = team
    if buildTeam.len == 0 and ladderBuild.team >= 0: buildTeam = "AB"[ladderBuild.team] & ""
    if buildTeam.len == 0: quit "--build needs --build-team A|B (or --team) outside our ladder games"
    let side = if buildTeam == "A": 0 else: 1
    if assumed[side].guid.len == 0: assumed[side] = AssumedBuild(guid: build, team: side, source: "--build")
  if mode == "serve": serve(replay, game, registryPath, judge, focus, assumed, workers,
    if first < 0: 0'i32 else: first, if last < 0: high(int32) else: last, memory * 1024 * 1024, share)
  elif mode == "work": quit work(replay, game, registryPath, judge, team, assumed, workers)
  else: quit decisions(replay, game, registryPath, judge, dragons, team,
    if first < 0: 0'i32 else: first, if last < 0: high(int32) else: last, asJson, showState, assumed,
    workers)

main()
