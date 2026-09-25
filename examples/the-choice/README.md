# The choice

The same strategy in C, Python and Nim, from [The choice](../../blog/02-the-choice.md). Each turn, a dragon tries every move and every follow-up move, flood-fills the visible 7×7 window from where it would end up, and takes the move that leaves it the most room. `c-idle` and `python-idle` only repeat their last move, which measures each language's fixed cost per turn.

The helper files come from the toolkit, so they aren't copied here. To run the bots:

1. In this folder, run `unswbc maps`.
2. Run `unswbc init c scratch` and `unswbc init python scratch-py`. Copy `helper.c` and `helper.h` into `c/`, `c-idle/` and `nim/`, and `helper.py` into `python/` and `python-idle/`.
3. Copy `nimbase.h` into `nim/` from the `lib` folder that `nim dump` prints.
4. Run `nim c nim/strategy.nim`. `nim/nim.cfg` makes it write C into `nim/gen/` instead of building a program.
5. Run `fish measure.fish` to play each bot against itself on every map and print its points per turn.
