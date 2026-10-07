package viewer

import "core:fmt"
import rl "vendor:raylib"

MAXIMUM_PLAYBACK_SPEED :: 30 // Frames (rounds) per second, either direction

frame_count :: proc(viewer: ^Viewer_State) -> i32 {
	// One frame per round, each the board after that round's moves.
	return viewer.has_game ? max(1, i32(len(viewer.game.view.round_event))) : 1
}

current_frame :: proc(viewer: ^Viewer_State) -> i32 {
	return clamp(i32(viewer.playback.frame_position), 0, frame_count(viewer) - 1)
}

step_to_frame :: proc(viewer: ^Viewer_State, frame: i32) {
	viewer.playback.frame_position = f32(clamp(frame, 0, frame_count(viewer) - 1))
	viewer.playback.playing = false
	if viewer.selected_dragon >= 0 {select_dragon_turn(viewer, viewer.selected_dragon)}
}

advance_playback :: proc(viewer: ^Viewer_State, seconds: f32) {
	playback := &viewer.playback
	if !playback.playing {
		return
	}
	if playback.substeps {
		last := f32(max(0, turn_count(&viewer.game) - 1))
		playback.turn_position += playback.frames_per_second * seconds
		if playback.turn_position >= last || playback.turn_position <= 0 {
			playback.turn_position = clamp(playback.turn_position, 0, last)
			playback.playing = false
		}
		synchronize_active_turn(viewer)
		return
	}
	last := f32(frame_count(viewer) - 1)
	playback.frame_position += playback.frames_per_second * seconds
	if playback.frame_position >= last || playback.frame_position <= 0 {
		playback.frame_position = clamp(playback.frame_position, 0, last)
		playback.playing = false
	}
}

// Living dragon IDs at the frame, stepping forward or backward from the selection.
cycle_selected_dragon :: proc(viewer: ^Viewer_State, backward: bool) {
	dragons := board_at_selection(viewer, current_frame(viewer)).dragons
	selected_team: i32 = -1
	for dragon in dragons {if dragon.id == viewer.selected_dragon {selected_team = dragon.team}}
	ids := make([dynamic]i32, context.temp_allocator)
	for dragon in dragons {if selected_team < 0 || dragon.team == selected_team {append(&ids, dragon.id)}}
	if len(ids) == 0 {return}
	position := -1
	for id, index in ids {if id == viewer.selected_dragon {position = index}}
	if position < 0 {position = backward ? 0 : len(ids) - 1}
	position = (position + (backward ? len(ids) - 1 : 1)) % len(ids)
	select_dragon_turn(viewer, ids[position])
}

// The arrow keys step the timeline everywhere, even while typing a comment or
// reading a detail dialog, since nothing else uses them. Left and Right step
// between the focused dragon's key turns in Turns mode, and otherwise one turn
// or round, as Up and Down always do.
handle_step_keys :: proc(viewer: ^Viewer_State) {
	if !viewer.has_game {return}
	pressed :: proc(key: rl.KeyboardKey) -> bool {return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)}
	if pressed(.RIGHT) {step_movement(viewer, 1)}
	if pressed(.LEFT) {step_movement(viewer, -1)}
	if pressed(.DOWN) {step_playback(viewer, 1)}
	if pressed(.UP) {step_playback(viewer, -1)}
}

// One step in the current movement mode: between the focused dragon's key
// turns in Turns mode, otherwise one turn or round.
step_movement :: proc(viewer: ^Viewer_State, delta: i32) {
	if viewer.playback.substeps && viewer.selected_dragon >= 0 {step_key_turn(viewer, int(delta))} else {step_playback(viewer, delta)}
}

// The scroll wheel over the board steps as Left and Right do, scrolling down
// going forward. A notch arrives as 1.5 under Wayland and a touchpad scrolls in
// fractions, so each unit of scroll takes one step and the rest is dropped.
handle_board_wheel :: proc(viewer: ^Viewer_State, board_area: rl.Rectangle) {
	if viewer.detail_open || viewer.brain_open || !rl.CheckCollisionPointRec(rl.GetMousePosition(), board_area) {return}
	viewer.wheel_steps -= rl.GetMouseWheelMove()
	if abs(viewer.wheel_steps) >= 1 {
		step_movement(viewer, viewer.wheel_steps > 0 ? 1 : -1)
		viewer.wheel_steps = 0
	}
}

// Every key and gesture the viewer takes, as the Hotkeys button lists them.
HOTKEYS :: `Timeline
Left, Right: the focused dragon's previous or next key turn in Turns mode, else one turn or round
Up, Down: one turn or round back or forward
Scroll over the board: as Left and Right
Space: play or pause
Home, End: the first or last round
T: switch between Turns and Rounds

Dragons and view
Tab, Shift+Tab: focus the next or previous dragon
Right-click a dragon: focus it; right-click an empty cell: clear the selection
F: zoom onto the focused dragon's area, or back to the whole board
M: show or hide the Mental map overlay, the focused dragon's view graded against the truth
R: show or hide the Mirror overlay, each dragon's image under the map's symmetry
B: open or close the Brain
Esc: close the Brain or a dialog, else clear the selection and defocus the dragon

Selecting on the board
Click: select a cell or edge; Shift+click: a dragon
Drag: paint cells, erasing when the first was selected
Shift+drag: a rectangle of cells; Ctrl+drag: a line of cells

Manual mode (the Ghost button, with a dragon focused)
W, A, S, D: move the ghost north, west, south or east
2 to 9: split off rear segments and control the child first
Space: end this ghost's turn, then control the next living ghost
G: append the ghost line to the inbox as a saved comment

Comment box
Enter: save the comment; Ctrl+A: clear it; Ctrl+V: paste`

// Turns mode steps through each dragon's turn, Rounds mode whole rounds; the
// Turns button and T both switch.
toggle_turns :: proc(viewer: ^Viewer_State) {
	playback := &viewer.playback
	playback.substeps = !playback.substeps
	playback.playing = false
	if playback.substeps {
		playback.turn_position = f32(
			min(
				turn_count_before_frame(&viewer.game, current_frame(viewer)),
				max(0, turn_count(&viewer.game) - 1),
			),
		)
		synchronize_active_turn(viewer)
	}
}

handle_keyboard_shortcuts :: proc(viewer: ^Viewer_State) {
	if !viewer.has_game || viewer.comment_editing {
		return
	}
	if rl.IsKeyPressed(.B) {viewer.brain_open = !viewer.brain_open}
	if rl.IsKeyPressed(.T) {toggle_turns(viewer)}
	if rl.IsKeyPressed(.F) && viewer.selected_dragon >= 0 {viewer.area_view = !viewer.area_view}
	if rl.IsKeyPressed(.M) {viewer.overlays.mental_map = !viewer.overlays.mental_map}
	if rl.IsKeyPressed(.R) {viewer.overlays.mirror = !viewer.overlays.mirror}
	playback := &viewer.playback
	if rl.IsKeyPressed(.SPACE) && !viewer.ghost.active {
		playback.playing = !playback.playing
	}
	if rl.IsKeyPressed(.HOME) {
		step_to_frame(viewer, 0)
	}
	if rl.IsKeyPressed(.END) {
		step_to_frame(viewer, frame_count(viewer) - 1)
	}
	if rl.IsKeyPressed(.TAB) {
		cycle_selected_dragon(viewer, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
	}
	if rl.IsKeyPressed(.ESCAPE) {
		if viewer.brain_open {viewer.brain_open = false} else {
			clear_viewer_selections(viewer)
			// As the Defocus button, remembering the dragon to return to.
			if viewer.selected_dragon >= 0 {
				viewer.last_focused = viewer.selected_dragon
				viewer.selected_dragon = -1
			}
		}
	}
}

// Bot/map dropdowns, run button and status. Dropdowns draw last so they overlay.

// One row, laid out from its measured labels: transport, mode and speed on the
// left, the timeline filling the middle, position and focus actions on the right.
draw_playback_bar :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	playback := &viewer.playback
	h := f32(CONTROL_HEIGHT)
	y := area.y + (area.height - h) / 2
	text_y := i32(y + (h - UI_TEXT) / 2)
	x := area.x
	button :: proc(x: ^f32, y, h: f32, label: cstring) -> bool {
		width := f32(measure_text(label, UI_TEXT)) + BUTTON_PADDING
		pressed := rl.GuiButton({x^, y, width, h}, label)
		x^ += width + 4
		return pressed
	}
	if !viewer.has_game {rl.GuiLock()}
	if button(&x, y, h, "|<") {step_to_frame(viewer, 0)}
	if button(&x, y, h, "<") {step_playback(viewer, -1)}
	if button(&x, y, h, playback.playing ? "Pause" : "Play") {playback.playing = !playback.playing}
	if button(&x, y, h, ">") {step_playback(viewer, 1)}
	if button(&x, y, h, ">|") {step_to_frame(viewer, frame_count(viewer) - 1)}
	x += 6
	if button(&x, y, h, playback.substeps ? "Turns" : "Rounds") {toggle_turns(viewer)}
	x += 6
	// Manual mode: a ghost of the focused dragon (ghost.odin).
	if button(&x, y, h, viewer.ghost.active ? "End ghost" : "Ghost") {toggle_ghost(viewer)}
	x += 6
	rl.GuiSliderBar(
		{x, y + 4, 72, h - 8},
		"",
		"",
		&playback.frames_per_second,
		-MAXIMUM_PLAYBACK_SPEED,
		MAXIMUM_PLAYBACK_SPEED,
	)
	x += 78
	speed := fmt.ctprintf(
		"%+.0f %s/s",
		playback.frames_per_second,
		playback.substeps ? "turns" : "rounds",
	)
	draw_text(speed, i32(x), text_y, UI_TEXT, MUTED_TEXT_COLOR)
	x += f32(measure_text("+30 rounds/s", UI_TEXT)) + 14

	// Right-hand group, measured from the edge inwards.
	right := area.x + area.width
	// Toggles between the focused dragon and the team view, remembering the
	// dragon to return to. Right-clicking a dragon focuses it.
	focus_label: cstring = "Defocus"
	if viewer.selected_dragon < 0 {focus_label = viewer.last_focused >= 0 ? fmt.ctprintf("Focus D%d", viewer.last_focused) : "Focus"}
	focus_width := f32(measure_text("Focus D000", UI_TEXT)) + BUTTON_PADDING
	right -= focus_width
	if rl.GuiButton({right, y, focus_width, h}, focus_label) {
		if viewer.selected_dragon >= 0 {
			viewer.last_focused = viewer.selected_dragon
			viewer.selected_dragon = -1
		} else if viewer.last_focused >= 0 {select_dragon_turn(viewer, viewer.last_focused)}
	}
	focus := viewer.selected_dragon >= 0 ? fmt.ctprintf("Focus D%d", viewer.selected_dragon) : "No focus"
	right -= f32(measure_text(focus, UI_TEXT)) + 14
	draw_text(focus, i32(right), text_y, UI_TEXT, UI_ACCENT)
	label :=
		playback.substeps ? fmt.ctprintf("R%d / turn %d", current_frame(viewer), active_turn_index(viewer) + 1) : fmt.ctprintf("Round %d / %d", current_frame(viewer), frame_count(viewer) - 1)
	right -= f32(measure_text(label, UI_TEXT)) + 14
	draw_text(label, i32(right), text_y, UI_TEXT, TEXT_COLOR)

	timeline := playback.substeps ? playback.turn_position : playback.frame_position
	last :=
		playback.substeps ? max(0, turn_count(&viewer.game) - 1) : int(frame_count(viewer) - 1)
	if rl.GuiSliderBar(
		   {x, y + 4, max(40, right - x - 14), h - 8},
		   "",
		   "",
		   &timeline,
		   0,
		   f32(max(last, 1)),
	   ) !=
	   0 {
		if playback.substeps {playback.turn_position = f32(int(timeline)); synchronize_active_turn(viewer); playback.playing = false} else {step_to_frame(viewer, i32(timeline))}
	}
	rl.GuiUnlock()
}

// Fog and overlay toggles; returns the y coordinate below them.
draw_overlay_controls :: proc(viewer: ^Viewer_State, area: rl.Rectangle) -> f32 {
	y := area.y
	overlays := &viewer.overlays
	checkboxes := [?]struct {
		label: cstring,
		value: ^bool,
	} {
		{"Targets", &overlays.target_lines},
		{"Vision", &overlays.vision_windows},
		{"Fog", &overlays.fog},
		{"Deaths", &overlays.deaths},
		{"IDs", &overlays.dragon_ids},
		{"Grid", &overlays.grid},
		{"Edges", &overlays.edges},
		{"Sonar", &overlays.pings},
		{"Timers", &overlays.timers},
		{"Spawn gaps", &overlays.spawn_gaps},
		{"Search", &overlays.search},
		{"Path", &overlays.path},
		{"Mental map", &overlays.mental_map},
		{"Positions", &overlays.positions},
		{"Mirror", &overlays.mirror},
		{"Colours", &overlays.colors},
		{"Icons", &overlays.icons},
		{"Patterns", &overlays.patterns},
	}
	index := 0
	for checkbox in checkboxes {
		column := f32(index % 2) * (area.width / 2)
		rl.GuiCheckBox(
			{area.x + column, y + f32(index / 2) * 22 + 2, 14, 14},
			checkbox.label,
			checkbox.value,
		)
		index += 1
	}
	return y + f32((index + 1) / 2) * 22 + 8
}

// The zoom toggle beside the board's top-right corner, as F does: outward
// arrows zoom onto the focused dragon's area, inward arrows show the whole
// board. It sits above the board, or right of it when the board fills the
// height.
draw_zoom_button :: proc(viewer: ^Viewer_State, geometry: Board_Geometry, area: rl.Rectangle) {
	if viewer.selected_dragon < 0 {return}
	size: f32 = 30
	right := geometry.origin.x + geometry.cell_size * f32(geometry.columns)
	button := rl.Rectangle{right - size, geometry.origin.y - size - 6, size, size}
	if button.y < area.y {button = {right + 6, geometry.origin.y, size, size}}
	if button.x + size > area.x + area.width {button.x = right - size; button.y = geometry.origin.y + 4}
	hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), button) && !viewer.detail_open && !viewer.brain_open
	color := hovered ? UI_ACCENT : rl.Fade(UI_ACCENT, 0.7)
	rl.DrawRectangleRounded(button, 0.25, 6, rl.Fade(BACKGROUND, 0.85))
	rl.DrawRectangleRoundedLinesEx(button, 0.25, 6, 2, color)
	centre := rl.Vector2{button.x + size / 2, button.y + size / 2}
	reach, head := size * 0.3, size * 0.14
	for corner in ([4]rl.Vector2{{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) {
		outer := centre + corner * reach
		rl.DrawLineEx(centre + corner * 2, outer, 2, color)
		// The arrowhead points out to the corner to zoom in, and back to the
		// centre to show the whole board.
		tip := viewer.area_view ? centre + corner * 3 : outer
		back := viewer.area_view ? rl.Vector2{1, 1} : rl.Vector2{-1, -1}
		rl.DrawLineEx(tip, tip + {corner.x * back.x * head, 0}, 2, color)
		rl.DrawLineEx(tip, tip + {0, corner.y * back.y * head}, 2, color)
	}
	if hovered && rl.IsMouseButtonPressed(.LEFT) {viewer.area_view = !viewer.area_view}
}

// A round chart in the sidebar scrubs like the timeline: a press seeks to the
// round under the pointer, and dragging keeps seeking until release, even
// beyond the chart's ends.
Scrub_Chart :: enum {
	None,
	Breakdown,
	Judge_Points,
	Evaluation,
}

scrub_chart :: proc(viewer: ^Viewer_State, which: Scrub_Chart, chart: rl.Rectangle, span, rounds: f32) {
	mouse := rl.GetMousePosition()
	frame := i32((mouse.x - chart.x) / max(span, 1) * rounds + 0.5)
	if !viewer.detail_open && rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(mouse, chart) {
		viewer.scrubbing = which
		step_to_frame(viewer, frame)
		return
	}
	if viewer.scrubbing != which {return}
	if !rl.IsMouseButtonDown(.LEFT) {viewer.scrubbing = .None; return}
	if clamp(frame, 0, frame_count(viewer) - 1) != current_frame(viewer) {step_to_frame(viewer, frame)}
}

// The team the whole viewer treats as ours: the breakdown chart and the board's
// looks, the enemy's initial-dragon colour and the beliefs strip follow it. The Us
// button sets it. Until then it is the one team the recovery can rebuild, else
// the focused dragon's, else team A, settled once the recovery has said which
// teams it can rebuild, so focusing another dragon later never moves it.
our_team :: proc(viewer: ^Viewer_State) -> int {
	if viewer.our_team >= 0 {return int(viewer.our_team) & 1}
	view := &viewer.game.view
	team := 0
	if view.recoverable_teams[0] != view.recoverable_teams[1] {
		team = view.recoverable_teams[1] ? 1 : 0
	} else if indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]; found && len(indices) > 0 {
		team = int(view.turn_team[indices[0]]) & 1
	}
	if !view.recovery_starting {viewer.our_team = i32(team)}
	return team
}

// The Us button: which team is ours, by its side and bot, and a click swaps it.
draw_us_button :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	view := &viewer.game.view
	team := our_team(viewer)
	label := fmt.ctprintf("Us: %c, %s", 'A' + team, bot_name(team == 0 ? view.bot_a : view.bot_b))
	if rl.GuiButton(area, label) {viewer.our_team = i32(1 - team)}
}
