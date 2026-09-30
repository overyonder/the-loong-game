package viewer

import "core:fmt"
import "core:slice"
import rl "vendor:raylib"


// Square cells fitted and centred inside an area. The view shows `columns` ×
// `rows` cells from board column `left` and row `top`, wrapping round the
// torus: the whole board, or the area round a followed head. Cells beyond the
// view's far side are clipped away.
Board_Geometry :: struct {
	origin:        rl.Vector2,
	cell_size:     f32,
	width:         i32,
	height:        i32,
	left, top:     i32,
	columns, rows: i32,
}

// Side of the area view that `f` toggles round the focused dragon's head.
AREA_VIEW_SIDE :: 15

// The whole board, or with a `centre` cell the area view round it.
board_geometry_for_area :: proc(
	export: ^Game_View,
	area: rl.Rectangle,
	centre: i32 = -1,
) -> Board_Geometry {
	columns, rows := export.width, export.height
	left, top: i32
	if centre >= 0 {
		columns, rows = min(AREA_VIEW_SIDE, export.width), min(AREA_VIEW_SIDE, export.height)
		left = (centre % export.width - columns / 2 + export.width) % export.width
		top = (centre / export.width - rows / 2 + export.height) % export.height
	}
	cell_size := min(area.width / f32(columns), area.height / f32(rows))
	return {
		origin = {
			area.x + (area.width - cell_size * f32(columns)) / 2,
			area.y + (area.height - cell_size * f32(rows)) / 2,
		},
		cell_size = cell_size,
		width = export.width,
		height = export.height,
		left = left,
		top = top,
		columns = columns,
		rows = rows,
	}
}

cell_rectangle :: proc(geometry: Board_Geometry, cell: i32) -> rl.Rectangle {
	column := (cell % geometry.width - geometry.left + geometry.width) % geometry.width
	row := (cell / geometry.width - geometry.top + geometry.height) % geometry.height
	return {
		geometry.origin.x + f32(column) * geometry.cell_size,
		geometry.origin.y + f32(row) * geometry.cell_size,
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
	   column >= geometry.columns ||
	   row >= geometry.rows {
		return -1
	}
	return (row + geometry.top) % geometry.height * geometry.width +
		(column + geometry.left) % geometry.width
}

draw_board_edges :: proc(export: ^Game_View, geometry: Board_Geometry) {
	thickness := max(2, geometry.cell_size / 6)
	for edge in export.edges {
		corner := cell_rectangle(geometry, edge.y * geometry.width + edge.x)
		start := rl.Vector2{corner.x, corner.y}
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

// A cell's background: plain, or with Spawn gaps on, tinted by its maximum
// reset gap's band (palette.odin), so fast-spawning ground stands out under
// everything drawn on it.
cell_background :: proc(viewer: ^Viewer_State, cell: i32) -> rl.Color {
	maximums := viewer.game.view.spawn_maximum
	if !viewer.overlays.spawn_gaps || int(cell) >= len(maximums) || maximums[cell] <= 0 {return COLOR_CELL}
	for band in SPAWN_BANDS {
		if maximums[cell] <= band.maximum {return color_lerp(COLOR_CELL, SPAWN_TINT, band.share)}
	}
	return COLOR_CELL
}

color_lerp :: proc(from, to: rl.Color, share: f32) -> rl.Color {
	mix :: proc(a, b: u8, share: f32) -> u8 {return u8(f32(a) + (f32(b) - f32(a)) * share)}
	return {mix(from.r, to.r, share), mix(from.g, to.g, share), mix(from.b, to.b, share), 255}
}

// Turn mode shows the board at the active turn's start, before that dragon
// moves; round mode shows the round after every dragon has moved.
board_at_selection :: proc(viewer: ^Viewer_State, frame: i32) -> ^Board_Frame {
	game := &viewer.game
	index := active_turn_index(viewer)
	if index >= 0 {return turn_board(game, index)}
	return frame_board(game, frame)
}

draw_board_frame :: proc(viewer: ^Viewer_State, area: rl.Rectangle, frame: i32) -> Board_Geometry {
	export := &viewer.game.view
	board := board_at_selection(viewer, frame)
	geometry := board_geometry_for_area(export, area, area_view_centre(viewer, board))
	// main ends the clip after the gizmo overlays.
	if board_view_clipped(geometry) {begin_board_view_clip(geometry)}
	turn, found := focused_dragon_turn(viewer, frame)
	for cell in 0 ..< export.width * export.height {
		rl.DrawRectangleRec(cell_rectangle(geometry, cell), cell_background(viewer, cell))
		if viewer.overlays.grid {rl.DrawRectangleLinesEx(cell_rectangle(geometry, cell), 1, COLOR_GRID)}
	}
	for pearl in board.pearls {rl.DrawCircleV(cell_center(geometry, pearl), geometry.cell_size * 0.23, COLOR_PEARL)}
	// True countdowns sit bottom-right: cyan where the focused dragon remembers
	// the same next spawn, otherwise gold, with a wrong memory in red above.
	if viewer.overlays.timers {
		remembered: map[i32]Remembered_Spawn
		if found && turn.gizmo_reliable {remembered = remembered_spawns(&viewer.game, turn)}
		for timer in board.timers {
			memory, known := remembered[timer.cell]
			color := known && memory.correct ? CORRECT_TIMER_COLOR : rl.Fade(COLOR_PEARL, 0.75)
			draw_cell_text(geometry, timer.cell, fmt.tprintf("%d", timer.remaining), .Bottom_Right, color)
		}
		for cell, memory in remembered {
			if memory.correct {continue}
			label := memory.never ? "never" : fmt.tprintf("%d", memory.stated - frame)
			draw_cell_text(geometry, cell, label, .Above_Bottom_Right, COLOR_WRONG)
		}
	}
	if viewer.overlays.edges {draw_board_edges(export, geometry)}
	// A dragon without diagnostics is followed on the replay alone, so its
	// portals show where each leads.
	if viewer.overlays.edges && found && !turn.has_record && !turn.recovery_pending {draw_portal_links(export, geometry)}
	if found && turn.gizmo_reliable {draw_mental_map(viewer, geometry, turn)}
	if found {
		if viewer.overlays.vision_windows {draw_vision_window(geometry, turn.head, COLOR_SELECTED)}
	}
	// The focused decision's pings: those it read and the echoes of its
	// previous sonar. Its own sends this turn reach it only as next turn's echoes.
	mental := mental_view(viewer, turn, found)
	if viewer.overlays.pings && !mental && found && focused_decision_phase(viewer) != .Waiting {
		pings := decision_pings(&viewer.game, turn)
		// What it read in purple, the echoes of its own sonar in teal, each
		// ray once: a ray back on its own sender is both.
		rows := make([dynamic]int, context.temp_allocator)
		append(&rows, ..pings.received[:])
		for echo in pings.echoes {if !slice.contains(pings.received[:], echo) {append(&rows, echo)}}
		for row, position in rows {
			ping := game_ping(&viewer.game, row)
			draw_ping_ray(geometry, ping, position < len(pings.received) ? SONAR_RECEIVED : SONAR_ECHO)
			if ping.decoded != "" {
				// The sender's own reading of the value, beside the impact.
				meaning := ping.decoded
				if len(meaning) > 48 {meaning = fmt.tprintf("%s...", meaning[:45])}
				draw_text_with_backdrop(
					fmt.ctprintf("D%d: %s", ping.sender, meaning),
					cell_center(geometry, ping.end) + {geometry.cell_size * 0.4, -geometry.cell_size * 0.4},
					12,
					TEXT_COLOR,
				)
			}
		}
	}
	if viewer.overlays.deaths && !mental {
		for death in board.deaths {
			r := cell_rectangle(geometry, death.cell)
			rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y + r.height}, 3, COLOR_DEATH)
		}
	}
	draw_dragon_bodies(viewer, board, geometry, mental ? turn : nil)
	if found && viewer.overlays.fog && !mental {
		for cell in 0 ..< export.width * export.height {
			dx := abs(cell % export.width - turn.head % export.width)
			dy := abs(cell / export.width - turn.head / export.width)
			if min(dx, export.width - dx) > WINDOW_RADIUS ||
			   min(dy, export.height - dy) > WINDOW_RADIUS {
				rl.DrawRectangleRec(cell_rectangle(geometry, cell), rl.Color{8, 14, 12, 170})
			}
		}
		draw_vision_window(geometry, turn.head, COLOR_SELECTED)
	}

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
	   (abs(first % g.width - second % g.width) == 1 ||
			   abs(first % g.width - second % g.width) == g.width - 1) {
		// Neighbours across the drawn seam, wherever the view puts it.
		left := g.origin.x
		right := left + f32(g.width) * g.cell_size
		rl.DrawLineEx(a, {a.x > b.x ? right : left, a.y}, thickness, color)
		rl.DrawLineEx({a.x > b.x ? left : right, b.y}, b, thickness, color)
	} else if first % g.width == second % g.width &&
	   (abs(first / g.width - second / g.width) == 1 ||
			   abs(first / g.width - second / g.width) == g.height - 1) {
		top := g.origin.y
		bottom := top + f32(g.height) * g.cell_size
		rl.DrawLineEx(a, {a.x, a.y > b.y ? bottom : top}, thickness, color)
		rl.DrawLineEx({b.x, a.y > b.y ? top : bottom}, b, thickness, color)
	} else {
		rl.DrawCircleLinesV(a, g.cell_size * 0.2, color)
		rl.DrawCircleLinesV(b, g.cell_size * 0.2, color)
	}
}

draw_ping_ray :: proc(g: Board_Geometry, ping: Game_Ping, color: rl.Color) {
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
		a, b := cell_center(g, cell), cell_center(g, next)
		if abs(a.x - b.x) > g.cell_size * 1.1 || abs(a.y - b.y) > g.cell_size * 1.1 {
			middle :=
				a +
				rl.Vector2{f32(offsets[direction][0]), f32(offsets[direction][1])} *
					g.cell_size *
					0.5
			draw_dashed_segment(a, middle, color)
			middle =
				b -
				rl.Vector2{f32(offsets[direction][0]), f32(offsets[direction][1])} *
					g.cell_size *
					0.5
			draw_dashed_segment(middle, b, color)
		} else {draw_dashed_segment(a, b, color)}
		cell = next
		if cell == ping.end {break}
	}
	impact := cell_center(g, ping.end)
	radius := g.cell_size * 0.3
	for i in 0 ..< 4 {
		corners := [4]rl.Vector2{{0, -radius}, {radius, 0}, {0, radius}, {-radius, 0}}
		rl.DrawLineEx(impact + corners[i], impact + corners[(i + 1) % 4], 2, color)
	}
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
				select_dragon_turn(viewer, dragon.id)
				return
			}
		}
	}
	clear_viewer_selections(viewer)
}

// Composite the connected strokes once, like SVG group opacity .85. Drawing
// translucent segments independently would brighten every round joint.
dragon_body_layer: rl.RenderTexture2D

draw_round_stroke :: proc(a, b: rl.Vector2, width: f32, color: rl.Color) {
	rl.DrawLineEx(a, b, width, color)
	rl.DrawCircleV(a, width / 2, color)
	rl.DrawCircleV(b, width / 2, color)
}

// A dragon yet to move, mixed most of the way into the board so it stays opaque.
faded :: proc(color: rl.Color) -> rl.Color {
	mix :: proc(a, b: u8) -> u8 {return u8((u32(a) * 2 + u32(b) * 3) / 5)}
	return {mix(color.r, COLOR_CELL.r), mix(color.g, COLOR_CELL.g), mix(color.b, COLOR_CELL.b), color.a}
}

// With a mental map's turn, dragons it doesn't know of are drawn in the
// unknown colour.
draw_dragon_bodies :: proc(viewer: ^Viewer_State, board: ^Board_Frame, g: Board_Geometry, mental: ^Dragon_Turn = nil) {
	width, height := rl.GetScreenWidth(), rl.GetScreenHeight()
	if dragon_body_layer.texture.width != width || dragon_body_layer.texture.height != height {
		if dragon_body_layer.id != 0 {rl.UnloadRenderTexture(dragon_body_layer)}
		dragon_body_layer = rl.LoadRenderTexture(width, height)
	}
	// The layer is drawn whole; the area view clips it when it is composited.
	if board_view_clipped(g) {rl.EndScissorMode()}
	rl.BeginTextureMode(dragon_body_layer)
	rl.ClearBackground(rl.BLANK)
	for &dragon in board.dragons {
		color := TEAM_BODY_COLORS[dragon.team]
		if mental != nil && !dragon_known(mental, g, &dragon) {color = UNKNOWN_DRAGON_COLOR}
		if dragon_awaits_turn(viewer, dragon.id) {color = faded(color)}
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
	if board_view_clipped(g) {begin_board_view_clip(g)}
	rl.DrawTextureRec(
		dragon_body_layer.texture,
		{0, 0, f32(width), -f32(height)},
		{0, 0},
		rl.Fade(rl.WHITE, 0.85),
	)
	for &dragon in board.dragons {
		if len(dragon.body) == 0 {continue}
		center := cell_center(g, dragon.body[0])
		head_color := TEAM_HEAD_COLORS[dragon.team]
		if mental != nil && !dragon_known(mental, g, &dragon) {head_color = UNKNOWN_DRAGON_COLOR}
		if dragon_awaits_turn(viewer, dragon.id) {head_color = faded(head_color)}
		rl.DrawCircleV(center, g.cell_size * 0.36, head_color)
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

draw_dashed_segment :: proc(a, b: rl.Vector2, color: rl.Color) {
	for dash in 0 ..< 4 {rl.DrawLineEx(a + (b - a) * (f32(dash) / 4), a + (b - a) * ((f32(dash) + 0.5) / 4), 2, color)}
}

// The focused dragon's head while `f` has the area view on and it is on the
// board, else -1 for the whole board.
area_view_centre :: proc(viewer: ^Viewer_State, board: ^Board_Frame) -> i32 {
	if !viewer.area_view || viewer.selected_dragon < 0 {return -1}
	for dragon in board.dragons {
		if dragon.id == viewer.selected_dragon && len(dragon.body) > 0 {return dragon.body[0]}
	}
	return -1
}

// Whether the view shows less than the whole board, so drawing must clip to it.
board_view_clipped :: proc(g: Board_Geometry) -> bool {
	return g.columns < g.width || g.rows < g.height
}

begin_board_view_clip :: proc(g: Board_Geometry) {
	rl.BeginScissorMode(
		i32(g.origin.x),
		i32(g.origin.y),
		i32(g.cell_size * f32(g.columns)),
		i32(g.cell_size * f32(g.rows)),
	)
}

// Text inside a board cell sits in one corner, a size under the board's other
// labels, and shrinks to fit the cell so neighbouring cells' text never overlaps.
CELL_TEXT :: 10
Cell_Corner :: enum {
	Top_Left,
	Top_Right,
	Bottom_Right,
	// The line above the bottom-right corner.
	Above_Bottom_Right,
}

draw_cell_text :: proc(
	geometry: Board_Geometry,
	cell: i32,
	text: string,
	corner: Cell_Corner,
	color: rl.Color,
) {
	if text == "" {return}
	r := cell_rectangle(geometry, cell)
	label := fmt.ctprintf("%s", text)
	room := r.width - 3
	size := i32(CELL_TEXT)
	width := f32(measure_text(label, size))
	if width > room {
		size = i32(f32(size) * room / width)
		if size < 7 {return}
		width = f32(measure_text(label, size))
	}
	x := corner == .Top_Left ? r.x + 2 : r.x + r.width - 1 - width
	line := f32(size) * font_scale * 1.15
	y := r.y + 1
	if corner == .Bottom_Right {y = r.y + r.height - 1 - line}
	if corner == .Above_Bottom_Right {y = r.y + r.height - 1 - 2 * line}
	draw_text(label, i32(x), i32(y), size, color)
}

// A line joining the two edges of each portal pair, from the replay.
draw_portal_links :: proc(export: ^Game_View, geometry: Board_Geometry) {
	middle :: proc(geometry: Board_Geometry, edge: Board_Edge) -> rl.Vector2 {
		corner := cell_rectangle(geometry, edge.y * geometry.width + edge.x)
		return edge.side == 0 ? {corner.x + geometry.cell_size / 2, corner.y} : {corner.x, corner.y + geometry.cell_size / 2}
	}
	for edge, index in export.edges {
		if edge.kelp {continue}
		for other in export.edges[index + 1:] {
			if other.kelp || other.portal != edge.portal {continue}
			a, b := middle(geometry, edge), middle(geometry, other)
			rl.DrawLineEx(a, b, 1.5, rl.Fade(COLOR_PORTAL, 0.6))
			rl.DrawCircleV(a, 3, COLOR_PORTAL)
			rl.DrawCircleV(b, 3, COLOR_PORTAL)
		}
	}
}
