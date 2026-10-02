## `loong-sample-replays`: paced, resumable collection of the public replay
## archive, with durable progress and participant indexes (README.md).
##
## Requests to the site are paced and slow down on throttling instead of
## halting; a hard rejection halts the run and saves a cooldown. Only the games
## retention.nim's classes select are downloaded, and a full store evicts the
## least protected first. Progress lives in status.json and manifest.sqlite, so
## a rerun resumes where the last stopped; a transient NAS error is retried
## after a pause instead of ending the run, and a network timeout or failed
## connection is retried with a fresh connection, then ends the run as paused,
## so the next run resumes. No submission provenance or private releases are read.

import std/[algorithm, httpclient, json, math, monotimes, net, os, posix, sequtils, sets, strutils, tables, times, uri]
import ../gamedata/sha256
import retention, sqlite

const
  Base = "https://game.battlecode.au"
  Agent = "LoongReplayResearch/1.0"
  SlowDown = [429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
  MaxInterval = 60.0
  MaxConsecutiveRejections = 6
  FreeSpaceFloor = 5'i64 * 1024 * 1024 * 1024
  ## Linux errno values of a NAS mount that has gone away for a while
  ## (EIO, ENOTCONN, ETIMEDOUT, EHOSTDOWN, ESTALE): retried, not fatal.
  TransientErrors = [5'i32, 107, 110, 112, 116]
  LockExclusive = 2
  LockNonBlocking = 4
  NasPause = 30_000
  NasAttempts = 60
  ## A request that times out or loses its connection is retried this many
  ## times, after a pause growing by NetworkPause each attempt.
  NetworkAttempts = 5
  NetworkPause = 30_000
  ## A refresh stops after this many listing pages in a row hold only cached
  ## series: new series land among cached ones over the first dozen pages.
  RefreshCachedPages = 3

proc flock(descriptor, operation: cint): cint {.importc, header: "<sys/file.h>".}

var interrupted: bool   ## set by SIGINT, which is how the collector's unit stops it
var selectedTeam = OurTeam
var ratingsPath: string

type
  Interrupted = object of CatchableError
  RejectedRequest = object of CatchableError
    status: int
    retryAfter: string
  NetworkUnavailable = object of CatchableError
    ## The site stayed unreachable through every retry.

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

proc ratingsFromBoard*(board: JsonNode): JsonNode =
  ## Every rated team on the leaderboard; the public page lists only the top ten.
  result = newJObject()
  for row in board:
    if row{"elo"} != nil and row["elo"].kind != JNull:
      result[$row["id"].getInt] = %*{"id": row["id"], "name": row["name"],
        "elo": row["elo"].getFloat}
  if result.len == 0: raise newException(ValueError, "Leaderboard schema changed or returned no ratings")

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

proc integerAfter(text, marker: string): JsonNode =
  ## The integer, possibly negative, after the first `marker`, or null.
  let at = text.find(marker)
  if at < 0: return newJNull()
  var index = at + marker.len
  let negative = index < text.len and text[index] == '-'
  if negative: inc index
  let digits = text.digitsAt(index)
  if digits.len == 0: return newJNull()
  %(if negative: -parseBiggestInt(digits) else: parseBiggestInt(digits))

proc matchFromPage(page: string): JsonNode =
  ## When the series was requested, whether it was ranked, its seed, and each
  ## team's Elo and change as the page showed them when fetched.
  let requested = page.integerAfter("requestedAt:new Date(")
  let seedAt = page.find("seed:")
  let seed = if seedAt >= 0: page.stringLiteralAt(seedAt + 5) else: ""
  let ranked = if "ranked:true" in page: %true elif "ranked:false" in page: %false else: newJNull()
  %*{"requested_at": (if requested.kind == JInt:
      %(initTime(requested.getBiggestInt div 1000, int(requested.getBiggestInt mod 1000) * 1_000_000).utc.format(
        "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")) else: newJNull()),
    "ranked": ranked, "seed": (if seed.len > 0: %parseJson(seed).getStr else: newJNull()),
    "elo_a": page.integerAfter("teamAElo:"), "elo_b": page.integerAfter("teamBElo:"),
    "elo_change_a": page.integerAfter("eloChangeA:"), "elo_change_b": page.integerAfter("eloChangeB:")}

proc battleFromPage*(page: string): tuple[teams, games, match: JsonNode] =
  result.match = matchFromPage(page)
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
    # {id:N,status:"S",winner:null|"W",hasReplay:true|false then ,mapName:"M"
    # and } or ,...}
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
      var map = newJNull()
      if list.continuesWith(",mapName:", index):
        let name = list.stringLiteralAt(index + 9)
        if name.len > 0:
          map = %parseJson(name).getStr
          index += 9 + name.len
      if index < list.len and list[index] == ',':
        while index < list.len and list[index] notin {'{', '}'}: inc index
      if index >= list.len or list[index] != '}': break parse
      result.games.add %*{"id": parseInt(identifier), "status": status, "winner": winner,
        "has_replay": replay, "map": map}
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

template onNetwork(what: string, reset, body: untyped): untyped =
  ## `body`, retried with `reset` run first after a timeout or failed
  ## connection; NetworkUnavailable once NetworkAttempts are spent.
  var attempt = 0
  while true:
    try:
      body
      break
    except TimeoutError, OSError, IOError, ProtocolError:
      let message = getCurrentExceptionMsg()
      inc attempt
      if attempt >= NetworkAttempts:
        raise newException(NetworkUnavailable,
          what & ": " & message & " after " & $attempt & " attempts")
      say what & ": " & message & "; retrying in " & $(NetworkPause div 1000 * attempt) & "s"
      pause(float(NetworkPause div 1000 * attempt))
      reset

proc siteClient(): HttpClient =
  newHttpClient(userAgent = Agent, maxRedirects = 0, timeout = 60_000)

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
    var response: Response
    # A timed-out connection can't be reused, so each retry opens a new one.
    onNetwork(resource):
      client.http.close()
      client.http = siteClient()
    do:
      response = client.http.request(url)
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

proc leaderboard(): JsonNode =
  ## The authenticated API's full leaderboard, with the user's toolkit key.
  let key = parseFile(getHomeDir() / ".unswbc/keys.json")[Base].getStr
  proc client(): HttpClient =
    newHttpClient(timeout = 90_000, headers = newHttpHeaders({"Authorization": "Bearer " & key}))
  var http = client()
  var response: Response
  try:
    onNetwork("leaderboard"):
      http.close()
      http = client()
    do:
      response = http.request(Base & "/api/v1/leaderboard?limit=200")
    if response.code.int >= 400: raise newException(IOError, "leaderboard: HTTP " & $response.code.int)
    result = parseJson(response.body)
  finally:
    http.close()

# The NAS

template onNas(action: string, body: untyped): untyped =
  ## `body`, retried after a pause while the NAS mount is away.
  var attempt = 0
  while true:
    try:
      body
      break
    except OSError, IOError:
      let code = osLastError().int32
      inc attempt
      if code notin TransientErrors or attempt >= NasAttempts: raise
      say action & ": " & osErrorMsg(OSErrorCode(code)) & "; retrying in " & $(NasPause div 1000) & "s"
      pause(NasPause / 1000)

proc freeBytes(path: string): int64 =
  var stats: Statvfs
  if statvfs(path.cstring, stats) != 0: raiseOSError(osLastError(), path)
  int64(stats.f_bavail) * int64(stats.f_frsize)

proc nonEmptyFile(path: string): bool =
  onNas("stat " & path):
    result = fileExists(path) and getFileSize(path) > 0

# Collection

proc number(node: JsonNode, default = 0.0): float =
  ## A JSON number, integer or not.
  if node == nil: default
  elif node.kind == JInt: float(node.getInt)
  elif node.kind == JFloat: node.getFloat
  else: default

proc isoNow(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff") & "+00:00"

proc openManifest(destination: string): Database =
  ## The collection's manifest: battles seen, replays stored and pins held.
  createDir(destination)
  # WAL lets readers such as the ladder's target scorer run during a commit.
  result = openDatabase(destination / "manifest.sqlite", 60_000)
  result.execute("PRAGMA journal_mode=WAL")
  result.execute("""
    CREATE TABLE IF NOT EXISTS battles (id INTEGER PRIMARY KEY, teams TEXT, games TEXT);
    CREATE TABLE IF NOT EXISTS replays (id INTEGER PRIMARY KEY,
        battle INTEGER, sha256 TEXT,
        bytes INTEGER, downloaded_at TEXT, source TEXT);
    CREATE TABLE IF NOT EXISTS pins (game INTEGER, role TEXT, reason TEXT, pinned_at TEXT,
        PRIMARY KEY (game, role, reason));
    """)
  # `match` (matchFromPage) came later; battles cached before it have none.
  if not result.rows("PRAGMA table_info(battles)").anyIt(it[1] == "match"):
    result.execute("ALTER TABLE battles ADD COLUMN match TEXT")

proc snapshotTeams(): JsonNode =
  ## Every rated team from one authenticated leaderboard request.
  if ratingsPath.len > 0:
    let saved = parseFile(ratingsPath)
    if saved.kind == JArray: ratingsFromBoard(saved)
    elif saved{"teams"} != nil: saved["teams"]
    else: saved
  else: ratingsFromBoard(leaderboard())

proc collect(destination: string, interval: float, battlesGiven: seq[int], maxGames: int,
    teams: seq[int], replays: string, totalGames: int, pinRole, pinReason: string): string =
  ## `maxGames` and `totalGames` 0 mean no limit. With `pinRole`, every game of
  ## the given battles and teams is pinned for that role and reason.
  let destination = destination.absolutePath.normalizedPath
  createDir(destination)
  createDir(replays)
  let statePath = destination / "status.json"
  var state = if fileExists(statePath): parseFile(statePath) else: %*{"page": 1, "status": "new"}
  if epochTime() < state{"retry_not_before"}.number:
    raise newException(ValueError, "Saved rejection cooldown has not elapsed; no requests sent")
  let db = openManifest(destination)
  var kept: Retention
  var client = Client(interval: interval,
    http: siteClient())
  state["status"] = %"running"
  if state.hasKey("error"): state.delete("error")
  state["started_at"] = %isoNow()

  proc downloaded(): int = parseInt(db.rows("SELECT COUNT(*) FROM replays")[0][0])

  proc save() =
    state["updated_at"] = %isoNow()
    state["requests_this_run"] = %client.requests
    state["interval"] = %client.interval
    state["downloaded_games"] = %downloaded()
    state["store_bytes"] = %kept.storedBytes
    onNas("write " & statePath):
      writeFile(statePath.changeFileExt("tmp"), state.pretty(2) & "\n")
      moveFile(statePath.changeFileExt("tmp"), statePath)

  proc sampleComplete(): bool = totalGames > 0 and downloaded() >= totalGames

  proc evict(game, class: int) =
    ## Delete a stored replay and its manifest row.
    let target = replays / $game & ".replay"
    onNas("remove " & target): removeFile(target)
    discard db.rows("DELETE FROM replays WHERE id=?", game)
    kept.storedBytes -= kept.stored[game]
    kept.stored.del game
    say "Evicted " & $game & " (" & ClassNames[class] & ")"

  proc makeRoom(class, game: int, requiredBytes = 0'i64): bool =
    ## Evict until a replay of average size fits under the cap, taking only
    ## games less protected than this one, or as protected and older.
    let bytes = if requiredBytes > 0: requiredBytes
      elif kept.stored.len > 0: kept.storedBytes div kept.stored.len
      else: 1_000_000
    if bytes > StoreCap: return false
    if kept.storedBytes + bytes <= StoreCap: return true
    for (candidateClass, candidate) in kept.evictionOrder:
      if candidateClass > class or (candidateClass == class and candidate >= game): break
      evict(candidate, candidateClass)
      if kept.storedBytes + bytes <= StoreCap: return true

  proc processBattle(identifier: int): bool =
    var teams, games, match: JsonNode
    let cached = db.rows("SELECT teams,games,match FROM battles WHERE id=?", identifier)
    if cached.len > 0:
      (teams, games) = (parseJson(cached[0][0]), parseJson(cached[0][1]))
    # Refresh a battle that was still being played when cached.
    if cached.len == 0 or not games.allIt(it.finished):
      (teams, games, match) = battleFromPage(client.fetch("/visualiser?match=" & $identifier))
      discard db.rows("INSERT OR REPLACE INTO battles (id,teams,games,match) VALUES (?,?,?,?)",
        identifier, $teams, $games, $match)
    kept.addBattle(teams, games)
    var available: seq[JsonNode]
    for game in games:
      if game.downloadable: available.add game
    if maxGames > 0 and available.len > maxGames: available.setLen(maxGames)
    if pinRole.len > 0:
      for game in available:
        discard db.rows("INSERT OR IGNORE INTO pins VALUES (?,?,?,?)", game["id"].getInt,
          pinRole, pinReason, isoNow())
        kept.pins.incl game["id"].getInt
    for game in available:
      if sampleComplete(): return true
      let gameId = game["id"].getInt
      let class = kept.keepClass(gameId)
      if class == 0: continue   # no retention class selects it
      let target = replays / $gameId & ".replay"
      let exists = nonEmptyFile(target)
      if exists and gameId in kept.stored: continue
      if not exists and not makeRoom(class, gameId):
        say "Store full of more protected replays; skipped " & $gameId
        continue
      var free: int64
      onNas("free space"): free = freeBytes(replays)
      if free < FreeSpaceFloor: raise newException(IOError, "Less than 5 GiB free for replays; collection paused")
      state["current_game"] = %gameId
      save()
      let source = "/api/matches/" & $gameId & "/replay"
      var payload: string
      if exists:
        onNas("read " & target): payload = readFile(target)
      else: payload = client.fetch(source)
      let start = payload.strip(trailing = false)
      if payload.len == 0 or start.startsWith("<") or start.startsWith("{\"error\""):
        raise newException(ValueError, "Replay response was empty, HTML, or an error document")
      if not makeRoom(class, gameId, int64(payload.len)):
        say "Replay does not fit below the store cap; skipped " & $gameId
        continue
      if not exists:
        onNas("write " & target):
          writeFile(target.changeFileExt("partial"), payload)
          moveFile(target.changeFileExt("partial"), target)
      discard db.rows("INSERT OR REPLACE INTO replays VALUES (?,?,?,?,?,?)", gameId, identifier,
        sha256Hex(payload), payload.len, isoNow(), Base & source)
      kept.storedBytes += int64(payload.len) - kept.stored.getOrDefault(gameId)
      kept.stored[gameId] = payload.len
      # A newer game pushes the oldest out of each of its teams' samples.
      for team in kept.teamsOf[gameId]:
        for old in kept.outOfSample(team):
          if old in kept.stored and kept.keepClass(old) == 0: evict(old, 0)
      save()
      say (if exists: "Reused " else: "Downloaded ") & $gameId & "; total=" & $state["downloaded_games"].getInt

  try:
    if sampleComplete():
      state["status"] = %"completed_sample"
      return "completed_sample"
    client.robots = parseRobots(client.fetch("/robots.txt", optionalRobots = true))
    client.interval = max(interval, client.robots.crawlDelay)
    # Refreshed each run: newest-first collection makes current ratings the
    # nearest stand-in for ratings at game time.
    let snapshot = %*{"observed_at": isoNow(), "source": Base & "/api/v1/leaderboard",
      "teams": snapshotTeams()}
    onNas("write ratings"): writeFile(destination / "ratings.json", snapshot.pretty(2) & "\n")
    kept = loadRetention(db, snapshot["teams"], selectedTeam)
    state["ratings_observed_at"] = snapshot["observed_at"]
    save()
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
      for key in ["last_page", "refresh", "cached_pages"]:
        if state.hasKey(key): state.delete(key)
    elif state{"last_page"} != nil and state["page"].getInt > state["last_page"].getInt:
      # A finished crawl starts again from the newest page as a refresh, which
      # stops once RefreshCachedPages pages in a row hold only cached series, so
      # the newest-game samples keep up. An interrupted refresh resumes like a crawl.
      state["page"] = %1
      state["refresh"] = %true
      state["cached_pages"] = %0
    while state{"last_page"} == nil or state["page"].getInt <= state["last_page"].getInt:
      let (identifiers, lastPage) = listingFromPage(
        client.fetch("/battles?sort=at&dir=desc&page=" & $state["page"].getInt))
      state["last_page"] = %max(state{"last_page"}.getInt(0), lastPage)
      save()
      var cached = 0
      for identifier in identifiers:
        if db.rows("SELECT 1 FROM battles WHERE id=?", identifier).len > 0: inc cached
      for identifier in identifiers:
        if processBattle(identifier):
          state["status"] = %"completed_sample"
          return "completed_sample"
      let page = state["page"].getInt
      state["page"] = %(page + 1)
      if state{"refresh"}.getBool:
        say "Refresh page " & $page & ": " & $cached & " of " & $identifiers.len &
          " series already cached"
        let known = identifiers.len > 0 and cached == identifiers.len
        state["cached_pages"] = %(if known: state["cached_pages"].getInt + 1 else: 0)
        if state["cached_pages"].getInt >= RefreshCachedPages:
          say "Refresh reached " & $RefreshCachedPages & " cached pages at page " & $page
          state["page"] = %(state["last_page"].getInt + 1)
      save()
    for key in ["refresh", "cached_pages"]:
      if state.hasKey(key): state.delete(key)
    # Revisit unfinished series once; this is not an endless live feed.
    var pending: seq[int]
    for row in db.rows("SELECT id,games FROM battles"):
      if not parseJson(row[1]).allIt(it.finished): pending.add parseInt(row[0])
    for identifier in pending:
      if processBattle(identifier):
        state["status"] = %"completed_sample"
        return "completed_sample"
    # A team that rises into a class brings older games into its sample that
    # were skipped when they were first seen; fetch every selected game missing.
    var unfilled: seq[int]
    for row in db.rows("SELECT id,games FROM battles"):
      if parseJson(row[1]).anyIt(it.downloadable and it["id"].getInt notin kept.stored and
          kept.keepClass(it["id"].getInt) > 0):
        unfilled.add parseInt(row[0])
    if unfilled.len > 0: say "Filling samples from " & $unfilled.len & " series"
    for identifier in unfilled:
      if processBattle(identifier):
        state["status"] = %"completed_sample"
        return "completed_sample"
    var unavailable = 0
    for row in db.rows("SELECT games FROM battles"):
      for game in parseJson(row[0]):
        if not game.downloadable: inc unavailable
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
  except NetworkUnavailable as error:
    # The state is saved, so the next run resumes where this one stopped.
    state["status"] = %"paused_network"
    state["error"] = %error.msg
    say error.msg
    result = "paused_network"
  except CatchableError as error:
    state["status"] = %"paused"
    state["error"] = %error.msg
    raise
  finally:
    save()
    db.close()

proc gameIds(listPath: string): seq[int] =
  ## Game ids from a file, one per line, bare or as `<id>.replay`.
  for line in lines(listPath):
    let name = line.strip
    if name.len > 0: result.add parseInt(name.split('.')[0])

proc prunePlan(destination, listPath: string) =
  ## The stored replays retention would delete now: every game no class selects,
  ## then, while the store is over the cap, the least protected, oldest first.
  ## Writes their file names to `listPath` and changes nothing.
  let db = openManifest(destination)
  defer: db.close()
  let kept = loadRetention(db, snapshotTeams(), selectedTeam)
  var bytes = kept.storedBytes
  var names: seq[string]
  var deleted, remaining: array[ClassNames.len, (int, int64)]
  for (class, game) in kept.evictionOrder:
    if class > 0 and bytes <= StoreCap:
      remaining[class][0] += 1
      remaining[class][1] += kept.stored[game]
      continue
    names.add $game & ".replay"
    bytes -= kept.stored[game]
    deleted[class][0] += 1
    deleted[class][1] += kept.stored[game]
  writeFile(listPath, names.join("\n") & (if names.len > 0: "\n" else: ""))
  var above, top = 0
  for rating in kept.ratings.values:
    if rating > kept.ourRating: inc above
    if rating >= TopRating: inc top
  say "Our rating " & $kept.ourRating & ", " & $above & " teams above us, " & $top &
    " at " & $TopRating & " or more; " & $kept.stored.len & " stored replays, " &
    formatFloat(float(kept.storedBytes) / 1e9, ffDecimal, 1) & " GB"
  for class, name in ClassNames:
    say "  " & name & ": keep " & $remaining[class][0] & " (" &
      formatFloat(float(remaining[class][1]) / 1e9, ffDecimal, 1) & " GB), delete " &
      $deleted[class][0] & " (" & formatFloat(float(deleted[class][1]) / 1e9, ffDecimal, 1) & " GB)"
  say $names.len & " replays to delete, listed in " & listPath

proc pruneDrop(destination, replays, listPath: string) =
  ## Drop the manifest rows of listed replays whose files are gone.
  let db = openManifest(destination)
  defer: db.close()
  var dropped, present = 0
  for game in gameIds(listPath):
    if nonEmptyFile(replays / $game & ".replay"): inc present
    else:
      discard db.rows("DELETE FROM replays WHERE id=?", game)
      inc dropped
  say "Dropped " & $dropped & " manifest rows; " & $present & " listed replays still exist and keep theirs"

proc pinGames(destination, listPath, role, reason: string) =
  let db = openManifest(destination)
  defer: db.close()
  var missing = 0
  let games = gameIds(listPath)
  for game in games:
    discard db.rows("INSERT OR IGNORE INTO pins VALUES (?,?,?,?)", game, role, reason, isoNow())
    if db.rows("SELECT 1 FROM replays WHERE id=?", game).len == 0: inc missing
  say "Pinned " & $games.len & " games for " & role & " (" & reason & "); " & $missing & " are not stored"

proc releasePins(destination, role, reason: string) =
  ## Release a role's pins: all of them, or those with `reason`.
  let db = openManifest(destination)
  defer: db.close()
  let before = parseInt(db.rows("SELECT COUNT(*) FROM pins")[0][0])
  if reason.len > 0: discard db.rows("DELETE FROM pins WHERE role=? AND reason=?", role, reason)
  else: discard db.rows("DELETE FROM pins WHERE role=?", role)
  say "Released " & $(before - parseInt(db.rows("SELECT COUNT(*) FROM pins")[0][0])) & " pins"

const Usage = """
loong-sample-replays [--count N | --all] [--output DIR] [--interval SECONDS]
    [--own-team ID] [--ratings FILE]
    [--battles ID...] [--teams ID...] [--pin-role ROLE --pin-reason TEXT]
    [--max-games N] [--replays DIR]
  Collect public replays into DIR (default public-replays): manifest.sqlite,
  status.json and ratings.json there, and one ID.replay per game in --replays
  (default DIR/replays). No collection starts unless this command is invoked.
  --own-team ID is required for collection and prune planning. Retention keeps
  your team's games, the newest 500 per team rated 1950+, explicit pins, and
  the newest 40 per team above your rating, under a 100 GB decimal replay cap.
  Reads your toolkit API key from ~/.unswbc/keys.json. --ratings FILE uses a
  saved ratings.json or leaderboard array. Requests start two seconds apart,
  follow robots rules, slow down on throttling, and save progress on interruption.
  --count defaults to 5; --all scans a finite discovered snapshot newest first.
  --battles ID... and --teams ID... restrict collection. Pin options pin their
  games. --max-games caps games per battle. Exits 0 on completion, 2 on pause.

loong-sample-replays --output DIR --prune-plan LIST
  Write to LIST the stored replays retention would delete now (every game no
  class selects, then the least protected while over the cap), print what
  each class keeps and loses, and change nothing.
loong-sample-replays --output DIR [--replays DIR] --prune-drop LIST
  Drop the manifest rows of LIST's replays whose files are gone.
loong-sample-replays --output DIR --pin-games LIST --pin-role ROLE --pin-reason TEXT
  Pin LIST's game ids (one per line, bare or as ID.replay) for ROLE.
loong-sample-replays --output DIR --release-pins --pin-role ROLE [--pin-reason TEXT]
  Release ROLE's pins, or only those with TEXT."""

when isMainModule:
  var count = 5
  var all = false
  var output = "public-replays"
  var interval = 2.0
  var battles, teams: seq[int]
  var maxGames = 0
  var replays, pinRole, pinReason, pinList, planList, dropList = ""
  var release = false
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
    of "--own-team": selectedTeam = parseInt(value())
    of "--ratings": ratingsPath = value()
    of "--interval": interval = parseFloat(value())
    of "--max-games": maxGames = parseInt(value())
    of "--replays": replays = value()
    of "--pin-role": pinRole = value()
    of "--pin-reason": pinReason = value()
    of "--pin-games": pinList = value()
    of "--release-pins": release = true
    of "--prune-plan": planList = value()
    of "--prune-drop": dropList = value()
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
  if (pinRole.len > 0) != (pinReason.len > 0) and not release:
    quit("--pin-role and --pin-reason go together", 2)
  if pinList.len > 0:
    if pinRole.len == 0: quit("--pin-games needs --pin-role and --pin-reason", 2)
    pinGames(output.absolutePath.normalizedPath, pinList, pinRole, pinReason)
    quit(0)
  if release:
    if pinRole.len == 0: quit("--release-pins needs --pin-role", 2)
    releasePins(output.absolutePath.normalizedPath, pinRole, pinReason)
    quit(0)
  if selectedTeam <= 0 and dropList.len == 0:
    quit("Collection and prune planning require --own-team ID", 2)
  createDir(output)
  if replays.len == 0: replays = output / "replays"
  replays = replays.absolutePath.normalizedPath
  let lock = posix.open(cstring(output / "collector.lock"), O_WRONLY or O_CREAT, 0o644)
  if lock < 0: quit("Cannot open " & output / "collector.lock", 1)
  if flock(lock, LockExclusive or LockNonBlocking) != 0:
    # A targeted run, such as the ladder fetching particular games, waits its turn.
    if battles.len == 0 and teams.len == 0: quit("Another collector holds " & output / "collector.lock", 1)
    say "Waiting for the collector holding " & output / "collector.lock"
    if flock(lock, LockExclusive) != 0: quit("Cannot lock " & output / "collector.lock", 1)
  if planList.len > 0:
    prunePlan(output.absolutePath.normalizedPath, planList)
    quit(0)
  if dropList.len > 0:
    pruneDrop(output.absolutePath.normalizedPath, replays, dropList)
    quit(0)
  setControlCHook(proc () {.noconv.} = interrupted = true)
  let status = collect(output, interval, battles, maxGames, teams, replays,
    if all or battles.len > 0 or teams.len > 0: 0 else: count, pinRole, pinReason)
  quit(if status in ["completed_sample", "completed_discovered_snapshot",
    "completed_targeted_batch"]: 0 else: 2)
