## Split: a long dragon turns its last segments into a new dragon running the same program.
import std/options
from ../controller import nil
from ../turn import nil

proc reflex*(atLength, childSize: int): proc(state: turn.Turn): Option[turn.Action] =
  ## Splits instead of moving once the dragon is `atLength` long and the split is legal.
  result = proc(state: turn.Turn): Option[turn.Action] =
    if state.length >= atLength and controller.unswbc_can_split(state.ct, childSize.cint) != 0:
      return some(turn.split(childSize))
