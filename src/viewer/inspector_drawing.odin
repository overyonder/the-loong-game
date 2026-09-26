package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Wrap every diagnostic, including packet fields, and scroll the complete
// inspector. No fixed ping count or clipped final records.
inspector_paragraph :: proc(
	viewer: ^Viewer_State,
	cursor: ^rl.Vector2,
	width: f32,
	text: string,
	color := TEXT_COLOR,
	kind := "",
	id: i32 = -1,
) {
	start := cursor.y
	line := ""
	for word in strings.split(text, " ", context.temp_allocator) {
		next := fmt.tprintf("%s%s%s", line, len(line) > 0 ? " " : "", word)
		if len(line) > 0 && measure_text(fmt.ctprintf("%s", next), 18) > i32(width) {
			draw_text(fmt.ctprintf("%s", line), i32(cursor.x), i32(cursor.y), 18, color)
			cursor.y += 23 * font_scale
			line = word
		} else {line = next}
	}
	draw_text(fmt.ctprintf("%s", line), i32(cursor.x), i32(cursor.y), 18, color)
	cursor.y += 27 * font_scale
	if kind != "" {
		r := rl.Rectangle{cursor.x, start, width, cursor.y - start}
		if highlighted(viewer, kind, id) {rl.DrawRectangleLinesEx(r, 2, COLOR_SELECTED)}
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {toggle_highlight(viewer, kind, id)}
	}
}

draw_memory_map :: proc(
	viewer: ^Viewer_State,
	turn: ^Dragon_Turn,
	cursor: ^rl.Vector2,
	width: f32,
) {
	export := &viewer.game.export
	g := board_geometry_for_area(export, {cursor.x, cursor.y, width, 220})
	for cell in 0 ..< export.width * export.height {rl.DrawRectangleRec(cell_rectangle(g, cell), COLOR_UNKNOWN)}
	for cell in turn.memory {
		if cell.cell < 0 || cell.cell >= export.width * export.height {continue}
		r := cell_rectangle(g, cell.cell)
		color := COLOR_CELL
		if cell.accuracy == "wrong" {color = rl.Color{150, 45, 40, 255}}
		if cell.accuracy == "partial" {color = rl.Color{115, 85, 40, 255}}
		rl.DrawRectangleRec(r, color)
		if !cell.topology_only &&
		   cell.pearl {rl.DrawCircleV(cell_center(g, cell.cell), g.cell_size * 0.25, COLOR_PEARL)}
		for edge, d in cell.edges {
			if edge.kind != 2 && edge.kind != 3 {continue}
			a := rl.Vector2{r.x, r.y}
			b := rl.Vector2{r.x + r.width, r.y}
			if d == 1 {a = {r.x + r.width, r.y}; b = {r.x + r.width, r.y + r.height}}
			if d == 2 {a = {r.x, r.y + r.height}; b = {r.x + r.width, r.y + r.height}}
			if d == 3 {b = {r.x, r.y + r.height}}
			rl.DrawLineEx(
				a,
				b,
				edge.confidence == 1 ? 1 : 2,
				edge.kind == 2 ? COLOR_KELP : COLOR_PORTAL,
			)
		}
	}
	for item in viewer.highlights {
		if item.kind ==
		   "cell" {rl.DrawRectangleLinesEx(cell_rectangle(g, item.id), 2, COLOR_SELECTED)}
	}
	if rl.IsMouseButtonPressed(.LEFT) &&
	   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
	   rl.CheckCollisionPointRec(
		   rl.GetMousePosition(),
		   {g.origin.x, g.origin.y, g.cell_size * f32(g.width), g.cell_size * f32(g.height)},
	   ) {
		cell := cell_at_point(g, rl.GetMousePosition())
		viewer.selected_cell = cell
		toggle_highlight(viewer, "cell", cell)
	}
	cursor.y += 228
}

draw_dragon_inspector :: proc(viewer: ^Viewer_State, area: rl.Rectangle, frame: i32) {
	viewer.inspector_area = area
	if rl.CheckCollisionPointRec(
		rl.GetMousePosition(),
		area,
	) {viewer.inspector_scroll = max(0, viewer.inspector_scroll - rl.GetMouseWheelMove() * 60)}
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	cursor := rl.Vector2{area.x, area.y - viewer.inspector_scroll}
	width := area.width - 8
	turn, found := selected_dragon_turn(&viewer.game, viewer.selected_dragon, frame)
	if !found {
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			"Right-click a dragon, or Tab to select. No decision for the selected dragon in this round.",
		)
		return
	}
	inspector_paragraph(
		viewer,
		&cursor,
		width,
		fmt.tprintf(
			"Dragon %d / round %d / length %d / action %s",
			turn.dragon,
			turn.round,
			turn.length,
			turn.action,
		),
	)
	inspector_paragraph(
		viewer,
		&cursor,
		width,
		"Yellow 7x7 outline: recorded pre-action observation at this dragon's turn, before its move. Board is truth; map below is recovered memory.",
		MUTED_TEXT_COLOR,
	)
	if turn.report_present {
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			turn.memory_source == "recorded" ? "RECORDED state trace from this replay" : turn.reliable ? "RECOVERED state: no action divergence so far; not historical memory proof" : "UNRELIABLE rerun: action divergence, missing trace or digest fault",
			turn.reliable ? TEXT_COLOR : WARNING_COLOR,
		)
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf("Regime %s / role %s / target %d", turn.regime, turn.role, turn.target),
			COLOR_SELECTED,
			"role",
			turn.dragon,
		)
		if turn.diagnostic.version > 0 {
			inspector_paragraph(
				viewer,
				&cursor,
				width,
				fmt.tprintf(
					"%s/%s -> %s/%s: %s",
					turn.diagnostic.previous_regime,
					turn.diagnostic.previous_role,
					turn.regime,
					turn.role,
					fmt.tprintf(
						"%s; target: %s",
						turn.diagnostic.reason,
						turn.diagnostic.target_reason,
					),
				),
				TEXT_COLOR,
				"regime",
				turn.dragon,
			)
		} else {
			inspector_paragraph(
				viewer,
				&cursor,
				width,
				fmt.tprintf(
					"Chosen plan score %.3f; exits %d, reachable space %d. These are plan metrics, NOT target or role scores. Legacy trace does not record transition reasons, candidates or planned path.",
					turn.score,
					turn.exits,
					turn.space,
				),
				WARNING_COLOR,
			)
		}
	} else {inspector_paragraph(
			viewer,
			&cursor,
			width,
			"Memory unavailable: no identified-build state trace. No inferred memory is shown.",
			WARNING_COLOR,
		)}
	inspector_paragraph(
		viewer,
		&cursor,
		width,
		"Bot memory: unknown cells black; remembered pearls gold; topology errors red / partial amber. Click cells to inspect.",
	)
	draw_memory_map(viewer, turn, &cursor, width)
	if viewer.selected_cell >= 0 {
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"Cell %d (%d,%d)",
				viewer.selected_cell,
				viewer.selected_cell % viewer.game.export.width,
				viewer.selected_cell / viewer.game.export.width,
			),
			COLOR_SELECTED,
		)
		known := false
		directions := "NESW"
		for cell in turn.memory {
			if cell.cell != viewer.selected_cell {continue}
			known = true
			if cell.topology_only {inspector_paragraph(viewer, &cursor, width, "Legacy topology only: pearl contents and timers were not dumped. Not filled from truth.", WARNING_COLOR)} else {
				inspector_paragraph(
					viewer,
					&cursor,
					width,
					fmt.tprintf(
						"Observed %v at r%d; remembered pearl %v at r%d; spawn due r%d / ESTIMATED period %d (-1 means not stored); pearl source %d; samples %d; geometry source %d at r%d. Reported origin is unverified.",
						cell.observed,
						cell.observed_round,
						cell.pearl,
						cell.pearl_round,
						cell.spawn_round,
						cell.spawn_period,
						cell.pearl_source,
						cell.spawn_samples,
						cell.source,
						cell.record_round,
					),
				)
			}
			for edge, d in cell.edges {inspector_paragraph(viewer, &cursor, width, fmt.tprintf("%c kind %d confidence %d source %d/r%d; destination %d source %d/r%d; portal %d", directions[d], edge.kind, edge.confidence, edge.source, edge.record_round, edge.destination, edge.destination_source, edge.destination_round, edge.portal), MUTED_TEXT_COLOR)}
		}
		if !known {inspector_paragraph(viewer, &cursor, width, "Unknown in recovered memory", MUTED_TEXT_COLOR)}
		for node in turn.diagnostic.search {
			if node.cell ==
			   viewer.selected_cell {inspector_paragraph(viewer, &cursor, width, fmt.tprintf("Search cost %d, utility %s. %s", node.cost, node.utility_evaluated ? fmt.tprintf("%.3f", node.utility) : "not evaluated", turn.diagnostic.search_objective))}
		}
	}
	if turn.diagnostic.version > 0 {
		for constraint in turn.diagnostic.sonar_constraints {inspector_paragraph(viewer, &cursor, width, fmt.tprintf("Bot tentative sonar constraint: origin %d direction %d round %d; conditional on unseen portals=%v", constraint.origin, constraint.direction, constraint.round, constraint.conditional_on_unseen_portals), WARNING_COLOR)}
		if turn.diagnostic.path_kind != "" {
			inspector_paragraph(
				viewer,
				&cursor,
				width,
				"Historical source stores no farm cycle/yield, lobe value or per-edge report origin. Spawn due is stored; spawn period is not.",
				MUTED_TEXT_COLOR,
			)
		} else {
			inspector_paragraph(
				viewer,
				&cursor,
				width,
				fmt.tprintf(
					"Farm cycle %v / ESTIMATED yield %.3f; lobe doors %v / ESTIMATED value %.3f; link partner %d",
					turn.diagnostic.farm.cycle,
					turn.diagnostic.farm.estimated_yield,
					turn.diagnostic.lobe.doors,
					turn.diagnostic.lobe.estimated_value,
					turn.diagnostic.link_partner,
				),
			)
		}
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"Coverage target %d / owned unknown %d / complete %v",
				turn.diagnostic.coverage.target,
				turn.diagnostic.coverage.owned_unknown,
				turn.diagnostic.coverage.complete,
			),
			TEXT_COLOR,
			"coverage",
			turn.dragon,
		)
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"Path %v (%s); %d settled search cells. %s",
				turn.diagnostic.path,
				turn.diagnostic.path_kind,
				len(turn.diagnostic.search),
				turn.diagnostic.search_objective,
			),
			TEXT_COLOR,
			"path",
			turn.dragon,
		)
		for candidate, index in turn.diagnostic.candidates {
			inspector_paragraph(
				viewer,
				&cursor,
				width,
				fmt.tprintf(
					"Candidate %v score %.3f risk %.3f survival %d/%d: %s",
					candidate.directions,
					candidate.score,
					candidate.risk,
					candidate.survival_depth,
					candidate.survival_horizon,
					candidate.reason,
				),
				TEXT_COLOR,
				"candidate",
				i32(index),
			)
		}
	}
	inspector_paragraph(
		viewer,
		&cursor,
		width,
		"All pings transmitted this round or delivered to this decision; blue hitscans, gold reflections. Scroll for every packet:",
	)
	for ping in viewer.game.export.pings {
		if !(ping.round == frame && (ping.sender == turn.dragon || ping.hit == turn.dragon) ||
			   ping.received_round == frame && ping.hit == turn.dragon) {continue}
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"#%d dragon %d %s -> %d (%s)%s; %s",
				ping.id,
				ping.sender,
				ping.direction,
				ping.hit,
				ping.protocol,
				ping.reflected ? " REFLECTED" : "",
				ping.value,
			),
			COLOR_SELECTED,
			"ping",
			ping.id,
		)
		inspector_paragraph(viewer, &cursor, width, ping.decoded)
		inspector_paragraph(
			viewer,
			&cursor,
			width,
			fmt.tprintf(
				"Sent round %d; received round %d; hit kind %d; receiver %s",
				ping.round,
				ping.received_round,
				ping.hit_kind,
				ping.acceptance,
			),
			MUTED_TEXT_COLOR,
		)
	}
	viewer.inspector_scroll = min(
		viewer.inspector_scroll,
		max(0, cursor.y + viewer.inspector_scroll - area.y - area.height + 24),
	)
}
