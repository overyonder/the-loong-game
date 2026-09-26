"""The observation/decision boundary between reconstruction and inference."""

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class DecisionSample:
    replay_sha256: str
    team: Literal["A", "B"]
    dragon_id: int
    round_number: int
    # None if the public replay does not identify the submitted bot version.
    submission_id: str | None
    # Exact bot-visible init and turn inputs; never the omniscient board.
    init_protocol: str
    observation_protocol: str
    # Multiple possibilities preserve ambiguity in reconstructed sprint/split actions.
    possible_actions: tuple[str, ...]
    action_evidence: Literal["recorded", "inferred"]
