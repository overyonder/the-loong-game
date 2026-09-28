# Through one dragon's eyes

> **Editor's note, 28 September 2026.** I've rewritten this post to be shorter and to quote the viewer's current loader. I took the examples and figures from the rerun ladder, played with toolkit 1.2.2 on the new generated maps.

When a dragon does something stupid, the official visualiser shows the whole board. But the dragon only saw the 7×7 square around its head, and a move that looks absurd from above can look sensible from inside that square. So the debugging question is never "what was on the board?" but "what could this dragon see?" The seventh tool answers it: a debug viewer that shows a game through one dragon's eyes, written in [Odin](https://odin-lang.org) for the reasons in [The choice](02-the-choice.md) and built on the [decoder](08-reading-a-replay.md).

## From replay to viewer

The viewer's Python side rebuilds the game from the replay and exports it as JSON for the Odin display: the map's kelp and portals, the board before every round, and one record for every dragon turn, holding the dragon's window, its indicator text and its action. From `examples/tooling`, `just viewer REPLAY --round 208 --dragon 7` builds the viewer and opens that turn, and `--image board.png` saves the display as a picture instead.

## Loading a game into an arena

Loading is where Odin's context allocator earns its place. The loader creates a fresh arena and hands its allocator to everything that follows, including the JSON parser, which allocates as much as it likes:

```odin
game: Loaded_Game
if virtual.arena_init_growing(&game.arena) != nil {
	return "Could not reserve memory for the export"
}
allocator := virtual.arena_allocator(&game.arena)
data, read_error := os.read_entire_file(path, allocator)
if read_error != nil {
	virtual.arena_destroy(&game.arena)
	return fmt.aprintf("Could not read %s: %v", path, read_error)
}
if unmarshal_error := json.unmarshal(data, &game.export, allocator = allocator);
   unmarshal_error != nil {
	virtual.arena_destroy(&game.arena)
	return fmt.aprintf("Could not parse %s: %v", path, unmarshal_error)
}
```

Every string, slice and map in the game ends up in that one arena, including thousands of 49-tile windows, and opening the next game frees all of it with a single `arena_destroy`. There's no way to leak or double-free one of those small allocations. The full source is in [replays/viewer/](../replays/viewer/main.odin).

## What a bot can tell you

A replay records what a dragon saw and did, but not why. A bot can say why through its indicator, the short text the viewer shows beside the dragon. The example bots use it to name their role and behaviour each turn. Our competition bot goes further without spending a point during play. The replay records what each dragon observed, and the bot is deterministic, so our viewer re-runs the same build on those observations and gets the same decisions back, this time with every behaviour it considered written out: whether each was eligible, its score and reason, and which one it chose. The viewer draws that as a tree beside the board. A bad move then leads straight to the decision that caused it.

## Why chasing pearls kills

Back to the question from the last post: why do the pearl chaser's dragons hit walls and themselves so much more often than the plain flood-fill bot's? Here's one in the viewer, on the bundled Autarky map, just before it dies:

![The debug viewer at round 208 of room-c against room-pearls on Autarky. Dragon 7 of room-pearls is 27 segments long. Its head sits inside a small walled box on the left of the board, and the rest of its body trails across the right side. The inspector reports the dragon's length and action, MOVE N, and notes that the bot's memory is unavailable because its build can't be identified.](images/viewer-long-dragon-portal.png)

Its head is inside a small walled box that the dragon can only have entered through a portal, and most of its body is back on the other side of the board, far outside its 49-tile window. Its next move went north through the portal edge and landed on its own body on the far side. That's the portal blind spot from [the map generator post](05-maps-nobody-has-seen.md), and 28 of the pearl chaser's 91 self-hits in these games went through a portal the same way.

The next one has no portal to blame. Pale Maze, one of the generated maps, has no portals, and this dragon had grown to 55 segments:

![The debug viewer at round 131 of room-c against room-pearls on Pale Maze, a 26×50 generated map with no portals. Dragon 9 of room-pearls is 55 segments long, and its head is enclosed by a loop of its own body. The inspector reports its action, MOVE S.](images/viewer-long-dragon.png)

Its head is wound inside a loop of its own body, so most of what its window shows is itself. The flood fill only counts room inside the window, so it has almost nothing to choose between moves with, and the next move ran into its own body.

Across all 70 games the numbers agree. Chasing pearls works, in that dragons get long, and the ones that die on their own bodies are long too:

![Median dragon lengths across the 70 games. The longest dragon per game: 22 segments for room-c and 46.5 for room-pearls. Dragons that hit themselves: 8.5 for room-c and 27 for room-pearls.](images/pearl-lengths.svg)

A third of the pearl chaser's self-hits were dragons longer than 49 segments, too long to fit in their own window. The flood fill was designed for a short dragon, and chasing pearls takes that assumption away. A bot that grows long needs to know where its own body is outside its window, which is a job for strategy.

## Next up

The last tool on the wishlist is profiling: [where the points go](10-where-the-points-go.md).
