## `loong-sample-replays`: paced, resumable collection of the public replay
## archive, with durable progress and a manifest of every battle and replay.
##
## Requests to the site follow its robots.txt, are paced, and slow down on
## throttling instead of halting; a hard rejection halts the run and saves a
## cooldown. Progress lives in status.json and manifest.sqlite, so a rerun
## resumes where the last stopped.

import std/[httpclient, json, math, monotimes, os, posix, sequtils, strutils, times, uri]
import ../gamedata/sha256
import sqlite

const
  Base = "https://game.battlecode.au"
  Agent = "LoongReplayResearch/1.0"
  SlowDown = [429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
  MaxInterval = 60.0
  MaxConsecutiveRejections = 6
  FreeSpaceFloor = 5'i64 * 1024 * 1024 * 1024
  LockExclusive = 2
  LockNonBlocking = 4

proc flock(descriptor, operation: cint): cint {.importc, header: "<sys/file.h>".}

var interrupted: bool   ## set by SIGINT, which is how the collector's unit stops it

type
  Interrupted = object of CatchableError
  RejectedRequest = object of CatchableError
    status: int
    retryAfter: string

  RobotRules = object
    ## The rules of robots.txt that apply to us, in file order.
    rules: seq[tuple[allow: bool, path: string]]
    crawlDelay: float

  Client = object
    interval: float
    lastRequest: MonoTime
    started: bool
    requests, rejections: int
    robots: RobotRules
    http: HttpClient

# Page parsing

proc digitsAt(text: string, at: int): string =
  var index = at
  while index < text.len and text[index].isDigit:
    result.add text[index]
    inc index

proc allAfter(text, marker: string): seq[string] =
  ## The digits following each occurrence of `marker`.
  var at = text.find(marker)
  while at >= 0:
    let digits = text.digitsAt(at + marker.len)
    if digits.len > 0: result.add digits
    at = text.find(marker, at + 1)

proc stringLiteralAt(text: string, at: int): string =
  ## The JSON string literal starting at `at`, quotes included, or "".
  if at >= text.len or text[at] != '"': return
  var index = at + 1
  while index < text.len:
    if text[index] == '\\': index += 2
    elif text[index] == '"': return text[at .. index]
    else: inc index

proc listingFromPage*(page: string): tuple[identifiers: seq[int], lastPage: int] =
  ## The battles a listing page links to, and the listing's last page.
  const link = "href=\"/battles/"
  var at = page.find(link)
  while at >= 0:
    let digits = page.digitsAt(at + link.len)
    if digits.len > 0 and page.continuesWith("\"", at + link.len + digits.len) and
        parseInt(digits) notin result.identifiers:
      result.identifiers.add parseInt(digits)
    at = page.find(link, at + 1)
  let unescaped = page.multiReplace(("&amp;", "&"), ("&#38;", "&"), ("&#x26;", "&"))
  result.lastPage = 1
  for marker in ["?page=", "&page="]:
    for digits in unescaped.allAfter(marker): result.lastPage = max(result.lastPage, parseInt(digits))
  at = page.find("total:")
  while at >= 0:
    let count = page.digitsAt(at + 6)
    let pageAt = at + 6 + count.len + 6
    let pageDigits = page.digitsAt(pageAt)
    let perPageAt = pageAt + pageDigits.len + 9
    let perPage = page.digitsAt(perPageAt)
    if count.len > 0 and page.continuesWith(",page:", at + 6 + count.len) and
        pageDigits.len > 0 and page.continuesWith(",perPage:", pageAt + pageDigits.len) and
        perPage.len > 0:
      result.lastPage = max(result.lastPage, (parseInt(count) + parseInt(perPage) - 1) div parseInt(perPage))
      break
    at = page.find("total:", at + 1)
  if result.identifiers.len == 0:
    raise newException(ValueError, "No battle links; refusing to assume archive complete")

proc battleFromPage*(page: string): tuple[teams, games: JsonNode] =
  result.teams = newJArray()
  for side in ["A", "B"]:
    let identifier = page.allAfter("team" & side & "Id:")
    let nameMarker = "team" & side & "Name:"
    let nameAt = page.find(nameMarker)
    let name = if nameAt >= 0: page.stringLiteralAt(nameAt + nameMarker.len) else: ""
    if identifier.len == 0 or name.len == 0: raise newException(ValueError, "Battle participant schema changed")
    let submission = page.allAfter("submission" & side & "Id:")
    result.teams.add %*{"id": parseInt(identifier[0]), "name": parseJson(name).getStr,
      "side": side, "submission_id": (if submission.len > 0: %parseInt(submission[0]) else: newJNull())}
  let open = page.find("games:[")
  let close = if open >= 0: page.find(']', open + 7) else: -1
  if close < 0: raise newException(ValueError, "Battle game list missing")
  let list = page[open + 7 ..< close]
  result.games = newJArray()
  var at = list.find("{id:")
  while at >= 0:
    # {id:N,status:"S",winner:null|"W",hasReplay:true|false then } or ,...}
    block parse:
      var index = at + 4
      let identifier = list.digitsAt(index)
      index += identifier.len
      if identifier.len == 0 or not list.continuesWith(",status:\"", index): break parse
      index += 9
      let statusEnd = list.find('"', index)
      if statusEnd <= index or '\n' in list[index ..< statusEnd]: break parse
      let status = list[index ..< statusEnd]
      index = statusEnd + 1
      if not list.continuesWith(",winner:", index): break parse
      index += 8
      var winner = newJNull()
      if list.continuesWith("null", index): index += 4
      elif index < list.len and list[index] == '"':
        let winnerEnd = list.find('"', index + 1)
        if winnerEnd < 0 or '\n' in list[index ..< winnerEnd]: break parse
        winner = %list[index + 1 ..< winnerEnd]
        index = winnerEnd + 1
      else: break parse
      if not list.continuesWith(",hasReplay:", index): break parse
      index += 11
      let replay = if list.continuesWith("true", index): true
                   elif list.continuesWith("false", index): false
                   else: break parse
      index += (if replay: 4 else: 5)
      if index < list.len and list[index] == ',':
        while index < list.len and list[index] notin {'{', '}'}: inc index
      if index >= list.len or list[index] != '}': break parse
      result.games.add %*{"id": parseInt(identifier), "status": status, "winner": winner,
        "has_replay": replay}
    at = list.find("{id:", at + 1)
  if result.games.len == 0: raise newException(ValueError, "Battle game schema changed")

# Robots

proc parseRobots(text: string): RobotRules =
  ## The group for our agent, else the `*` group: its Allow and Disallow lines,
  ## first match wins as Python's robotparser reads them, and its Crawl-delay.
  var groups: seq[tuple[agents: seq[string], rules: seq[tuple[allow: bool, path: string]], delay: float]]
  var inAgents = false
  for raw in text.splitLines:
    let line = raw.split('#')[0].strip
    let colon = line.find(':')
    if colon < 0: continue
    let key = line[0 ..< colon].strip.toLowerAscii
    let value = line[colon + 1 .. ^1].strip
    case key
    of "user-agent":
      if not inAgents: groups.add (@[], @[], 0.0)
      groups[^1].agents.add value.toLowerAscii
      inAgents = true
    of "allow", "disallow":
      if groups.len == 0: continue
      inAgents = false
      if value.len == 0 and key == "disallow": groups[^1].rules.add (true, "")
      elif value.len > 0: groups[^1].rules.add (key == "allow", value.decodeUrl)
    of "crawl-delay":
      if groups.len == 0: continue
      inAgents = false
      try: groups[^1].delay = parseFloat(value) except ValueError: discard
    else: inAgents = false
  let name = Agent.split('/')[0].toLowerAscii
  var chosen = -1
  for index, group in groups:
    if group.agents.anyIt(it != "*" and it in name):
      chosen = index
      break
  if chosen < 0:
    for index, group in groups:
      if "*" in group.agents: chosen = index
  if chosen >= 0: result = RobotRules(rules: groups[chosen].rules, crawlDelay: groups[chosen].delay)

proc allows(robots: RobotRules, url: string): bool =
  let parsed = parseUri(url)
  var path = parsed.path & (if parsed.query.len > 0: "?" & parsed.query else: "")
  if path.len == 0: path = "/"
  for rule in robots.rules:
    if rule.path == "*" or path.decodeUrl.startsWith(rule.path): return rule.allow
  true

# Requests

proc say(line: string) =
  echo line
  flushFile(stdout)

proc pause(seconds: float) =
  ## Sleep in short steps, so SIGINT stops the run promptly.
  let until = getMonoTime() + initDuration(milliseconds = int(seconds * 1000))
  while getMonoTime() < until:
    if interrupted: raise newException(Interrupted, "interrupted")
    sleep(min(200, max(1, int((until - getMonoTime()).inMilliseconds))))

proc retryDelay(value: string): float =
  ## Seconds a Retry-After header asks for: a number or an HTTP date.
  if value.len == 0: return 0
  try: return parseFloat(value)
  except ValueError: discard
  try: return (parse(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()) - now().utc).inMilliseconds / 1000
  except CatchableError: return 0

proc rejected(status: int, retryAfter: string): ref RejectedRequest =
  result = newException(RejectedRequest, "HTTP " & $status & "; collector halted")
  result.status = status
  result.retryAfter = retryAfter

proc slowDown(client: var Client, status: int, retryAfter: string) =
  inc client.rejections
  if client.rejections > MaxConsecutiveRejections: raise rejected(status, retryAfter)
  client.interval = min(MaxInterval, max(client.interval * 2, 1.0))
  let pause = max(client.interval, retryDelay(retryAfter))
  say "HTTP " & $status & "; interval now " & formatFloat(client.interval, ffDecimal, 2) &
    "s, pausing " & $int(round(pause)) & "s"
  pause(pause)

proc fetch(client: var Client, resource: string, optionalRobots = false): string =
  ## A site resource, following HTTPS redirects without pacing them off the site.
  let site = parseUri(Base).hostname
  var url = $combine(parseUri(Base), parseUri(resource))
  var redirects = 0
  while redirects < 6:
    if interrupted: raise newException(Interrupted, "interrupted")
    let onSite = parseUri(url).hostname == site
    if onSite and not client.robots.allows(url):
      raise newException(ValueError, "robots.txt disallows " & resource)
    if onSite:
      if client.started:
        let waited = (getMonoTime() - client.lastRequest).inMilliseconds.float / 1000
        if waited < client.interval: pause(client.interval - waited)
      client.lastRequest = getMonoTime()
      client.started = true
    inc client.requests
    let response = client.http.request(url)
    let status = response.code.int
    if status < 300:
      client.rejections = 0
      return response.body
    let retryAfter = response.headers.getOrDefault("Retry-After")
    if optionalRobots and status in [404, 410]: return ""   # no robots policy published
    if status in [301, 302, 303, 307, 308]:
      url = $combine(parseUri(url), parseUri(response.headers.getOrDefault("Location")))
      if parseUri(url).scheme != "https": raise newException(ValueError, "Refusing non-HTTPS redirect")
      inc redirects
      continue
    if status in SlowDown and onSite:
      client.slowDown(status, retryAfter)
      url = $combine(parseUri(Base), parseUri(resource))
      redirects = 0
      continue
    raise rejected(status, retryAfter)
  raise newException(ValueError, "Too many redirects")

# Storage

proc freeBytes(path: string): int64 =
  var stats: Statvfs
  if statvfs(path.cstring, stats) != 0: raiseOSError(osLastError(), path)
  int64(stats.f_bavail) * int64(stats.f_frsize)

proc nonEmptyFile(path: string): bool =
  fileExists(path) and getFileSize(path) > 0

proc linkReplayStore(destination, replays: string) =
  ## Keep `<destination>/replays` as the path consumers use, linked to the store.
  let store = destination / "replays"
  let target = replays.absolutePath.normalizedPath
  createDir(target)
  if symlinkExists(store):
    if expandSymlink(store).absolutePath(destination).normalizedPath != target:
      raise newException(ValueError, store & " already links to " & expandSymlink(store))
  elif dirExists(store) or fileExists(store):
    raise newException(ValueError, store & " is a local directory; move it to " & target & " first")
  else: createSymlink(target, store)

# Collection

proc number(node: JsonNode, default = 0.0): float =
  ## A JSON number, integer or not.
  if node == nil: default
  elif node.kind == JInt: float(node.getInt)
  elif node.kind == JFloat: node.getFloat
  else: default

proc isoNow(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff") & "+00:00"

proc collect(destination: string, interval: float, battlesGiven: seq[int], maxGames: int,
    teams: seq[int], replays: string, totalGames: int): string =
  ## `maxGames` and `totalGames` 0 mean no limit.
  let destination = destination.absolutePath.normalizedPath
  createDir(destination)
  if replays.len > 0: linkReplayStore(destination, replays)
  createDir(destination / "replays")
  let statePath = destination / "status.json"
  var state = if fileExists(statePath): parseFile(statePath) else: %*{"page": 1, "status": "new"}
  if epochTime() < state{"retry_not_before"}.number:
    raise newException(ValueError, "Saved rejection cooldown has not elapsed; no requests sent")
  # WAL lets readers such as the ladder's target scorer run during a commit.
  let db = openDatabase(destination / "manifest.sqlite", 60_000)
  db.execute("PRAGMA journal_mode=WAL")
  db.execute("""
    CREATE TABLE IF NOT EXISTS battles (id INTEGER PRIMARY KEY, teams TEXT, games TEXT);
    CREATE TABLE IF NOT EXISTS replays (id INTEGER PRIMARY KEY,
        battle INTEGER, sha256 TEXT,
        bytes INTEGER, downloaded_at TEXT, source TEXT);
    """)
  var client = Client(interval: interval,
    http: newHttpClient(userAgent = Agent, maxRedirects = 0, timeout = 60_000))
  state["status"] = %"running"
  if state.hasKey("error"): state.delete("error")
  state["started_at"] = %isoNow()

  proc downloaded(): int = parseInt(db.rows("SELECT COUNT(*) FROM replays")[0][0])

  proc save() =
    state["updated_at"] = %isoNow()
    state["requests_this_run"] = %client.requests
    state["interval"] = %client.interval
    state["downloaded_games"] = %downloaded()
    writeFile(statePath.changeFileExt("tmp"), state.pretty(2) & "\n")
    moveFile(statePath.changeFileExt("tmp"), statePath)

  proc sampleComplete(): bool = totalGames > 0 and downloaded() >= totalGames

  proc processBattle(identifier: int): bool =
    var teams, games: JsonNode
    let cached = db.rows("SELECT teams,games FROM battles WHERE id=?", identifier)
    if cached.len > 0:
      (teams, games) = (parseJson(cached[0][0]), parseJson(cached[0][1]))
    else:
      (teams, games) = battleFromPage(client.fetch("/visualiser?match=" & $identifier))
      discard db.rows("INSERT INTO battles VALUES (?,?,?)", identifier, $teams, $games)
    var available: seq[JsonNode]
    for game in games:
      if game["has_replay"].getBool and game["status"].getStr == "completed": available.add game
    if maxGames > 0 and available.len > maxGames: available.setLen(maxGames)
    for game in available:
      if sampleComplete(): return true
      let gameId = game["id"].getInt
      let target = destination / "replays" / $gameId & ".replay"
      let exists = nonEmptyFile(target)
      if exists and db.rows("SELECT 1 FROM replays WHERE id=?", gameId).len > 0: continue
      if freeBytes(destination / "replays") < FreeSpaceFloor: raise newException(IOError, "Less than 5 GiB free for replays; collection paused")
      state["current_game"] = %gameId
      save()
      let source = "/api/matches/" & $gameId & "/replay"
      var payload: string
      if exists:
        payload = readFile(target)
      else: payload = client.fetch(source)
      let start = payload.strip(trailing = false)
      if payload.len == 0 or start.startsWith("<") or start.startsWith("{\"error\""):
        raise newException(ValueError, "Replay response was empty, HTML, or an error document")
      if not exists:
        writeFile(target.changeFileExt("partial"), payload)
        moveFile(target.changeFileExt("partial"), target)
      discard db.rows("INSERT OR REPLACE INTO replays VALUES (?,?,?,?,?,?)", gameId, identifier,
        sha256Hex(payload), payload.len, isoNow(), Base & source)
      save()
      say (if exists: "Reused " else: "Downloaded ") & $gameId & "; total=" & $state["downloaded_games"].getInt

  try:
    if sampleComplete():
      state["status"] = %"completed_sample"
      return "completed_sample"
    client.robots = parseRobots(client.fetch("/robots.txt", optionalRobots = true))
    client.interval = max(interval, client.robots.crawlDelay)
    var battles = battlesGiven
    if teams.len > 0:
      # Every series each team played, via the listing's team filter.
      for team in teams:
        var (page, lastPage) = (1, 1)
        while page <= lastPage:
          let (identifiers, last) = listingFromPage(client.fetch("/battles?teams=" & $team & "&page=" & $page))
          lastPage = last
          battles.add identifiers
          inc page
        say "Team " & $team & ": " & $battles.deduplicate.len & " series so far"
      battles = battles.deduplicate
    if battles.len > 0:
      for identifier in battles:
        if processBattle(identifier):
          state["status"] = %"completed_sample"
          return "completed_sample"
      state["status"] = %"completed_targeted_batch"
      return "completed_targeted_batch"
    if state{"order"}.getStr != "newest":
      state["order"] = %"newest"
      state["page"] = %1
      if state.hasKey("last_page"): state.delete("last_page")
    while state{"last_page"} == nil or state["page"].getInt <= state["last_page"].getInt:
      let (identifiers, lastPage) = listingFromPage(
        client.fetch("/battles?sort=at&dir=desc&page=" & $state["page"].getInt))
      state["last_page"] = %max(state{"last_page"}.getInt(0), lastPage)
      save()
      for identifier in identifiers:
        if processBattle(identifier):
          state["status"] = %"completed_sample"
          return "completed_sample"
      state["page"] = %(state["page"].getInt + 1)
      save()
    # Revisit unfinished series once; this is not an endless live feed.
    var pending: seq[int]
    for row in db.rows("SELECT id,games FROM battles"):
      for game in parseJson(row[1]):
        if game["status"].getStr != "completed":
          pending.add parseInt(row[0])
          break
    for identifier in pending:
      discard db.rows("DELETE FROM battles WHERE id=?", identifier)
      if processBattle(identifier):
        state["status"] = %"completed_sample"
        return "completed_sample"
    var unavailable = 0
    for row in db.rows("SELECT games FROM battles"):
      for game in parseJson(row[0]):
        if not game["has_replay"].getBool or game["status"].getStr != "completed": inc unavailable
    state["unavailable_games"] = %unavailable
    state["status"] = %"completed_discovered_snapshot"
    result = "completed_discovered_snapshot"
  except RejectedRequest as error:
    let delay = max(3600.0, retryDelay(error.retryAfter))
    state["status"] = %"halted_on_rejection"
    state["http_status"] = %error.status
    state["retry_after"] = if error.retryAfter.len > 0: %error.retryAfter else: newJNull()
    state["retry_not_before"] = %(epochTime() + delay)
    say error.msg
    result = "halted_on_rejection"
  except CatchableError as error:
    state["status"] = %"paused"
    state["error"] = %error.msg
    raise
  finally:
    save()
    db.close()

const Usage = """
loong-sample-replays [--count N | --all] [--output DIR] [--interval SECONDS]
    [--battles ID...] [--teams ID...] [--max-games N] [--replays DIR]
  Collect public replays into DIR (default public-replays): manifest.sqlite,
  status.json and DIR/replays, linked to --replays when given. Samples
  --count games (default 5), or with --all the whole archive, newest first;
  --battles and --teams restrict it to those series. --interval (default 2,
  at least 0.2) is the starting pause between site requests. Exits 0 when the
  collection completed and 2 when it halted."""

when isMainModule:
  var count = 5
  var all = false
  var output = "public-replays"
  var interval = 2.0
  var battles, teams: seq[int]
  var maxGames = 0
  var replays = ""
  let arguments = commandLineParams()
  var at = 0
  proc value(): string =
    inc at
    if at >= arguments.len or arguments[at].startsWith("--"): quit(Usage, 2)
    arguments[at]
  while at < arguments.len:
    case arguments[at]
    of "--count": count = parseInt(value())
    of "--all": all = true
    of "--output": output = value()
    of "--interval": interval = parseFloat(value())
    of "--max-games": maxGames = parseInt(value())
    of "--replays": replays = value()
    of "--battles", "--teams":
      let list = arguments[at]
      while at + 1 < arguments.len and not arguments[at + 1].startsWith("--"):
        inc at
        if list == "--battles": battles.add parseInt(arguments[at]) else: teams.add parseInt(arguments[at])
    of "-h", "--help": quit(Usage, 0)
    else: quit(Usage, 2)
    inc at
  if count < 1 or interval < 0.2 or interval.classify in {fcNan, fcInf}:
    quit("Require a positive count and a finite interval of at least 0.2 seconds", 2)
  createDir(output)
  let lock = posix.open(cstring(output / "collector.lock"), O_WRONLY or O_CREAT, 0o644)
  if lock < 0 or flock(lock, LockExclusive or LockNonBlocking) != 0:
    quit("Another collector holds " & output / "collector.lock", 1)
  setControlCHook(proc () {.noconv.} = interrupted = true)
  let status = collect(output, interval, battles, maxGames, teams, replays,
    if all: 0 else: count)
  quit(if status in ["completed_sample", "completed_discovered_snapshot",
    "completed_targeted_batch"]: 0 else: 2)
