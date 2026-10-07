package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// The replay stays untouched. Bodies and pearls belong to this frozen manual
// board; controlled indexes follow birth order, with a new child acting first.
Ghost :: struct {
	active: bool,
	dragon, start_round, start_turn: i32,
	start_substeps: bool,
	dragons: [dynamic]Board_Dragon,
	bodies: [dynamic][dynamic]i32,
	pearls: [dynamic]i32,
	controlled: [dynamic]int,
	current, steps, free_steps: int,
	turns: [dynamic]Ghost_Turn,
	refusal: string,
	refusal_text: [96]u8,
}
Ghost_Turn :: struct {
	actor: int, // index in controlled; zero is the parent
	split: int,
	directions: [dynamic]u8,
}

clear_ghost :: proc(ghost: ^Ghost) {
	for body in ghost.bodies {delete(body)}
	for turn in ghost.turns {delete(turn.directions)}
	delete(ghost.bodies)
	delete(ghost.dragons)
	delete(ghost.pearls)
	delete(ghost.controlled)
	delete(ghost.turns)
	ghost^ = {}
}

begin_ghost_turn :: proc(ghost: ^Ghost, actor: int) {
	ghost.current = actor
	ghost.steps = 0
	ghost.free_steps = (len(ghost.bodies[ghost.controlled[actor]]) + 3) / 4
	ghost.refusal = ""
	append(&ghost.turns, Ghost_Turn{actor = actor})
}

start_ghost :: proc(ghost: ^Ghost, board: ^Board_Frame, dragon: i32) {
	for entry, index in board.dragons {
		body := make([dynamic]i32)
		append(&body, ..entry.body)
		append(&ghost.bodies, body)
		append(&ghost.dragons, entry)
		if entry.id == dragon {append(&ghost.controlled, index)}
	}
	if len(ghost.controlled) == 0 {clear_ghost(ghost); return}
	append(&ghost.pearls, ..board.pearls)
	ghost.active = true
	ghost.dragon = dragon
	begin_ghost_turn(ghost, 0)
}

toggle_ghost :: proc(viewer: ^Viewer_State) {
	ghost := &viewer.ghost
	if ghost.active {clear_ghost(ghost); return}
	if viewer.selected_dragon < 0 {return}
	start_ghost(ghost, board_at_selection(viewer, current_frame(viewer)), viewer.selected_dragon)
	ghost.start_round = current_frame(viewer)
	ghost.start_turn = i32(active_turn_index(viewer))
	ghost.start_substeps = viewer.playback.substeps
	viewer.playback.playing = false
}

// Only frozen, uncontrolled survivors use the normal dragon renderer.
ghost_board :: proc(ghost: ^Ghost) -> ^Board_Frame {
	board := new(Board_Frame, context.temp_allocator)
	dragons := make([dynamic]Board_Dragon, context.temp_allocator)
	for dragon, index in ghost.dragons {
		if len(ghost.bodies[index]) == 0 || slice.contains(ghost.controlled[:], index) {continue}
		entry := dragon
		entry.body = ghost.bodies[index][:]
		append(&dragons, entry)
	}
	board.dragons = dragons[:]
	board.pearls = ghost.pearls[:]
	return board
}
ghost_step :: proc(view: ^Game_View, from, direction: i32) -> i32 {
	width, height := view.width, view.height
	x, y := from % width, from / width
	edge: [3]i32 // x, y, side
	switch direction {
	case 0: edge = {x, y, 0}
	case 2: edge = {x, (y + 1) % height, 0}
	case 3: edge = {x, y, 1}
	case: edge = {(x + 1) % width, y, 1}
	}
	for crossed in view.edges {
		if crossed.x != edge[0] || crossed.y != edge[1] || crossed.side != edge[2] {continue}
		if crossed.kelp {return -1}
		for partner in view.edges {
			if partner.kelp || partner.portal != crossed.portal || partner == crossed {continue}
			// The tile beyond the partner edge, keeping the heading.
			if partner.side == 0 {return ((direction == 2 ? partner.y : partner.y - 1 + height) % height) * width + partner.x}
			return partner.y * width + (direction == 1 ? partner.x : (partner.x - 1 + width) % width)
		}
	}
	dx := [4]i32{0, 1, 0, -1}
	dy := [4]i32{-1, 0, 1, 0}
	return ((y + dy[direction] + height) % height) * width + (x + dx[direction] + width) % width
}

end_ghost_turn :: proc(ghost: ^Ghost) {
	for offset in 1 ..= len(ghost.controlled) {
		actor := (ghost.current + offset) % len(ghost.controlled)
		if len(ghost.bodies[ghost.controlled[actor]]) > 0 {begin_ghost_turn(ghost, actor); return}
	}
	ghost.refusal = "no living ghosts"
}

ghost_die :: proc(ghost: ^Ghost, index: int) {
	for cell, segment in ghost.bodies[index] {
		if segment % 2 == 0 && !slice.contains(ghost.pearls[:], cell) {append(&ghost.pearls, cell)}
	}
	clear(&ghost.bodies[index])
}

move_ghost :: proc(ghost: ^Ghost, view: ^Game_View, direction: i32) {
	directions := "NESW"
	ghost.refusal = ""
	index := ghost.controlled[ghost.current]
	body := &ghost.bodies[index]
	if len(body^) == 0 {ghost.refusal = "dead; Space selects the next ghost"; return}
	paid := ghost.steps >= ghost.free_steps
	if paid && len(body^) < 3 {ghost.refusal = "paid step needs length 3"; return}
	head := ghost_step(view, body[0], direction)
	if head < 0 {ghost.refusal = "kelp"; return}
	for other, other_index in ghost.bodies {
		if !slice.contains(other[:], head) {continue}
		if other_index != index && other[0] == head {
			// The engine kills both at their pre-move positions, before any
			// paid tail removal or pearl consumption.
			append(&ghost.turns[len(ghost.turns) - 1].directions, directions[direction])
			ghost.steps += 1
			ghost_die(ghost, other_index)
			ghost_die(ghost, index)
			ghost.refusal = "ram; Space selects the next ghost"
			return
		}
		ghost.refusal = "dragon body (including its unmoved tail)"
		return
	}
	pearl_index := -1
	for cell, pearl in ghost.pearls {if cell == head {pearl_index = pearl; break}}
	// Paid movement costs a segment even when a pearl keeps the normal tail.
	inject_at(body, 0, head)
	if pearl_index >= 0 {ordered_remove(&ghost.pearls, pearl_index)} else {pop(body)}
	if paid {pop(body)}
	ghost.steps += 1
	append(&ghost.turns[len(ghost.turns) - 1].directions, directions[direction])
}

split_ghost :: proc(ghost: ^Ghost, count: int) {
	ghost.refusal = ""
	index := ghost.controlled[ghost.current]
	body := &ghost.bodies[index]
	if ghost.steps > 0 {ghost.refusal = "split replaces movement; press Space first"; return}
	if count < 2 || len(body^) - count < 2 {ghost.refusal = "split needs both parts at least length 2"; return}
	team := ghost.dragons[index].team
	teammates := 0
	for dragon, other in ghost.dragons {if dragon.team == team && len(ghost.bodies[other]) > 0 {teammates += 1}}
	if teammates >= 64 {ghost.refusal = "64 living teammates"; return}
	child := make([dynamic]i32)
	#reverse for cell in body[len(body^) - count:] {append(&child, cell)}
	resize(body, len(body^) - count)
	ghost.turns[len(ghost.turns) - 1].split = count
	append(&ghost.controlled, len(ghost.bodies))
	append(&ghost.bodies, child)
	append(&ghost.dragons, Board_Dragon{team = team})
	begin_ghost_turn(ghost, len(ghost.controlled) - 1)
}

ghost_line :: proc(ghost: ^Ghost) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for turn, index in ghost.turns {
		if index == len(ghost.turns) - 1 && turn.split == 0 && len(turn.directions) == 0 {continue}
		actor := turn.actor == 0 ? "parent" : turn.actor == 1 ? "child" : fmt.tprintf("child%d", turn.actor)
		action := turn.split > 0 ? fmt.tprintf("SPLIT %d", turn.split) : len(turn.directions) > 0 ? string(turn.directions[:]) : "PASS"
		append(&parts, index == 0 && turn.split > 0 ? action : fmt.tprintf("%s %s", actor, action))
	}
	return strings.join(parts[:], " / ", context.temp_allocator)
}

export_ghost :: proc(viewer: ^Viewer_State) {
	ghost := &viewer.ghost
	text := ghost_line(ghost)
	if text == "" {viewer.status = "No ghost actions to save"; return}
	record := Annotation{replay = viewer.comment_context.replay, version = 3,
		frame = ghost.start_round, dragon = ghost.dragon, turn_index = ghost.start_turn,
		substeps = ghost.start_substeps}
	append_annotation(viewer, text, record)
}

handle_ghost_keys :: proc(viewer: ^Viewer_State) {
	ghost := &viewer.ghost
	if !ghost.active || viewer.comment_editing {return}
	if rl.IsKeyPressed(.SPACE) {end_ghost_turn(ghost); return}
	if rl.IsKeyPressed(.G) {export_ghost(viewer); return}
	for key, direction in ([4]rl.KeyboardKey{.W, .D, .S, .A}) {
		if rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key) {move_ghost(ghost, &viewer.game.view, i32(direction)); return}
	}
	for key in rl.KeyboardKey.TWO ..= rl.KeyboardKey.NINE {
		if rl.IsKeyPressed(key) {split_ghost(ghost, int(key) - int(rl.KeyboardKey.ZERO)); return}
	}
}

draw_ghost :: proc(viewer: ^Viewer_State, geometry: Board_Geometry) {
	ghost := &viewer.ghost
	if !ghost.active {return}
	for index, actor in ghost.controlled {
		body := ghost.bodies[index][:]
		color := actor == ghost.current ? GHOST_COLOR : rl.Fade(GHOST_COLOR, 0.5)
		for cell, position in body {
			if position > 0 {draw_cell_link(geometry, body[position - 1], cell, color, geometry.cell_size * 0.3)}
		}
		if len(body) > 0 {rl.DrawCircleLinesV(cell_center(geometry, body[0]), geometry.cell_size * 0.4, color)}
	}
	body := ghost.bodies[ghost.controlled[ghost.current]][:]
	position := len(body) > 0 ? cell_center(geometry, body[0]) : geometry.origin
	actor := ghost.current == 0 ? "parent" : "child"
	text := fmt.ctprintf("ghost %s, length %d, step %d (%d/%d free, %d paid); %s",
		actor, len(body), ghost.steps, min(ghost.steps, ghost.free_steps), ghost.free_steps,
		max(0, ghost.steps - ghost.free_steps), ghost.refusal != "" ? ghost.refusal : "Space ends turn")
	draw_text_with_backdrop(text, position + {geometry.cell_size * 0.5, geometry.cell_size * 0.3}, CELL_TEXT, ghost.refusal != "" ? COLOR_WRONG : GHOST_COLOR)
}
