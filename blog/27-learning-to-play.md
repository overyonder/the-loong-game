# Learning to play

The planning bot in the previous article makes its choices from rules and scores we wrote. Our learned bot gets the same incomplete view of the game, but learns those choices from games. We train a large network where compute is cheap, then teach a smaller one that can live inside the competition judge's 100-million-point turn budget.

> **Training note, 2 October 2026.** This is the design we are running now, across a 16 GB workstation card and a four-H100 rental. Training and evaluation are still in progress, so the measurements and the final submitted bot may change.

The two networks have different jobs. These are the labels used in the diagrams.

## A short glossary

### Networks

| Term | Meaning here |
| --- | --- |
| **Teacher** | The 44-million-weight network that learns by reinforcement learning. It is too large for the submitted bot. |
| **Student** | The smaller network distilled from the teacher. This is the network exported into our bot. |
| **Actor or policy** | The part of a network that turns one dragon's observation and memory into probabilities for its next action. |
| **Critic** | A training-only network that estimates how a position will turn out. Ours may see the true board, but the actor and submitted student never can. |
| **Part** | One component of an action: its kind, a move direction, a split size, or one step of a sprint. The policy scores the relevant parts and packs them into one action. |

### Training

| Term | Meaning here |
| --- | --- |
| **Sample** | One dragon's observation, memory, chosen action, probability, reward and training targets at one turn. |
| **Rollout** | The samples collected while many games advance under fixed policy weights. |
| **Batch and minibatch** | A batch is the rollout used for one update. Training divides it into minibatches that fit the GPU. |
| **Epoch** | One pass over that rollout's training sequences. We make two passes before collecting fresh games. |
| **Update** | One rollout followed by its optimisation epochs. Checkpoint intervals are counted in updates. |

### Saved state

| Term | Meaning here |
| --- | --- |
| **Checkpoint** | A resumable file containing weights, AdamW state, update number, settings and the level-replay state. `latest.pt` is replaced atomically. |
| **Snapshot** | An immutable copy used as a league opponent or a student candidate. It does not carry the optimiser state needed to resume training. |
| **League** | The pool of past teachers, exploiters and learned imitations that supplies opponents. |
| **Sidecar** | The student process that keeps distilling new teacher checkpoints while teacher training continues. |
| **Distillation** | Training the student to reproduce the teacher's action distribution on positions the student itself reaches. |
| **Quantisation** | Replacing expensive floating-point weights and activations with small integers, while training with the same rounding the bot will use. |

## The whole pipeline

![The reinforcement-learning pipeline. A pool of 4,096 generated maps feeds a GPU engine, which resets thousands of games onto maps selected by prioritised level replay. A league of past teacher snapshots, exploiters and mimics supplies opponents. Recorded ladder-bot turns supply demonstrations. The 44-million-weight teacher contains a residual spatial trunk, mixture-of-experts layers, a GRU, action heads and a privileged critic. Atomic teacher checkpoints feed an on-policy student sidecar. The student uses integer convolutions, one routed expert pair, n-tuple tables, a GRU and quantisation-aware training, then exports into a Nim and Rake WebAssembly bot. Beneath the pipeline, the figure lists all 43 papers reviewed for the design, keyed to the components they informed.](images/rl-pipeline.svg)

The engine is the base of the system. We ported the organisers' C++ engine to fixed arrays and CUDA, then ran it in lockstep against the 1.2.2 engine. Across 100,000 games, every turn block agreed on all 126,645,678 dragon-turns.

With 2,048 games resident on one card, the port advances about 761,000 dragon-turns a second. Observations, actions and rewards stay on the GPU instead of crossing a process boundary for every dragon.

### Maps that keep moving

The engine runs lanes of independent games. When one ends, the trainer chooses a map, draws a new 62-bit seed and resets that lane immediately. The core pool has 4,096 generated files, with more generated and community maps beside it. Size, symmetry, kelp, portals, pearl gaps and starting bodies all vary.

The pool is generated before a training process starts. What changes dynamically is which map each lane receives. [Prioritized Level Replay](https://arxiv.org/abs/2010.03934) records the positive advantage left in the last game on each map, gives unseen maps half of new starts, and otherwise mixes difficult maps with ones that have gone longest without play. A newly generated pool is picked up when a run restarts. The official and ladder maps never enter this pool. They are held out for evaluation, so a student has to generalise before it can pass its gate.

## The machines

![The training machines and orchestration. A local AM4 workstation with a Ryzen 7 5800X3D, 32 GB DDR4 and a 16 GB RTX 5070 Ti connects both to a private S3 object store and, through a rental connector, to a Vast.ai host. The rental has two Xeon Gold 6448Y processors, 64 physical cores, 128 threads, 1 TB RAM and four H100 GPUs. Three GPUs train the teacher while one distils the student. The scripts pack inputs, connect and start jobs, run teacher, student and CPU demonstration workers, save atomic checkpoints and immutable snapshots, and pull durable copies every fifteen minutes and before shutdown. Credentials, addresses, account details and identifiers are absent.](images/rl-compute-topology.svg)

The workstation is where a run begins and ends. It builds the judge and source bundle, prepares maps and demonstrations, starts the rental jobs, checks the exported student, and keeps the durable copy. Its RTX 5070 Ti can continue either network after the rental ends, although the 16 GB card must alternate between them.

The four-H100 host was deliberately disposable. Three cards ran the teacher with local SGD; the fourth ran the student. Its 64 CPU cores generated and encoded more demonstrations while the GPUs trained.

### Two transfer paths

Our scripts used a control path and a bulk-data path. The rental connector carried commands, small tar streams, checkpoints and logs. A private S3 object store held larger fleet archives. The rental fetched those through short-lived signed links, so it never needed a permanent cloud credential.

The launch scripts pinned each job to a GPU and the matching half of a NUMA node. `teacher.sh` resumed the trainer, `student.sh` watched for a complete teacher checkpoint, and `demos.sh` used otherwise idle CPU cores to play and encode new games. `judge.sh` packed the locally built judge and streamed it to the host.

Every fifteen minutes, the pull job copied `latest.pt`, immutable snapshots, logs and evaluation results back to the workstation. The same pull ran before the rental's deadline. A failed rental could therefore lose part of one update, but not the run.

## The teacher

One policy controls every dragon. Its observation is egocentric: a 15 by 15 crop of the remembered map, a coarse overview of the whole remembered map, scalar facts and up to eight sonar messages. The crop is rotated so forward is always up and is mirrored at random during training. That removes two symmetries the network would otherwise have to relearn.

### Seeing and remembering

Eight residual blocks process the crop, with FiLM injecting the scalar state into each one. Separate convolutions read the overview. A set encoder pools sonar, and two top-two-of-sixteen expert layers add capacity without running every expert on every turn.

A 512-unit GRU carries each dragon's memory. Every reader takes a layer-normalised copy. Without that normalisation, the update gate saturated and the network learnt little beyond its commonest action.

### Choosing an action

The action is a tree rather than one enormous categorical choice. One head chooses move, sprint or split. Further heads choose a move's relative direction or a split size. A sprint uses a recurrent decoder for two to eight steps, with each direction conditioned on the steps before it. Illegal split sizes and unaffordable sprint steps are masked. Nothing else is forbidden, because deliberately dying can be the correct move.

The policy also chooses a role at birth and every fixed role interval, then holds it between choices. A claim head selects a nearby cell or no claim and sends that choice in the status packet. This is the small part we took from hierarchical reinforcement learning: roles give temporal commitment, while actions remain free to react on every turn.

## Critic and reward

The critic answers a different question from the policy: given the position, how much return should we expect? During training it sees the true board, every dragon and every pearl countdown. It encodes that board once per team per round, then reads out a value for each acting dragon. This is centralised training with decentralised execution in the style of MAPPO and asymmetric actor-critic. The actor still receives only information a submitted dragon could have.

The terminal reward is the game result. Potential-based shaping adds 0.02 for each segment of longest-dragon lead and 0.01 for each segment of total-length lead, scaled by the current shaping setting. As a difference of potentials, it makes the signal denser without changing which terminal policy is optimal.

PPO clips each update, Generalized Advantage Estimation carries delayed results back through the rollout, and AdamW applies the gradients. Auxiliary heads ask the memory to reconstruct hidden cells, enemy heads three rounds ahead and the dragon's own future length.

Opponent models are not alternative critics. A critic estimates our expected return. A learned imitation of another ladder bot changes the opponent, so our policy needs to cope with a different set of situations. Keeping those two jobs separate stops an opponent-specific value estimate from becoming the definition of success.

## Ladder play without ladder-map training

The league contains frozen teacher snapshots from this run and other runs, including exploiters. Prioritised fictitious self-play weights an opponent by the square of one minus our smoothed win rate, so policies that still beat us appear more often. Self-play remains the default, with a fixed reference policy taking a smaller share so the run cannot silently forget its starting competence.

### Demonstrations as they arrive

Public ladder games enter by another route. We replay a foil or imitation policy, record every decision, and encode each dragon's life into compressed recurrent chunks. The trainer memory-maps those chunks and applies the DAPG demonstration loss beside PPO. An encoder can keep following a directory while games arrive, and training rescans it every few updates, so new games join without restarting the teacher.

### Compiled opponents

A mimic can also become a league opponent when it has a compatible checkpoint. A WASM bot cannot execute inside the CUDA engine, so our compiled planning bots play through the judge's served-team mode instead: the official engine and the WASM opponent run on the CPU, while a GPU server batches the teacher's replies. Those games are used for evaluation, and they can be introduced occasionally when an evaluation exposes a weakness. This gives the teacher changing opponents without training it on held-out ladder maps.

## The sidecar

![Teacher and student execution. On separate GPUs, the teacher trains continuously while the student repeatedly copies the teacher's latest atomic checkpoint and distils for fifteen minutes. On a single 16 GB card, the same jobs alternate in forty-five-minute and fifteen-minute turns. The teacher writes latest.pt every five updates in the live setup, a league snapshot every twenty-five updates by default, and saves again at normal exit or SIGTERM. Each student round keeps an immutable round-HHMM.pt for evaluation. Every dragon-turn remains in the active rollout, but a model file is not written after every dragon-turn.](images/rl-sidecar.svg)

The teacher writes `latest.pt` beside the live file and renames it into place, so the student can never open a half-written checkpoint. Our live command saves every five teacher updates, at normal exit, and when SIGTERM stops a rental. Separate league snapshots are written every 25 updates by default.

The student sidecar copies the newest complete teacher checkpoint at the start of each 15-minute round, resumes its own optimiser, and plays new games under its own policy. The teacher labels the action distributions on those positions. Each round ends quantisation-aware and is copied to an immutable `round-HHMM.pt`, which is what the fleet evaluates.

### One smaller card

On the workstation's 16 GB card, both networks do not fit at once. The same protocol alternates: 45 minutes of resumable teacher training, then 15 minutes of resumable student training. Stopping the wrapper sends SIGTERM to the current child, and the teacher saves the last completed update before exiting.

Every environment turn is kept in the current rollout until that update trains. We do not write a model snapshot after each dragon-turn. At tens of thousands of samples a second, doing so would replace training with filesystem writes. The atomic checkpoint and immutable snapshot intervals give us the two properties we need: a run can resume after interruption, and every policy sent to evaluation can be reproduced.

## The student

![The submitted student. A 15 by 15 remembered crop, whole-map overview, scalars and sonar inbox feed four integer convolutions, one of four expert pairs selected by a router and thirteen n-tuple lookup tables. Their features join a 256-unit GRU, committed role and claim heads, and move, split and recurrent sprint heads. The most probable legal action and a status sonar packet form the reply. Export checks the same recorded turns through PyTorch's integer implementation and the WebAssembly bot.](images/rl-student.svg)

The submitted bot cannot carry the teacher. The ZIP is capped at 4 MB, each dragon has 48 MB of memory, and a turn costs at most 100 million judge points. The student replaces the teacher's trunk with four 3 by 3 convolutions, but runs only one of four routed expert pairs on a turn. Thirteen n-tuple tables recognise small spatial patterns in the fresh window. A 256-unit GRU, overview and sonar encoders, role and claim heads, and the teacher's action tree complete it.

The student trains on-policy. It plays the states its own imperfect policy reaches and asks the teacher what distribution it should have produced there. This avoids the familiar failure where a student looks good on teacher states, makes one different move in a real game, and then has no training for everything that follows.

### Integer arithmetic

During the final third of each distillation round, training fakes the exact arithmetic used by the bot. Convolution weights are signed 8-bit values, activations are 16-bit, sums are exact 32-bit integers and each layer requantises with its recorded scale. Later dense layers and the GRU use 8-bit weights with one scale per row. The bot embeds about 1 MB of weights and performs about 8 million multiply-adds on a turn.

### Export gate

Export checks the student twice. PyTorch's integer path must choose the same action as the quantised student. Then the judge replays those turn blocks through the WebAssembly bot in inspection mode. Its observation tensor, remembered map, action and fixed status sonar must agree on every turn, and the judge measures its p99 point cost. Only after those checks does a student play verdicts against the foil and the latest reviewed planning bot.

## Literature used in the design

The diagram's keys cover every paper in the design plan. This list gives the full references and says what survived contact with this game.

| Papers | Where they landed |
| --- | --- |
| Schulman et al., [Proximal Policy Optimization Algorithms](https://arxiv.org/abs/1707.06347) (2017), and [High-Dimensional Continuous Control Using Generalized Advantage Estimation](https://arxiv.org/abs/1506.02438) (2016) | PPO is the main optimiser, and GAE carries sparse results back through each rollout. |
| Yu et al., [The Surprising Effectiveness of PPO in Cooperative Multi-Agent Games](https://arxiv.org/abs/2103.01955) (2022), Huang et al., [The 37 Implementation Details of PPO](https://arxiv.org/abs/2205.09123) (2022), and Pinto et al., [Asymmetric Actor Critic for Image-Based Robot Learning](https://arxiv.org/abs/1710.06542) (2018) | These give the centralised critic, PPO implementation details and the separation between privileged training and partial-information play. |
| Ng, Harada and Russell, [Policy Invariance under Reward Transformations](https://ai.stanford.edu/~ang/papers/icml99-shaping.pdf) (1999) | The length margins enter as potential-based shaping rather than independent goals. |
| Vinyals et al., [Grandmaster Level in StarCraft II Using Multi-Agent Reinforcement Learning](https://doi.org/10.1038/s41586-019-1724-z) (2019), Jaderberg et al., [Population Based Training of Neural Networks](https://arxiv.org/abs/1711.09846) (2017), and [Human-level Performance in 3D Multiplayer Games with Population-Based Reinforcement Learning](https://doi.org/10.1126/science.aau6249) (2019) | AlphaStar supplies the league and autoregressive action-head precedents. Population members, exploiters and mutable training settings come from the two PBT papers. |
| Jiang, Grefenstette and Rocktaschel, [Prioritized Level Replay](https://arxiv.org/abs/2010.03934) (2021), and Cobbe et al., [Leveraging Procedural Generation to Benchmark Reinforcement Learning](https://arxiv.org/abs/1912.01588) (2020) | Generated maps provide the task distribution, while level replay balances novelty, difficulty and staleness. |
| Lin et al., [Don't Use Large Mini-Batches, Use Local SGD](https://arxiv.org/abs/1808.07217) (2020) | The three-GPU run lets each worker take local steps, then averages weights and AdamW moments every eight steps. |
| He et al., [Deep Residual Learning for Image Recognition](https://arxiv.org/abs/1512.03385) (2016), Wu and He, [Group Normalization](https://arxiv.org/abs/1803.08494) (2018), and Perez et al., [FiLM](https://arxiv.org/abs/1709.07871) (2018) | Residual blocks process the spatial crop, GroupNorm normalises their channels and FiLM injects scalar state into every block. |
| Shazeer et al., [Outrageously Large Neural Networks](https://arxiv.org/abs/1701.06538) (2017), Fedus, Zoph and Shazeer, [Switch Transformers](https://arxiv.org/abs/2101.03961) (2022), and Obando-Ceron et al., [Mixtures of Experts Unlock Parameter Scaling for Deep RL](https://arxiv.org/abs/2402.08609) (2024) | The teacher activates two of sixteen experts. The student uses a Switch-style top-one router so it stores four expert pairs but computes one. |
| Cho et al., [Learning Phrase Representations using RNN Encoder-Decoder for Statistical Machine Translation](https://arxiv.org/abs/1406.1078) (2014), and Ba, Kiros and Hinton, [Layer Normalization](https://arxiv.org/abs/1607.06450) (2016) | GRUs carry a dragon's state between turns. Layer normalisation prevents that state collapsing to the commonest action. |
| Zaheer et al., [Deep Sets](https://arxiv.org/abs/1703.06114) (2017), Parisotto and Salakhutdinov, [Neural Map](https://arxiv.org/abs/1702.08360) (2018), and Jaderberg et al., [Reinforcement Learning with Unsupervised Auxiliary Tasks](https://arxiv.org/abs/1611.05397) (2017) | A set encoder reads unordered sonar packets, the observation carries a structured remembered map, and auxiliary heads predict hidden and future state. |
| Berner et al., [Dota 2 with Large Scale Deep Reinforcement Learning](https://arxiv.org/abs/1912.06680) (2019) | New overview layers can start at zero without changing a trained policy, the network-surgery technique used by OpenAI Five. |
| Bacon, Harb and Precup, [The Option-Critic Architecture](https://arxiv.org/abs/1609.05140) (2017), and Vezhnevets et al., [FeUdal Networks](https://arxiv.org/abs/1703.01161) (2017) | Their temporal hierarchy appears only as the committed role head. We did not add a second policy that owns primitive actions. |
| Rajeswaran et al., [Learning Complex Dexterous Manipulation with Deep Reinforcement Learning and Demonstrations](https://arxiv.org/abs/1709.10087) (2018), Kapturowski et al., [Recurrent Experience Replay in Distributed Reinforcement Learning](https://openreview.net/forum?id=r1lyTjAqYX) (2019), and Schmitt et al., [Kickstarting Deep Reinforcement Learning](https://arxiv.org/abs/1803.03835) (2018) | DAPG mixes recorded foil turns into PPO, recurrent demonstration chunks begin with a burn-in state, and kickstarting fades the penalty toward the warm-start policy. |
| Rusu et al., [Policy Distillation](https://arxiv.org/abs/1511.06295) (2016), Agarwal et al., [On-Policy Distillation of Language Models](https://arxiv.org/abs/2306.13649) (2024), and Warrington et al., [Robust Asymmetric Learning in POMDPs](https://arxiv.org/abs/2012.15566) (2021) | The small policy learns the large one's distribution on student-visited states. A2D is the warning behind keeping privileged board information in the critic rather than the teacher policy's inputs. |
| Loshchilov and Hutter, [Decoupled Weight Decay Regularization](https://arxiv.org/abs/1711.05101) (2019), and Jacob et al., [Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference](https://arxiv.org/abs/1712.05877) (2018) | AdamW carries the optimisation state in resumable checkpoints. Quantisation-aware training reproduces the submitted bot's integer arithmetic. |
| Buro, [From Simple Features to Sophisticated Evaluation Functions](https://doi.org/10.1007/3-540-48957-6_8) (1999), and Szubert and Jaskowski, [Temporal Difference Learning of N-Tuple Networks for the Game 2048](https://doi.org/10.1109/CIG.2014.6932877) (2014) | The student's n-tuple tables cheaply recognise local arrangements that would otherwise need more convolutional capacity. |

## Literature we reviewed but did not use directly

Some papers were useful because they marked a path we should not take for this run.

| Paper | Why it is not part of the current design |
| --- | --- |
| Shao et al., [DeepSeekMath](https://arxiv.org/abs/2402.03300) (2024) | GRPO compares several sampled answers to the same prompt. A Loong decision changes a long sequential state and already has a learned value baseline, so full-game GRPO would discard useful temporal credit. We reserved it for isolated choices such as split size. |
| Douillard et al., [DiLoCo](https://arxiv.org/abs/2311.08105) (2023) | DiLoCo is designed for weakly connected islands that communicate hundreds of times less often. Our three rented GPUs were on one host, so averaging weights and AdamW state every eight local steps was simpler and frequent enough. |
| Lee et al., [SimBa](https://arxiv.org/abs/2410.09754) (2025), and Nauman et al., [BRO](https://arxiv.org/abs/2405.16158) (2024) | Both show ways to scale networks in continuous-control benchmarks. Our bottleneck was a partially observed spatial board, recurrent memory and a strict WebAssembly budget. We kept SimBa's lesson about normalised residual paths, but not its MLP architecture. BRO's large optimistic critics did not fit our discrete multi-agent PPO setup. |
| Ross, Gordon and Bagnell, [DAgger](https://arxiv.org/abs/1011.0686) (2011) | DAgger asks an expert to label the learner's visited states. Public replays contain only the states the ladder bot actually visited, and another team's hidden state is unavailable. We used DAPG on recorded trajectories instead. |
| Hester et al., [Deep Q-learning from Demonstrations](https://arxiv.org/abs/1704.03732) (2018) | DQfD is an off-policy value-learning method built around replay. Our recurrent multi-agent policy is trained on-policy with PPO, and its structured sprint distribution is easier to represent as actor heads than as Q-values for every packed action. |
| Teh et al., [Distral](https://arxiv.org/abs/1707.04175) (2017) | Distral trains several task policies around a shared distilled policy. We need one general submission and had time for one main teacher. Short specialist fine-tunes can still feed the same student without maintaining a permanent policy per map family. |

The rejected approaches can become sensible under different constraints. More disconnected GPUs would make DiLoCo attractive. An expert that can label arbitrary states would reopen DAgger. A stable family of specialists would give Distral a real set of tasks. For this run, each extra mechanism had to improve the one teacher, one student and one submitted bot we could finish before the cutoff.

Next: [A tour of our bot](28-a-tour-of-our-bot.md), the historical planning design and its unfinished student-mover integration.
