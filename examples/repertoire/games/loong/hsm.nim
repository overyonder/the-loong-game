## Connect the generic hierarchical state machine to the Loong turn loop.
## The bot's indicator names the states it entered, so the replay shows each decision.
import std/strutils
from ../../decision_architectures/hierarchical_state_machine import nil
from controller import nil
from radio import nil
from turn import nil
from window import nil

proc run*(root: hierarchical_state_machine.State[turn.Turn, turn.Action],
    sonar: radio.Radio = nil, indicate = 0) =
  ## `indicate` is how many levels below the root the indicator names.
  var ct: ptr controller.Controller
  var game: ptr controller.Game
  controller.unswbc_init(ct.addr, game.addr)
  while controller.unswbc_update(ct, game) != 0:
    var state = turn.Turn(ct: ct, game: game, id: controller.unswbc_id(ct).int,
      facing: controller.unswbc_facing(ct), heard: turn.Heard(championId: -1))
    if sonar != nil: sonar.listen(state)
    state.length = controller.unswbc_length(ct).int
    state.at = controller.unswbc_position(ct)
    state.view = window.read(ct, state.heard.championId)
    let path = hierarchical_state_machine.path(root, state)
    if indicate > 0:
      var names: seq[string]
      for level in 1 .. indicate: names.add(path[level].name)
      controller.unswbc_indicator(cstring(names.join(" ")))
    let action = hierarchical_state_machine.decide(path, state)
    case action.kind
    of turn.Move: controller.unswbc_move(action.side)
    of turn.Split: controller.unswbc_split(ct, action.childSize.cint)
    if sonar != nil: sonar.announce(state, path[1].name)
    controller.unswbc_end_turn()

proc root*(children: openArray[hierarchical_state_machine.State[turn.Turn, turn.Action]]):
    hierarchical_state_machine.State[turn.Turn, turn.Action] =
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Dragon", children: @children)
