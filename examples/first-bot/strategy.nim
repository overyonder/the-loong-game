# The first strategy bot: evade a close enemy head, otherwise roam.
from ../repertoire/games/loong/hsm import nil
from ../repertoire/games/loong/behaviours/evade import nil
from ../repertoire/games/loong/behaviours/roam import nil

hsm.run(hsm.root([
  evade.hsmState(within = 2),
  roam.hsmState()
]))
