package viewer

import "core:fmt"
import "core:slice"
import "core:strings"

// Pairwise comparison of the knowledge bots annotate for consensus
// (diagnostics.md, Team consensus annotations), never board truth. Computed
// for the turn on screen from each living teammate's latest record.

Consensus_Row :: struct {
	category, status, details:                                          string,
	reporters, alive, pairs, overlapping_pairs, comparisons, conflicts: i32,
	// How widely the facts are shared: those any reporting dragon states,
	// those every one of them states, and the mean share each holds.
	known_any, known_all:                                               i32,
	mean_share:                                                         f32,
}

// A fact's key in its category's scope, and where it is drawn: the cell, and
// for an edge its side (N/E/S/W as 0..3), or -1 for a cell or a claim.
fact_key :: proc(scope: string, cell, direction, width, height: i32) -> (key: string, at, side: i32) {
	letters := "NESW"
	switch scope {
	case "singleton":
		return "claim", -1, -1
	case "cell":
		return fmt.tprintf("cell %d", cell), cell, -1
	case "directed_edge":
		return fmt.tprintf("cell %d %c", cell, letters[direction & 3]), cell, direction & 3
	}
	// A physical edge: N and S share the northern side, E and W the western,
	// across the torus seam too.
	x, y := cell % width, cell / width
	if direction == 1 {x = (x + 1) % width}
	if direction == 2 {y = (y + 1) % height}
	north := direction == 0 || direction == 2
	return fmt.tprintf("edge %d %c", y * width + x, north ? 'N' : 'W'), y * width + x, north ? 0 : 3
}

// A turn's consensus facts: category -> fact key -> the values stated for it.
Knowledge_Snapshot :: map[string]map[string][dynamic]string

knowledge_snapshot :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> Knowledge_Snapshot {
	snapshot := make(Knowledge_Snapshot, context.temp_allocator)
	if !turn.gizmo_reliable {return snapshot}
	width, height := game.view.width, game.view.height
	for &gizmo in turn.gizmos {
		for field in gizmo.consensus {
			if field.category not_in game.consensus_meanings {
				allocator := game_allocator(game)
				category := strings.clone(field.category, allocator)
				append(&game.consensus_categories, category)
				game.consensus_meanings[category] = strings.clone(gizmo.reason, allocator)
				game.consensus_singletons[category] = field.scope == "singleton"
				game.consensus_scopes[category] = strings.clone(field.scope, allocator)
			}
			if field.category not_in snapshot {snapshot[field.category] = make(map[string][dynamic]string, context.temp_allocator)}
			facts := &snapshot[field.category]
			for row, index in gizmo.rows {
				known, _ := parse_int_field(row, field.known_column)
				if known < field.minimum {continue}
				cell := index < len(gizmo.row_cells) ? gizmo.row_cells[index] : 0
				key, _, _ := fact_key(field.scope, cell, field.direction, width, height)
				if key not_in facts {facts[key] = make([dynamic]string, context.temp_allocator)}
				value := int(field.column) < len(row) ? row[field.column] : ""
				// `?` and an empty value state nothing, so they are not compared.
				if value == "?" || value == "" {continue}
				if !slice.contains(facts[key][:], value) {append(&facts[key], value)}
			}
		}
	}
	return snapshot
}

parse_int_field :: proc(row: []string, column: i32) -> (i32, bool) {
	if int(column) >= len(row) {return 0, false}
	value := 0
	negative := false
	text := row[column]
	for character, position in text {
		if position == 0 && character == '-' {negative = true; continue}
		if character < '0' || character > '9' {return 0, false}
		value = value * 10 + int(character - '0')
	}
	return i32(negative ? -value : value), len(text) > 0
}

// The team's consensus at the end of turn `index`: each living dragon's
// latest record at or before it, compared pair by pair in every category.
consensus_rows :: proc(game: ^Loaded_Game, index, team: int) -> []Consensus_Row {
	view := &game.view
	stop := index + 1 < len(view.turn_event) ? int(view.turn_event[index + 1]) : len(view.event_kind)
	board := board_after_events(game, &game.consensus_board, stop, false)
	alive := make([dynamic]i32, context.temp_allocator)
	for dragon in board.dragons {if int(dragon.team) == team {append(&alive, dragon.id)}}
	slice.sort(alive[:])
	Latest :: struct {
		snapshot: Knowledge_Snapshot,
		round:    i32,
	}
	latest := make(map[i32]Latest, context.temp_allocator)
	for dragon in alive {
		indices := game.turn_indices_by_dragon[dragon]
		for position := len(indices) - 1; position >= 0; position -= 1 {
			if indices[position] > index {continue}
			turn := opened_turn(game, indices[position])
			latest[dragon] = {knowledge_snapshot(game, turn), turn.round}
			break
		}
	}
	rows := make([dynamic]Consensus_Row, context.temp_allocator)
	for category in game.consensus_categories {
		singleton := game.consensus_singletons[category]
		reporters := make([dynamic]i32, context.temp_allocator)
		for dragon in alive {if entry, found := latest[dragon]; found && category in entry.snapshot {append(&reporters, dragon)}}
		if len(reporters) == 0 {continue}
		row := Consensus_Row {
			category  = category,
			reporters = i32(len(reporters)),
			alive     = i32(len(alive)),
			pairs     = i32(len(alive) * (len(alive) - 1) / 2),
		}
		witnesses := make([dynamic]string, context.temp_allocator)
		for first, position in reporters {
			for second in reporters[position + 1:] {
				left := &latest[first].snapshot[category]
				right := &latest[second].snapshot[category]
				keys := make([dynamic]string, context.temp_allocator)
				// A fact one of them leaves unstated, `?` or empty, isn't compared.
				for key, values in left {if len(values) > 0 && key in right && len(right[key]) > 0 {append(&keys, key)}}
				slice.sort(keys[:])
				if len(keys) > 0 {row.overlapping_pairs += 1}
				for key in keys {
					row.comparisons += 1
					a, b := left[key][:], right[key][:]
					slice.sort(a)
					slice.sort(b)
					if len(a) != 1 || len(b) != 1 || a[0] != b[0] {
						row.conflicts += 1
						if len(witnesses) < 30 {
							append(&witnesses, fmt.tprintf("D%d vs D%d, %s: %v vs %v", first, second, key, a, b))
						}
					}
				}
			}
		}
		// Reach: the facts any reporter states against those all of them do.
		holders := make(map[string]i32, context.temp_allocator)
		for dragon in reporters {
			for key, values in latest[dragon].snapshot[category] {if len(values) > 0 {holders[key] += 1}}
		}
		row.known_any = i32(len(holders))
		for _, count in holders {if count == i32(len(reporters)) {row.known_all += 1}}
		if row.known_any > 0 {
			for dragon in reporters {
				held := 0
				for _, values in latest[dragon].snapshot[category] {if len(values) > 0 {held += 1}}
				row.mean_share += f32(held) / f32(row.known_any) / f32(len(reporters))
			}
		}
		missing := false
		if singleton {for dragon in reporters {missing = missing || len(latest[dragon].snapshot[category]) == 0}}
		row.status =
			row.conflicts > 0 ? "DISAGREE" : len(reporters) != len(alive) || missing ? "INCOMPLETE" : row.comparisons == 0 ? "UNKNOWN" : "AGREE"
		details := strings.builder_make(context.temp_allocator)
		fmt.sbprint(&details, "Latest contributing turns:")
		for dragon, position in reporters {fmt.sbprintf(&details, "%s D%d: r%d", position > 0 ? "," : "", dragon, latest[dragon].round)}
		fmt.sbprint(&details, "\n")
		if singleton {
			for dragon in reporters {
				values := make([dynamic]string, context.temp_allocator)
				for key, stated in latest[dragon].snapshot[category] {if key == "claim" {append(&values, ..stated[:])}}
				fmt.sbprintf(&details, "D%d: %s\n", dragon, len(values) > 0 ? strings.join(values[:], ", ", context.temp_allocator) : "unknown")
			}
		}
		fmt.sbprint(&details, strings.join(witnesses[:], "\n", context.temp_allocator))
		if int(row.conflicts) > len(witnesses) {
			fmt.sbprintf(&details, "\n%d more conflicts (counted, not listed).", int(row.conflicts) - len(witnesses))
		}
		row.details = strings.to_string(details)
		append(&rows, row)
	}
	return rows[:]
}
