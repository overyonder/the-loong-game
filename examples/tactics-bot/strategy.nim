# The tactics bot: the roles bot with a coiling champion and feeders that forage,
# then sacrifice themselves to the champion once grown. The sacrifice's length and
# memory are first guesses, left for tuning once the architecture settles.
from ../repertoire/games/loong/hsm import nil
from ../repertoire/games/loong/roles import nil
from ../repertoire/games/loong/champion_radio import nil
from ../repertoire/games/loong/behaviours/coil import nil
from ../repertoire/games/loong/behaviours/deliver import nil
from ../repertoire/games/loong/behaviours/evade import nil
from ../repertoire/games/loong/behaviours/forage import nil
from ../repertoire/games/loong/behaviours/hunt import nil
from ../repertoire/games/loong/behaviours/roam import nil
from ../repertoire/games/loong/behaviours/split import nil

hsm.run(hsm.root([
  roles.champion([evade.hsmState(within = 2), coil.hsmState(clearOf = 3), roam.hsmState()],
    reflex = split.reflex(atLength = 10, childSize = 3)),
  roles.kamikaze([hunt.hsmState(), roam.hsmState()]),
  roles.other("Feeder", [evade.hsmState(within = 2),
    deliver.hsmState(atLength = 6, memoryTurns = 12), forage.hsmState()])
]), sonar = champion_radio.create(memoryTurns = 12), indicate = 2)
