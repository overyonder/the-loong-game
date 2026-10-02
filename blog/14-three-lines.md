# Three lines

The first strategy bot gave us an architecture we could extend, but one bot can't answer every useful question at once. A design kept close to the textbooks is easy to explain and improve systematically. A rival that can use any method is free to find a shortcut. A learned policy can absorb patterns that are awkward to express as rules. We therefore develop three bot lines side by side: textbook, foil and learned.

![Three bot lines share the game, evaluation pool and replay evidence. The textbook line assembles known methods clearly, the foil is a rival free to use any method, and the learned line trains a policy and distils it into a small student.](images/three-bot-lines.svg)

## Textbook

The textbook line asks what a standard computer-science method would do here. Its bot is assembled from data structures, decision architectures and game techniques with their usual names and boundaries. A behaviour owns one purpose, the circumstances in which it applies and the action it takes. The bot's main file only chooses which behaviours and parameters to assemble.

That gives us a direction for improvement. Whenever the implementation departs from the method it is meant to follow, the departure becomes something to inspect. If an idea looks novel while the bot is still making ordinary mistakes, I first look for the established method it is approximating.

```text
bots/
  textbook/main/NNNN/   # one numbered textbook version
  foil/main/NNNN/       # one numbered foil version
  rl/main/NNNN/         # one numbered learned version
```

## Foil

The foil is the rival and counterpoint. It can use whatever method seems likely to work, with no duty to resemble a textbook design. We play it against the textbook line, read the surprising games in the viewer and carry general lessons between them.

The lines remain separate even when one teaches the other something. Otherwise a comparison would quietly become a comparison of one bot with itself, and we would lose the different set of mistakes that makes the foil useful.

| Line | The question it keeps asking |
| --- | --- |
| Textbook | What established method should this layer use? |
| Foil | What can beat the current bots, by any method? |
| Learned | What policy can the games teach, within the judge's limits? |

## Learned

The learned line turns games into a policy. A large teacher can use more computation while training, then a smaller student learns its choices and fits inside the judge's time and memory limits. [Learning to play](27-learning-to-play.md) follows that pipeline from self-play through distillation.

The three lines can share infrastructure without sharing an implementation. They use the same judge, generated maps, evaluation pool, build registry and replay viewer. A result can therefore be compared on the same terms while each line keeps its own answer to how a dragon should decide.

## Frozen versions

![The current version is frozen, built with pinned library pieces and kept as replay provenance, an opponent and a regression test. Library pieces advance independently from pseudocode to Nim and, when a measured kernel needs it, Rake.](images/frozen-versions.svg)

A line's highest numbered version is the one being developed. When it reaches a point worth evaluating, we freeze that numbered directory, register the WebAssembly it builds and begin work under the next number. A frozen version never changes.

Keeping old versions costs some space, but deleting them would discard evidence. They are opponents in the [ladder of our own](07-a-ladder-of-our-own.md), baselines for a verdict, and the exact programs needed to rebuild an old game's decisions in the viewer. An identifier such as `textbook-main-NNNN` says which line it belongs to, that it is a main version, and which immutable snapshot it is.

## Versioned pieces

Freezing a whole bot isn't enough if its imports can change underneath it. Each reusable library piece has its own numbered versions. Its clearest form may begin as pseudocode, move into Nim when a bot uses it, and gain a Rake version when measurements show that its hot loop belongs in a vector kernel. Those are new versions of one piece rather than silent rewrites.

Each bot's `library.toml` pins the exact versions it imports. The build assembles those pieces once and records their hashes with the WebAssembly, so rerunning an old bot means rebuilding the same source rather than today's library under yesterday's name. [Counting room faster](18-counting-room-faster.md) shows that progression on a flood fill, from the direct Nim version to the measured Rake kernel.

The numbers record provenance. A later number doesn't claim that its bot is better. A new version may test an idea that loses at first, as the tactics bot did, or expose a dependency that the next version supplies. The games and replays say what happened. The version tells us exactly what played them.

## Next up

[Roles](15-roles.md): giving dragons different jobs, and letting each one work out its role from the same local program.
