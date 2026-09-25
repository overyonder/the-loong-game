// A debug viewer for Loong replays: the board through one dragon's eyes.
//   python3 -m replays.export game.replay --output game.json
//   odin build viewer -out:build/loong-viewer && build/loong-viewer game.json
package viewer

import "core:fmt"
import os "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

PANEL_WIDTH :: 420

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: loong-viewer game.json")
		os.exit(1)
	}
	viewer := Viewer{selected = -1, speed = 8, fog = .Fade, memory_frame = -1}
	loaded, ok := load_game(os.args[1])
	if !ok {
		fmt.eprintln("could not load", os.args[1])
		os.exit(1)
	}
	viewer.game = loaded
	defer unload_game(&viewer.game)
	if len(os.args) > 2 {
		// Optional starting round and dragon, handy for screenshots.
		round, _ := strconv.parse_int(os.args[2])
		viewer.frame = f32(round)
	}
	if len(os.args) > 3 {
		dragon, _ := strconv.parse_int(os.args[3])
		viewer.selected = i32(dragon)
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(1500, 900, "Loong viewer")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)
	if path := os.get_env("LOONG_VIEWER_FONT", context.temp_allocator); path != "" {
		font = rl.LoadFontEx(strings.clone_to_cstring(path, context.temp_allocator), 44, nil, 0)
		rl.SetTextureFilter(font.texture, .BILINEAR)
		has_font = font.glyphCount > 0
	}

	for !rl.WindowShouldClose() {
		handle_input(&viewer)
		last := f32(len(viewer.game.frames) - 1)
		if viewer.playing {
			viewer.frame = clamp(viewer.frame + viewer.speed * rl.GetFrameTime(), 0, last)
		}
		refresh_memory(&viewer)

		width, height := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		geometry := draw_board(&viewer, {16, 16, width - PANEL_WIDTH - 32, height - 32})
		draw_panel(&viewer, {width - PANEL_WIDTH, 20, PANEL_WIDTH - 20, height - 40})
		if rl.IsMouseButtonPressed(.LEFT) {
			select_at(&viewer, geometry, rl.GetMousePosition())
		}
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

handle_input :: proc(viewer: ^Viewer) {
	last := f32(len(viewer.game.frames) - 1)
	if rl.IsKeyPressed(.SPACE) do viewer.playing = !viewer.playing
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) do viewer.frame = min(f32(i32(viewer.frame)) + 1, last)
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) do viewer.frame = max(f32(i32(viewer.frame)) - 1, 0)
	if rl.IsKeyPressed(.HOME) do viewer.frame = 0
	if rl.IsKeyPressed(.END) do viewer.frame = last
	if rl.IsKeyPressed(.UP) do viewer.speed *= 2
	if rl.IsKeyPressed(.DOWN) do viewer.speed /= 2
	if rl.IsKeyPressed(.F) do viewer.fog = Fog((int(viewer.fog) + 1) % len(Fog))
	if rl.IsKeyPressed(.ESCAPE) do viewer.selected = -1
	if rl.IsKeyPressed(.TAB) {
		// The next living dragon after the selected one, by ID.
		dragons := viewer.game.frames[i32(viewer.frame)].dragons
		if len(dragons) > 0 {
			next := dragons[0].id
			for dragon in dragons {
				if dragon.id > viewer.selected {
					next = dragon.id
					break
				}
			}
			viewer.selected = next
		}
	}
}

select_at :: proc(viewer: ^Viewer, g: Board_Geometry, point: rl.Vector2) {
	game := &viewer.game
	x, y := i32((point.x - g.x) / g.cell), i32((point.y - g.y) / g.cell)
	if point.x < g.x || point.y < g.y || x >= game.width || y >= game.height do return
	cell := y * game.width + x
	for dragon in game.frames[i32(viewer.frame)].dragons {
		for part in dragon.body {
			if part == cell {
				viewer.selected = dragon.id
				return
			}
		}
	}
}
