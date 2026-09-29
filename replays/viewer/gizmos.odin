package viewer

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Wire types for diagnostics.md. No role names or scoring policy live here.
Gizmo_Cell :: struct {
	cell:  i32,
	value: union {
		f32,
	},
	label: string,
	color: [4]u8,
}
Gizmo_Edge :: struct {
	cell, direction: i32,
	label:           string,
	color:           [4]u8,
}
Gizmo_Node :: struct {
	id, label, parent, reason, objective: string,
	eligible:                  union {
		bool,
	},
	score:                     union {
		f64,
	},
	x, y:                      f32,
	active:                    bool,
}
// A remembered position (diagnostics.md, Positions): where something was last
// known, how far it may be from there now, and how long ago it was known.
// A dragon's position may also carry the believer's view of it: its team,
// its length (exact or a lower bound) and whether it is its team's champion,
// which the beliefs strip grades against the replay (beliefs.odin).
Gizmo_Position :: struct {
	cell, radius, age:      i32,
	cells:                  []i32, // where it may be, when the bot lists it
	source, label, team:    string,
	color:                  [4]u8,
	dragon, length:         union {
		i32,
	},
	length_exact, champion: bool,
}
Gizmo_Link :: struct {
	from, to, label: string,
	active:          bool,
}
Gizmo :: struct {
	id, parent, layout, expression, slot:              string,
	row_ids, row_states:                               []string,
	operands:                                          []struct {
		name:  string,
		value: f64,
	},
	result:                                            union {
		f64,
	},
	version:                                           i32,
	display_column, evaluated_column:                  union {
		i32,
	},
	display_format, display_position, display_overlay: string,
	truth_columns:                                     []string,
	columns:                                           []string,
	rows:                                              [][]string,
	row_cells:                                         []i32,
	retain:                                            bool,
	kind, label, objective, reason:                    string,
	color:                                             [4]u8,
	points:                                            []i32,
	cells:                                             []Gizmo_Cell,
	edges:                                             []Gizmo_Edge,
	score:                                             f32,
	selected:                                          bool,
	nodes:                                             []Gizmo_Node,
	links:                                             []Gizmo_Link,
	positions:                                         []Gizmo_Position,
	// Facts a table offers for the team consensus (diagnostics.md).
	consensus:                                         []struct {
		category, scope:                         string,
		column, known_column, minimum, direction: i32,
	},
	// Present on a sonar table, which Signals shows joined with its pings.
	sonar:                                             struct {
		role:                           string,
		value_column, meaning_column:   i32,
		outcome_column, cells_column:   union {
			i32,
		},
	},
}

gizmo_color :: proc(color: [4]u8) -> rl.Color {
	if color == ([4]u8{}) {return UI_ACCENT}
	return {color[0], color[1], color[2], color[3]}
}

draw_gizmo_cells :: proc(gizmo: ^Gizmo, geometry: Board_Geometry) {
	for cell in gizmo.cells {
		r := cell_rectangle(geometry, cell.cell)
		color := gizmo_color(cell.color)
		if cell.color == ([4]u8{}) {color = gizmo_color(gizmo.color)}
		color.a = min(color.a, 110)
		rl.DrawRectangleRec(r, color)
		draw_cell_text(geometry, cell.cell, cell.label, .Top_Left, TEXT_COLOR)
	}
	for edge in gizmo.edges {
		r := cell_rectangle(geometry, edge.cell)
		a := rl.Vector2{r.x, r.y}
		b := rl.Vector2{r.x + r.width, r.y}
		if edge.direction == 1 {a = {r.x + r.width, r.y}; b = {r.x + r.width, r.y + r.height}}
		if edge.direction == 2 {a = {r.x, r.y + r.height}; b = {r.x + r.width, r.y + r.height}}
		if edge.direction == 3 {b = {r.x, r.y + r.height}}
		rl.DrawLineEx(a, b, 3, gizmo_color(edge.color))
	}
}

draw_gizmo_overlays :: proc(viewer: ^Viewer_State, geometry: Board_Geometry, frame: i32) {
	turn, found := focused_dragon_turn(viewer, frame)
	if !found || !turn.gizmo_reliable {return}
	for &gizmo, index in turn.gizmos {
		color := gizmo_color(gizmo.color)
		thickness: f32 = highlighted(viewer, "gizmo", i32(index)) ? 5 : 2
		switch gizmo.kind {
		case "map":
			if gizmo.display_overlay == "markers" {draw_gizmo_cells(&gizmo, geometry)}
		case "line", "path":
			if !viewer.overlays.path {continue}
			for point, position in gizmo.points {
				if position >
				   0 {rl.DrawLineEx(cell_center(geometry, gizmo.points[position - 1]), cell_center(geometry, point), thickness, color)}
			}
		case "target":
			if !viewer.overlays.target_lines {continue}
			for point in gizmo.points {
				center := cell_center(geometry, point)
				rl.DrawCircleLinesV(center, geometry.cell_size * 0.4, color)
				draw_text(
					fmt.ctprintf("%s", gizmo.label),
					i32(center.x + 5),
					i32(center.y),
					14,
					color,
				)
			}
		case "table":
			// Remembered next spawns are drawn graded with the true countdowns
			// (draw_board_frame), so only other timer columns are drawn here.
			if column, show := gizmo.display_column.(i32); show && gizmo.display_overlay == "timers" && int(column) < len(gizmo.truth_columns) && gizmo.truth_columns[column] == "spawn_due" {continue}
			visible :=
				gizmo.display_overlay == "timers" ? viewer.overlays.timers : viewer.overlays.search
			if column, show := gizmo.display_column.(i32); show && visible {
				for row, row_index in gizmo.rows {
					if row_index >= len(gizmo.row_cells) {continue}
					r := cell_rectangle(geometry, gizmo.row_cells[row_index])
					if gizmo.display_overlay !=
					   "timers" {rl.DrawRectangleRec(r, rl.Color{139, 169, 158, 25})}
					evaluated := true
					if flag, has_flag := gizmo.evaluated_column.(i32);
					   has_flag {evaluated = row[flag] != "0"}
					label := cell_diagnostic_label(row[column], gizmo.display_format, turn.round, evaluated)
					// A bot's remembered timers default to the top-right corner in the
					// legend's teal, apart from the search values and the true countdowns.
					timers := gizmo.display_overlay == "timers"
					corner: Cell_Corner = gizmo.display_position == "top_right" || timers && gizmo.display_position == "" ? .Top_Right : .Top_Left
					// Most remembered timers are unknown, so only known ones are drawn.
					if timers && label == "?" {continue}
					text_color := gizmo.color != ([4]u8{}) ? color : timers ? CORRECT_TIMER_COLOR : BOARD_TEXT
					draw_cell_text(geometry, gizmo.row_cells[row_index], label, corner, text_color)
				}
			}
		case "search":
			if viewer.overlays.search {draw_gizmo_cells(&gizmo, geometry)}
		case "positions":
			if !viewer.overlays.positions {continue}
			if mental_view(viewer, turn, found) {draw_believed_positions(&gizmo, geometry, turn)} else {draw_positions(&gizmo, geometry)}
		}
	}
}

// Derive canvas spacing from producer coordinates, without interpreting nodes.
gizmo_graph_extent :: proc(gizmo: ^Gizmo, minimum_width: f32) -> rl.Vector2 {
	xs := make([]f32, len(gizmo.nodes), context.temp_allocator)
	ys := make([]f32, len(gizmo.nodes), context.temp_allocator)
	for node, index in gizmo.nodes {xs[index] = node.x; ys[index] = node.y}
	slice.sort(xs)
	slice.sort(ys)
	dx, dy: f32 = 1, 1
	for index in 1 ..< len(xs) {
		if gap := xs[index] - xs[index - 1]; gap > 0.00001 {dx = min(dx, gap)}
		if gap := ys[index] - ys[index - 1]; gap > 0.00001 {dy = min(dy, gap)}
	}
	return {max(minimum_width, 180 / dx), max(80, 48 / dy)}
}

draw_gizmo_state_graph :: proc(
	viewer: ^Viewer_State,
	gizmo: ^Gizmo,
	area: rl.Rectangle,
	viewport: rl.Rectangle,
) {
	for link in gizmo.links {
		start, end: rl.Vector2
		for node in gizmo.nodes {
			point := rl.Vector2{area.x + node.x * area.width, area.y + node.y * area.height}
			if node.id == link.from {start = point}
			if node.id == link.to {end = point}
		}
		color := link.active ? UI_ACCENT : MUTED_TEXT_COLOR
		if link.from == link.to {
			rl.DrawCircleLinesV({start.x, start.y - 18}, 18, color)
			draw_text(
				fmt.ctprintf("%s", link.label),
				i32(start.x + 24),
				i32(start.y - 38),
				12,
				color,
			)
		} else {
			delta := end - start
			distance := math.sqrt(delta.x * delta.x + delta.y * delta.y)
			if distance > 0 {
				direction := delta / distance
				normal := rl.Vector2{-direction.y, direction.x}
				start += normal * 6
				end += normal * 6 - direction * 12
				draw_graph_curve(start, end, link.active ? 3 : 1, color)
				rl.DrawLineEx(end, end - direction * 9 + normal * 5, 2, color)
				rl.DrawLineEx(end, end - direction * 9 - normal * 5, 2, color)
				label_position := (start + end) / 2 + normal * 14
				draw_text(
					fmt.ctprintf("%s", link.label),
					i32(label_position.x),
					i32(label_position.y),
					12,
					color,
				)
			}
		}
	}
	for node in gizmo.nodes {
		point := rl.Vector2{area.x + node.x * area.width, area.y + node.y * area.height}
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewport) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), {point.x - 9, point.y - 12, 170, 26}) {
			delete(viewer.gizmo_selection)
			viewer.gizmo_selection = strings.clone(node.id)
		}
		if viewer.gizmo_selection == node.id {rl.DrawCircleLinesV(point, 10, UI_ACCENT)}
		rl.DrawCircleV(point, 7, node.active ? UI_ACCENT : MUTED_TEXT_COLOR)
		clipped_text(node.label, point.x + 10, point.y - 8, 152, TEXT_COLOR)
	}
}

draw_gizmo_children :: proc(
	viewer: ^Viewer_State,
	turn: ^Dragon_Turn,
	parent: string,
	cursor: ^rl.Vector2,
	width: f32,
	root_slot: string = "",
) {
	for &gizmo, index in turn.gizmos {
		if gizmo.parent != parent {continue}
		if parent == "" && (gizmo.slot != root_slot || gizmo.sonar.role != "") {continue}
		draw_gizmo(viewer, turn, &gizmo, index, cursor, width)
	}
}

// One record, then everything attached to it.
draw_gizmo :: proc(
	viewer: ^Viewer_State,
	turn: ^Dragon_Turn,
	gizmo: ^Gizmo,
	index: int,
	cursor: ^rl.Vector2,
	width: f32,
) {
	inspector_paragraph(
		viewer,
		cursor,
		width,
		gizmo.label,
		gizmo_color(gizmo.color),
		"gizmo",
		i32(index),
	)
	if len(gizmo.objective) >
	   0 {inspector_paragraph(viewer, cursor, width, fmt.tprintf("Objective: %s", gizmo.objective))}
	if gizmo.kind == "candidate" {
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf("Score %.4f%s", gizmo.score, gizmo.selected ? " / chosen" : ""),
		)
	}
	if len(gizmo.reason) > 0 {inspector_paragraph(viewer, cursor, width, gizmo.reason)}
	if gizmo.kind == "target" {
		for point in gizmo.points {
			inspector_paragraph(viewer, cursor, width, fmt.tprintf("At (%d,%d)", point % viewer.game.view.width, point / viewer.game.view.width), gizmo_color(gizmo.color), "cell", point)
		}
	}
	if gizmo.kind == "map" {
		geometry := board_geometry_for_area(
			&viewer.game.view,
			{cursor.x, cursor.y, width, 220},
		)
		rl.DrawRectangleRec({cursor.x, cursor.y, width, 220}, COLOR_UNKNOWN)
		draw_gizmo_cells(gizmo, geometry)
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), {cursor.x, cursor.y, width, 220}) {
			viewer.selected_cell = cell_at_point(geometry, rl.GetMousePosition())
		}
		cursor.y += 228
	}
	if gizmo.kind == "map" || gizmo.kind == "search" {
		for cell in gizmo.cells {
			if cell.cell == viewer.selected_cell {
				inspector_paragraph(
					viewer,
					cursor,
					width,
					fmt.tprintf("Cell %d: %s", cell.cell, cell.label),
				)
				if value, present := cell.value.(f32);
				   present {inspector_paragraph(viewer, cursor, width, fmt.tprintf("Value: %.4f", value))}
			}
		}
		for edge in gizmo.edges {
			if edge.cell ==
			   viewer.selected_cell {inspector_paragraph(viewer, cursor, width, fmt.tprintf("Edge %d: %s", edge.direction, edge.label))}
		}
	}
	// A long table's own attachments, such as a map of its cells, come before
	// its rows, so they are seen without scrolling past every row.
	children_first := gizmo.kind == "table" && gizmo.id != "" && len(gizmo.rows) > LONG_TABLE_ROWS
	if children_first {draw_gizmo_children(viewer, turn, gizmo.id, cursor, width)}
	if gizmo.kind == "table" {
		draw_diagnostic_table(viewer, turn, gizmo, index, cursor, width)
	}
	if gizmo.kind == "calculation" {draw_gizmo_calculation(viewer, gizmo, cursor, width)}
	if gizmo.kind == "positions" {
		for position in gizmo.positions {
			inspector_paragraph(
				viewer,
				cursor,
				width,
				fmt.tprintf(
					"%s at (%d,%d), %s, %d rounds ago%s",
					position.label != "" ? position.label : "Position",
					position.cell % viewer.game.view.width,
					position.cell / viewer.game.view.width,
					len(position.cells) > 0 ? fmt.tprintf("%d cells possible", len(position.cells)) : fmt.tprintf("within %d steps", position.radius),
					position.age,
					position.source != "" ? fmt.tprintf(", %s", position.source) : "",
				),
				gizmo_color(position.color != ([4]u8{}) ? position.color : gizmo.color),
				"cell",
				position.cell,
			)
		}
	}
	if gizmo.kind == "state" && gizmo.layout == "tree" {
		draw_gizmo_tree_nodes(viewer, turn, gizmo, "", cursor, width, 0)
	} else if gizmo.kind == "state" {
		extent := gizmo_graph_extent(gizmo, max(80, width - 180))
		overflow := max(0, extent.x + 180 - width)
		pan := &viewer.gizmo_graph_pan[index]
		pan^ = clamp(pan^, 0, overflow)
		if overflow > 0 {
			rl.GuiSliderBar({cursor.x, cursor.y, width, 12}, "", "", pan, 0, overflow)
			cursor.y += 20
		}
		view_height := min(extent.y + 44, 340)
		viewport := rl.Rectangle{cursor.x, cursor.y, width - 10, view_height}
		y := &viewer.gizmo_graph_y[index]
		limit := max(0, extent.y + 44 - view_height)
		if !viewer.detail_open &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewport) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) {
			viewer.gizmo_graph_hovered = true
			y^ -= rl.GetMouseWheelMove() * 60
		}
		y^ = clamp(y^, 0, limit)
		if limit > 0 {
			bar := rl.Rectangle{cursor.x + width - 8, cursor.y, 8, view_height}
			if rl.IsMouseButtonDown(.LEFT) &&
			   rl.CheckCollisionPointRec(rl.GetMousePosition(), bar) {
				y^ = clamp((rl.GetMousePosition().y - bar.y) / bar.height, 0, 1) * limit
			}
			rl.DrawRectangleRec(bar, rl.Color{35, 40, 38, 255})
			thumb := max(16, view_height * view_height / (extent.y + 44))
			rl.DrawRectangleRec(
				{bar.x, bar.y + (view_height - thumb) * y^ / limit, 5, thumb},
				MUTED_TEXT_COLOR,
			)
		}
		rl.DrawRectangleLinesEx({cursor.x, cursor.y, width, view_height}, 1, MUTED_TEXT_COLOR)
		visible_top := max(cursor.y, viewer.inspector_area.y + 34)
		visible_bottom := min(
			cursor.y + view_height,
			viewer.inspector_area.y + viewer.inspector_area.height,
		)
		if visible_bottom > visible_top {
			rl.BeginScissorMode(
				i32(cursor.x),
				i32(visible_top),
				i32(width - 10),
				i32(visible_bottom - visible_top),
			)
			draw_gizmo_state_graph(
				viewer,
				gizmo,
				{cursor.x + 12 - pan^, cursor.y + 16 - y^, extent.x, extent.y},
				viewport,
			)
			rl.BeginScissorMode(
				i32(viewer.inspector_area.x),
				i32(viewer.inspector_area.y + 34),
				i32(viewer.inspector_area.width),
				i32(viewer.inspector_area.height - 34),
			)
		}
		cursor.y += view_height + 12
	}
	if gizmo.kind == "state" && gizmo.layout != "tree" {
		for node in gizmo.nodes {
			if gizmo_selection_within(turn, viewer.gizmo_selection, node.id) {
				inspector_paragraph(viewer, cursor, width, node.label, UI_ACCENT)
				if node.reason != "" {inspector_paragraph(viewer, cursor, width, node.reason)}
				draw_gizmo_children(viewer, turn, node.id, cursor, width)
			}
		}
	}
	if gizmo.id != "" && !children_first {draw_gizmo_children(viewer, turn, gizmo.id, cursor, width)}
}

LONG_TABLE_ROWS :: 20

// Absolute remembered deadlines remain useful after leaving vision. Subtract
// only the recorded decision round; never fill unknowns from replay truth.
cell_diagnostic_label :: proc(value, format: string, round: i32, evaluated: bool) -> string {
	number, parsed := strconv.parse_f64(value)
	if !evaluated {return ""}
	if !parsed {return "?"}
	if format == "round_delta" {
		if number < 0 {return "?"}
		return fmt.tprintf("%.0f", number - f64(round))
	}
	return fmt.tprintf("%.1f", number)
}

// Each position as the cell where it was last known, outlined, and the cells
// it may occupy now, hatched with their boundary traced, both fading as the
// knowledge ages.
draw_positions :: proc(gizmo: ^Gizmo, geometry: Board_Geometry) {
	// The full board isn't otherwise clipped, and a wide area must not cover
	// the sidebars; the area view already clips.
	clip := !board_view_clipped(geometry)
	if clip {begin_board_view_clip(geometry)}
	defer if clip {rl.EndScissorMode()}
	for position in gizmo.positions {
		color := gizmo_color(position.color != ([4]u8{}) ? position.color : gizmo.color)
		color = rl.Fade(color, max(0.35, 1 - f32(position.age) / 40))
		if position.radius > 0 || len(position.cells) > 0 {
			draw_position_area(position_area(position, geometry.width, geometry.height), geometry, color)
		}
		r := cell_rectangle(geometry, position.cell)
		inset := geometry.cell_size * 0.12
		rl.DrawRectangleLinesEx({r.x + inset, r.y + inset, r.width - 2 * inset, r.height - 2 * inset}, 2, color)
		label := position.age > 0 ? fmt.ctprintf("%s, %d ago", position.label, position.age) : fmt.ctprintf("%s", position.label)
		if position.label != "" {draw_text_with_backdrop(label, cell_center(geometry, position.cell) + {geometry.cell_size * 0.3, -geometry.cell_size * 0.6}, CELL_TEXT, color)}
	}
}

// The cells a position's subject may occupy: those the bot lists, else every
// cell within `radius` steps of `cell` on the torus (diagnostics.md, Positions).
position_area :: proc(entry: Gizmo_Position, width, height: i32) -> []bool {
	area := make([]bool, width * height, context.temp_allocator)
	if len(entry.cells) > 0 {
		for cell in entry.cells {if cell >= 0 && cell < width * height {area[cell] = true}}
		return area
	}
	for cell in 0 ..< width * height {
		dx := abs(cell % width - entry.cell % width)
		dy := abs(cell / width - entry.cell / width)
		area[cell] = min(dx, width - dx) + min(dy, height - dy) <= entry.radius
	}
	return area
}

// An area of cells, lightly hatched with its boundary traced, since areas
// overlap.
draw_position_area :: proc(area: []bool, geometry: Board_Geometry, color: rl.Color) {
	width, height := geometry.width, geometry.height
	for inside, cell in area {
		if !inside {continue}
		r := cell_rectangle(geometry, i32(cell))
		draw_hatch(r, rl.Fade(color, 0.15))
		x, y := i32(cell) % width, i32(cell) / width
		neighbours := [4]i32{((y + height - 1) % height) * width + x, y * width + (x + 1) % width, ((y + 1) % height) * width + x, y * width + (x + width - 1) % width}
		sides := [4][2]rl.Vector2{{{r.x, r.y}, {r.x + r.width, r.y}}, {{r.x + r.width, r.y}, {r.x + r.width, r.y + r.height}}, {{r.x, r.y + r.height}, {r.x + r.width, r.y + r.height}}, {{r.x, r.y}, {r.x, r.y + r.height}}}
		for neighbour, side in neighbours {
			if !area[neighbour] {rl.DrawLineEx(sides[side][0], sides[side][1], 1.5, rl.Fade(color, 0.6))}
		}
	}
}
