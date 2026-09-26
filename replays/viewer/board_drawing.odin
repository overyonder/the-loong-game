package viewer

import "core:fmt"
import rl "vendor:raylib"


// Square cells fitted and centred inside an area.
Board_Geometry :: struct {
	origin:    rl.Vector2,
	cell_size: f32,
	width:     i32,
	height:    i32,
}

board_geometry_for_area :: proc(export: ^Debug_View_Export, area: rl.Rectangle) -> Board_Geometry {
	cell_size := min(area.width / f32(export.width), area.height / f32(export.height))
	return {
		origin = {
			area.x + (area.width - cell_size * f32(export.width)) / 2,
			area.y + (area.height - cell_size * f32(export.height)) / 2,
		},
		cell_size = cell_size,
		width = export.width,
		height = export.height,
	}
}

cell_rectangle :: proc(geometry: Board_Geometry, cell: i32) -> rl.Rectangle {
	return {
		geometry.origin.x + f32(cell % geometry.width) * geometry.cell_size,
		geometry.origin.y + f32(cell / geometry.width) * geometry.cell_size,
		geometry.cell_size,
		geometry.cell_size,
	}
}

cell_center :: proc(geometry: Board_Geometry, cell: i32) -> rl.Vector2 {
	rectangle := cell_rectangle(geometry, cell)
	return {rectangle.x + rectangle.width / 2, rectangle.y + rectangle.height / 2}
}

// Cell under a screen point, or -1.
cell_at_point :: proc(geometry: Board_Geometry, point: rl.Vector2) -> i32 {
	column := i32((point.x - geometry.origin.x) / geometry.cell_size)
	row := i32((point.y - geometry.origin.y) / geometry.cell_size)
	if point.x < geometry.origin.x ||
	   point.y < geometry.origin.y ||
	   column >= geometry.width ||
	   row >= geometry.height {
		return -1
	}
	return row * geometry.width + column
}

draw_board_edges :: proc(export: ^Debug_View_Export, geometry: Board_Geometry) {
	thickness := max(2, geometry.cell_size / 6)
	for edge in export.edges {
		start := rl.Vector2 {
			geometry.origin.x + f32(edge.x) * geometry.cell_size,
			geometry.origin.y + f32(edge.y) * geometry.cell_size,
		}
		end :=
			start +
			(edge.side == 0 ? rl.Vector2{geometry.cell_size, 0} : rl.Vector2{0, geometry.cell_size})
		if edge.kelp {
			draw_round_stroke(start, end, thickness, COLOR_KELP)
		} else {
			// Reference portals use a 3px dash/3px gap at 24px cells.
			for dash in 0 ..< 4 {
				a := start + (end - start) * (f32(dash) / 4)
				b := start + (end - start) * ((f32(dash) + 0.5) / 4)
				rl.DrawLineEx(a, b, thickness, COLOR_PORTAL)
			}
		}
		if !edge.kelp && geometry.cell_size >= 14 {
			label := fmt.ctprintf("%d", edge.portal)
			draw_text(
				label,
				i32((start.x + end.x) / 2) + 2,
				i32((start.y + end.y) / 2) + 2,
				10,
				COLOR_PORTAL,
			)
		}
	}
}

// 7×7 view outline, split correctly across the torus seams.
draw_vision_window :: proc(geometry: Board_Geometry, head: i32, color: rl.Color) {
	for row in i32(0) ..< WINDOW_SIDE {
		for column in i32(0) ..< WINDOW_SIDE {
			if row != 0 && row != WINDOW_SIDE - 1 && column != 0 && column != WINDOW_SIDE - 1 {
				continue
			}
			x := (head % geometry.width + column - WINDOW_RADIUS + geometry.width) % geometry.width
			y := (head / geometry.width + row - WINDOW_RADIUS + geometry.height) % geometry.height
			r := cell_rectangle(geometry, y * geometry.width + x)
			if row == 0 {rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y}, 1.5, color)}
			if row ==
			   WINDOW_SIDE -
				   1 {rl.DrawLineEx({r.x, r.y + r.height}, {r.x + r.width, r.y + r.height}, 1.5, color)}
			if column == 0 {rl.DrawLineEx({r.x, r.y}, {r.x, r.y + r.height}, 1.5, color)}
			if column ==
			   WINDOW_SIDE -
				   1 {rl.DrawLineEx({r.x + r.width, r.y}, {r.x + r.width, r.y + r.height}, 1.5, color)}
		}
	}
}

draw_text_with_backdrop :: proc(
	text: cstring,
	position: rl.Vector2,
	font_size: i32,
	color: rl.Color,
) {
	width := measure_text(text, font_size)
	rl.DrawRectangle(
		i32(position.x) - 2,
		i32(position.y) - 1,
		width + 4,
		font_size + 2,
		rl.Fade(COLOR_UNKNOWN, 0.7),
	)
	draw_text(text, i32(position.x), i32(position.y), font_size, color)
}

// Selected units show the recorded board at their own turnStart, not the
// round boundary or the previous decision. This is truth, explicitly labelled.
board_at_selection :: proc(viewer: ^Viewer_State, frame: i32) -> ^Board_Frame {
	turn, found := selected_dragon_turn(&viewer.game, viewer.selected_dragon, frame)
	if found {return &turn.board}
	return &viewer.game.export.frames[frame]
}

draw_board_frame :: proc(viewer: ^Viewer_State, area: rl.Rectangle, frame: i32) -> Board_Geometry {
	export := &viewer.game.export
	geometry := board_geometry_for_area(
		export,
		{area.x, area.y + 28, area.width, area.height - 28},
	)
	board := board_at_selection(viewer, frame)
	turn, found := selected_dragon_turn(&viewer.game, viewer.selected_dragon, frame)
	draw_text(
		found ? "Recorded truth at selected dragon's turn; memory is in inspector" : "Recorded truth at round boundary; right-click a dragon to inspect",
		i32(area.x),
		i32(area.y),
		18,
		MUTED_TEXT_COLOR,
	)
	for cell in 0 ..< export.width * export.height {
		rl.DrawRectangleRec(cell_rectangle(geometry, cell), COLOR_CELL)
		if viewer.overlays.grid {rl.DrawRectangleLinesEx(cell_rectangle(geometry, cell), 1, COLOR_GRID)}
	}
	if found && viewer.overlays.coverage {
		for cell in turn.diagnostic.owned_cells {rl.DrawRectangleRec(cell_rectangle(geometry, cell), rl.Color{127, 176, 105, 16})}
	}
	if found && viewer.overlays.search {
		for node in turn.diagnostic.search {
			if node.cell < 0 || node.cell >= export.width * export.height {continue}
			color := rl.Color{139, 169, 158, 14}
			rl.DrawRectangleRec(cell_rectangle(geometry, node.cell), color)
			if geometry.cell_size >= 28 {
				r := cell_rectangle(geometry, node.cell)
				draw_text(
					node.utility_evaluated ? fmt.ctprintf("%.0f", node.utility) : "?",
					i32(r.x + 2),
					i32(r.y + 2),
					12,
					BOARD_TEXT,
				)
			}
		}
	}
	for pearl in board.pearls {rl.DrawCircleV(cell_center(geometry, pearl), geometry.cell_size * 0.23, COLOR_PEARL)}
	if viewer.overlays.timers {
		for timer in board.timers {
			center := cell_center(geometry, timer.cell)
			draw_text(
				fmt.ctprintf("%d", timer.remaining),
				i32(center.x + geometry.cell_size * 0.16),
				i32(center.y + geometry.cell_size * 0.12),
				12,
				rl.Fade(COLOR_PEARL, 0.75),
			)
		}
	}
	if viewer.overlays.edges {draw_board_edges(export, geometry)}
	if found {
		if viewer.overlays.vision_windows {draw_vision_window(geometry, turn.head, COLOR_SELECTED)}
		if turn.report_present &&
		   turn.target >= 0 &&
		   turn.target < export.width * export.height &&
		   viewer.overlays.target_lines {
			rl.DrawCircleLinesV(
				cell_center(geometry, turn.target),
				geometry.cell_size * 0.48,
				COLOR_SELECTED,
			)
		}
		if viewer.overlays.strategy_labels && turn.report_present {
			label := fmt.ctprintf(
				"%s / %s%s",
				turn.regime,
				turn.role,
				turn.reliable ? "" : " UNRELIABLE",
			)
			position :=
				cell_center(geometry, turn.head) +
				rl.Vector2{geometry.cell_size * 0.6, geometry.cell_size * 0.5}
			position.x = min(
				position.x,
				geometry.origin.x +
				f32(geometry.width) * geometry.cell_size -
				f32(measure_text(label, 14)) -
				4,
			)
			if position.y + 16 * font_scale >
			   geometry.origin.y + f32(geometry.height) * geometry.cell_size {
				position.y = cell_center(geometry, turn.head).y - geometry.cell_size * 0.8
			}
			draw_text_with_backdrop(label, position, 14, COLOR_SELECTED)
		}

		if viewer.overlays.path {
			for cell, index in turn.diagnostic.path {
				if index >
				   0 {draw_cell_link(geometry, turn.diagnostic.path[index - 1], cell, rl.Fade(COLOR_SELECTED, 0.65), 2)}
			}
		}
		if viewer.overlays.coverage &&
		   turn.diagnostic.version > 0 &&
		   turn.diagnostic.coverage.target >= 0 {
			rl.DrawRectangleLinesEx(
				cell_rectangle(geometry, turn.diagnostic.coverage.target),
				4,
				rl.Color{100, 190, 255, 255},
			)
		}
	}
	if viewer.overlays.pings {
		for ping in export.pings {
			if (ping.round == frame && ping.sender == viewer.selected_dragon) ||
			   (ping.received_round == frame && ping.hit == viewer.selected_dragon) {
				draw_ping_ray(geometry, ping)
			}
		}
	}
	if viewer.overlays.deaths {
		for death in export.frames[frame].deaths {
			r := cell_rectangle(geometry, death.cell)
			rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y + r.height}, 3, COLOR_DEATH)
		}
	}
	draw_dragon_bodies(viewer, board, geometry)

	for highlight in viewer.highlights {
		if highlight.kind ==
		   "cell" {rl.DrawRectangleLinesEx(cell_rectangle(geometry, highlight.id), 4, COLOR_SELECTED)}
		if highlight.kind == "dragon" {
			for dragon in board.dragons {
				if dragon.id == highlight.id &&
				   len(dragon.body) >
					   0 {rl.DrawCircleLinesV(cell_center(geometry, dragon.body[0]), geometry.cell_size * 0.55, COLOR_SELECTED)}
			}
		}
		if highlight.kind == "edge" && highlight.id >= 0 && int(highlight.id) < len(export.edges) {
			edge := export.edges[highlight.id]
			r := cell_rectangle(geometry, edge.y * export.width + edge.x)
			rl.DrawLineEx(
				{r.x, r.y},
				edge.side == 0 ? rl.Vector2{r.x + r.width, r.y} : rl.Vector2{r.x, r.y + r.height},
				6,
				COLOR_SELECTED,
			)
		}
	}
	return geometry
}

// Adjacent torus links split at seams; portal jumps are visibly discontinuous.
draw_cell_link :: proc(g: Board_Geometry, first, second: i32, color: rl.Color, thickness: f32) {
	a, b := cell_center(g, first), cell_center(g, second)
	if abs(a.x - b.x) <= g.cell_size * 1.1 && abs(a.y - b.y) <= g.cell_size * 1.1 {
		rl.DrawLineEx(a, b, thickness, color)
	} else if first / g.width == second / g.width &&
	   abs(first % g.width - second % g.width) == g.width - 1 {
		left := g.origin.x
		right := left + f32(g.width) * g.cell_size
		rl.DrawLineEx(a, {a.x > b.x ? right : left, a.y}, thickness, color)
		rl.DrawLineEx({a.x > b.x ? left : right, b.y}, b, thickness, color)
	} else if first % g.width == second % g.width &&
	   abs(first / g.width - second / g.width) == g.height - 1 {
		top := g.origin.y
		bottom := top + f32(g.height) * g.cell_size
		rl.DrawLineEx(a, {a.x, a.y > b.y ? bottom : top}, thickness, color)
		rl.DrawLineEx({b.x, a.y > b.y ? top : bottom}, b, thickness, color)
	} else {
		rl.DrawCircleLinesV(a, g.cell_size * 0.2, color)
		rl.DrawCircleLinesV(b, g.cell_size * 0.2, color)
	}
}

draw_ping_ray :: proc(g: Board_Geometry, ping: Export_Ping) {
	color := ping.reflected ? COLOR_SELECTED : rl.Color{155, 189, 181, 125}
	cell := ping.origin
	direction: i32 = 0
	if ping.direction == "east" {direction = 1}
	if ping.direction == "south" {direction = 2}
	if ping.direction == "west" {direction = 3}
	offsets := [4][2]i32{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
	for _ in 0 ..< max(g.width, g.height) {
		if cell == ping.end && ping.origin == ping.end {break}
		next :=
			((cell / g.width + offsets[direction][1] + g.height) % g.height) * g.width +
			(cell % g.width + offsets[direction][0] + g.width) % g.width
		draw_cell_link(g, cell, next, color, 1)
		cell = next
		if cell == ping.end {break}
	}
	rl.DrawCircleLinesV(cell_center(g, ping.end), g.cell_size * 0.35, color)
}

WINDOW_RADIUS :: 3
WINDOW_SIDE :: 7
// Select the dragon whose body covers the clicked cell, or clear the selection.
select_dragon_at_cell :: proc(viewer: ^Viewer_State, frame: i32, cell: i32) {
	if cell < 0 {
		return
	}
	for dragon in board_at_selection(viewer, frame).dragons {
		for body_cell in dragon.body {
			if body_cell == cell {
				viewer.selected_dragon = dragon.id
				return
			}
		}
	}
	viewer.selected_dragon = -1
}

// Composite the connected strokes once, like SVG group opacity .85. Drawing
// translucent segments independently would brighten every round joint.
dragon_body_layer: rl.RenderTexture2D

draw_round_stroke :: proc(a, b: rl.Vector2, width: f32, color: rl.Color) {
	rl.DrawLineEx(a, b, width, color)
	rl.DrawCircleV(a, width / 2, color)
	rl.DrawCircleV(b, width / 2, color)
}

draw_dragon_bodies :: proc(viewer: ^Viewer_State, board: ^Board_Frame, g: Board_Geometry) {
	width, height := rl.GetScreenWidth(), rl.GetScreenHeight()
	if dragon_body_layer.texture.width != width || dragon_body_layer.texture.height != height {
		if dragon_body_layer.id != 0 {rl.UnloadRenderTexture(dragon_body_layer)}
		dragon_body_layer = rl.LoadRenderTexture(width, height)
	}
	rl.BeginTextureMode(dragon_body_layer)
	rl.ClearBackground(rl.BLANK)
	for dragon in board.dragons {
		color := TEAM_BODY_COLORS[dragon.team]
		for cell, index in dragon.body {
			rl.DrawCircleV(cell_center(g, cell), g.cell_size * 0.25, color)
			if index == 0 {continue}
			previous := dragon.body[index - 1]
			dx := abs(previous % g.width - cell % g.width)
			dy := abs(previous / g.width - cell / g.width)
			// Keep caps at portal discontinuities; wrap links stop at the board seam.
			if dx + dy == 1 || (dy == 0 && dx == g.width - 1) || (dx == 0 && dy == g.height - 1) {
				draw_cell_link(g, previous, cell, color, g.cell_size * 0.5)
			}
		}
	}
	rl.EndTextureMode()
	rl.DrawTextureRec(
		dragon_body_layer.texture,
		{0, 0, f32(width), -f32(height)},
		{0, 0},
		rl.Fade(rl.WHITE, 0.85),
	)
	for dragon in board.dragons {
		if len(dragon.body) == 0 {continue}
		center := cell_center(g, dragon.body[0])
		rl.DrawCircleV(center, g.cell_size * 0.36, TEAM_HEAD_COLORS[dragon.team])
		if dragon.id == viewer.selected_dragon {
			rl.DrawRing(
				center,
				g.cell_size * 0.62 - max(1, g.cell_size * 0.0625),
				g.cell_size * 0.62 + max(1, g.cell_size * 0.0625),
				0,
				360,
				64,
				TEAM_HEAD_COLORS[1],
			)
		}
		if viewer.overlays.dragon_ids {
			label := fmt.ctprintf("%d", dragon.id)
			draw_text(
				label,
				i32(center.x) - measure_text(label, 13) / 2,
				i32(center.y - 7 * font_scale),
				13,
				COLOR_CELL,
			)
		}
	}
}
