# Through one dragon's eyes

<!-- draft: c8818e86ed, stage: Building our tooling -->

When a dragon does something stupid, the official visualiser shows us the whole board. But the dragon never saw the whole board. It saw the 7×7 square around its head, plus whatever its program chose to remember, and a move that looks absurd from above can look perfectly sensible from inside that square. So the question when debugging is never "what was on the board?" but "what did this dragon think was on the board?"

The seventh tool on the wishlist answers that question: a debug viewer that shows a game through one dragon's eyes. It's written in [Odin](https://odin-lang.org), for the reasons in [The choice](02-the-choice.md), and it builds on the [decoder](08-reading-a-replay.md) from the last post. At the end, we'll use it on the question that post left open.

## From replay to viewer

The viewer owns replay decoding as well as display. Its [board library](../src/viewer/board.py) reconstructs observations, and the inline export recipe in [just/inspection.just](../just/inspection.just) writes JSON for Odin: the map's kelp and portal edges, the true board before every round, and one record for every dragon turn. A turn looks like this:

```json
{"dragon": 0, "team": 0, "round": 129, "head": 199, "length": 86,
 "window": "ooaaaaaooaaaaaooaaaaaoooAoaao..o.aa.....o.oooo.o.",
 "indicator": "", "action": "MOVE E"}
```

The `window` is the dragon's view as 49 characters, row by row: `.` for empty, `o` for a pearl, and a letter for each dragon segment, capital for a head. The `indicator` is the text a bot can attach to its dragon each turn, which the strategy posts later in the series use to show each dragon's role and mode.

## Loading a game into an arena

The viewer reads that JSON with Odin's standard library, and this is where Odin's context allocator earns its place. The loader creates a fresh arena, makes it the allocator for everything that follows, and lets the JSON parser allocate as much as it likes:

```odin
load_game :: proc(path: string) -> (game: Game, ok: bool) {
	if virtual.arena_init_growing(&game.arena) != nil {
		return
	}
	context.allocator = virtual.arena_allocator(&game.arena)

	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil || json.unmarshal(data, &game.export) != nil || game.version != 1 || len(game.frames) == 0 {
		virtual.arena_destroy(&game.arena)
		return
	}
	game.turns_by_dragon = make(map[i32][dynamic]int)
	for turn, index in game.turns {
		if turn.dragon not_in game.turns_by_dragon {
			game.turns_by_dragon[turn.dragon] = make([dynamic]int)
		}
		append(&game.turns_by_dragon[turn.dragon], index)
	}
	return game, true
}
```

Every string, slice and map in the game ends up in that one arena, including thousands of 49-character windows, without the parser knowing anything about it. Closing the game frees all of it with a single `arena_destroy`, so there's no chance of leaking or double-freeing one of those small allocations.

## What a dragon remembers

The first viewer accumulated each dragon's visible tiles and faded them after they left its window. That was an estimate of what a bot *could* remember, not a record of what its program retained. The screenshots below show that early view. Their side panels must not be read as recovered bot memory.

The current public viewer shows recorded observations and labels that limitation. Recovering a bot's internal state requires its exact build and knowledge of its state format. The private viewer can re-run identified builds over recorded observations and report action mismatches and state-check results; that recovery code and the private bot models are not part of this public release. Even a matching re-run is evidence about the reconstruction, not a memory dump from the original game.

The current source is in [src/viewer/](../src/viewer/main.odin). From `examples/tooling`, `just viewer REPLAY --round 130 --dragon 0` builds the Odin display and opens the selected turn. `just viewer REPLAY --no-display --export game.json` exports the observation data without opening a window. The code excerpt above describes the original version-one loader; the current export format is version three.

## Why chasing pearls kills

Back to the question from the last post. The pearl-chasing bot's dragons hit walls and themselves about three times as often as the plain flood-fill bot's. Here's one of them in the viewer, on the 16×16 Colosseum map, just before it dies:

![The debug viewer at round 130 of room-pearls against room-c on Colosseum. Dragon 0 of room-pearls is 86 segments long and fills most of the board. Only a 7×7 square around its head is lit. Below the head is a portal edge. The side panel shows its memory, much of which no longer matches the board.](images/viewer-long-dragon-portal.png)

The dragon is 86 segments long on a board of 256 tiles. Its window holds 49 tiles, so most of its own body is somewhere it can't see. On its next move it went south, through the portal edge under its head, and landed on its own body on the far side. That's the portal blind spot from [the map generator post](05-maps-nobody-has-seen.md), made much more likely by a body that fills a third of the board.

The next one has no portals to blame. The big_empty map has no kelp and no portals at all, and this dragon had grown to 122 segments:

![The debug viewer at round 337 of room-pearls against room-c on big_empty, a 64×64 map with no kelp or portals. Dragon 4 of room-pearls is 122 segments long. Its head is wound into a tight knot of its own body, and its 7×7 window shows almost nothing but its own segments.](images/viewer-long-dragon.png)

Its head is wound into a knot of its own body, and almost everything in its window is itself. The flood fill only counts room inside the window, and here the window has very little in it but the dragon's own segments, so the bot has almost nothing to choose between its moves with. Its next move ran into its own body.

The numbers across all 66 games say the same thing. Chasing pearls works, in that the dragons get long: the pearl chaser's longest dragon reached a median of 33.5 segments per game, against 13.5 for the plain flood-fill bot. But its dragons that hit themselves had a median length of 32, against 13.5, and 17 of those 51 were longer than 49 segments, too long to fit in their own window even in principle. The flood fill was designed for a short dragon, and chasing pearls quietly takes that assumption away.

So the change wasn't wrong to want length. It was missing the other half: a bot that grows long needs to know where its own body is outside its window, and which parts of it will have moved on by the time it gets there. That's a job for strategy, and the next stage of the series is where it belongs.

## Next up

The last tool on the wishlist is profiling: [where the points go](10-where-the-points-go.md).
