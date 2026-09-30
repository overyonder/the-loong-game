package viewer

import "core:fmt"
import "core:strconv"
import rl "vendor:raylib"

draw_objective_inspector :: proc(viewer: ^Viewer_State, area: rl.Rectangle, frame: i32) {
	if !viewer.detail_open && rl.CheckCollisionPointRec(rl.GetMousePosition(), area) {
		viewer.objective_scroll = clamp(
			viewer.objective_scroll - rl.GetMouseWheelMove() * 60,
			0,
			viewer.objective_scroll_limit,
		)
	}
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	// The pane's padding, and room for the scroll bar.
	cursor := rl.Vector2{area.x + PANE_INSET, area.y + PANE_INSET - viewer.objective_scroll}
	width := area.width - 2 * PANE_INSET - 8
	hotkeys := rl.Rectangle{cursor.x, cursor.y, f32(measure_text("Hotkeys", UI_TEXT)) + BUTTON_PADDING, CONTROL_HEIGHT}
	if rl.GuiButton(hotkeys, "Hotkeys") {open_diagnostic_detail(viewer, "Hotkeys", HOTKEYS)}
	cursor.y += CONTROL_HEIGHT + 8
	cursor.y = draw_overlay_controls(viewer, {cursor.x, cursor.y, width, area.height})
	draw_judge_points(viewer, &cursor, width, frame)
	draw_team_breakdown(viewer, &cursor, width, frame)
	turn, found := focused_dragon_turn(viewer, frame)
	if found && turn.gizmo_reliable {draw_accuracy_summary(viewer, &cursor, width, turn)}
	if viewer.selected_cell >= 0 {
		cell := viewer.selected_cell
		export := &viewer.game.view
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"Selected cell %d (%d,%d)",
				cell,
				cell % export.width,
				cell / export.width,
			),
			UI_ACCENT,
		)
		board := board_at_selection(viewer, frame)
		pearl := false
		for p in board.pearls {if p == cell {pearl = true}}
		inspector_paragraph(viewer, &cursor, width, fmt.tprintf("Replay pearl present: %v", pearl))
		for dragon in board.dragons {for p in dragon.body {if p == cell {
					inspector_paragraph(
						viewer,
						&cursor,
						width,
						fmt.tprintf(
							"Occupant: dragon %d / team %s / length %d",
							dragon.id,
							dragon.team == 0 ? "A" : "B",
							len(dragon.body),
						),
					)
				}}}
		due: i32 = -1
		for timer in board.timers {if timer.cell == cell {due = frame + timer.remaining}}
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			due >= 0 ? fmt.tprintf("Next spawn attempt: r%d (in %d)", due, due - frame) : "Next spawn attempt: none",
		)
		rule_found := false
		for rule in export.spawn_rules {if rule.cell == cell {
				rule_found = true
				inspector_paragraph(
					viewer,
					&cursor,
					width,
					rule.maximum == 0 ? "Spawning: disabled" : fmt.tprintf("Reset range: %d..%d rounds, mean %.1f", rule.minimum, rule.maximum, f32(rule.minimum + rule.maximum) / 2),
				)
			}}
		if found && turn.gizmo_reliable {
			for gizmo in turn.gizmos {
				if gizmo.kind != "table" || len(gizmo.truth_columns) == 0 {continue}
				for row, row_index in gizmo.rows {
					if row_index >= len(gizmo.row_cells) ||
					   gizmo.row_cells[row_index] != cell {continue}
					for quantity, column in gizmo.truth_columns {
						if quantity == "" {continue}
						actual: f64 = -1
						if quantity == "spawn_due" {actual = f64(due)}
						for rule in export.spawn_rules {if rule.cell == cell {
								if quantity == "spawn_min" {actual = f64(rule.minimum)}
								if quantity == "spawn_max" {actual = f64(rule.maximum)}
								if quantity ==
								   "spawn_mean" {actual = f64(rule.minimum + rule.maximum) / 2}
							}}
						estimate, parsed := strconv.parse_f64(row[column])
						if parsed && actual >= 0 && estimate >= 0 {
							inspector_paragraph(
								viewer,
								&cursor,
								width,
								fmt.tprintf(
									"%s: bot %.1f / replay %.1f / error %+.1f",
									gizmo.columns[column],
									estimate,
									actual,
									estimate - actual,
								),
							)
						}
					}
				}
			}
		}
		if !rule_found {inspector_paragraph(viewer, &cursor, width, "Reset range: not recorded")}
	}
	cursor.y = draw_compact_legend(cursor, width)
	finish_scroll_section(
		&viewer.objective_scroll,
		&viewer.objective_scroll_limit,
		area,
		max(0, cursor.y + viewer.objective_scroll - area.y - area.height + 24),
	)
}

// A left drag on the board selects cells: Shift draws a rectangle, Control a
// line, and a plain drag paints like a brush, erasing when its first cell was
// already highlighted. Every drag adds to the selection, and a right-click on
// an empty cell clears it. A click that never leaves its cell toggles that cell
// or edge, and with Shift the dragon there.
Drag_Shape :: enum {
	Brush,
	Rectangle,
	Line,
}

handle_board_range_selection :: proc(viewer: ^Viewer_State, geometry: Board_Geometry, frame: i32) {
	cell := cell_at_point(geometry, rl.GetMousePosition())
	if rl.IsMouseButtonPressed(.LEFT) && cell >= 0 {
		viewer.drag_selecting = true
		viewer.drag_start_cell = cell
		viewer.drag_end_cell = cell
		viewer.drag_moved = false
		viewer.drag_shape = .Brush
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {viewer.drag_shape = .Rectangle}
		if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {viewer.drag_shape = .Line}
		viewer.brush_erases = highlighted(viewer, "cell", cell)
	}
	if !viewer.drag_selecting {return}
	if cell >= 0 && cell != viewer.drag_end_cell {
		// A brush paints every cell it crossed since the last frame.
		if viewer.drag_shape == .Brush {for id in line_cells(geometry, viewer.drag_end_cell, cell) {paint_cell(viewer, id)}}
		viewer.drag_end_cell = cell
		viewer.drag_moved = true
	}
	cells := drag_cells(viewer, geometry)
	for id in cells {rl.DrawRectangleLinesEx(cell_rectangle(geometry, id), 2, COLOR_SELECTED)}
	if !rl.IsMouseButtonReleased(.LEFT) {return}
	viewer.drag_selecting = false
	if !viewer.drag_moved {highlight_board_item(viewer, geometry, frame); return}
	if viewer.drag_shape != .Brush {for id in cells {if !highlighted(viewer, "cell", id) {append(&viewer.highlights, Highlight{"cell", id})}}}
	viewer.selected_cell = -1 // A range has no implicit single-cell inspector.
}

// The cells a rectangle or line drag would add, outlined while it is held.
drag_cells :: proc(viewer: ^Viewer_State, geometry: Board_Geometry) -> []i32 {
	first, last := viewer.drag_start_cell, viewer.drag_end_cell
	switch viewer.drag_shape {
	case .Brush:
		return nil
	case .Line:
		return line_cells(geometry, first, last)
	case .Rectangle:
	}
	cells := make([dynamic]i32, context.temp_allocator)
	x0, y0 := first % geometry.width, first / geometry.width
	x1, y1 := last % geometry.width, last / geometry.width
	for y in min(y0, y1) ..= max(y0, y1) {for x in min(x0, x1) ..= max(x0, x1) {append(&cells, y * geometry.width + x)}}
	return cells[:]
}

// The cells from one to another in a line, each touching the last
// (Bresenham's line).
line_cells :: proc(geometry: Board_Geometry, first, last: i32) -> []i32 {
	cells := make([dynamic]i32, context.temp_allocator)
	x0, y0 := first % geometry.width, first / geometry.width
	x1, y1 := last % geometry.width, last / geometry.width
	dx, dy := abs(x1 - x0), -abs(y1 - y0)
	sx: i32 = x0 < x1 ? 1 : -1
	sy: i32 = y0 < y1 ? 1 : -1
	error := dx + dy
	x, y := x0, y0
	for {
		append(&cells, y * geometry.width + x)
		if x == x1 && y == y1 {break}
		twice := 2 * error
		if twice >= dy {error += dy; x += sx}
		if twice <= dx {error += dx; y += sy}
	}
	return cells[:]
}

paint_cell :: proc(viewer: ^Viewer_State, id: i32) {
	if highlighted(viewer, "cell", id) == !viewer.brush_erases {return}
	toggle_highlight(viewer, "cell", id)
}
