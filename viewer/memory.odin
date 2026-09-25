package viewer

// Rebuild what the selected dragon has seen by the start of the drawn frame. The
// dragon is assumed to remember the last thing it saw in every cell, which is the
// most any bot could know. A dragon that split off starts with an empty memory,
// because it's a fresh process.
refresh_memory :: proc(viewer: ^Viewer) {
	game := &viewer.game
	frame := i32(viewer.frame)
	if frame == viewer.memory_frame && viewer.selected == viewer.memory_dragon && viewer.memory != nil {
		return
	}
	cells := int(game.width * game.height)
	if viewer.memory == nil {
		viewer.memory = make([]Content, cells, context.allocator)
		viewer.visible = make([]bool, cells, context.allocator)
		viewer.actual = make([]Content, cells, context.allocator)
	}
	viewer.memory_frame, viewer.memory_dragon = frame, viewer.selected

	board := game.frames[frame]
	for &cell in viewer.actual do cell = .Empty
	for pearl in board.pearls do viewer.actual[pearl] = .Pearl
	for dragon in board.dragons {
		for cell, index in dragon.body {
			viewer.actual[cell] = dragon.team == 0 ? (index == 0 ? .A_Head : .A_Body) : (index == 0 ? .B_Head : .B_Body)
		}
	}

	for &cell in viewer.memory do cell = .Unknown
	for &cell in viewer.visible do cell = false
	turns, found := game.turns_by_dragon[viewer.selected]
	if !found do return
	latest := -1
	for index in turns {
		turn := game.turns[index]
		if turn.round >= frame do break
		latest = index
		for character, offset in turn.window {
			viewer.memory[window_cell(game, turn.head, offset)] = content_of(character)
		}
	}
	if latest >= 0 && game.turns[latest].round == frame - 1 {
		for offset in 0 ..< 49 {
			viewer.visible[window_cell(game, game.turns[latest].head, offset)] = true
		}
	}
}

// The board cell at one position of a window, wrapping at the map's edges.
window_cell :: proc(game: ^Game, head: i32, offset: int) -> i32 {
	x := (head % game.width + i32(offset % 7) - 3 + game.width) % game.width
	y := (head / game.width + i32(offset / 7) - 3 + game.height) % game.height
	return y * game.width + x
}

content_of :: proc(character: rune) -> Content {
	switch character {
	case 'o': return .Pearl
	case 'a': return .A_Body
	case 'A': return .A_Head
	case 'b': return .B_Body
	case 'B': return .B_Head
	}
	return .Empty
}

// The selected dragon's latest turn before the drawn frame.
latest_turn :: proc(viewer: ^Viewer) -> (^Turn, bool) {
	turns, found := viewer.game.turns_by_dragon[viewer.selected]
	if !found do return nil, false
	for position := len(turns) - 1; position >= 0; position -= 1 {
		turn := &viewer.game.turns[turns[position]]
		if turn.round < i32(viewer.frame) do return turn, true
	}
	return nil, false
}
