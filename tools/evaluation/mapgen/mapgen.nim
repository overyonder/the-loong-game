## `loong-mapgen` (`just mapgen`): generate symmetric maps that look like the
## official ones, for held-out evaluation.
##
##   just mapgen --count 96 --seed 2028            # tools/evaluation/maps/generated/
##   just mapgen --count 4 --style labyrinth --output DIR
##   just mapgen --check tools/evaluation/maps/generated
##   just mapgen --like tools/evaluation/maps/trophy.map --count 4 --candidates 3
##
## Inputs: a seed and optional world settings. Outputs: `gen_<seed>_<nn>.map`
## files in `--output`, one summary per map on stdout. `--check DIR` writes
## nothing and reports each map in DIR that falls outside the official
## envelope. `--like MAP...` writes `like_<map>_<nn>.map` files instead: maps
## sharing each MAP's size, symmetry, border, dragons and supply, drawn until
## their lessons lie nearest the MAP's, with a table of both.
##
## The generator is xCirno's layered world generator
## (https://gist.github.com/xCirno1/ffdaac4236c1f1085c351af4fdfc1600), posted
## as [Stockfish]xCirno in the competition Discord, widened to the official
## maps' variety and bounded by their envelope. tools/evaluation/README.md
## describes its stages.

import std/[os, strutils]
import world, stages, profile, generate
import ../[arguments, paths, python_math]

proc normalised(path: string): string =
  ## A path as Python's `Path` prints it: no empty or `.` components.
  var parts: seq[string]
  for part in path.split('/'):
    if part.len > 0 and part != ".": parts.add part
  result = parts.join("/")
  if path.startsWith("/"): result = "/" & result
  if result.len == 0: result = "."

proc shown(path: string): string =
  ## A written file's path relative to the repository when it lies inside it.
  if path.isAbsolute and path.startsWith(Root & "/"): path[Root.len + 1 .. ^1] else: path

proc main(): int =
  let line = parseCommandLine(commandLineParams(), "usage: mapgen [options]", @[
    OptionSpec(name: "count", arity: One, help: "Maps to generate"),
    OptionSpec(name: "seed", arity: One, help: "Random seed"),
    OptionSpec(name: "output", arity: One, help: "Directory for the maps"),
    OptionSpec(name: "check", arity: One, help: "Report DIR's maps against the official envelope instead of generating"),
    OptionSpec(name: "like", arity: Many, help: "Write --count maps like each MAP instead: its size, symmetry, border, " &
      "dragons and supply, and the nearest lessons of --draws times as many worlds"),
    OptionSpec(name: "draws", arity: One, help: "Worlds drawn per map kept, with --like"),
    OptionSpec(name: "size", arity: One, help: "WxH, e.g. 48x24 (default: drawn)"),
    OptionSpec(name: "min-side", arity: One, help: "Minimum dimension (8 to 64); use 10 for queen-rule training maps"),
    OptionSpec(name: "sym", arity: One, help: "x, y or xy"),
    OptionSpec(name: "style", arity: One, help: StyleNames.join(", ")),
    OptionSpec(name: "landmark", arity: One, help: Landmarks.join(", ") & " or none"),
    OptionSpec(name: "border", arity: One, help: "closed or wrap"),
    OptionSpec(name: "dragons", arity: One, help: "Dragons per side, 1 to 7"),
    OptionSpec(name: "supply", arity: One, help: "Target pearls per round"),
    OptionSpec(name: "candidates", arity: One, help: "Worlds judged per map, best kept")])
  let count = line.integer("count", 20)
  let seed = line.integer("seed", 2026)
  let output = normalised(line.last("output", Root / "tools/evaluation/maps/generated"))
  let candidates = line.integer("candidates", 8)
  let officialMaps = Root / "tools/evaluation/maps"
  let lessons = officialLessons(officialMaps)
  if line.given("check"):
    let directory = normalised(line.last("check"))
    let profiles = mapProfiles(directory)
    let official = mapProfiles(officialMaps)
    echo profileTable(@[("official", official), (directory, profiles)])
    var outsideCount = 0
    for p in profiles:
      let measures = lessons.envelope.outside(p)
      if measures.len == 0: continue
      inc outsideCount
      var parts: seq[string]
      for m in measures: parts.add "'" & m & "': " & p.measureRepr(m)
      echo "outside: ", p.name, " {", parts.join(", "), "}"
    echo outsideCount, " of ", profiles.len, " maps outside the official envelope"
    return (if outsideCount > 0: 1 else: 0)
  for (option, allowed) in [("sym", @["x", "y", "xy"]), ("style", @StyleNames), ("landmark", @Landmarks & "none"),
                            ("border", @["closed", "wrap"])]:
    if line.given(option) and line.last(option) notin allowed:
      line.fail "argument --" & option & ": invalid choice: '" & line.last(option) & "'"
  if line.given("like"):
    createDir(output)
    var names: seq[string]
    for (m, _) in LessonCaps: names.add m
    echo "| Map | Distance | ", names.join(" | "), " |"
    echo "| --- |", " ---: |".repeat(names.len + 1)
    proc row(profile: MapProfile): string =
      var cells: seq[string]
      for m in names: cells.add pythonFixed(profile.measure(m), 2)
      cells.join(" | ")
    for source in line.all("like"):
      let (like, found) = siblings(readFile(source), count, seed, lessons, candidates, line.integer("draws", 8),
                                   line.integer("min-side", 8))
      let stem = source.splitFile.name
      echo "| ", stem, " | | ", row(like), " |"
      for number, sibling in found:
        let name = "like_" & stem & "_" & align($(number + 1), 2, '0') & ".map"
        writeFile(output / name, sibling.world.text)
        echo "| ", name, " (", sibling.world.styleName, ") | ", pythonFixed(sibling.distance, 2), " | ",
          row(sibling.profile), " |"
    return 0
  var settings = defaultSettings()
  settings.minSide = line.integer("min-side", 8)
  if line.given("size"):
    let parts = line.last("size").split('x')
    settings.w = parseInt(parts[0])
    settings.h = parseInt(parts[1])
  if line.given("sym"): settings.sym = line.last("sym")
  if line.given("style"): settings.style = line.last("style")
  if line.given("landmark"): settings.landmark = line.last("landmark")
  if line.given("supply"): settings.supply = line.number("supply", 0)
  if line.given("border"): settings.closed = ord(line.last("border") == "closed")
  if line.given("dragons") and line.integer("dragons", 0) != 0:
    settings.perSide = max(1, min(7, line.integer("dragons", 0)))
  createDir(output)
  for number in 1 .. count:
    # A world seed with no candidate inside the envelope moves to the next.
    var made = false
    for attempt in 0 ..< 20:
      let (ok, world) = generate((seed * 100 + number) * 20 + attempt, lessons, candidates, settings)
      if not ok: continue
      let path = output / "gen_" & $seed & "_" & align($number, 2, '0') & ".map"
      writeFile(path, world.text)
      echo shown(path)
      echo world.summary
      made = true
      break
    if not made:
      stderr.writeLine "no map inside the envelope for number ", number
      return 1
  0

try: quit main()
except CatchableError as error:
  stderr.writeLine error.msg
  quit 1
