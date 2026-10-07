## Independent agreement with the actual C++ header's output, plus loss/error
## cases at that external stream boundary. No native match or GPU runs here.

import std/[json, os, strutils]
from ../../native_profile import nil
from ../../../../gamedata/columns import nil

let arguments = commandLineParams()
if arguments.len != 3: quit("check PRODUCER_LOG VERIFIED_WORKLOAD.cols OUTPUT", 2)
let original = readFile(arguments[0])
let output = arguments[2].absolutePath
createDir(output)

proc runCase(name, text, mode: string, wantedExit: int,
    expected = "enabled", verified = true): JsonNode =
  let store = output / name
  createDir(store)
  writeFile(store / "judge.log", text)
  writeFile(store / "profile-mode.txt", mode & "\n")
  if verified: copyFile(arguments[1], store / "native-workload.cols")
  let actual = native_profile.writeNativeProfileReport(store, store, 44, expected)
  doAssert actual == wantedExit, name & ": unexpected acceptance"
  parseFile(store / "profile-summary.json")

let complete = runCase("complete", original, "enabled", 0)
doAssert complete["profile_stream_complete"].getBool
doAssert complete["accepted"].getBool
doAssert complete["host"]["callback_sum"]["calls"].getInt == 88
doAssert complete["host"]["callback_sum"]["ns"].getInt == 990
doAssert complete["device"]["actions_htod"]["calls"].getInt == 9
doAssert complete["device"]["actions_htod"]["ns"].getInt == 123
doAssert complete["copy"]["htod"]["bytes"].getBiggestInt == 9007199254740993'i64
var dense = columns.openColumnsFile(output / "complete/native-profile.cols")
doAssert columns.columnValues[uint64](dense, "batch.waves").values[0] == 7
doAssert columns.columnValues[uint64](dense, "batch.decisions").values[0] == 88
doAssert columns.columnValues[uint64](dense, "copy.bytes").values[0] == 9007199254740993'u64
columns.closeColumnsFile(dense)

let disabled = runCase("disabled", "ordinary judge log\n", "disabled", 0,
  "disabled")
doAssert disabled["status"].getStr == "unknown" and not disabled[
    "profile_known"].getBool
doAssert not disabled.hasKey("host")
let absent = runCase("absent", "ordinary judge log\n", "enabled", 2)
doAssert absent["status"].getStr == "unknown" and not absent["accepted"].getBool

var missing = ""
for line in original.splitLines():
  if line.len > 0 and not line.startsWith("native-profile\t1\thost\tdrain\t"):
    missing.add line & "\n"
discard runCase("missing-stage", missing, "enabled", 2)
dense = columns.openColumnsFile(output / "missing-stage/native-profile.cols")
doAssert columns.columnValues[uint8](dense, "host.known").values[3] == 0
doAssert columns.columnValues[uint8](dense, "host.known").values[4] == 1
columns.closeColumnsFile(dense)

discard runCase("truncated", original.split("native-profile\t1\tcopy")[0],
    "enabled", 2)
discard runCase("failed", original.replace("completed\t1\tfailed\t0",
    "completed\t1\tfailed\t1"), "enabled", 2)
discard runCase("unfinished", original.replace("completed\t1", "completed\t0"),
    "enabled", 2)
discard runCase("serialize-count", original.replace("serialize\t44\t",
    "serialize\t43\t"), "enabled", 2)
discard runCase("version", original.replace("native-profile\t1\t",
    "native-profile\t2\t"), "enabled", 2)
discard runCase("negative", original.replace("setup\t1\t111", "setup\t-1\t111"),
    "enabled", 2)
discard runCase("overflow", original.replace("setup\t1\t111",
    "setup\t1\t18446744073709551616"), "enabled", 2)
discard runCase("duplicate", original.replace("setup\t1\t111\n",
    "setup\t1\t111\nnative-profile\t1\thost\tsetup\t1\t111\n"), "enabled", 2)
discard runCase("wrong-mode", original, "disabled", 2)
discard runCase("unexpected-profile", original, "disabled", 2, "disabled")
discard runCase("no-replay-validation", original, "enabled", 2,
    verified = false)

let half = original.replace("batch\t44\t", "batch\t22\t").replace(
    "serialize\t44\t", "serialize\t22\t")
let multiple = runCase("multiple", half & "ordinary judge log\n" & half,
    "enabled", 0)
doAssert multiple["batches"].getInt == 2
doAssert multiple["profile_games"].getInt == 44
doAssert multiple["host"]["callback_sum"]["ns"].getInt == 1980
doAssert multiple["copy"]["htod"]["bytes"].getBiggestInt == 18014398509481986'i64
echo "16 external-stream cases passed; no GPU or candidate runtime claim"
