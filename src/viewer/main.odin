// The viewer's display. src/viewer/recovery.py chooses the game, identifies the
// build that played it, re-runs that build and writes the export this opens:
//
//   just viewer latest-loss
//   just viewer 250734
//
// Everything shown about our own dragons is the bot's own state, recovered by
// that re-run. Where the build could not be identified the export says so and
// the inspector shows observations instead, labelled as observations.
package viewer

import "core:fmt"
import os "core:os"
import rl "vendor:raylib"

TOP_BAR_HEIGHT :: 44
BOTTOM_BAR_HEIGHT :: 176
SIDE_PANEL_WIDTH :: 520
PANEL_PADDING :: 12

apply_export_startup_settings :: proc(viewer: ^Viewer_State) {
	viewer.selected_dragon = viewer.game.export.selected_dragon
	viewer.playback.frame_position = f32(
		clamp(viewer.game.export.start_frame, 0, i32(frame_count(viewer) - 1)),
	)
	if viewer.game.export.version == 4 {
		viewer.playback.playing = viewer.game.export.start_playing
		viewer.playback.frames_per_second = viewer.game.export.start_frames_per_second
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: viewer <export.json>   (run it through `just viewer`)")
		os.exit(2)
	}
	viewer := Viewer_State {
		selected_dragon = -1,
		playback = {frames_per_second = 4},
		selected_cell = -1,
		overlays = {
			strategy_labels = true,
			target_lines = true,
			deaths = true,
			edges = true,
			grid = true,
			dragon_ids = true,
			vision_windows = true,
			pings = true,
			timers = true,
			search = true,
			path = true,
			coverage = true,
		},
		scale = 1,
	}
	viewer.status = load_debug_view_export_into_viewer(&viewer, os.args[1])
	if !viewer.has_game {
		fmt.eprintln(viewer.status)
		os.exit(1)
	}
	watch_export := false
	image_path := ""
	for argument, index in os.args[2:] {
		if argument == "--image" && index + 3 < len(os.args) {image_path = os.args[index + 3]}
		watch_export = watch_export || argument == "--watch"
	}
	last_export_write, _ := os.modification_time_by_path(os.args[1])

	if len(image_path) > 0 {rl.SetConfigFlags({.WINDOW_HIDDEN})}
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_HIGHDPI})
	rl.InitWindow(1600, 960, "Loong viewer")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(30)

	initialize_typography()
	defer rl.UnloadFont(viewer_font)

	// Open where `just viewer --dragon N --round R` asked to look.
	apply_export_startup_settings(&viewer)
	load_annotations(&viewer)

	for !rl.WindowShouldClose() {
		if watch_export {
			updated, err := os.modification_time_by_path(os.args[1])
			if err == nil && updated != last_export_write {
				viewer.status = load_debug_view_export_into_viewer(&viewer, os.args[1])
				if viewer.has_game {
					apply_export_startup_settings(&viewer)
					last_export_write = updated
				}
			}
		}
		handle_keyboard_shortcuts(&viewer)
		advance_playback(&viewer, rl.GetFrameTime())

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
		board_area := rl.Rectangle {
			padding,
			top + padding,
			screen_width - panel - padding,
			screen_height - top - bottom - 2 * padding,
		}

		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		frame := current_frame(&viewer)
		geometry := draw_board_frame(&viewer, board_area, frame)
		if rl.IsMouseButtonPressed(.RIGHT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), board_area) {
			select_dragon_at_cell(&viewer, frame, cell_at_point(geometry, rl.GetMousePosition()))
		}
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(
			   rl.GetMousePosition(),
			   board_area,
		   ) {highlight_board_item(&viewer, geometry, frame)}
		inspector_top := draw_overlay_controls(&viewer, side_panel)
		draw_dragon_inspector(
			&viewer,
			{
				side_panel.x,
				inspector_top,
				side_panel.width,
				side_panel.y + side_panel.height - inspector_top,
			},
			frame,
		)
		draw_playback_bar(&viewer, {0, screen_height - bottom, screen_width, 76})
		draw_annotation_editor(&viewer, {12, screen_height - bottom + 80, screen_width - 24, 92})
		build := &viewer.game.export.build
		draw_provenance_bar(&viewer, build, {0, 0, screen_width, top})
		rl.EndDrawing()
		if len(image_path) > 0 {
			picture := rl.LoadImageFromScreen()
			success := rl.ExportImage(picture, fmt.ctprintf("%s", image_path))
			rl.UnloadImage(picture)
			if !success {fmt.eprintln("Image export failed"); os.exit(1)}
			break
		}
		free_all(context.temp_allocator)
	}
}

// Which build produced the state on screen, and how faithfully it re-ran.
// A viewer that shows a bot's memory has to say where that memory came from.
draw_provenance_bar :: proc(viewer: ^Viewer_State, build: ^Export_Build, area: rl.Rectangle) {
	export := &viewer.game.export
	size := i32(16 * viewer.scale)
	x := i32(area.x + 12 * viewer.scale)
	y := i32(area.y + (area.height - f32(size)) / 2)
	if export.recorded_traces {
		draw_text(
			"Recorded bot state traces from replay; build identity shown only when identified",
			x,
			y,
			size,
			TEXT_COLOR,
		)
	} else if build.identified {
		draw_text(
			fmt.ctprintf(
				"%s  |  team %s  |  build %s (%s)  |  %.2f%% of re-run actions differ",
				export.map_name,
				export.team,
				build.bot,
				build.how,
				build.mismatch_rate * 100,
			),
			x,
			y,
			size,
			TEXT_COLOR,
		)
	} else {
		draw_text(
			fmt.ctprintf(
				"%s  |  build not identified: observations only, not memory",
				export.map_name,
			),
			x,
			y,
			size,
			WARNING_COLOR,
		)
	}
}
