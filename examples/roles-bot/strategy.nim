# The roles bot: the first bot's behaviours, grouped under the role each dragon
# works out for itself from its length and what its teammates announce by sonar.
from ../repertoire/games/loong/hsm import nil
from ../repertoire/games/loong/roles import nil
from ../repertoire/games/loong/length_radio import nil
from ../repertoire/games/loong/behaviours/evade import nil
from ../repertoire/games/loong/behaviours/hunt import nil
from ../repertoire/games/loong/behaviours/roam import nil
from ../repertoire/games/loong/behaviours/split import nil

hsm.run(hsm.root([
  roles.champion([evade.hsmState(within = 2), roam.hsmState()],
    reflex = split.reflex(atLength = 10, childSize = 3)),
  roles.kamikaze([hunt.hsmState(), roam.hsmState()]),
  roles.other("Worker", [evade.hsmState(within = 2), roam.hsmState()])
]), sonar = length_radio.create(memoryTurns = 12), indicate = 1)
