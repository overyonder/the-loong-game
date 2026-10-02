# Local tooling

Run the canonical commands from `examples/tooling`. Install Nim 2.2 or newer, Zig
0.16, `just`, the `unswbc` Python toolkit, and the development libraries for
SQLite, OpenSSL and zlib. Building the judge also needs Wasmtime's C headers
and static library, plus libunwind. Set `WASMTIME_INCLUDE` and `WASMTIME_LIB`,
or pass `-Dwasmtime-include=DIR -Dwasmtime-lib=DIR` to its build.
`LOONG_PYTHON` selects the Python interpreter.

```sh
cd examples/tooling
just tools-build
just zig-judge-build
```

These build stages write only under the repository's ignored `build/`
directory. Other commands use the resulting binaries; they don't compile
missing tools. See [profiling](profiling/README.md), the
[judge](zig_judge/README.md) and the [collector](../replays/README.md).
The organiser's Python-only compiler and engine APIs have small Python
adapters. Replay decoding, gap fitting and regeneration checks run in Nim.

## Map variants

The input is a local packed Cap'n Proto replay, optionally gzip compressed,
and its unsigned 64-bit match seed. Supply map files with the same geometry
and metadata as the replay. Starting dragons come from the replay; a
candidate's pearl gaps come from the map file.

```sh
just map-variants check --map maps/arena.map --replay /path/game.replay --seed 123
just map-variants lookup --maps maps --replay /path/game.replay --seed 123
just map-variants lookup --maps maps --variants /path/my-tables \
  --replay /path/game.replay --seed 123 --output /path/restored.map
```

`MAP_VARIANTS=/path/my-tables` supplies the variants directory when
`--variants` is omitted. It is optional: a clean checkout can use ordinary
published maps and the released decoder. No fitted tables or stored games
are bundled. Lookup prints the chosen map path. With `--output`, it also
writes that table with the replay's starting dragons. Identical tables are
deduplicated. Zero matches or multiple distinct matches are errors.

`check` prints `first_contradiction_round<TAB>none`, or the first contradicting
round with exit status 1. Compatibility checks every recorded spawn and
every expected spawn on a free tile. Occupied tiles and existing pearls
suppress a spawn but still consume the engine's next random countdown.

To fit a table, supply at least three replays and their seeds in a TSV:

```text
seed	replay
123	/path/first.replay
456	/path/second.replay
789	/path/third.replay
```

```sh
just map-variants fit --map maps/arena.map --games /path/games.tsv \
  --largest-span 2000 --hidden-most 150 --output /path/fitted.map
```

The fitter searches gap widths up to `--largest-span`; `--hidden-most` bounds
extra countdown owners whose first spawn was hidden. It writes a `.map`
only after a table explains every supplied game. An unobserved enabled or hidden gap,
or another candidate found by its bounded search that explains all games,
is unresolved and prevents output. This is a bounded search, not a proof
that finite observations uniquely identify the original table. New evidence
can rule out a fitted table. Replay format 2 is supported. Unsupported map sizes, symmetry, replay events
or ambiguous body headings are refused. Exit status 2 reports invalid or
unresolved input.

## Regeneration

Regeneration restores countdowns through the supplied official engine. It
needs the original seed and exactly one compatible published or fitted gap
table. There is no fallback to guessed gaps.

```sh
just regenerate --replay /path/site.replay --seed 123 --maps maps \
  --variants /path/my-tables --output /path/restored.replay
```

The command replays recorded moves, splits and sonar through the engine,
then compares physical events, the result and final standings. It writes
nothing to the requested replay path when they differ. It refuses an
existing output. A successful run writes the packed replay and a sibling
`restored.regeneration.tsv` with columns `source_sha256`, `engine_sha256`,
`seed`, `turns`.

For one side whose exact local build is available:

```sh
just regenerate --replay /path/site.replay --seed 123 --maps maps \
  --build BUILD_GUID --side A --output /path/restored.replay
```

The immutable registry resolves the build; the judge runs it against the
other side's recorded actions with a 300-second timeout. `--registry`,
`--judge` and `--python` override their defaults. This verifies physical
agreement, not equality of hidden decisions or CPU points. The action-only
mode negotiates protocol 3, so it cannot recover omitted original protocol
negotiation or private bot memory. Diagnostics must be rebuilt separately
from the exact bot, as described in the viewer's diagnostics contract.

`--engine FILE.wasm` selects the engine explicitly. The default is the
installed toolkit's engine. Use the version that produced the original
game; rule changes can make regeneration fail. Toolkit 1.2.3 or newer is
required when the selected engine uses its 48-byte result ABI. The judge
host accepts both 32-byte and 48-byte results; the bundled CPU lockstep
reference has the narrower compatibility described in its README.
