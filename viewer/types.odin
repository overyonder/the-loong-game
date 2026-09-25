package viewer

import virtual "core:mem/virtual"

// The export written by `python3 -m replays.export`. Field names match its JSON keys.
// Cells are numbered y * width + x.

Edge :: struct {
	x, y:   i32,
	side:   i32,  // 0 = the cell's north edge, 1 = its west edge
	kelp:   bool,
	portal: i32,  // portal pair number, or -1 for kelp
}

Dragon :: struct {
	id:   i32,
	team: i32,   // 0 = team A, 1 = team B
	body: []i32, // cells from head to tail
}

Death :: struct {
	id, team, cell: i32,
	reason:         string,
}

// The true board before a round. The last frame is the board after the final round.
Frame :: struct {
	dragons: []Dragon,
	pearls:  []i32,
	deaths:  []Death, // deaths during the round before this frame
}

// One dragon's turn: what it could see, what it did, and the indicator it set.
Turn :: struct {
	dragon, team, round: i32,
	head, length:        i32,
	window:              string, // 49 characters, row by row around the head: . o a A b B
	indicator:           string,
	action:              string,
}

Export :: struct {
	version:       i32,
	width, height: i32,
	bot_a, bot_b:  string,
	winner:        string,
	edges:         []Edge,
	frames:        []Frame,
	turns:         []Turn,
}

// A loaded game. Everything it points to lives in `arena`, so one call frees the lot.
Game :: struct {
	arena:           virtual.Arena,
	using export:    Export,
	turns_by_dragon: map[i32][dynamic]int, // indices into turns, in order
}

// What a cell holds, on the true board or in a dragon's memory.
Content :: enum u8 {Unknown, Empty, Pearl, A_Body, A_Head, B_Body, B_Head}

Fog :: enum {Show, Fade, Hide}

Viewer :: struct {
	game:     Game,
	frame:    f32,  // fractional during playback; the drawn frame is its floor
	playing:  bool,
	speed:    f32,  // rounds per second, negative to rewind
	fog:      Fog,
	selected: i32,  // dragon ID, or -1

	// The selected dragon's view of the board at the drawn frame.
	memory:   []Content, // last thing it saw in each cell
	visible:  []bool,    // in its window on its latest turn
	actual:   []Content, // the true board
	memory_frame, memory_dragon: i32,
}
