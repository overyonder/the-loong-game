package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// A consensus category drawn as a board: each fact where it lies, green where
// every dragon stating it agrees, red where any disagree and grey where one
// dragon alone states it, stronger the more dragons state it. Clicking a cell
// lists each dragon's value for it and where that dragon learned it.

Belief_Statement :: struct {
	dragon:               i32,
	value, source, round: string,
}
Belief_Fact :: struct {
	at, side:   i32, // the cell, and an edge's side or -1 (fact_key)
	statements: [dynamic]Belief_Statement,
}
// Which belief the detail dialog maps, at which turn and for which team.
Belief_Map_View :: struct {
	category:   string,
	index, team: int,
	cell:       i32,
}

// Every fact of `category` the team's living dragons state at the end of
// turn `index`, each from its latest record, and how many dragons report it.
belief_facts :: proc(game: ^Loaded_Game, index, team: int, category: string) -> (facts: map[string]Belief_Fact, reporters: int) {
	facts = make(map[string]Belief_Fact, context.temp_allocator)
	view := &game.view
	stop := index + 1 < len(view.turn_event) ? int(view.turn_event[index + 1]) : len(view.event_kind)
	board := board_after_events(game, &game.consensus_board, stop, false)
	width, height := view.width, view.height
	for dragon in board.dragons {
		if int(dragon.team) != team {continue}
		indices := game.turn_indices_by_dragon[dragon.id]
		turn: ^Dragon_Turn
		for position := len(indices) - 1; position >= 0; position -= 1 {
			if indices[position] <= index {turn = opened_turn(game, indices[position]); break}
		}
		if turn == nil || !turn.has_record || !turn.gizmo_reliable {continue}
		reported := false
		for &gizmo in turn.gizmos {
			for field in gizmo.consensus {
				if field.category != category {continue}
				reported = true
				source_column, round_column := fact_columns(&gizmo, field.column)
				for row, position in gizmo.rows {
					known, _ := parse_int_field(row, field.known_column)
					if known < field.minimum {continue}
					value := int(field.column) < len(row) ? row[field.column] : ""
					if value == "?" || value == "" {continue}
					cell := position < len(gizmo.row_cells) ? gizmo.row_cells[position] : 0
					key, at, side := fact_key(field.scope, cell, field.direction, width, height)
					if key not_in facts {facts[key] = {at = at, side = side, statements = make([dynamic]Belief_Statement, context.temp_allocator)}}
					fact := &facts[key]
					append(&fact.statements, Belief_Statement{
						dragon = dragon.id,
						value  = value,
						source = source_column >= 0 && source_column < len(row) ? row[source_column] : "",
						round  = round_column >= 0 && round_column < len(row) ? row[round_column] : "",
					})
				}
			}
		}
		if reported {reporters += 1}
	}
	return
}

// A belief column's source and round columns: `FACT.source` and `FACT.round`
// for the fact named before its first `.`, after any `belief: ` prefix
// (diagnostics.md), or -1.
fact_columns :: proc(gizmo: ^Gizmo, column: i32) -> (source, round: int) {
	source, round = -1, -1
	if int(column) >= len(gizmo.columns) {return}
	name := strings.trim_prefix(gizmo.columns[column], "belief: ")
	if dot := strings.index_byte(name, '.'); dot >= 0 {name = name[:dot]}
	for other, position in gizmo.columns {
		if other == fmt.tprintf("%s.source", name) {source = position}
		if other == fmt.tprintf("%s.round", name) {round = position}
	}
	return
}

// Agreement on one fact: every statement the same, or one dragon alone.
fact_color :: proc(fact: Belief_Fact, reporters: int) -> rl.Color {
	color := MUTED_TEXT_COLOR
	if len(fact.statements) > 1 {
		color = COLOR_CORRECT
		for statement in fact.statements[1:] {if statement.value != fact.statements[0].value {color = COLOR_WRONG}}
	}
	share := f32(len(fact.statements)) / f32(max(1, reporters))
	return rl.Fade(color, 0.25 + 0.75 * share)
}

// The map and, beside it, the selected cell's statements and then `text`.
draw_belief_map :: proc(viewer: ^Viewer_State, area: rl.Rectangle, text: string) {
	request := &viewer.detail_map
	facts, reporters := belief_facts(&viewer.game, request.index, request.team, request.category)
	side := min(area.height, area.width * 0.55)
	map_area := rl.Rectangle{area.x, area.y, side, side}
	geometry := board_geometry_for_area(&viewer.game.view, map_area)
	rl.DrawRectangleRec({geometry.origin.x, geometry.origin.y, geometry.cell_size * f32(geometry.columns), geometry.cell_size * f32(geometry.rows)}, COLOR_CELL)
	for _, fact in facts {
		if fact.at < 0 {continue}
		color := fact_color(fact, reporters)
		r := cell_rectangle(geometry, fact.at)
		switch fact.side {
		case -1:
			rl.DrawRectangleRec(r, color)
		case 0:
			rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y}, 3, color)
		case 1:
			rl.DrawLineEx({r.x + r.width, r.y}, {r.x + r.width, r.y + r.height}, 3, color)
		case 2:
			rl.DrawLineEx({r.x, r.y + r.height}, {r.x + r.width, r.y + r.height}, 3, color)
		case 3:
			rl.DrawLineEx({r.x, r.y}, {r.x, r.y + r.height}, 3, color)
		}
	}
	if request.cell >= 0 {rl.DrawRectangleLinesEx(cell_rectangle(geometry, request.cell), 2, COLOR_SELECTED)}
	if rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(rl.GetMousePosition(), map_area) {
		request.cell = cell_at_point(geometry, rl.GetMousePosition())
	}
	// The statements about the selected cell and its sides, then the summary.
	body := rl.Rectangle{area.x + side + 16, area.y, area.width - side - 16, area.height}
	rl.BeginScissorMode(i32(body.x), i32(body.y), i32(body.width), i32(body.height))
	if rl.CheckCollisionPointRec(rl.GetMousePosition(), body) {
		viewer.detail_scroll = clamp(viewer.detail_scroll - rl.GetMouseWheelMove() * 60, 0, viewer.detail_scroll_limit)
	}
	cursor := rl.Vector2{body.x, body.y - viewer.detail_scroll}
	if request.cell >= 0 {
		width := viewer.game.view.width
		inspector_paragraph(viewer, &cursor, body.width - 12, fmt.tprintf("Cell (%d,%d)", request.cell % width, request.cell / width), UI_ACCENT)
		keys := make([dynamic]string, context.temp_allocator)
		for key, fact in facts {
			if fact.at == request.cell || fact.side >= 0 && edge_touches(fact, request.cell, viewer.game.view.width, viewer.game.view.height) {append(&keys, key)}
		}
		slice.sort(keys[:])
		if len(keys) == 0 {inspector_paragraph(viewer, &cursor, body.width - 12, "No dragon states it", MUTED_TEXT_COLOR)}
		for key in keys {
			fact := facts[key]
			place := fmt.tprintf("(%d,%d)", fact.at % width, fact.at / width)
			if fact.side >= 0 {place = fmt.tprintf("%s %s side", place, DIRECTION_NAMES[fact.side])}
			inspector_paragraph(viewer, &cursor, body.width - 12, fmt.tprintf("%s: %d of %d dragons", place, len(fact.statements), reporters), fact_color(fact, 1))
			for statement in fact.statements {
				learned := statement.source
				if statement.round != "" {learned = fmt.tprintf("%s, r%s", learned, statement.round)}
				inspector_paragraph(viewer, &cursor, body.width - 12, fmt.tprintf("D%d: %s%s", statement.dragon, statement.value, learned != "" ? fmt.tprintf(" (%s)", learned) : ""))
			}
		}
		cursor.y += 8
	}
	for line in strings.split(text, "\n", context.temp_allocator) {inspector_paragraph(viewer, &cursor, body.width - 12, line)}
	finish_scroll_section(&viewer.detail_scroll, &viewer.detail_scroll_limit, body, max(0, cursor.y + viewer.detail_scroll - body.y - body.height + 12))
	rl.EndScissorMode()
}

// Whether an edge fact lies on a side of `cell`: its own cell's, or the
// neighbouring cell's shared side.
edge_touches :: proc(fact: Belief_Fact, cell, width, height: i32) -> bool {
	x, y := fact.at % width, fact.at / width
	switch fact.side {
	case 0:
		return cell == ((y + height - 1) % height) * width + x
	case 1:
		return cell == y * width + (x + 1) % width
	case 2:
		return cell == ((y + 1) % height) * width + x
	case 3:
		return cell == y * width + (x + width - 1) % width
	}
	return false
}
