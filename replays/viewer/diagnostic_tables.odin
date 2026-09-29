package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

open_diagnostic_detail :: proc(viewer: ^Viewer_State, title, text: string) {
	delete(viewer.detail_title)
	delete(viewer.detail_text)
	viewer.detail_title = strings.clone(title)
	viewer.detail_text = strings.clone(text)
	viewer.detail_open = true
	viewer.detail_scroll = 0
	viewer.detail_map = {cell = -1}
	viewer.playback.playing = false
}

draw_diagnostic_table :: proc(
	viewer: ^Viewer_State,
	turn: ^Dragon_Turn,
	gizmo: ^Gizmo,
	gizmo_index: int,
	cursor: ^rl.Vector2,
	width: f32,
) {
	if len(gizmo.row_cells) > 0 {
		if viewer.selected_cell < 0 {
			inspector_paragraph(
				viewer,
				cursor,
				width,
				fmt.tprintf(
					"%d cells; select one",
					len(gizmo.rows),
				),
				MUTED_TEXT_COLOR,
			)
			return
		}
		found := false
		for row, index in gizmo.rows {
			if gizmo.row_cells[index] != viewer.selected_cell {continue}
			found = true
			// Edge, pearl and spawn beliefs are drawn on the board (mental map and
			// timers), so only the facts behind them are listed.
			for value, column in row {
				if column < len(gizmo.truth_columns) {
					quantity := gizmo.truth_columns[column]
					if quantity == "edges" || quantity == "pearl" || quantity == "spawn_due" {continue}
				}
				inspector_paragraph(
					viewer,
					cursor,
					width,
					fmt.tprintf("%s: %s", gizmo.columns[column], value),
				)
			}
			if index < len(gizmo.row_ids) {
				draw_gizmo_children(viewer, turn, gizmo.row_ids[index], cursor, width)
			}
		}
		if !found {inspector_paragraph(viewer, cursor, width, "Selected cell has no record in this table", MUTED_TEXT_COLOR)}
		return
	}
	if len(gizmo.columns) == 0 {return}
	// Each column as wide as its widest entry, within bounds. Spare width is
	// shared out, and a table wider than the pane scrolls sideways.
	widths := make([]f32, len(gizmo.columns), context.temp_allocator)
	for name, column in gizmo.columns {widths[column] = f32(measure_text(fmt.ctprintf("%s", name), UI_TEXT))}
	for row, position in gizmo.rows {
		if position >= 200 {break}
		for value, column in row {
			if column < len(widths) {widths[column] = max(widths[column], f32(measure_text(fmt.ctprintf("%s", value), UI_TEXT)))}
		}
	}
	total: f32 = 0
	for &column_width in widths {column_width = clamp(column_width + 12, 36, 320); total += column_width}
	if total < width {
		for &column_width in widths {column_width += (width - total) / f32(len(widths))}
		total = width
	}
	pan := &viewer.gizmo_graph_pan[gizmo_index]
	overflow := max(0, total - width)
	if overflow > 0 {
		rl.GuiSliderBar({cursor.x, cursor.y, width, 12}, "", "", pan, 0, overflow)
		cursor.y += 18
	}
	pan^ = clamp(pan^, 0, overflow)
	lefts := make([]f32, len(widths), context.temp_allocator)
	left := cursor.x - pan^
	for column in 0 ..< len(widths) {lefts[column] = left; left += widths[column]}
	// Only the table's own width is drawn into while it scrolls.
	clip :: proc(viewer: ^Viewer_State, x, width: f32, overflow: f32) {
		if overflow <= 0 {return}
		area := viewer.inspector_clip
		left := max(area.x, x)
		right := min(area.x + area.width, x + width)
		rl.BeginScissorMode(i32(left), i32(area.y), i32(max(0, right - left)), i32(area.height))
	}
	unclip :: proc(viewer: ^Viewer_State, overflow: f32) {
		if overflow <= 0 {return}
		area := viewer.inspector_clip
		rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	}
	if overflow > 0 &&
	   rl.CheckCollisionPointRec(rl.GetMousePosition(), {cursor.x, cursor.y, width, 28 * f32(len(gizmo.rows) + 1)}) {
		pan^ = clamp(pan^ - rl.GetMouseWheelMoveV().x * 60, 0, overflow)
	}
	clip(viewer, cursor.x, width, overflow)
	for name, column in gizmo.columns {clipped_text(name, lefts[column] + 4, cursor.y, widths[column] - 8, UI_ACCENT)}
	unclip(viewer, overflow)
	cursor.y += 28
	for row, index in gizmo.rows {
		state := index < len(gizmo.row_states) ? gizmo.row_states[index] : ""
		color :=
			state == "selected" ? UI_ACCENT : state == "ineligible" ? WARNING_COLOR : state == "not_evaluated" ? MUTED_TEXT_COLOR : TEXT_COLOR
		box := rl.Rectangle{cursor.x, cursor.y, width, 26}
		rl.DrawRectangleLinesEx(box, state == "selected" ? 2 : 1, rl.Color{68, 78, 74, 255})
		detail := ""
		clip(viewer, cursor.x, width, overflow)
		for value, column in row {
			if column >= len(widths) {break}
			clipped_text(value, lefts[column] + 4, cursor.y + 4, widths[column] - 8, color)
			detail = fmt.tprintf("%s%s: %s\n", detail, gizmo.columns[column], value)
		}
		unclip(viewer, overflow)
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), box) {
			if index < len(gizmo.row_ids) {
				delete(viewer.gizmo_selection)
				viewer.gizmo_selection = strings.clone(gizmo.row_ids[index])
			} else {
				open_diagnostic_detail(viewer, gizmo.label, fmt.tprintf("%s\n%s", state, detail))
			}
		}
		cursor.y += 28
		if index < len(gizmo.row_ids) &&
		   gizmo_selection_within(turn, viewer.gizmo_selection, gizmo.row_ids[index]) {
			cursor.x += 12
			// A selectable row must still expose values clipped by its cells,
			// including leaf rows which have no attached gizmos.
			for value, column in row {
				if column < len(widths) && measure_text(fmt.ctprintf("%s", value), UI_TEXT) > i32(widths[column] - 8) {
					inspector_paragraph(viewer, cursor, width - 12,
						fmt.tprintf("%s: %s", gizmo.columns[column], value))
				}
			}
			draw_gizmo_children(viewer, turn, gizmo.row_ids[index], cursor, width - 12)
			cursor.x -= 12
		}
	}

}

draw_diagnostic_detail_dialog :: proc(viewer: ^Viewer_State) {
	if !viewer.detail_open {return}
	mapped := viewer.detail_map.category != ""
	width := min(f32(rl.GetScreenWidth()) - 80, mapped ? 1500 : 850)
	height := min(f32(rl.GetScreenHeight()) - 80, mapped ? 950 : 650)
	area := rl.Rectangle {
		(f32(rl.GetScreenWidth()) - width) / 2,
		(f32(rl.GetScreenHeight()) - height) / 2,
		width,
		height,
	}
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, 160})
	rl.DrawRectangleRec(area, BACKGROUND)
	rl.DrawRectangleLinesEx(area, 2, UI_ACCENT)
	draw_text(
		fmt.ctprintf("%s", viewer.detail_title),
		i32(area.x + 16),
		i32(area.y + 16),
		UI_TEXT + 4,
		TEXT_COLOR,
	)
	if rl.GuiButton({area.x + area.width - 90, area.y + 12, 75, CONTROL_HEIGHT}, "Close") ||
	   rl.IsKeyPressed(.ESCAPE) {viewer.detail_open = false}
	if mapped {
		draw_belief_map(viewer, {area.x + 16, area.y + 55, area.width - 32, area.height - 70}, viewer.detail_text)
		return
	}
	rl.BeginScissorMode(
		i32(area.x + 12),
		i32(area.y + 50),
		i32(area.width - 24),
		i32(area.height - 60),
	)
	viewer.detail_scroll = clamp(
		viewer.detail_scroll - rl.GetMouseWheelMove() * 60,
		0,
		viewer.detail_scroll_limit,
	)
	cursor := rl.Vector2{area.x + 16, area.y + 55 - viewer.detail_scroll}
	for line in strings.split(viewer.detail_text, "\n", context.temp_allocator) {
		inspector_paragraph(viewer, &cursor, area.width - 40, line)
	}
	finish_scroll_section(
		&viewer.detail_scroll,
		&viewer.detail_scroll_limit,
		{area.x + 12, area.y + 50, area.width - 24, area.height - 60},
		max(0, cursor.y + viewer.detail_scroll - area.y - area.height + 20),
	)
	rl.EndScissorMode()
}
