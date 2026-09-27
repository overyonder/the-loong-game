## A sonar protocol: what a dragon hears at the start of its turn, and what it says at the end.
from turn import nil

type Radio* = ref object
  listen*: proc(state: var turn.Turn)
  announce*: proc(state: turn.Turn, role: string)
