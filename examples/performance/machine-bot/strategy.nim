# Runs one experiment from experiments.c per turn and logs the CPU points it took. In the
# judge the clock advances one nanosecond per point, so the clock reads points.
from ../../repertoire/games/loong/controller import nil

type Experiment {.importc, header: "experiments.h".} = object
  name: cstring
  run: proc (words: ptr uint32): uint32 {.cdecl.}

var firstExperiment {.importc: "EXPERIMENTS[0]", header: "experiments.h".}: Experiment
let experiments = cast[ptr UncheckedArray[Experiment]](firstExperiment.addr)
var experimentCount {.importc: "EXPERIMENT_COUNT", header: "experiments.h".}: cint
var experimentWords {.importc: "EXPERIMENT_WORDS", header: "experiments.h", nodecl.}: cuint
proc fillWords(words: ptr uint32) {.importc: "FillWords", header: "experiments.h".}

var ct: ptr controller.Controller
var game: ptr controller.Game
controller.unswbc_init(ct.addr, game.addr)
var words = newSeq[uint32](experimentWords)
fillWords(words[0].addr)

var turn = 0
while controller.unswbc_update(ct, game) != 0:
  if turn < experimentCount:
    let experiment = experiments[turn]
    let started = controller.clockNanoseconds()
    let sum = experiment.run(words[0].addr)
    let points = controller.clockNanoseconds() - started
    controller.unswbc_log(cstring("machine " & $experiment.name & " points=" & $points &
      " result=" & $sum))
  inc turn
  controller.unswbc_move(controller.unswbc_facing(ct))
  controller.unswbc_end_turn()
