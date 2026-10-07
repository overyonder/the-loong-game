## Extend the fixed SDK22/both-seat prefix into the declared paired workload.
## This prepares canonical jobs; it never builds or plays a bot.

import std/[json, os, sets, strutils]
from ../../gamedata/sha256 import nil

proc prepareNativeWorkloadSchedule*(prefix, store, maps, botA, botB: string,
    games: int): int =
  if games < 44 or games > 10000 or games mod 2 != 0:
    raise newException(ValueError, "workload needs 44..10000 paired games")
  for path in [store, maps, botA, botB]:
    if path.len == 0 or path.find({'\t', '\r', '\n'}) >= 0:
      raise newException(ValueError, "invalid workload path")
  if not fileExists(botA) or not fileExists(botB):
    raise newException(ValueError, "registered WASM artifact missing")
  var mapNames: seq[string]
  var seedStart: uint64
  var prefixGames = 0
  var uniqueMaps = initHashSet[string]()
  for line in lines(prefix):
    let fields = line.split('\t')
    if fields.len != 4 or parseInt(fields[0]) != prefixGames or
        parseInt(fields[3]) != prefixGames mod 2:
      raise newException(ValueError, "invalid SDK22 prefix: " & line)
    let seed = uint64(parseBiggestUInt(fields[2]))
    if prefixGames == 0: seedStart = seed
    if seedStart > high(uint64) - 4999'u64 or
        seed != seedStart + uint64(prefixGames div 2):
      raise newException(ValueError, "prefix does not use paired consecutive seeds")
    let mapName = fields[1]
    if mapName.len == 0 or mapName.extractFilename != mapName or
        mapName.find({'\r', '\n'}) >= 0 or not fileExists(maps / mapName):
      raise newException(ValueError, "SDK map missing or invalid: " & mapName)
    if prefixGames mod 2 == 0:
      if mapName in uniqueMaps:
        raise newException(ValueError, "duplicate SDK map in prefix: " & mapName)
      uniqueMaps.incl mapName
      mapNames.add mapName
    elif mapNames[^1] != mapName:
      raise newException(ValueError, "paired map differs in prefix")
    inc prefixGames
  if prefixGames != 44 or mapNames.len != 22:
    raise newException(ValueError, "prefix must contain exactly the SDK22/both-seat jobs")
  createDir(store)
  if fileExists(store / "schedule.tsv") or fileExists(store / "jobs.tsv"):
    raise newException(ValueError, "workload schedule already exists: " & store)
  var schedule = open(store / "schedule.tsv", fmWrite)
  defer: schedule.close()
  var jobs = open(store / "jobs.tsv", fmWrite)
  defer: jobs.close()
  for index in 0 ..< games:
    let identity = align($index, 3, '0')
    let pair = index div 2
    let mapName = mapNames[pair mod mapNames.len]
    let seed = seedStart + uint64(pair)
    let directory = store / "games" / identity
    createDir(directory)
    schedule.writeLine(identity & "\t" & mapName & "\t" & $seed & "\t" &
        $(index mod 2))
    let first = if index mod 2 == 0: botA else: botB
    let second = if index mod 2 == 0: botB else: botA
    jobs.writeLine(identity & "\t" & maps / mapName & "\t" & first & "\t" &
        second & "\t" & $seed & "\t" & directory / "game.replay" & "\tA\tB")
  let metadata = %*{"games": games, "pairs": games div 2,
    "sdk_maps": mapNames.len, "seed_start": seedStart,
    "prefix_sha256": sha256.sha256Hex(readFile(prefix)),
    "source_prefix": prefix, "maps": maps, "bot_a": botA, "bot_b": botB,
    "schedule": "schedule.tsv", "canonical_jobs": "jobs.tsv",
    "map_ids": "original map labels and raw dragon IDs preserved"}
  writeFile(store / "schedule.json", metadata.pretty & "\n")
