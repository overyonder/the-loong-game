## Public example: alternate north and west. No viewer code knows these states.
import controller, gizmos
when defined(loongDiagnostics):
  import std/json

const LOONG_BEHAVIOURS = ["NORTH", "WEST"]
template TRACE(behaviour: untyped) = discard

initialise()
while readTurn():
  let direction = if game().roundNumber mod 2 == 0: 0 else: 3
  TRACE(LOONG_BEHAVIOURS[direction div 3])
  sendMoves([direction, 0, 0], 1)
  diagnosticBlock:
    let head = int(observation().head.position.y * game().width + observation().head.position.x)
    let destination = if direction == 3:
      (head div int(game().width)) * int(game().width) + (head + int(game(
          ).width) - 1) mod int(game().width)
    else:
      (head + int(game().width * (game().height - 1))) mod int(game().width *
          game().height)
    emitGizmoJson($( %* {"version": 1, "kind": "target",
        "label": LOONG_BEHAVIOURS[direction div 3], "points": [destination]}))
    emitGizmoJson($( %* {"version": 1, "kind": "candidate",
        "label": LOONG_BEHAVIOURS[direction div 3],
      "objective": "Alternate direction using round parity", "score": 1,
          "selected": true}))
    emitGizmoJson($( %* {"version": 1, "kind": "state",
      "label": "Alternating policy",
      "reason": "Even round: north. Odd round: west.",
      "nodes": [{"id": "north", "label": "North", "x": 0.1, "y": 0.2, "active": direction == 0},
                {"id": "west", "label": "West", "x": 0.7, "y": 0.8,
                    "active": direction == 3}],
      "links": [{"from": "north", "to": "west", "label": "odd round", "active": direction == 3},
                {"from": "west", "to": "north", "label": "even round",
                    "active": direction == 0}]}))
  finishTurn()
