package viewer

// Boards are rebuilt from the game's events (gamedata/format.md,
// `event`): a board is the starting dragons with every earlier event applied.
// A keyframe copy is kept every KEYFRAME_ROUNDS rounds the first time a
// replay passes it, so any board is at most that many rounds of events away.

KEYFRAME_ROUNDS :: 32

EVENT_ROUND_START :: 1
EVENT_TURN_START :: 2
EVENT_COUNTDOWN :: 3
EVENT_TILE :: 4
EVENT_MOVE :: 5
EVENT_SPLIT :: 6
EVENT_DEATH :: 7

// The board after the first `position` events.
Board_State :: struct {
	position:            int,                   // events applied
	round:               i32,
	dragons:             [dynamic]Board_Dragon, // bodies are [dynamic] arrays' slices
	bodies:              [dynamic][dynamic]i32, // each dragon's body, parallel to `dragons`
	pearl:               []bool,                // per cell
	due:                 []i32,                 // per cell: round of its next spawn attempt, or -1
	deaths_this_round:   [dynamic]Board_Death,
}

Board_Keyframe :: struct {
	state: Board_State,
}

// One cursor over the events, and the frame it last produced.
Board_Replay :: struct {
	state:   Board_State,
	started: bool,
	pearls:  [dynamic]i32,
	timers:  [dynamic]Pearl_Timer,
	frame:   Board_Frame,
}

initial_board_state :: proc(game: ^Loaded_Game, allocator := context.allocator) -> (state: Board_State) {
	view := &game.view
	cells := int(view.width * view.height)
	state.round = -1
	state.pearl = make([]bool, cells, allocator)
	state.due = make([]i32, cells, allocator)
	for &due in state.due {due = -1}
	state.dragons = make([dynamic]Board_Dragon, allocator)
	state.bodies = make([dynamic][dynamic]i32, allocator)
	state.deaths_this_round = make([dynamic]Board_Death, allocator)
	dragons := column_values(&view.columns, "start.dragon", u32)
	teams := column_values(&view.columns, "start.team", u8)
	for dragon, index in dragons {
		body := make([dynamic]i32, allocator)
		for cell in list_row(&view.columns, "start.body", "start.body#", index, u32) {append(&body, i32(cell))}
		append(&state.bodies, body)
		append(&state.dragons, Board_Dragon{id = i32(dragon), team = i32(teams[index])})
	}
	return
}

copy_board_state :: proc(into: ^Board_State, from: Board_State, allocator := context.allocator) {
	if into.pearl == nil {
		into.pearl = make([]bool, len(from.pearl), allocator)
		into.due = make([]i32, len(from.due), allocator)
		into.dragons = make([dynamic]Board_Dragon, allocator)
		into.bodies = make([dynamic][dynamic]i32, allocator)
		into.deaths_this_round = make([dynamic]Board_Death, allocator)
	}
	into.position, into.round = from.position, from.round
	copy(into.pearl, from.pearl)
	copy(into.due, from.due)
	clear(&into.dragons)
	append(&into.dragons, ..from.dragons[:])
	for len(into.bodies) < len(from.bodies) {append(&into.bodies, make([dynamic]i32, allocator))}
	for &body, index in into.bodies[:len(from.bodies)] {
		clear(&body)
		append(&body, ..from.bodies[index][:])
	}
	resize(&into.bodies, len(from.bodies))
	clear(&into.deaths_this_round)
	append(&into.deaths_this_round, ..from.deaths_this_round[:])
}

board_dragon_index :: proc(state: ^Board_State, dragon: i32) -> int {
	for entry, index in state.dragons {if entry.id == dragon {return index}}
	return -1
}

apply_board_event :: proc(game: ^Loaded_Game, state: ^Board_State, event: int) {
	view := &game.view
	a, b, c, d := view.event_a[event], view.event_b[event], view.event_c[event], view.event_d[event]
	switch view.event_kind[event] {
	case EVENT_ROUND_START:
		state.round = a
		clear(&state.deaths_this_round)
	case EVENT_COUNTDOWN:
		state.due[a] = state.round + b
	case EVENT_TILE:
		state.pearl[a] = b != 0
	case EVENT_MOVE:
		index := board_dragon_index(state, a)
		if index < 0 {break}
		body := &state.bodies[index]
		inject_at(body, 0, b)
		for len(body) > 1 && body[len(body) - 1] != c {pop(body)}
	case EVENT_SPLIT:
		parent := board_dragon_index(state, a)
		if parent < 0 {break}
		clear(&state.bodies[parent])
		for cell in list_row(&view.columns, "split.parent_body", "split.parent_body#", int(d), u32) {append(&state.bodies[parent], i32(cell))}
		child := make([dynamic]i32, game_allocator(game))
		for cell in list_row(&view.columns, "split.child_body", "split.child_body#", int(d), u32) {append(&child, i32(cell))}
		append(&state.bodies, child)
		append(&state.dragons, Board_Dragon{id = b, team = c})
	case EVENT_DEATH:
		index := board_dragon_index(state, a)
		if index < 0 {break}
		head := state.bodies[index][0] if len(state.bodies[index]) > 0 else -1
		append(
			&state.deaths_this_round,
			Board_Death{id = a, team = state.dragons[index].team, cell = head, reason = death_reason_name(b)},
		)
		delete(state.bodies[index])
		ordered_remove(&state.bodies, index)
		ordered_remove(&state.dragons, index)
	}
	state.position = event + 1
}

death_reason_name :: proc(code: i32) -> string {
	switch code {
	case 0:
		return "hit a wall"
	case 1:
		return "hit itself"
	case 2:
		return "hit another dragon"
	case 3:
		return "lost a head-to-head"
	case 4:
		return "no valid action"
	}
	return "unknown reason"
}

// The board after the first `stop` events, with who has died so far this round
// when `deaths` is set: advanced from the cursor when no keyframe lies between,
// else restored from the nearest keyframe before.
board_after_events :: proc(game: ^Loaded_Game, replay: ^Board_Replay, stop: int, deaths: bool) -> ^Board_Frame {
	allocator := game_allocator(game)
	if !replay.started {
		replay.state = initial_board_state(game, allocator)
		replay.started = true
	}
	state := &replay.state
	keyframe := -1
	for frame, index in game.keyframes {if frame.state.position <= stop {keyframe = index}}
	if state.position > stop || (keyframe >= 0 && game.keyframes[keyframe].state.position > state.position) {
		if keyframe >= 0 {
			copy_board_state(state, game.keyframes[keyframe].state, allocator)
		} else {
			replay.state = initial_board_state(game, allocator)
		}
	}
	for state.position < stop {
		event := state.position
		apply_board_event(game, state, event)
		if game.view.event_kind[event] == EVENT_ROUND_START &&
		   state.round % KEYFRAME_ROUNDS == 0 &&
		   int(state.round) / KEYFRAME_ROUNDS == len(game.keyframes) {
			append(&game.keyframes, Board_Keyframe{})
			copy_board_state(&game.keyframes[len(game.keyframes) - 1].state, state^, allocator)
		}
	}
	clear(&replay.pearls)
	for present, cell in state.pearl {if present {append(&replay.pearls, i32(cell))}}
	clear(&replay.timers)
	for due, cell in state.due {
		if due >= 0 {append(&replay.timers, Pearl_Timer{cell = i32(cell), remaining = max(0, due - state.round)})}
	}
	for &dragon, index in state.dragons {dragon.body = state.bodies[index][:]}
	replay.frame = {
		dragons = state.dragons[:],
		pearls  = replay.pearls[:],
		deaths  = deaths ? state.deaths_this_round[:] : nil,
		timers  = replay.timers[:],
	}
	return &replay.frame
}

// A round's board after every dragon has moved in it, with the round's deaths:
// the heads its sonar pings leave from.
frame_board :: proc(game: ^Loaded_Game, frame: i32) -> ^Board_Frame {
	rounds := game.view.round_event
	stop := int(frame) + 1 < len(rounds) ? int(rounds[frame + 1]) : len(game.view.event_kind)
	return board_after_events(game, &game.frame_board, stop, true)
}

// The board at a turn's start, before the dragon acts, with the round's deaths so far.
turn_board :: proc(game: ^Loaded_Game, turn: int) -> ^Board_Frame {
	return board_after_events(game, &game.turn_board, int(game.view.turn_event[turn]), true)
}
