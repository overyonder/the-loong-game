## Every dragon announces its length and where its head is. A dragon remembers
## the longest teammate it has heard from, and where that teammate was.
from controller import nil
from radio import nil
from turn import nil

const
  TeamTag = 0x4C4F'u64        # "LO": marks our messages, since sonar carries no sender or team
  RoleCodes = ["Champion", "Feeder", "Kamikaze"]

proc encode(id, role, length: int, at: controller.Position): uint64 =
  ## 16-bit tag, 16-bit sender ID, 4-bit role, 12-bit length, and the sender's head position.
  (TeamTag shl 48) or (uint64(id and 0xFFFF) shl 32) or (uint64(role) shl 28) or
    (uint64(length and 0xFFF) shl 16) or (uint64(at.x and 0xFF) shl 8) or uint64(at.y and 0xFF)

proc create*(memoryTurns: int): radio.Radio =
  var heard = turn.Heard(turnsAgo: memoryTurns + 1)
  radio.Radio(
    listen: proc(state: var turn.Turn) =
      var count: cint
      let messages = controller.unswbc_sonar(state.ct, count.addr)
      inc heard.turnsAgo
      if heard.turnsAgo > memoryTurns: heard.longest = 0
      for i in 0 ..< count.int:
        let message = messages[i]
        let sender = int((message shr 32) and 0xFFFF)
        if (message shr 48) != TeamTag or sender == state.id: continue   # not ours, or our own echo
        let length = int((message shr 16) and 0xFFF)
        if length >= heard.longest:
          heard = turn.Heard(longest: length, championId: sender, turnsAgo: 0,
            championX: int((message shr 8) and 0xFF), championY: int(message and 0xFF))
      state.heard = heard,
    announce: proc(state: turn.Turn, role: string) =
      let message = encode(state.id, RoleCodes.find(role), state.length, state.at)
      for side in 0 .. 3: controller.unswbc_send_sonar_to(controller.UNSWBC_DIRECTIONS[side], message))
