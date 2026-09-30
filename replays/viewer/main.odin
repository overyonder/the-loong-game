// The viewer's display. `just viewer` writes the replay's game columns this
// maps, and the recovery (replays/recovery/serve.nim) re-runs the build that
// played each side and streams its decisions in:
//
//   just viewer game.replay --seat A GUID
//
// Everything shown about a rebuilt dragon is the bot's own state, recovered by
// that re-run. A side with no build shows the replay alone.
package viewer

import "core:fmt"
import os "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"
import rl "vendor:raylib"

TOP_BAR_HEIGHT :: 8
// The beliefs, playback and comment panes stacked under the board, with their
// margins.
BOTTOM_BAR_HEIGHT :: BELIEFS_PANE_HEIGHT + PLAYBACK_PANE_HEIGHT + COMMENT_PANE_HEIGHT + 3 * PANEL_PADDING
// The header, the beliefs' boxes and the four knowledge measures under them.
BELIEFS_PANE_HEIGHT :: 150
PLAYBACK_PANE_HEIGHT :: 38
COMMENT_PANE_HEIGHT :: 52
// Every top-level pane has a one-pixel border and this much space inside it.
PANE_INSET :: 6
// The evaluation bar beside the board (evaluation.odin).
EVALUATION_BAR_WIDTH :: 14
SIDE_PANEL_WIDTH :: 360
LEFT_PANEL_WIDTH :: 250
// The evaluation pane, between the left panel and the board (evaluation.odin).
EVALUATION_PANEL_WIDTH :: 170
PANEL_PADDING :: 10

// Where the command line asked the viewer to open: `--dragon N --round R
// --turn T --play --speed S`. Absent values keep the loaded game's defaults.
// `--turn` opens Turns mode at that turn index and overrides `--round`. A
// dragon with a round or turn opens zoomed on its area unless `--whole-board`.
// Playback starts in Turns mode unless `--rounds`.
Startup_Settings :: struct {
	dragon, round:     i32,
	turn:              int,
	playing:           bool,
	whole_board:       bool,
	rounds:            bool,
	frames_per_second: f32,
}

apply_startup_settings :: proc(viewer: ^Viewer_State, startup: Startup_Settings) {
	// `--dragon -1` opens without a focus, as a restart after Defocus does.
	if startup.dragon >= -1 {viewer.selected_dragon = startup.dragon}
	viewer.playback.frame_position = f32(clamp(max(startup.round, 0), 0, i32(frame_count(viewer) - 1)))
	viewer.playback.playing = startup.playing
	viewer.playback.frames_per_second = startup.frames_per_second
	viewer.area_view = startup.dragon >= 0 && (startup.round >= 0 || startup.turn >= 0) && !startup.whole_board
	viewer.playback.substeps = !startup.rounds || startup.turn >= 0
	if viewer.playback.substeps && turn_count(&viewer.game) > 0 {
		viewer.playback.turn_position = f32(
			min(turn_count_before_frame(&viewer.game, current_frame(viewer)), turn_count(&viewer.game) - 1),
		)
		synchronize_active_turn(viewer)
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(
			"usage: viewer GAME.cols [--recover LOONG_RECOVER --replay REPLAY --registry DIR --judge LOONG_JUDGE] [--inbox PATH --replay-name NAME] [--position FILE | --dragon N --round R --turn T --whole-board --rounds] [--play] [--speed S] [--watch] [--image PNG] [--size WxH] [--knowledge FILE]   (run it through `just viewer`)",
		)
		os.exit(2)
	}
	viewer := Viewer_State {
		selected_dragon = -1,
		last_focused = -1,
		playback = {frames_per_second = 4, substeps = true},
		selected_cell = -1,
		overlays = {
			target_lines = true,
			deaths = true,
			edges = true,
			grid = true,
			dragon_ids = true,
			vision_windows = true,
			fog = true,
			pings = true,
			timers = true,
			spawn_gaps = true,
			search = true,
			path = true,
			positions = true,
			// Dims every cell the dragon has no record of, so it starts off.
			mental_map = false,
		},
		scale = 1,
	}
	game_path := os.args[1]
	load_status := load_game_into_viewer(&viewer, game_path)
	defer delete(load_status)
	viewer.status = load_status
	if !viewer.has_game {
		fmt.eprintln(viewer.status)
		os.exit(1)
	}
	watch_export := false
	image_path := ""
	// `--knowledge FILE` writes the team knowledge of every round and exits,
	// with no window (knowledge.odin).
	knowledge_path := ""
	// The window's starting size; `--size 1440x900` also sizes `--image` renders.
	start_width, start_height: i32 = 1600, 960
	startup := Startup_Settings{dragon = -2, round = -1, turn = -1, frames_per_second = 4}
	recover, replay, registry, judge: string
	// A saved position (position.odin), which takes the place of the options
	// that say where to open.
	restored: Viewer_Position
	has_position := false
	// Passed on to the recovery: each team's build.
	passed := make([dynamic]string, context.temp_allocator)
	for argument, index in os.args[2:] {
		value := os.args[index + 3] if index + 3 < len(os.args) else ""
		if argument == "--image" {image_path = value}
		if argument == "--knowledge" {knowledge_path = value}
		if argument == "--recover" {recover = value}
		if argument == "--replay" {replay = value}
		if argument == "--registry" {registry = value}
		if argument == "--judge" {judge = value}
		if argument == "--build" || argument == "--build-team" {append(&passed, argument, value)}
		// --seat SIDE GUID BOT: the build that played a side.
		if argument == "--seat" && index + 5 < len(os.args) {append(&passed, argument, os.args[index + 3], os.args[index + 4], os.args[index + 5])}
		if argument == "--inbox" {viewer.comment_context.inbox_path = value}
		if argument == "--replay-name" {viewer.comment_context.replay = value}
		if argument == "--position" {restored, has_position = read_position(value, viewer.overlays)}
		if number, ok := strconv.parse_int(value); ok {
			if argument == "--dragon" {startup.dragon = i32(number)}
			if argument == "--round" {startup.round = i32(number)}
			if argument == "--turn" {startup.turn = number}
		}
		if speed, ok := strconv.parse_f32(value); ok && argument == "--speed" {startup.frames_per_second = speed}
		startup.playing = startup.playing || argument == "--play"
		startup.whole_board = startup.whole_board || argument == "--whole-board"
		startup.rounds = startup.rounds || argument == "--rounds"
		if argument == "--size" && index + 3 < len(os.args) {
			parts := strings.split(os.args[index + 3], "x", context.temp_allocator)
			if len(parts) == 2 {
				width, width_ok := strconv.parse_int(parts[0])
				height, height_ok := strconv.parse_int(parts[1])
				if width_ok && height_ok {start_width, start_height = i32(width), i32(height)}
			}
		}
		watch_export = watch_export || argument == "--watch"
	}
	if recover != "" && replay != "" && registry != "" && judge != "" {
		command := make([dynamic]string)
		append(&command, recover, "--replay", replay, "--registry", registry, "--judge", judge)
		for argument in passed {append(&command, strings.clone(argument))}
		viewer.recovery.command = command[:]
	}
	// Watching reloads the game when a rerun (`just watch`) rewrites it, and
	// shows the rerun's progress from GAME.cols.status.
	last_game_write, _ := os.modification_time_by_path(game_path)
	status_path := fmt.aprintf("%s.status", game_path)
	defer delete(status_path)
	position_path := fmt.aprintf("%s.position", game_path)
	defer delete(position_path)
	last_position: string
	defer delete(last_position)

	if len(knowledge_path) > 0 {
		if !export_knowledge(&viewer, knowledge_path) {
			fmt.eprintfln("Could not write %s", knowledge_path)
			os.exit(1)
		}
		fmt.eprintfln("wrote %s", knowledge_path)
		return
	}

	if len(image_path) > 0 {rl.SetConfigFlags({.WINDOW_HIDDEN})}
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_HIGHDPI})
	rl.InitWindow(start_width, start_height, "Loong viewer")
	defer rl.CloseWindow()
	// A display window always opens fullscreen.
	if len(image_path) == 0 {rl.ToggleFullscreen()}
	defer if dragon_body_layer.id != 0 {rl.UnloadRenderTexture(dragon_body_layer)}
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)

	initialize_typography()
	defer rl.UnloadFont(viewer_font)

	// Open where `just viewer --dragon N --round R` asked to look, or where a
	// saved position says, with its selections.
	if has_position {position_startup(restored, &startup)}
	apply_startup_settings(&viewer, startup)
	select_dragon_turn(&viewer, viewer.selected_dragon)
	if startup.turn >= 0 && turn_count(&viewer.game) > 0 {
		viewer.playback.turn_position = f32(min(startup.turn, turn_count(&viewer.game) - 1))
		synchronize_active_turn(&viewer)
	}
	if has_position {restore_selections(&viewer, restored)}
	load_annotations(&viewer)
	start_recovery(&viewer)
	defer stop_recovery(&viewer)
	// An image shows the focused dragon's decisions, so it waits for them.
	if len(image_path) > 0 {
		deadline := time.tick_now()
		for (viewer.game.view.recovery_starting || viewer.game.view.pending_dragons[viewer.selected_dragon]) &&
		    viewer.recovery.running &&
		    time.tick_since(deadline) < 120 * time.Second {
			poll_recovery(&viewer)
			time.sleep(10 * time.Millisecond)
		}
	}

	defer delete(viewer.detail_title)
	defer delete(viewer.detail_text)
	last_update := rl.GetTime()
	next_watch_check := last_update
	last_status_write, _ := os.modification_time_by_path(status_path)
	redraw_pending := true
	was_focused := rl.IsWindowFocused()
	for !rl.WindowShouldClose() {
		// GLFW cursor coordinates use window units, while raylib draws in screen
		// units. Its resize callback can incorrectly apply DPI scaling twice on
		// Wayland. Reconcile after event polling, for custom hits and raygui alike.
		window_width, window_height := glfw.GetWindowSize(glfw.GetCurrentContext())
		if window_width > 0 && window_height > 0 {
			rl.SetMouseScale(
				f32(rl.GetScreenWidth()) / f32(window_width),
				f32(rl.GetScreenHeight()) / f32(window_height),
			)
		}
		now := rl.GetTime()
		elapsed := f32(now - last_update)
		last_update = now
		input_changed := viewer_input_changed()
		focused := rl.IsWindowFocused()
		redraw := redraw_pending || input_changed || focused != was_focused || rl.IsWindowResized()
		was_focused = focused
		// Widgets can change state after the board is drawn. Settle that change
		// on the following frame, then leave the front buffer untouched.
		redraw_pending = input_changed
		redraw = poll_recovery(&viewer) || redraw
		if watch_export && now >= next_watch_check {
			next_watch_check = now + 0.1
			status_write, _ := os.modification_time_by_path(status_path)
			if status_write != last_status_write {
				last_status_write = status_write
				redraw = true
			}
			game_write, game_error := os.modification_time_by_path(game_path)
			if game_error == nil && game_write != last_game_write {
				redraw = true
				delete(load_status)
				load_status = load_game_into_viewer(&viewer, game_path)
				viewer.status = load_status
				if viewer.has_game {
					last_game_write = game_write
					// A rerun replaced the replay too; its recovery starts over.
					start_recovery(&viewer)
				}
			}
		}
		prioritise_recovery(&viewer)
		scan_issues(&viewer.game)
		previous_frame := current_frame(&viewer)
		previous_turn := active_turn_index(&viewer)
		was_playing := viewer.playback.playing
		handle_step_keys(&viewer)
		if !viewer.detail_open {
			handle_keyboard_shortcuts(&viewer)
			advance_playback(&viewer, elapsed)
		}
		redraw =
			redraw ||
			previous_frame != current_frame(&viewer) ||
			previous_turn != active_turn_index(&viewer) ||
			was_playing != viewer.playback.playing
		if !redraw {
			// Polling remains bounded and responsive, including watched exports.
			// There are no continuous UI animations to render while idle.
			time.sleep(time.Second / 60)
			rl.PollInputEvents()
			free_all(context.temp_allocator)
			continue
		}

		scale := viewer.scale
		screen_width := f32(rl.GetScreenWidth())
		screen_height := f32(rl.GetScreenHeight())
		top := TOP_BAR_HEIGHT * scale
		bottom := BOTTOM_BAR_HEIGHT * scale
		padding := PANEL_PADDING * scale
		panel := SIDE_PANEL_WIDTH * scale
		side_panel := rl.Rectangle {
			screen_width - panel + padding,
			top + padding,
			panel - 2 * padding,
			screen_height - top - bottom - 2 * padding,
		}
		left_panel := rl.Rectangle {
			padding,
			top + padding,
			LEFT_PANEL_WIDTH * scale - 2 * padding,
			screen_height - top - bottom - 2 * padding,
		}
		evaluation_pane := rl.Rectangle {
			LEFT_PANEL_WIDTH * scale,
			top + padding,
			EVALUATION_PANEL_WIDTH * scale - padding,
			screen_height - top - bottom - 2 * padding,
		}
		left := (EVALUATION_PANEL_WIDTH + LEFT_PANEL_WIDTH) * scale
		board_pane := rl.Rectangle {
			left + padding,
			top + padding,
			screen_width - panel - left - 2 * padding,
			screen_height - top - bottom - 2 * padding,
		}
		inset := PANE_INSET * scale
		inside :: proc(pane: rl.Rectangle, inset: f32) -> rl.Rectangle {
			return {pane.x + inset, pane.y + inset, pane.width - 2 * inset, pane.height - 2 * inset}
		}
		board_area := inside(board_pane, inset)
		// The evaluation bar takes the board pane's left edge.
		evaluation_bar := rl.Rectangle{board_area.x, board_area.y, EVALUATION_BAR_WIDTH * scale, board_area.height}
		board_area.x += (EVALUATION_BAR_WIDTH + PANEL_PADDING) * scale
		board_area.width -= (EVALUATION_BAR_WIDTH + PANEL_PADDING) * scale
		beliefs_pane := rl.Rectangle{padding, screen_height - bottom, screen_width - 2 * padding, BELIEFS_PANE_HEIGHT * scale}
		playback_pane := rl.Rectangle{padding, beliefs_pane.y + beliefs_pane.height + padding, beliefs_pane.width, PLAYBACK_PANE_HEIGHT * scale}
		comment_pane := rl.Rectangle{padding, playback_pane.y + playback_pane.height + padding, beliefs_pane.width, COMMENT_PANE_HEIGHT * scale}

		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		frame := current_frame(&viewer)
		draw_evaluation_bar(&viewer, evaluation_bar)
		geometry := draw_board_frame(&viewer, board_area, frame)
		draw_gizmo_overlays(&viewer, geometry, frame)
		if board_view_clipped(geometry) {rl.EndScissorMode()}
		draw_zoom_button(&viewer, geometry, board_area)
		handle_board_wheel(&viewer, board_area)
		if !viewer.detail_open &&
		   !viewer.brain_open &&
		   rl.IsMouseButtonPressed(.RIGHT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), board_area) {
			select_dragon_at_cell(&viewer, frame, cell_at_point(geometry, rl.GetMousePosition()))
		}
		if !viewer.detail_open &&
		   !viewer.brain_open {handle_board_range_selection(&viewer, geometry, frame)}
		if viewer.detail_open || viewer.brain_open {rl.GuiLock()}
		if !viewer.brain_open {
			draw_evaluation_pane(&viewer, inside(evaluation_pane, inset))
			draw_objective_inspector(&viewer, left_panel, frame)
			draw_dragon_inspector(&viewer, inside(side_panel, inset), frame)
		}
		if !viewer.detail_open {rl.GuiUnlock()}
		draw_beliefs_panel(&viewer, inside(beliefs_pane, inset))
		draw_playback_bar(&viewer, inside(playback_pane, inset))
		draw_annotation_editor(&viewer, inside(comment_pane, inset))
		for pane in ([?]rl.Rectangle{evaluation_pane, left_panel, side_panel, board_pane, beliefs_pane, playback_pane, comment_pane}) {
			rl.DrawRectangleLinesEx(pane, 1, PANE_BORDER)
		}

		// A rerun's progress (`just watch`).
		if watch_export {
			status_data, status_error := os.read_entire_file(status_path, context.temp_allocator)
			if status_error == nil && len(status_data) > 0 {
				rl.DrawRectangleRec({0, 0, screen_width, top}, BACKGROUND)
				draw_text(fmt.ctprintf("%s", string(status_data)), 12, 12, UI_TEXT, WARNING_COLOR)
			}
		}
		rl.GuiUnlock()
		if viewer.detail_open {rl.GuiLock()}
		draw_gizmo_panel(&viewer)
		rl.GuiUnlock()
		draw_diagnostic_detail_dialog(&viewer)
		rl.EndDrawing()
		if len(image_path) > 0 {
			picture := rl.LoadImageFromScreen()
			success := rl.ExportImage(picture, fmt.ctprintf("%s", image_path))
			rl.UnloadImage(picture)
			if !success {fmt.eprintln("Image export failed"); os.exit(1)}
			break
		}
		if !viewer.playback.playing {
			position := encode_position(&viewer)
			if position != "" && position != last_position {
				_ = os.write_entire_file(position_path, transmute([]u8)position)
				delete(last_position)
				last_position = strings.clone(position)
			}
		}
		free_all(context.temp_allocator)
	}
}

// Do not drain key/character queues: the annotation editor owns text input.
viewer_input_changed :: proc() -> bool {
	if rl.GetMouseDelta() != (rl.Vector2{}) || rl.GetMouseWheelMove() != 0 {return true}
	for button in 0 ..< 7 {
		if rl.IsMouseButtonDown(rl.MouseButton(button)) ||
		   rl.IsMouseButtonReleased(rl.MouseButton(button)) {return true}
	}
	for key in 1 ..< 349 {
		if rl.IsKeyPressed(rl.KeyboardKey(key)) ||
		   rl.IsKeyPressedRepeat(rl.KeyboardKey(key)) ||
		   rl.IsKeyReleased(rl.KeyboardKey(key)) {return true}
	}
	return false
}
