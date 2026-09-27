## Every dragon announces its length. A dragon remembers the longest teammate
## it has heard from recently.
from controller import nil
from radio import nil
from turn import nil

const
  TeamTag = 0x4C4F4F4E'u64    # "LOON": marks our messages, since sonar carries no sender or team
  RoleCodes = ["Worker", "Champion", "Kamikaze"]

proc encode(id, role, length: int): uint64 =
  ## Tag in the top 32 bits, then the sender's ID, its role and its length.
  (TeamTag shl 32) or (uint64(id and 0xFFFF) shl 16) or (uint64(role) shl 12) or uint64(length and 0xFFF)

proc decodeLength(message: uint64, ourId: int): int =
  ## A teammate's length, or -1 if the message isn't from a teammate.
  ## A ray can stop at the sender's own body, so our own messages come back to us.
  if (message shr 32) != TeamTag or int((message shr 16) and 0xFFFF) == ourId: -1
  else: int(message and 0xFFF)

proc create*(memoryTurns: int): radio.Radio =
  var longest = 0
  var turnsAgo = memoryTurns
  radio.Radio(
    listen: proc(state: var turn.Turn) =
      var count: cint
      let messages = controller.unswbc_sonar(state.ct, count.addr)
      inc turnsAgo
      if turnsAgo > memoryTurns: longest = 0
      for i in 0 ..< count.int:
        let length = decodeLength(messages[i], state.id)
        if length > 0:
          longest = max(longest, length)
          turnsAgo = 0
      state.heard = turn.Heard(longest: longest, championId: -1, turnsAgo: turnsAgo),
    announce: proc(state: turn.Turn, role: string) =
      # One message each way. Whichever teammate a ray reaches first hears us.
      let message = encode(state.id, RoleCodes.find(role), state.length)
      for side in 0 .. 3: controller.unswbc_send_sonar_to(controller.UNSWBC_DIRECTIONS[side], message))
