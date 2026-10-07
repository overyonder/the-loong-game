## ISO 8601 times as the records write them: `2026-10-06T05:00:00Z` for the
## fleet's ledger, and Python's `isoformat()` with a `+00:00` offset and
## microseconds elsewhere.

import std/[strutils, times]

proc iso*(epoch: float): string = fromUnixFloat(epoch).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc isoNow*(): string =
  ## The current time as Python's `datetime.now(UTC).isoformat()` writes it.
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff'+00:00'")

proc parseIso*(text: string): float =
  ## An ISO 8601 time with `Z`, a `+HH:MM` offset, or none (UTC), in epoch seconds.
  var body = text
  var offset = 0
  if body.endsWith("Z"): body = body[0 ..< ^1]
  elif body.len > 6 and body[^6] in {'+', '-'} and body[^3] == ':':
    let sign = if body[^6] == '-': -1 else: 1
    offset = sign * (parseInt(body[^5 .. ^4]) * 3600 + parseInt(body[^2 .. ^1]) * 60)
    body = body[0 ..< ^6]
  var fraction = 0.0
  let dot = body.find('.')
  if dot >= 0:
    fraction = parseFloat("0" & body[dot .. ^1])
    body = body[0 ..< dot]
  let format = if 'T' in body: "yyyy-MM-dd'T'HH:mm:ss" else: "yyyy-MM-dd HH:mm:ss"
  float(parse(body, format, utc()).toTime.toUnix) + fraction - float(offset)
