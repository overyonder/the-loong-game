package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The producer owns the alternatives, hierarchy, eligibility and calculations.
// This renderer only lays out the canonical records and their supplied outcomes.
draw_gizmo_tree_nodes :: proc(
	viewer: ^Viewer_State,
	turn: ^Dragon_Turn,
	gizmo: ^Gizmo,
	parent: string,
	cursor: ^rl.Vector2,
	width: f32,
	depth: int,
	parent_anchor: rl.Vector2 = {},
) {
	if depth > 128 {return}
	for node in gizmo.nodes {
		if node.parent != parent {continue}
		left := cursor.x + f32(depth) * 14
		available := max(60, width - f32(depth) * 14 - 8)
		eligibility, evaluated := node.eligible.(bool)
		score, scored := node.score.(f64)
		color :=
			node.active ? UI_ACCENT : evaluated && !eligibility ? WARNING_COLOR : MUTED_TEXT_COLOR
		state :=
			node.active ? "selected" : evaluated ? (eligibility ? "eligible" : "ineligible") : "not evaluated"
		// The objective names what the score measures, such as suitability.
		if scored {state = fmt.tprintf("%s / %s%.5g", state, node.objective != "" ? fmt.tprintf("%s ", node.objective) : "", score)}
		box := rl.Rectangle{left, cursor.y, available, 26}
		if depth > 0 {draw_graph_curve(parent_anchor, {left + 4, cursor.y + 13}, 1, color)}
		if viewer.gizmo_selection == node.id {rl.DrawRectangleRec(box, rl.Color{43, 51, 63, 255})}
		rl.DrawRectangleLinesEx(box, node.active ? 2 : 1, color)
		// The state and score take what the label leaves, the label at least a third.
		label_width := min(f32(measure_text(fmt.ctprintf("%s", node.label), UI_TEXT)), available / 3)
		state_width := min(f32(measure_text(fmt.ctprintf("%s", state), UI_TEXT)), available - label_width - 24)
		clipped_text(node.label, left + 8, cursor.y + 4, available - state_width - 24, color)
		clipped_text(state, left + available - state_width - 8, cursor.y + 4, state_width, color)
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), box) {
			delete(viewer.gizmo_selection)
			viewer.gizmo_selection = strings.clone(node.id)
		}
		cursor.y += 30
		if gizmo_selection_within(turn, viewer.gizmo_selection, node.id) {
			saved_x := cursor.x
			cursor.x = left + 12
			if node.reason != "" {inspector_paragraph(viewer, cursor, available - 20, node.reason)}
			draw_gizmo_children(viewer, turn, node.id, cursor, available - 20)
			cursor.x = saved_x
		}
		draw_gizmo_tree_nodes(
			viewer,
			turn,
			gizmo,
			node.id,
			cursor,
			width,
			depth + 1,
			{left + 4, box.y + box.height},
		)
	}
}

draw_gizmo_calculation :: proc(
	viewer: ^Viewer_State,
	gizmo: ^Gizmo,
	cursor: ^rl.Vector2,
	width: f32,
) {
	inspector_paragraph(viewer, cursor, width, gizmo.expression, UI_ACCENT)
	for operand in gizmo.operands {
		clipped_text(operand.name, cursor.x + 8, cursor.y, width * 0.65 - 8)
		clipped_text(
			fmt.tprintf("%.6g", operand.value),
			cursor.x + width * 0.65,
			cursor.y,
			width * 0.35,
		)
		cursor.y += 24
	}
	value, present := gizmo.result.(f64)
	inspector_paragraph(
		viewer,
		cursor,
		width,
		present ? fmt.tprintf("Result = %.6g", value) : "Not evaluated",
		present ? TEXT_COLOR : MUTED_TEXT_COLOR,
	)
}

draw_generic_inspector :: proc(viewer: ^Viewer_State, area: rl.Rectangle, turn: ^Dragon_Turn) {
	viewer.inspector_area = area
	// The expand button leads the row and three tabs fill the rest; the open tab
	// is underlined in gold.
	h := f32(CONTROL_HEIGHT)
	draw_expand_button(viewer, {area.x, area.y, h, h})
	tabs_x := area.x + h + 3
	tab_width := (area.x + area.width - tabs_x - 2 * 3) / 3
	tabs := [3]cstring{"Brain", "Signals", "Sources"}
	open := viewer.generic_memory_tab ? 2 : viewer.generic_signals_tab ? 1 : 0
	for label, index in tabs {
		tab := rl.Rectangle{tabs_x + f32(index) * (tab_width + 3), area.y, tab_width, h}
		if index == open {rl.DrawRectangleRec({tab.x, tab.y + h + 1, tab.width, 2}, UI_ACCENT)}
		if !rl.GuiButton(tab, label) {continue}
		viewer.generic_signals_tab = index == 1
		viewer.generic_memory_tab = index == 2
		viewer.inspector_scroll = 0
	}
	// A band under the tabs says whether the records explain a decision about
	// to be made on this board or one whose result the board shows.
	phase := focused_decision_phase(viewer)
	band := rl.Rectangle{area.x, area.y + h + 8, area.width, h}
	band_color := [Decision_Phase]rl.Color {
		.Waiting  = MUTED_TEXT_COLOR,
		.Deciding = UI_ACCENT,
		.Decided  = DECIDED_COLOR,
	}
	rl.DrawRectangleRec(band, rl.Fade(band_color[phase], 0.18))
	rl.DrawRectangleRec({band.x, band.y, 4, band.height}, band_color[phase])
	band_text: string
	switch phase {
	case .Waiting:
		band_text = fmt.tprintf("R%d waiting", turn.round)
	case .Deciding:
		band_text = fmt.tprintf("R%d deciding %s", turn.round, turn.action)
	case .Decided:
		band_text = fmt.tprintf("R%d decided %s", turn.round, turn.action)
	}
	clipped_text(band_text, band.x + 12, band.y + (h - UI_TEXT) / 2, band.width - 18, band_color[phase])
	body := rl.Rectangle{area.x, band.y + h + 6, area.width, area.y + area.height - band.y - h - 6}
	if !viewer.detail_open &&
	   !viewer.gizmo_graph_hovered &&
	   rl.CheckCollisionPointRec(rl.GetMousePosition(), body) {
		viewer.inspector_scroll = clamp(
			viewer.inspector_scroll - rl.GetMouseWheelMove() * 60,
			0,
			viewer.inspector_scroll_limit,
		)
	}
	viewer.gizmo_graph_hovered = false
	rl.BeginScissorMode(i32(body.x), i32(body.y), i32(body.width), i32(body.height))
	viewer.inspector_clip = body
	defer rl.EndScissorMode()
	cursor := rl.Vector2{body.x + 6, body.y + 6 - viewer.inspector_scroll}
	// Every tab stays empty until the dragon's turn, so none runs ahead of the
	// board.
	if phase == .Waiting {
		finish_scroll_section(&viewer.inspector_scroll, &viewer.inspector_scroll_limit, body, 0)
		return
	}
	if !turn.gizmo_reliable {
		inspector_paragraph(
			viewer,
			&cursor,
			body.width - 18,
			"Diagnostics do not match the replay",
			WARNING_COLOR,
		)
	} else {
		if turn.recovery_pending {
			inspector_paragraph(viewer, &cursor, body.width - 18, recovery_notice(viewer, turn), UI_ACCENT)
		} else if len(turn.gizmos) == 0 {
			inspector_paragraph(viewer, &cursor, body.width - 18, "No diagnostics recorded", MUTED_TEXT_COLOR)
			// The recovery's note on this dragon's build, such as a refusal to recover it.
			if turn.build_status != "" {inspector_paragraph(viewer, &cursor, body.width - 18, fmt.tprintf("Build: %s", turn.build_status), MUTED_TEXT_COLOR)}
		}
		for error in turn.gizmo_errors {inspector_paragraph(viewer, &cursor, body.width - 18, error, WARNING_COLOR)}
	}
	// Signals opens with this turn's pings, joined with both ends' sonar
	// tables, so those tables aren't listed again among its root records.
	if viewer.generic_signals_tab {draw_radio(viewer, &cursor, body.width - 18, turn)}
	if turn.gizmo_reliable {
		slot := viewer.generic_memory_tab ? "memory" : viewer.generic_signals_tab ? "" : "brain"
		found := false
		for gizmo in turn.gizmos {if gizmo.parent == "" && gizmo.slot == slot && gizmo.sonar.role == "" {found = true}}
		rejected := false
		for name in turn.gizmo_rejected_slots {rejected = rejected || name == slot}
		if !found && rejected {
			inspector_paragraph(
				viewer,
				&cursor,
				body.width - 18,
				fmt.tprintf("%s root rejected", slot),
				WARNING_COLOR,
			)
		} else if !found && !turn.recovery_pending {inspector_paragraph(viewer, &cursor, body.width - 18, viewer.generic_memory_tab ? "No sources recorded" : viewer.generic_signals_tab ? "No other signals supplied" : "No Brain view supplied", MUTED_TEXT_COLOR)}
		draw_gizmo_children(viewer, turn, "", &cursor, body.width - 18, slot)
	}
	finish_scroll_section(
		&viewer.inspector_scroll,
		&viewer.inspector_scroll_limit,
		body,
		max(0, cursor.y + viewer.inspector_scroll - body.y - body.height + 12),
	)
}

draw_gizmo_panel :: proc(viewer: ^Viewer_State) {
	if !viewer.brain_open {return}
	area := rl.Rectangle {
		30,
		20,
		f32(rl.GetScreenWidth()) - 60,
		f32(rl.GetScreenHeight()) - BOTTOM_BAR_HEIGHT * viewer.scale - 36,
	}
	rl.DrawRectangleRec(area, BACKGROUND)
	rl.DrawRectangleLinesEx(area, 1, UI_ACCENT)
	turn, found := focused_dragon_turn(viewer, current_frame(viewer))
	if !found {
		h := f32(CONTROL_HEIGHT)
		draw_expand_button(viewer, {area.x + 12, area.y + 12, h, h})
		clipped_text("No decision at this round", area.x + 18 + h, area.y + 12 + (h - UI_TEXT) / 2, area.width - 30 - h)
		return
	}
	draw_generic_inspector(
		viewer,
		{area.x + 12, area.y + 12, area.width - 24, area.height - 24},
		turn,
	)
}

// Keep ancestors expanded when a nested attachment is selected.
gizmo_selection_within :: proc(turn: ^Dragon_Turn, selection, ancestor: string) -> bool {
	current := selection
	for _ in 0 ..< 128 {
		if current == "" {return false}
		if current == ancestor {return true}
		parent := ""
		for gizmo in turn.gizmos {
			if gizmo.id == current {parent = gizmo.parent; break}
			for node in gizmo.nodes {
				if node.id == current {parent = node.parent != "" ? node.parent : gizmo.id; break}
			}
			for row_id in gizmo.row_ids {if row_id == current {parent = gizmo.id; break}}
			if parent != "" {break}
		}
		current = parent
	}
	return false
}

// Expands the inspector over the board, or collapses it back into the
// sidebar, as B does: a left arrow while in the sidebar, a right arrow while
// expanded.
draw_expand_button :: proc(viewer: ^Viewer_State, button: rl.Rectangle) {
	pressed := rl.GuiButton(button, "")
	centre := rl.Vector2{button.x + button.width / 2, button.y + button.height / 2}
	reach := button.height * 0.22
	point: f32 = viewer.brain_open ? 1 : -1
	tip := centre + {point * reach, 0}
	rl.DrawLineEx(tip, centre + {-point * reach, -reach * 1.4}, 2, UI_ACCENT)
	rl.DrawLineEx(tip, centre + {-point * reach, reach * 1.4}, 2, UI_ACCENT)
	if pressed {viewer.brain_open = !viewer.brain_open}
}
