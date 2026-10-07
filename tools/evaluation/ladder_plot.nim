## `just plot-ladder DIR`: a saved offline ladder's rating trajectories
## (`ratings.svg`) and matchup score shares (`matchups.svg`), drawn as SVG
## from its results.json.

import std/[algorithm, json, math, os, strutils, tables]
import ladder, python_math

const
  Tab10 = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22",
           "#17becf"]
  # ColorBrewer's RdYlGn, red for 0 through green for 1.
  RedYellowGreen = [[165, 0, 38], [215, 48, 39], [244, 109, 67], [253, 174, 97], [254, 224, 139], [255, 255, 191],
                    [217, 239, 139], [166, 217, 106], [102, 189, 99], [26, 152, 80], [0, 104, 55]]
  Font = "font-family=\"DejaVu Sans, sans-serif\""

proc escaped(text: string): string =
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc number(value: float): string = pythonFixed(value, 2)

proc shareColour(share: float): string =
  ## The colour of a score share on RdYlGn.
  let position = clamp(share, 0.0, 1.0) * float(RedYellowGreen.high)
  let low = min(int(floor(position)), RedYellowGreen.high - 1)
  let t = position - float(low)
  var channels: array[3, int]
  for c in 0 .. 2:
    let (a, b) = (float(RedYellowGreen[low][c]), float(RedYellowGreen[low + 1][c]))
    channels[c] = int(round(a + (b - a) * t))
  "rgb(" & $channels[0] & "," & $channels[1] & "," & $channels[2] & ")"

proc niceTicks(low, high: float, wanted = 6): seq[float] =
  ## Round tick values covering [low, high], about `wanted` of them.
  let span = max(high - low, 1e-9)
  let raw = span / float(wanted)
  let magnitude = pow(10.0, floor(log10(raw)))
  var step = magnitude
  for factor in [1.0, 2.0, 2.5, 5.0, 10.0]:
    step = factor * magnitude
    if span / step <= float(wanted): break
  var tick = ceil(low / step) * step
  while tick <= high + step * 1e-9:
    result.add tick
    tick += step

proc ratingsSvg(report: JsonNode, names: seq[string]): string =
  var rounds: seq[float]
  for snapshot in report["history"]: rounds.add float(snapshot["round"].getInt)
  var (lowest, highest) = (Inf, -Inf)
  for snapshot in report["history"]:
    for name in names:
      let rating = snapshot["ratings"][name].getFloat
      lowest = min(lowest, rating)
      highest = max(highest, rating)
  let pad = max(1.0, (highest - lowest) * 0.05)
  (lowest, highest) = (lowest - pad, highest + pad)
  let (width, height) = (1200.0, 700.0)
  let (left, top, right, bottom) = (80.0, 50.0, 900.0, 630.0)
  let lastRound = max(rounds)
  let firstRound = min(rounds)
  proc x(round: float): float = left + (round - firstRound) / max(1.0, lastRound - firstRound) * (right - left)
  proc y(rating: float): float = bottom - (rating - lowest) / (highest - lowest) * (bottom - top)
  var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $int(width) & " " & $int(height) &
            "\" width=\"" & $int(width) & "\" height=\"" & $int(height) & "\" " & Font & " font-size=\"13\">\n"
  svg.add "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"
  svg.add "<text x=\"" & number((left + right) / 2) & "\" y=\"30\" text-anchor=\"middle\" font-size=\"16\">" &
          escaped("Offline ladder · " & $int(lastRound) & " rounds · Bradley–Terry fit to date") & "</text>\n"
  for tick in niceTicks(lowest, highest):
    svg.add "<line x1=\"" & number(left) & "\" x2=\"" & number(right) & "\" y1=\"" & number(y(tick)) & "\" y2=\"" &
            number(y(tick)) & "\" stroke=\"black\" stroke-opacity=\"0.18\"/>\n"
    svg.add "<text x=\"" & number(left - 6) & "\" y=\"" & number(y(tick) + 4) & "\" text-anchor=\"end\">" &
            pythonFixed(tick, 0) & "</text>\n"
  for tick in niceTicks(firstRound, lastRound):
    svg.add "<line x1=\"" & number(x(tick)) & "\" x2=\"" & number(x(tick)) & "\" y1=\"" & number(top) & "\" y2=\"" &
            number(bottom) & "\" stroke=\"black\" stroke-opacity=\"0.18\"/>\n"
    svg.add "<text x=\"" & number(x(tick)) & "\" y=\"" & number(bottom + 18) & "\" text-anchor=\"middle\">" &
            pythonFixed(tick, 0) & "</text>\n"
  var boundary = 18
  while float(boundary) <= lastRound:
    svg.add "<line x1=\"" & number(x(float(boundary))) & "\" x2=\"" & number(x(float(boundary))) & "\" y1=\"" &
            number(top) & "\" y2=\"" & number(bottom) & "\" stroke=\"gray\" stroke-opacity=\"0.25\" stroke-width=\"0.8\"/>\n"
    boundary += 18
  svg.add "<rect x=\"" & number(left) & "\" y=\"" & number(top) & "\" width=\"" & number(right - left) &
          "\" height=\"" & number(bottom - top) & "\" fill=\"none\" stroke=\"black\"/>\n"
  for index, name in names:
    let colour = Tab10[index mod Tab10.len]
    var points: seq[string]
    var final = 0.0
    for snapshot in report["history"]:
      final = snapshot["ratings"][name].getFloat
      points.add number(x(float(snapshot["round"].getInt))) & "," & number(y(final))
    let dash = if name.startsWith("trained"): " stroke-dasharray=\"6,4\""
               elif index >= Tab10.len: " stroke-dasharray=\"2,2\""
               else: ""
    svg.add "<polyline points=\"" & points.join(" ") & "\" fill=\"none\" stroke=\"" & colour &
            "\" stroke-width=\"1.5\"" & dash & "/>\n"
    let legendY = top + 20 + float(index) * 20
    svg.add "<line x1=\"" & number(right + 20) & "\" x2=\"" & number(right + 44) & "\" y1=\"" & number(legendY) &
            "\" y2=\"" & number(legendY) & "\" stroke=\"" & colour & "\" stroke-width=\"1.5\"" & dash & "/>\n"
    svg.add "<text x=\"" & number(right + 50) & "\" y=\"" & number(legendY + 4) & "\">" &
            escaped(name & " (" & pythonFixed(final, 0) & ")") & "</text>\n"
  svg.add "<text x=\"" & number((left + right) / 2) & "\" y=\"" & number(bottom + 45) &
          "\" text-anchor=\"middle\">Pairing round (vertical lines mark map changes)</text>\n"
  svg.add "<text transform=\"translate(22," & number((top + bottom) / 2) &
          ") rotate(-90)\" text-anchor=\"middle\">Rating (Elo scale)</text>\n"
  svg.add "</svg>\n"
  svg

proc matchupsSvg(report: JsonNode, names: seq[string]): string =
  let points = headToHead(names, report["games"])
  let cell = min(60.0, 640.0 / float(max(1, names.len)))
  let (left, top) = (220.0, 60.0)
  let size = cell * float(names.len)
  let (width, height) = (left + size + 140, top + size + 150)
  var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & number(width) & " " & number(height) &
            "\" width=\"" & number(width) & "\" height=\"" & number(height) & "\" " & Font & " font-size=\"12\">\n"
  svg.add "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"
  svg.add "<text x=\"" & number(left + size / 2) & "\" y=\"30\" text-anchor=\"middle\" font-size=\"15\">" &
          escaped("Matchup score share · row bot vs column bot") & "</text>\n"
  for row, a in names:
    for column, b in names:
      let scored = points.getOrDefault((a, b), 0.0)
      let count = scored + points.getOrDefault((b, a), 0.0)
      if count <= 0: continue
      let share = scored / count
      let (cx, cy) = (left + float(column) * cell, top + float(row) * cell)
      svg.add "<rect x=\"" & number(cx) & "\" y=\"" & number(cy) & "\" width=\"" & number(cell) & "\" height=\"" &
              number(cell) & "\" fill=\"" & shareColour(share) & "\"/>\n"
      svg.add "<text x=\"" & number(cx + cell / 2) & "\" y=\"" & number(cy + cell / 2 - 2) &
              "\" text-anchor=\"middle\" font-size=\"8\">" & pythonFixed(share * 100, 0) & "%</text>\n"
      svg.add "<text x=\"" & number(cx + cell / 2) & "\" y=\"" & number(cy + cell / 2 + 9) &
              "\" text-anchor=\"middle\" font-size=\"8\">(n=" & pythonFixed(count, 0) & ")</text>\n"
  svg.add "<rect x=\"" & number(left) & "\" y=\"" & number(top) & "\" width=\"" & number(size) & "\" height=\"" &
          number(size) & "\" fill=\"none\" stroke=\"black\"/>\n"
  for index, name in names:
    let middle = float(index) * cell + cell / 2
    svg.add "<text x=\"" & number(left - 6) & "\" y=\"" & number(top + middle + 4) & "\" text-anchor=\"end\">" &
            escaped(name) & "</text>\n"
    svg.add "<text transform=\"translate(" & number(left + middle) & "," & number(top + size + 10) &
            ") rotate(-45)\" text-anchor=\"end\">" & escaped(name) & "</text>\n"
  svg.add "<text x=\"" & number(left + size / 2) & "\" y=\"" & number(height - 15) &
          "\" text-anchor=\"middle\">Opponent</text>\n"
  # the colour bar
  let (barX, barTop) = (left + size + 30, top)
  svg.add "<defs><linearGradient id=\"share\" x1=\"0\" y1=\"1\" x2=\"0\" y2=\"0\">"
  for index in 0 .. RedYellowGreen.high:
    let offset = float(index) / float(RedYellowGreen.high)
    svg.add "<stop offset=\"" & number(offset) & "\" stop-color=\"" & shareColour(offset) & "\"/>"
  svg.add "</linearGradient></defs>\n"
  svg.add "<rect x=\"" & number(barX) & "\" y=\"" & number(barTop) & "\" width=\"20\" height=\"" & number(size) &
          "\" fill=\"url(#share)\" stroke=\"black\"/>\n"
  for tick in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
    let tickY = barTop + size - tick * size
    svg.add "<text x=\"" & number(barX + 26) & "\" y=\"" & number(tickY + 4) & "\">" & pythonFixed(tick, 1) & "</text>\n"
  svg.add "<text transform=\"translate(" & number(barX + 70) & "," & number(barTop + size / 2) &
          ") rotate(90)\" text-anchor=\"middle\">Win = 1; draw = 0.5</text>\n"
  svg.add "</svg>\n"
  svg

proc plotLadder*(directory: string) =
  ## Write `ratings.svg` and `matchups.svg` beside the ladder's results.json.
  let report = parseFile(directory / "results.json")
  var names: seq[string]
  for name in report["bots"]: names.add name.getStr
  names.sort(proc (a, b: string): int = cmp(-report["ratings"][a].getFloat, -report["ratings"][b].getFloat))
  writeFile(directory / "ratings.svg", ratingsSvg(report, names))
  writeFile(directory / "matchups.svg", matchupsSvg(report, names))
