## CPython's float arithmetic where it differs from a plain loop: `sum` of
## floats (Neumaier-compensated), `math.fsum`, `statistics.fmean`,
## `math.hypot`, `statistics.quantiles`, `round` and floor division. Generated
## maps were drawn with them, so the same seed gives the same map only when
## each value rounds as CPython rounded it.

import std/math

proc fma(x, y, z: float): float {.importc, header: "<math.h>".}
proc ldexp(x: float, exponent: cint): float {.importc, header: "<math.h>".}

proc pythonSum*(values: openArray[float]): float =
  ## `sum(values)` over floats: the first value added to the integer 0, then
  ## Neumaier's compensated sum, adding the compensation once at the end.
  if values.len == 0: return 0.0
  result = 0.0 + values[0]
  var compensation = 0.0
  for index in 1 ..< values.len:
    let value = values[index]
    let total = result + value
    if abs(result) >= abs(value): compensation += (result - total) + value
    else: compensation += (value - total) + result
    result = total
  if compensation != 0.0 and compensation.classify notin {fcInf, fcNegInf, fcNan}:
    result += compensation

proc fsum*(values: openArray[float]): float =
  ## `math.fsum(values)` for finite values: Shewchuk's exact partials,
  ## rounded half-even across them.
  var partials: seq[float]
  for value in values:
    var x = value
    var kept = 0
    for index in 0 ..< partials.len:
      var y = partials[index]
      if abs(x) < abs(y): swap(x, y)
      let high = x + y
      let low = y - (high - x)
      if low != 0.0:
        partials[kept] = low
        inc kept
      x = high
    partials.setLen(kept)
    if x != 0.0: partials.add x
  var count = partials.len
  if count == 0: return 0.0
  dec count
  var high = partials[count]
  var low = 0.0
  while count > 0:
    let x = high
    dec count
    let y = partials[count]
    high = x + y
    low = y - (high - x)
    if low != 0.0: break
  if count > 0 and ((low < 0.0 and partials[count - 1] < 0.0) or (low > 0.0 and partials[count - 1] > 0.0)):
    let y = low * 2.0
    let x = high + y
    if y == x - high: high = x
  high

proc fmean*(values: openArray[float]): float =
  ## `statistics.fmean(values)`.
  fsum(values) / float(values.len)

proc pythonHypot*(a, b: float): float =
  ## `math.hypot(a, b)`: CPython's vector norm, exact squares summed with
  ## their errors and a differential correction, rather than libm's hypot.
  let (x0, x1) = (abs(a), abs(b))
  let largest = max(x0, x1)
  if largest == 0.0: return largest
  var exponent: int
  discard frexp(largest, exponent)
  let scale = ldexp(1.0, cint(-exponent))
  var (total, fraction1, fraction2) = (1.0, 0.0, 0.0)
  for coordinate in [x0, x1]:
    let x = coordinate * scale
    let product = x * x
    let productLow = fma(x, x, -product)
    let sum = total + product
    fraction2 += (total - sum) + product
    total = sum
    fraction1 += productLow
  var h = sqrt(total - 1.0 + (fraction1 + fraction2))
  let product = -h * h
  let productLow = fma(-h, h, -product)
  let sum = total + product
  fraction2 += (total - sum) + product
  total = sum
  fraction1 += productLow
  let x = total - 1.0 + (fraction1 + fraction2)
  h += x / (2.0 * h)
  h / scale

proc quartiles*(sortedValues: openArray[float]): array[3, float] =
  ## `statistics.quantiles(values, n=4)`, the exclusive method, of values
  ## already sorted and at least two of them.
  let count = sortedValues.len
  let m = count + 1
  for i in 1 .. 3:
    let j = clamp(i * m div 4, 1, count - 1)
    let delta = i * m - j * 4
    result[i - 1] = (sortedValues[j - 1] * float(4 - delta) + sortedValues[j] * float(delta)) / 4.0

proc pythonRound*(value: float): int =
  ## `round(value)`: to the nearest integer, halves to even.
  var rounded = round(value)
  if abs(value - rounded) == 0.5: rounded = 2.0 * round(value / 2.0)
  int(rounded)

proc floorDiv*(a, b: int): int =
  ## `a // b`.
  result = a div b
  if (a mod b != 0) and ((a < 0) != (b < 0)): dec result

proc floorMod*(a, b: int): int =
  ## `a % b`, with the divisor's sign.
  result = a mod b
  if result != 0 and ((result < 0) != (b < 0)): result += b

proc floorMod*(a, b: float): float =
  ## `a % b` for floats, with the divisor's sign.
  result = a mod b
  if result != 0.0:
    if (b < 0.0) != (result < 0.0): result += b
  else:
    result = copySign(0.0, b)

proc snprintf(buffer: cstring, size: csize_t, format: cstring): cint {.importc, header: "<stdio.h>", varargs.}

proc pythonFixed*(value: float, digits: int): string =
  ## `f"{value:.{digits}f}"`: correctly rounded, as glibc's printf rounds.
  case value.classify
  of fcNan: return "nan"
  of fcInf: return "inf"
  of fcNegInf: return "-inf"
  else: discard
  var buffer = newString(400)
  let length = snprintf(cast[cstring](buffer[0].addr), csize_t(buffer.len), "%.*f", cint(digits), value)
  buffer.setLen(length)
  buffer

proc pythonMin*(a, b: float): float =
  ## `min(a, b)`: the first unless the second is smaller, so a NaN first wins.
  if b < a: b else: a
