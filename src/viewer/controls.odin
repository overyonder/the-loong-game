package viewer

import "core:fmt"
import rl "vendor:raylib"

MAXIMUM_PLAYBACK_SPEED :: 30 // Frames (rounds) per second, either direction

frame_count :: proc(viewer: ^Viewer_State) -> i32 {
	return viewer.has_game ? i32(len(viewer.game.export.frames)) : 1
}

current_frame :: proc(viewer: ^Viewer_State) -> i32 {
	return clamp(i32(viewer.playback.frame_position), 0, frame_count(viewer) - 1)
}

step_to_frame :: proc(viewer: ^Viewer_State, frame: i32) {
	viewer.playback.frame_position = f32(clamp(frame, 0, frame_count(viewer) - 1))
	viewer.playback.playing = false
}

advance_playback :: proc(viewer: ^Viewer_State, seconds: f32) {
	playback := &viewer.playback
	if !playback.playing {
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
	dragons := viewer.game.export.frames[current_frame(viewer)].dragons
	if len(dragons) == 0 {
		return
	}
	position := -1
	for dragon, index in dragons {
		if dragon.id == viewer.selected_dragon {
			position = index
		}
	}
	if position < 0 {
		position = backward ? 0 : len(dragons) - 1
	}
	position = (position + (backward ? len(dragons) - 1 : 1)) % len(dragons)
	viewer.selected_dragon = dragons[position].id
}

handle_keyboard_shortcuts :: proc(viewer: ^Viewer_State) {
	if !viewer.has_game || viewer.comment_editing {
		return
	}
	playback := &viewer.playback
	if rl.IsKeyPressed(.SPACE) {
		playback.playing = !playback.playing
	}
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
		step_to_frame(viewer, current_frame(viewer) + 1)
	}
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
		step_to_frame(viewer, current_frame(viewer) - 1)
	}
	if rl.IsKeyPressed(.HOME) {
		step_to_frame(viewer, 0)
	}
	if rl.IsKeyPressed(.END) {
		step_to_frame(viewer, frame_count(viewer) - 1)
	}
	if rl.IsKeyPressed(.UP) {
		playback.frames_per_second = min(playback.frames_per_second + 2, MAXIMUM_PLAYBACK_SPEED)
	}
	if rl.IsKeyPressed(.DOWN) {
		playback.frames_per_second = max(playback.frames_per_second - 2, -MAXIMUM_PLAYBACK_SPEED)
	}
	if rl.IsKeyPressed(.TAB) {
		cycle_selected_dragon(viewer, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
	}
	if rl.IsKeyPressed(.ESCAPE) {
		viewer.selected_dragon = -1
	}
}

// Bot/map dropdowns, run button and status. Dropdowns draw last so they overlay.

draw_playback_bar :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	playback := &viewer.playback
	frame := current_frame(viewer)
	last := frame_count(viewer) - 1
	x := area.x + 8
	y := area.y + 8
	if !viewer.has_game {
		rl.GuiLock()
	}
	if rl.GuiButton({x, y, 40, 28}, "|<") {step_to_frame(viewer, 0)}
	if rl.GuiButton({x + 44, y, 40, 28}, "<") {step_to_frame(viewer, frame - 1)}
	if rl.GuiButton(
		{x + 88, y, 80, 28},
		playback.playing ? "Pause" : "Play",
	) {playback.playing = !playback.playing}
	if rl.GuiButton({x + 172, y, 40, 28}, ">") {step_to_frame(viewer, frame + 1)}
	if rl.GuiButton({x + 216, y, 40, 28}, ">|") {step_to_frame(viewer, last)}
	rl.GuiSliderBar(
		{x + 330, y + 4, 220, 20},
		"Speed",
		fmt.ctprintf("%+.0f rounds/s", playback.frames_per_second),
		&playback.frames_per_second,
		-MAXIMUM_PLAYBACK_SPEED,
		MAXIMUM_PLAYBACK_SPEED,
	)
	if rl.GuiButton({x + 680, y, 70, 28}, "1x") {playback.frames_per_second = 1}
	if rl.GuiButton({x + 754, y, 70, 28}, "-1x") {playback.frames_per_second = -1}

	timeline := playback.frame_position
	timeline_label := fmt.ctprintf("round %d / %d", frame, last)
	if frame == last {
		timeline_label = fmt.ctprintf("frame %d / %d (final)", frame, last)
	}
	if rl.GuiSliderBar(
		   {x + 60, y + 38, area.width - 330, 20},
		   "Round",
		   timeline_label,
		   &timeline,
		   0,
		   f32(max(last, 1)),
	   ) !=
	   0 {
		step_to_frame(viewer, i32(timeline))
	}
	rl.GuiUnlock()
}

// Fog and overlay toggles; returns the y coordinate below them.
draw_overlay_controls :: proc(viewer: ^Viewer_State, area: rl.Rectangle) -> f32 {
	y := area.y
	if rl.GuiButton({area.x, y, 80, 26}, "Text -") {font_scale = max(0.9, font_scale - 0.1)}
	if rl.GuiButton({area.x + 86, y, 80, 26}, "Text +") {font_scale = min(1.6, font_scale + 0.1)}
	y += 34
	overlays := &viewer.overlays
	checkboxes := [?]struct {
		label: cstring,
		value: ^bool,
	} {
		{"Strategy labels", &overlays.strategy_labels},
		{"Target lines", &overlays.target_lines},
		{"Vision windows", &overlays.vision_windows},
		{"Deaths", &overlays.deaths},
		{"Dragon IDs", &overlays.dragon_ids},
		{"Grid", &overlays.grid},
		{"Kelp and portals", &overlays.edges},
		{"Ping hitscans", &overlays.pings},
		{"Pearl timers", &overlays.timers},
		{"Search flood", &overlays.search},
		{"Planned path", &overlays.path},
		{"Coverage", &overlays.coverage},
	}
	for checkbox, index in checkboxes {
		column := f32(index % 2) * (area.width / 2)
		rl.GuiCheckBox(
			{area.x + column, y + f32(index / 2) * 28, 16, 16},
			checkbox.label,
			checkbox.value,
		)
	}
	return y + f32((len(checkboxes) + 1) / 2) * 28 + 8
}
