## Compare reconstructed observations with independent official-engine input
## blocks obtained through the judge's served-team sockets. No Python toolkit.
import std/[algorithm, nativesockets, net, os, osproc, sequtils, sets, strutils, tables, tempfiles]
import ../[board, columns, gamedata, observations, store]
import ../../judge/harness
import ../../evaluation/paths

type Captured = object
  init, turn: string
  protocol: int

proc normalized(text: string): string =
  ## Body records are an unordered visible set; the wire's headers, values,
  ## messages, cell and edge order remain part of the comparison.
  var rows = text.strip.splitLines.mapIt(it.splitWhitespace.join(" "))
  for index, row in rows:
    if row.startsWith("DRAGON_BODIES "):
      let count = parseInt(row.splitWhitespace[1])
      var bodies = rows[index + 1 .. index + count]
      bodies.sort()
      for offset, body in bodies: rows[index + 1 + offset] = body
      break
  rows.join("\n")

proc header(text, name: string): string =
  for row in text.splitLines:
    if row.startsWith(name & " "): return row[name.len + 1 .. ^1]
  raise newException(ValueError, "missing " & name)

proc arenaReply(init, turn: string, dragon: int): string =
  let round = parseInt(turn.header("ROUND"))
  if round >= 25: return "ENDTURN\n"
  let dimensions = init.header("MAP").splitWhitespace.mapIt(parseInt(it))
  let width = dimensions[0]
  let height = dimensions[1]
  var head: (int, int)
  var occupied: HashSet[(int, int)]
  var pearls: HashSet[(int, int)]
  for row in turn.splitLines:
    let fields = row.splitWhitespace
    if fields.len == 6 and fields[0] in ["A", "B"]:
      let cell = (parseInt(fields[2]), parseInt(fields[3]))
      occupied.incl cell
      if parseInt(fields[1]) == dragon and fields[5] == "1": head = cell
    elif fields.len == 4 and fields[0].len > 0 and fields[0][0].isDigit:
      if fields[2] == "1": pearls.incl (parseInt(fields[0]), parseInt(fields[1]))
  let facing = turn.header("DIR")[0]
  var choices: seq[(bool, bool, char)]
  for (direction, dx, dy) in [('N', 0, -1), ('E', 1, 0), ('S', 0, 1), ('W', -1, 0)]:
    let cell = ((head[0] + dx + width) mod width, (head[1] + dy + height) mod height)
    # This generated fixture has no walls or portals.
    if cell notin occupied: choices.add (cell in pearls, direction == facing, direction)
  choices.sort()
  let command = if parseInt(turn.header("LENGTH")) >= 6 and parseInt(turn.header("UNIT_COUNT")) < 4:
                  "SPLIT 3"
                else: "MOVE " & (if choices.len > 0: $choices[^1][2] else: "N")
  let payload = (uint64(dragon) shl 40) or (uint64(round) shl 16) or uint64(parseInt(turn.header("LENGTH")))
  result = command & "\n"
  for direction in "NESW": result.add "SONAR " & direction & " " & $payload & "\n"
  result.add "PROTOCOL 3\nENDTURN\n"

proc receiveBytes(socket: Socket, size: int): string =
  while result.len < size:
    let part = socket.recv(size - result.len, timeout = 30000)
    if part.len == 0: raise newException(IOError, "judge closed in a protocol block")
    result.add part

proc checkFixture(directory, name, mapText, move: string) =
  let mapPath = directory / name & ".map"
  let replay = directory / name & ".replay"
  writeFile(mapPath, mapText)
  # UNIX socket paths must fit sockaddr_un even with a long checkout path.
  let socketPath = getTempDir() / "loong-reconstruction-" & $getCurrentProcessId() & ".sock"
  let listener = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP, buffered = false)
  defer:
    listener.close()
    removeFile(socketPath)
  listener.bindUnix(socketPath)
  listener.listen()
  let command = matchCommand() & @["--map", mapPath, "--seed", "1", "--serve-a", socketPath,
    "--serve-b", socketPath, "--replay", replay, "--debug", "31", "--timeout", "30"]
  let child = startProcess(command[0], args = command[1 .. ^1], options = {poParentStreams})
  defer:
    if child.running: child.terminate()
    child.close()
  var clients: array[2, Socket]
  for index in 0 .. 1: listener.accept(clients[index])
  defer:
    for client in clients: client.close()
  var initBlocks: Table[int, string]
  var captured: Table[(int, int), Captured]
  var ended: array[2, bool]
  var splits, sonar, sprints: int
  while not (ended[0] and ended[1]):
    var ready: seq[SocketHandle]
    for index, client in clients:
      if not ended[index]: ready.add client.getFd
    if selectRead(ready, 30000) == 0: raise newException(IOError, "judge protocol timed out")
    for index, client in clients:
      if ended[index] or client.getFd notin ready: continue
      let fields = client.recvLine(timeout = 30000).splitWhitespace
      if fields.len == 0: raise newException(IOError, "judge closed before END")
      case fields[0]
      of "GAME", "DEATH": discard
      of "END": ended[index] = true
      of "SPAWN": initBlocks[parseInt(fields[1])] = client.receiveBytes(parseInt(fields[2]))
      of "TURN":
        let dragon = parseInt(fields[1])
        let turn = client.receiveBytes(parseInt(fields[2]))
        let round = parseInt(turn.header("ROUND"))
        let reply = if name == "arena": arenaReply(initBlocks[dragon], turn, dragon)
          elif round >= 2: "ENDTURN\n"
          else: "MOVE " & (if dragon == 0: move else: "N") & "\nENDTURN\n"
        captured[(round, dragon)] = Captured(init: initBlocks[dragon], turn: turn,
            protocol: (if "ECHOES " in turn: 3 else: 1))
        if reply.startsWith("SPLIT"): inc splits
        if "SONAR " in reply: inc sonar
        if reply.startsWith("MOVE EE"): inc sprints
        client.send($reply.len & "\n" & reply)
      else: raise newException(ValueError, "unknown served message " & fields[0])
  doAssert child.waitForExit(30000) == 0
  let gamePath = directory / name & ".cols"
  writeGameColumns(replay, gamePath)
  var game = openColumnsFile(gamePath)
  defer: game.closeColumnsFile()
  var checked = 0
  discard game.replayDecisions(false, proc(dragon: int32): bool = true,
    proc(board: var ReconstructedBoard, dragon: int32, turnIndex: int) =
    let key = (int(board.round), int(dragon))
    doAssert key in captured, name & ": unexpected reconstructed decision " & $key
    let expected = captured[key]
    let (init, observation) = board.observe(dragon)
    var actual = observation
    if expected.protocol < 3:
      actual = observation.splitLines.filterIt(not it.startsWith("ECHOES ")).join("\n")
    doAssert normalized(init) == normalized(expected.init), name & ": init differs " & $key
    doAssert normalized(actual) == normalized(expected.turn), name & ": observation differs " & $key &
      "\nactual:\n" & actual & "\nexpected:\n" & expected.turn
    inc checked)
  doAssert checked == captured.len and checked > 0
  if name == "arena": doAssert splits > 0 and sonar > 0
  if name == "sprint": doAssert sprints > 0
  echo name, ": ", checked, " exact observations, ", splits, " splits, ", sonar, " sonar turns"

proc main() =
  createDir(storageRoot() / "checks")
  let directory = createTempDir("reconstruction-", "", storageRoot() / "checks")
  defer: removeDir(directory)
  # Food every round, no walls; enough room to exercise growth and splitting.
  var arena = "MAP 15 15\nTILE_COUNT 225\n"
  for y in 0 ..< 15:
    for x in 0 ..< 15: arena.add "TILE " & $x & " " & $y & " 1 1\n"
  arena.add "EDGE_COUNT 0\nDRAGON_COUNT 2\nDRAGON 0 3 2 2 1 2 0 2\nDRAGON 1 3 12 12 13 12 14 12\nEND\n"
  checkFixture(directory, "arena", arena, "")
  for (name, positions, move, edges) in [
      ("portal", "2 2 1 2 0 2", "E", "EDGE_COUNT 2\nEDGE 58 2 0\nEDGE 104 2 0\n"),
      ("sprint", "2 2 1 2 0 2", "EE", "EDGE_COUNT 0\n"),
      ("wrap", "9 2 8 2 7 2", "E", "EDGE_COUNT 0\n")]:
    checkFixture(directory, name, "MAP 10 10\nTILE_COUNT 1\nTILE 3 2 1 1\n" & edges &
      "DRAGON_COUNT 2\nDRAGON 0 3 " & positions & "\nDRAGON 1 3 8 8 8 9 8 0\nEND\n", move)

when isMainModule: main()
