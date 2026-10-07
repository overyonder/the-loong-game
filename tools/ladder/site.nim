## The competition site's authenticated API (`/api/v1`), with the team's key
## from `~/.unswbc/keys.json`. A request the site refuses for its rate limit
## (HTTP 429) waits its `Retry-After` and tries again, three times at most,
## unless `retry` is off, as a write's must be: a repeated POST can create a
## second battle. Writes are the ladder operations' to guard (ladder_ops.nim).

import std/[httpclient, json, os]
when not defined(ladderChecks): import std/strutils

const
  Server* = "https://game.battlecode.au"
  Api* = Server & "/api/v1"

type SiteError* = object of IOError
  status*: int       ## the HTTP status the site answered with
  body*:   string    ## its response, which names the reason

proc apiKey*(): string =
  parseFile(getHomeDir() / ".unswbc/keys.json")[Server].getStr

when defined(ladderChecks):
  var fixtureRequest*: proc(path: string, verb: HttpMethod, body: JsonNode, retry: bool): JsonNode

proc apiRequest*(path: string, verb = HttpGet, body: JsonNode = nil, retry = true): JsonNode =
  ## The site's JSON answer to `verb path`, or null for an empty one.
  when defined(ladderChecks):
    # Offline checks cannot fall through to the competition account.
    if fixtureRequest.isNil: raise newException(IOError, "missing offline site fixture")
    return fixtureRequest(path, verb, body, retry)
  else:
    var headers = newHttpHeaders({"Authorization": "Bearer " & apiKey()})
    if not body.isNil: headers["Content-Type"] = "application/json"
    let client = newHttpClient(timeout = 60_000, headers = headers)
    defer: client.close()
    for attempt in 0 ..< 4:
      let response = client.request(Api & path, httpMethod = verb,
                                    body = if body.isNil: "" else: $body)
      let status = response.code.int
      if status == 429 and retry and attempt < 3:
        let wait = response.headers.getOrDefault("Retry-After")
        sleep(int((if wait.len > 0: parseFloat(wait) else: 5.0) * 1000))
        continue
      if status >= 400:
        var error = newException(SiteError, verb.`$` & " " & path & ": HTTP " & $status)
        error.status = status
        error.body = response.body
        raise error
      let text = response.body
      return if text.strip.len == 0: newJNull() else: parseJson(text)

proc apiUpload*(path: string, fields: openArray[(string, string)], fileField, fileName, content: string): JsonNode =
  ## A multipart POST of `fields` and one ZIP file, sent once: a repeated
  ## upload would make a second submission.
  when defined(ladderChecks):
    raise newException(IOError, "offline checks never upload")
  else:
    let client = newHttpClient(timeout = 120_000,
                               headers = newHttpHeaders({"Authorization": "Bearer " & apiKey(), "Origin": Server}))
    defer: client.close()
    var data = newMultipartData()
    for (name, value) in fields: data[name] = value
    data.add(fileField, content, fileName, "application/zip", useStream = false)
    let response = client.request(Api & path, httpMethod = HttpPost, multipart = data)
    let status = response.code.int
    if status >= 400:
      var error = newException(SiteError, "POST " & path & ": HTTP " & $status)
      error.status = status
      error.body = response.body
      raise error
    let text = response.body
    return if text.strip.len == 0: newJNull() else: parseJson(text)
