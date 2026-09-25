package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

BACKGROUND :: rl.Color{29, 32, 33, 255}   // gruvbox dark hard
BOARD      :: rl.Color{29, 48, 39, 255}
GRID       :: rl.Color{243, 236, 223, 18}
KELP       :: rl.Color{127, 176, 105, 255}
PORTAL     :: rl.Color{232, 200, 114, 255}
PEARL      :: rl.Color{232, 200, 114, 255}
TEAM_A     :: rl.Color{255, 122, 61, 255}
TEAM_B     :: rl.Color{243, 236, 223, 255}
TEXT       :: rl.Color{235, 219, 178, 255}
MUTED      :: rl.Color{146, 131, 116, 255}

Board_Geometry :: struct {
	x, y, cell: f32,
}

board_geometry :: proc(game: ^Game, area: rl.Rectangle) -> Board_Geometry {
	cell := min(area.width / f32(game.width), area.height / f32(game.height))
	return {area.x + (area.width - cell * f32(game.width)) / 2, area.y + (area.height - cell * f32(game.height)) / 2, cell}
}

cell_centre :: proc(game: ^Game, geometry: Board_Geometry, cell: i32) -> rl.Vector2 {
	return {geometry.x + (f32(cell % game.width) + 0.5) * geometry.cell, geometry.y + (f32(cell / game.width) + 0.5) * geometry.cell}
}

draw_board :: proc(viewer: ^Viewer, area: rl.Rectangle) -> Board_Geometry {
	game := &viewer.game
	g := board_geometry(game, area)
	frame := game.frames[i32(viewer.frame)]
	rl.DrawRectangleRec({g.x, g.y, g.cell * f32(game.width), g.cell * f32(game.height)}, BOARD)
	for x in 1 ..< game.width {
		rl.DrawLineV({g.x + f32(x) * g.cell, g.y}, {g.x + f32(x) * g.cell, g.y + f32(game.height) * g.cell}, GRID)
	}
	for y in 1 ..< game.height {
		rl.DrawLineV({g.x, g.y + f32(y) * g.cell}, {g.x + f32(game.width) * g.cell, g.y + f32(y) * g.cell}, GRID)
	}
	for edge in game.edges {
		from := rl.Vector2{g.x + f32(edge.x) * g.cell, g.y + f32(edge.y) * g.cell}
		to := edge.side == 0 ? from + {g.cell, 0} : from + {0, g.cell}
		rl.DrawLineEx(from, to, max(2, g.cell * 0.14), edge.kelp ? KELP : PORTAL)
	}
	for pearl in frame.pearls {
		rl.DrawCircleV(cell_centre(game, g, pearl), g.cell * 0.18, PEARL)
	}
	for dragon in frame.dragons {
		colour := dragon.team == 0 ? TEAM_A : TEAM_B
		for index in 1 ..< len(dragon.body) {
			a, b := dragon.body[index - 1], dragon.body[index]
			// Neighbouring segments are joined, unless the body wraps round the board or went through a portal.
			if abs(a % game.width - b % game.width) + abs(a / game.width - b / game.width) == 1 {
				rl.DrawLineEx(cell_centre(game, g, a), cell_centre(game, g, b), g.cell * 0.5, colour)
			}
			rl.DrawCircleV(cell_centre(game, g, b), g.cell * 0.25, colour)
		}
		rl.DrawCircleV(cell_centre(game, g, dragon.body[0]), g.cell * 0.36, colour)
		if dragon.id == viewer.selected {
			rl.DrawCircleLinesV(cell_centre(game, g, dragon.body[0]), g.cell * 0.62, TEXT)
		}
	}
	for death in frame.deaths {
		centre := cell_centre(game, g, death.cell)
		size := g.cell * 0.3
		rl.DrawLineEx(centre - size, centre + size, 3, rl.RED)
		rl.DrawLineEx(centre + {-size, size}, centre + {size, -size}, 3, rl.RED)
	}
	draw_fog(viewer, g)
	return g
}

// Darken what the selected dragon can't see. Fade keeps remembered cells faintly
// visible; Hide shows only its current window.
draw_fog :: proc(viewer: ^Viewer, g: Board_Geometry) {
	if viewer.fog == .Show || viewer.selected < 0 || viewer.memory == nil do return
	game := &viewer.game
	for cell in 0 ..< game.width * game.height {
		alpha: u8
		switch {
		case viewer.visible[cell]:                                      alpha = 0
		case viewer.fog == .Fade && viewer.memory[cell] != .Unknown:     alpha = 150
		case:                                                            alpha = 235
		}
		if alpha > 0 {
			rl.DrawRectangleRec({g.x + f32(cell % game.width) * g.cell, g.y + f32(cell / game.width) * g.cell, g.cell, g.cell}, {12, 18, 15, alpha})
		}
	}
}

// A small map of cells, coloured by content: the dragon's memory, or how it differs from the board.
draw_minimap :: proc(viewer: ^Viewer, area: rl.Rectangle, compare: bool) {
	game := &viewer.game
	cell := min(area.width / f32(game.width), area.height / f32(game.height))
	for index in 0 ..< game.width * game.height {
		remembered, actual := viewer.memory[index], viewer.actual[index]
		colour := BOARD
		if compare {
			switch {
			case remembered == .Unknown:  colour = {12, 18, 15, 255}
			case remembered == actual:    colour = BOARD
			case remembered == .Pearl:    colour = {120, 100, 40, 255}  // remembers a pearl that's gone
			case actual == .Pearl:        colour = PEARL                // missed a pearl
			case:                         colour = rl.RED               // a dragon has moved in or out
			}
		} else {
			switch remembered {
			case .Unknown:         colour = {12, 18, 15, 255}
			case .Empty:           colour = BOARD
			case .Pearl:           colour = PEARL
			case .A_Body, .A_Head: colour = TEAM_A
			case .B_Body, .B_Head: colour = TEAM_B
			}
		}
		rl.DrawRectangleRec({area.x + f32(index % game.width) * cell, area.y + f32(index / game.width) * cell, cell, cell}, colour)
	}
}

// Set by main from LOONG_VIEWER_FONT; raylib's built-in pixel font is the fallback.
font: rl.Font
has_font: bool

text :: proc(value: string, x, y: f32, size: f32 = 20, colour := TEXT) {
	value := strings.clone_to_cstring(value, context.temp_allocator)
	if has_font {
		rl.DrawTextEx(font, value, {x, y}, size, 0, colour)
	} else {
		rl.DrawText(value, i32(x), i32(y), i32(size), colour)
	}
}

draw_panel :: proc(viewer: ^Viewer, area: rl.Rectangle) {
	game := &viewer.game
	x, y := area.x, area.y
	frame := i32(viewer.frame)
	winner := game.winner == "draw" ? "a draw" : fmt.tprintf("team %s wins", game.winner)
	text(fmt.tprintf("%s vs %s", game.bot_a, game.bot_b), x, y, 22); y += 30
	text(fmt.tprintf("%dx%d map, %s after %d rounds", game.width, game.height, winner, len(game.frames) - 1), x, y, 18, MUTED); y += 40
	text(fmt.tprintf("Round %d%s", frame, viewer.playing ? fmt.tprintf("   playing at %.0f/s", viewer.speed) : ""), x, y, 22); y += 30
	text(fmt.tprintf("Fog: %v", viewer.fog), x, y, 18, MUTED); y += 40

	if viewer.selected < 0 {
		text("Click a dragon, or press Tab,", x, y, 18, MUTED); y += 24
		text("to see the board through its eyes.", x, y, 18, MUTED); y += 40
	} else {
		text(fmt.tprintf("Dragon %d", viewer.selected), x, y, 24); y += 32
		if turn, found := latest_turn(viewer); found {
			text(fmt.tprintf("team %s, length %d", turn.team == 0 ? "A" : "B", turn.length), x, y, 18, MUTED); y += 26
			text(fmt.tprintf("indicator:   %s", len(turn.indicator) > 0 ? turn.indicator : "none"), x, y, 18); y += 26
			text(fmt.tprintf("last action: %s", turn.action), x, y, 18); y += 36
		} else {
			text("no turns yet", x, y, 18, MUTED); y += 36
		}
		size := (area.width - 20) / 2
		text("What it remembers", x, y, 17)
		text("Against the board", x + size + 20, y, 17); y += 26
		map_height := size * f32(game.height) / f32(game.width)
		draw_minimap(viewer, {x, y, size, map_height}, false)
		draw_minimap(viewer, {x + size + 20, y, size, map_height}, true)
		y += map_height + 14
		text("red: a dragon has moved", x, y, 16, MUTED); y += 22
		text("gold: a pearl it hasn't seen", x, y, 16, MUTED); y += 22
		text("brown: a pearl that's gone", x, y, 16, MUTED); y += 30
	}
	text("Space play   Left/Right step   Up/Down speed", x, area.y + area.height - 48, 16, MUTED)
	text("Tab next dragon   F fog   Esc deselect", x, area.y + area.height - 24, 16, MUTED)
}
