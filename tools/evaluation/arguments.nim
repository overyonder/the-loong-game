## Command lines in the shape the runners have always taken: `--name VALUE`
## or `--name=VALUE`, options that take several values up to the next
## option, repeatable options and flags, and positional arguments.

import std/[strutils, tables]

type
  Arity* = enum
    Flag       ## no value
    One        ## exactly one value
    Optional   ## zero or one value
    Many       ## one or more values, up to the next option
  OptionSpec* = object
    name*:  string
    arity*: Arity
    help*:  string
  CommandLine* = object
    usage:       string
    specs:       seq[OptionSpec]
    values*:     Table[string, seq[seq[string]]]   ## each occurrence's values
    positional*: seq[string]

proc fail*(line: CommandLine, message: string) {.noreturn.} =
  stderr.writeLine line.usage
  stderr.writeLine "error: " & message
  quit 2

proc helpText(line: CommandLine): string =
  result = line.usage & "\n"
  for spec in line.specs:
    let shape = case spec.arity
      of Flag: ""
      of One: " VALUE"
      of Optional: " [VALUE]"
      of Many: " VALUE..."
    result.add "\n  --" & spec.name & shape & "\n      " & spec.help

proc parseCommandLine*(arguments: seq[string], usage: string, specs: openArray[OptionSpec]): CommandLine =
  result = CommandLine(usage: usage, specs: @specs)
  var at = 0
  while at < arguments.len:
    let argument = arguments[at]
    inc at
    if argument in ["-h", "--help"]:
      echo result.helpText
      quit 0
    if not argument.startsWith("--") or argument == "--":
      result.positional.add argument
      continue
    let equals = argument.find('=')
    let name = if equals >= 0: argument[2 ..< equals] else: argument[2 .. ^1]
    var spec: OptionSpec
    var found = false
    for candidate in specs:
      if candidate.name == name:
        (spec, found) = (candidate, true)
    if not found: result.fail "unrecognized option --" & name
    var values: seq[string]
    if equals >= 0:
      if spec.arity == Flag: result.fail "--" & name & " takes no value"
      values.add argument[equals + 1 .. ^1]
    if spec.arity in {One, Optional} and values.len == 0 and at < arguments.len and
        not arguments[at].startsWith("--"):
      values.add arguments[at]
      inc at
    if spec.arity == Many:
      while at < arguments.len and not arguments[at].startsWith("--"):
        values.add arguments[at]
        inc at
    if spec.arity in {One, Many} and values.len == 0: result.fail "--" & name & " needs a value"
    result.values.mgetOrPut(name, @[]).add values

proc given*(line: CommandLine, name: string): bool = name in line.values

proc last*(line: CommandLine, name: string, default = ""): string =
  ## The option's last value, or `default` when it wasn't given or was bare.
  if name in line.values and line.values[name][^1].len > 0: line.values[name][^1][^1] else: default

proc all*(line: CommandLine, name: string): seq[string] =
  ## The values of the option's last occurrence.
  if name in line.values: line.values[name][^1] else: @[]

proc each*(line: CommandLine, name: string): seq[string] =
  ## One value from every occurrence of a repeatable option.
  if name in line.values:
    for occurrence in line.values[name]: result.add occurrence

proc integer*(line: CommandLine, name: string, default: int): int =
  let text = line.last(name)
  if text.len == 0: return default
  try: parseInt(text)
  except ValueError: line.fail "--" & name & " takes an integer, not " & text

proc number*(line: CommandLine, name: string, default: float): float =
  let text = line.last(name)
  if text.len == 0: return default
  try: parseFloat(text)
  except ValueError: line.fail "--" & name & " takes a number, not " & text
