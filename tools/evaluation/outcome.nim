## How a game ended, from its log and its process: the engine's last result
## line (`team A wins after 812 rounds (by elimination)`, `draw after ...`)
## and whether the game failed: the harness's timeout, a nonzero exit, a bot
## execution failure the engine reported, or no result at all.

import std/[json, strutils, unicode]

type GameEnd* = object
  completed*: bool      ## played to a result with no failure
  error*:     string    ## why not, when not completed
  winner*:    int       ## 0 A, 1 B, -1 a draw or no result
  found*:     bool      ## whether a result line was found
  rounds*:    int
  reason*:    string

proc failureAt(line: string): string =
  ## The failure a log line opens, as written up to its matched end, or "":
  ## `round N: bot N (team X) ` then running out of time, exiting, or the
  ## last fuel, trap or memory limit on the line.
  if not line.startsWith("round "): return ""
  var at = 6
  while at < line.len and line[at].isDigit: inc at
  if at == 6 or not line.continuesWith(": bot ", at): return ""
  at += 6
  let digits = at
  while at < line.len and line[at].isDigit: inc at
  if at == digits or not line.continuesWith(" (team ", at): return ""
  at += 7
  if at >= line.len or line[at] notin {'A', 'B'} or not line.continuesWith(") ", at + 1): return ""
  let start = at + 3
  for word in ["ran out of time", "exited"]:
    if line.continuesWith(word, start): return line[0 ..< start + word.len]
  var last = -1
  for word in ["fuel", "trap", "memory limit"]:
    let found = line.rfind(word)
    if found >= start: last = max(last, found + word.len)
  if last > 0: line[0 ..< last] else: ""

proc failureIn(text: string): string =
  ## The first failure in a log, as written: a failure line, or the engine's
  ## `died: no valid action` anywhere.
  for line in text.split('\n'):
    let opened = failureAt(line)
    if opened.len > 0: return opened
    if "died: no valid action" in line: return "died: no valid action"

proc replaceInvalidUtf8(text: string): string =
  ## Decoded as Python's `errors="replace"`: each invalid byte becomes U+FFFD.
  var at = 0
  while at < text.len:
    let length = graphemeLen(text, at)
    let size = runeLenAt(text, at)
    if validateUtf8(text[at ..< min(text.len, at + size)]) == -1 and at + size <= text.len:
      result.add text[at ..< at + size]
      at += size
    else:
      result.add "\u{FFFD}"
      inc at
    discard length

proc readOutcome*(text: string, code: int, timedOut: bool): GameEnd =
  let text = replaceInvalidUtf8(text)
  result.winner = -1
  for line in text.split('\n'):
    var winner = -2
    var rest: string
    if line.startsWith("team A wins after "): (winner, rest) = (0, line[18 .. ^1])
    elif line.startsWith("team B wins after "): (winner, rest) = (1, line[18 .. ^1])
    elif line.startsWith("draw after "): (winner, rest) = (-1, line[11 .. ^1])
    if winner == -2: continue
    var digits = 0
    while digits < rest.len and rest[digits].isDigit: inc digits
    if digits == 0 or not rest.continuesWith(" rounds (", digits): continue
    let close = rest.find(')', digits + 9)
    if close <= digits + 9: continue
    result.found = true
    result.winner = winner
    result.rounds = parseInt(rest[0 ..< digits])
    result.reason = rest[digits + 9 ..< close]
  let failure = failureIn(text)
  result.error =
    if timedOut: "Match exceeded the harness timeout"
    elif code != 0: "Battlecode exited with code " & $code
    elif failure.len > 0: "Bot execution failure: " & failure
    elif not result.found: "No engine result found"
    else: ""
  result.completed = result.error.len == 0

proc readOutcomeFile*(path: string, code: int, timedOut: bool): GameEnd =
  readOutcome(readFile(path), code, timedOut)

proc toJson*(outcome: GameEnd): JsonNode =
  ## The outcome fields of a game's record, in the order records keep them.
  %*{
    "status": if outcome.completed: "completed" else: "error",
    "error": if outcome.completed: newJNull() else: %outcome.error,
    "winner_side": if outcome.found and outcome.winner >= 0: %($"AB"[outcome.winner]) else: newJNull(),
    "rounds": if outcome.found: %outcome.rounds else: newJNull(),
    "reason": if outcome.found: %outcome.reason else: newJNull(),
  }
