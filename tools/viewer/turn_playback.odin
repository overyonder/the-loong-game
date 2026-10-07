package viewer

// Focus and engine time are independent. Selecting a dragon seeks its turn
// within the current round without changing the stepping mode.
select_dragon_turn :: proc(viewer: ^Viewer_State, dragon: i32) {
	frame := current_frame(viewer)
	viewer.selected_dragon = dragon

	for index in turn_count_before_frame(&viewer.game, frame) ..< turn_count_before_frame(&viewer.game, frame + 1) {
		if i32(viewer.game.view.turn_dragon[index]) == dragon {

			viewer.playback.turn_position = f32(index)
			return
		}
	}
}

clear_viewer_selections :: proc(viewer: ^Viewer_State) {
	viewer.selected_cell = -1
	clear(&viewer.highlights)
	viewer.drag_selecting = false
	viewer.drag_start_cell = -1
	viewer.drag_end_cell = -1
	delete(viewer.gizmo_selection)
	viewer.gizmo_selection = ""
	viewer.detail_open = false
}

active_turn_index :: proc(viewer: ^Viewer_State) -> int {
	if !viewer.playback.substeps ||
	   turn_count(&viewer.game) == 0 ||
	   current_frame(viewer) !=
		   i32(viewer.game.view.turn_round[clamp(int(viewer.playback.turn_position), 0, turn_count(&viewer.game) - 1)]) {return -1}
	return clamp(int(viewer.playback.turn_position), 0, turn_count(&viewer.game) - 1)
}

synchronize_active_turn :: proc(viewer: ^Viewer_State) {
	if turn_count(&viewer.game) == 0 {return}
	index := clamp(int(viewer.playback.turn_position), 0, turn_count(&viewer.game) - 1)
	// Focus is independent of the engine timeline.
	viewer.playback.frame_position = f32(viewer.game.view.turn_round[index])
}

step_playback :: proc(viewer: ^Viewer_State, delta: i32) {
	if viewer.playback.substeps {
		if turn_count(&viewer.game) == 0 {return}
		index := active_turn_index(viewer)
		if index < 0 {
			index = turn_count_before_frame(&viewer.game, current_frame(viewer))
			if delta > 0 {index -= 1}
		}
		viewer.playback.turn_position = f32(
			clamp(index + int(delta), 0, turn_count(&viewer.game) - 1),
		)
		synchronize_active_turn(viewer)
		viewer.playback.playing = false
	} else {step_to_frame(viewer, current_frame(viewer) + delta)}
}

// In turn mode, whether the dragon has yet to move this round: its turn is
// the active one or later.
dragon_awaits_turn :: proc(viewer: ^Viewer_State, dragon: i32) -> bool {
	active := active_turn_index(viewer)
	if active < 0 {return false}
	for index in active ..< turn_count_before_frame(&viewer.game, current_frame(viewer) + 1) {
		if i32(viewer.game.view.turn_dragon[index]) == dragon {return true}
	}
	return false
}

// In turn mode, the focused dragon's own turn when the active turn is one of
// its key turns: its own, showing what it saw, or the next, showing the
// result. The next may lie in the following round.
focused_key_turn :: proc(viewer: ^Viewer_State) -> (index: int, found: bool) {
	active := active_turn_index(viewer)
	if active < 0 {return -1, false}
	for offset in 0 ..= 1 {
		index = active - offset
		if index >= 0 && index < turn_count(&viewer.game) && i32(viewer.game.view.turn_dragon[index]) == viewer.selected_dragon {return index, true}
	}
	return -1, false
}

// The focused dragon's decision the panels show: at its key turns its own
// turn, otherwise its turn in the current round.
focused_dragon_turn :: proc(viewer: ^Viewer_State, frame: i32) -> (^Dragon_Turn, bool) {
	if index, found := focused_key_turn(viewer); found {return opened_turn(&viewer.game, index), true}
	return selected_dragon_turn(&viewer.game, viewer.selected_dragon, frame)
}

// Where the board stands against the focused dragon's decision: before its
// turn, at its turn (the board is what it sees as it decides), or after it
// (the board shows the result). Rounds mode is always after.
Decision_Phase :: enum {
	Waiting,
	Deciding,
	Decided,
}

focused_decision_phase :: proc(viewer: ^Viewer_State) -> Decision_Phase {
	if index, found := focused_key_turn(viewer); found {
		return index == active_turn_index(viewer) ? .Deciding : .Decided
	}
	return dragon_awaits_turn(viewer, viewer.selected_dragon) ? .Waiting : .Decided
}

// Step to the focused dragon's next or previous key turn.
step_key_turn :: proc(viewer: ^Viewer_State, delta: int) {
	indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]
	if !found || turn_count(&viewer.game) == 0 {return}
	last := turn_count(&viewer.game) - 1
	current := clamp(int(viewer.playback.turn_position), 0, last)
	target := -1
	for own in indices {
		for offset in 0 ..= 1 {
			key := clamp(own + offset, 0, last)
			if delta > 0 && key > current && (target < 0 || key < target) {target = key}
			if delta < 0 && key < current && key > target {target = key}
		}
	}
	if target < 0 {return}
	viewer.playback.turn_position = f32(target)
	synchronize_active_turn(viewer)
	viewer.playback.playing = false
}
