package viewer

import "core:fmt"
import "core:strconv"
import "core:strings"

// Bots' own sonar records joined with the replay's pings (diagnostics.md,
// Sonar records). The replay knows who sent each value and whom it hit; only
// the sender's record says what it means, and only the receiver's what it did
// with it. The receiver's memory rows for the cells a message names, before
// and after that turn, let its uptake be checked against its memory rather
// than taken on its word. No codec lives here.

// A receiver still on legacy input (before its PROTOCOL 3 takes effect, so
// always on its first turn) is not delivered values of 2^32 or more.
LEGACY_VALUE_LIMIT :: u64(1) << 32

Sonar_Row :: struct {
	value, meaning, outcome: string,
	cells:                   []i32,
}

// The dragon's turn in `round`, if it took one.
dragon_turn_in_round :: proc(game: ^Loaded_Game, dragon, round: i32) -> (int, bool) {
	indices, found := game.turn_indices_by_dragon[dragon]
	if !found {return -1, false}
	for index in indices {
		if i32(game.view.turn_round[index]) == round {return index, true}
		if i32(game.view.turn_round[index]) > round {break}
	}
	return -1, false
}

sonar_rows :: proc(turn: ^Dragon_Turn, role: string) -> []Sonar_Row {
	rows := make([dynamic]Sonar_Row, context.temp_allocator)
	if !turn.gizmo_reliable {return rows[:]}
	for &gizmo in turn.gizmos {
		annotation := gizmo.sonar
		if annotation.role != role {continue}
		for row in gizmo.rows {
			entry := Sonar_Row {
				value   = row[annotation.value_column],
				meaning = row[annotation.meaning_column],
			}
			if column, present := annotation.outcome_column.(i32); present {entry.outcome = row[column]}
			if column, present := annotation.cells_column.(i32); present {
				cells := make([dynamic]i32, context.temp_allocator)
				for part in strings.fields(row[column], context.temp_allocator) {
					if number, ok := strconv.parse_int(part); ok {append(&cells, i32(number))}
				}
				entry.cells = cells[:]
			}
			append(&rows, entry)
		}
	}
	return rows[:]
}

legacy_input :: proc(turn: ^Dragon_Turn) -> bool {
	// Recorded turns carry no input protocol; they read the current protocol.
	return turn.gizmo_input_protocol != 0 && turn.gizmo_input_protocol < 3
}

// Fill the ping's sender meaning, and its receiver's meaning, outcome and
// memory evidence, from both ends' records.
join_ping :: proc(game: ^Loaded_Game, ping: ^Game_Ping) {
	if sender, found := dragon_turn_in_round(game, ping.sender, ping.round); found {
		for row in sonar_rows(opened_turn(game, sender), "sent") {
			if row.value == ping.value {ping.decoded = row.meaning; break}
		}
	}
	if ping.hit < 0 || ping.received_round < 0 {return}
	index, found := dragon_turn_in_round(game, ping.hit, ping.received_round)
	if !found {return}
	receiver := opened_turn(game, index)
	value, _ := strconv.parse_u64(ping.value)
	if legacy_input(receiver) && value >= LEGACY_VALUE_LIMIT {
		ping.received_round = -1
		ping.acceptance = "dropped by the engine: the receiver's input was still legacy protocol, which drops values of 2^32 or more"
		return
	}
	// Earlier pings of the same value to this turn each took one row first.
	taken := 0
	start, _ := ping_rows_of_rounds(game, ping.received_round - 1, ping.received_round)
	for row in start ..< int(ping.id) {
		view := &game.view
		if view.ping_hit[row] == ping.hit &&
		   view.ping_received_round[row] == ping.received_round &&
		   fmt.tprintf("%d", view.ping_value[row]) == ping.value {taken += 1}
	}
	for row in sonar_rows(receiver, "received") {
		if row.value != ping.value {continue}
		if taken > 0 {taken -= 1; continue}
		ping.receiver_meaning = row.meaning
		ping.acceptance = row.outcome != "" ? row.outcome : "no outcome recorded"
		earlier: ^Dragon_Turn
		if before, has_before := dragon_turn_before(game, index); has_before {earlier = opened_turn(game, before)}
		ping.memory_evidence = uptake(row.cells, earlier, receiver)
		return
	}
	if receiver.gizmo_reliable {
		has_records := false
		for gizmo in receiver.gizmos {has_records = has_records || gizmo.sonar.role != ""}
		ping.acceptance = has_records ? "receiver recorded no handling of this value" : "not reported"
	}
}

// The dragon's turn before `index`, if any.
dragon_turn_before :: proc(game: ^Loaded_Game, index: int) -> (int, bool) {
	indices := game.turn_indices_by_dragon[i32(game.view.turn_dragon[index])]
	for position in 1 ..< len(indices) {if indices[position] == index {return indices[position - 1], true}}
	return -1, false
}

// The turn's memory table by cell: the graded mental map, else the Memory slot.
memory_rows :: proc(turn: ^Dragon_Turn) -> (columns: []string, rows: map[i32][]string) {
	rows = make(map[i32][]string, context.temp_allocator)
	if turn == nil || !turn.gizmo_reliable {return}
	table: ^Gizmo
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" || len(gizmo.row_cells) == 0 {continue}
		graded := false
		for quantity in gizmo.truth_columns {graded = graded || quantity == "edges" || quantity == "pearl"}
		if graded {table = &gizmo; break}
		if table == nil && gizmo.slot == "memory" {table = &gizmo}
	}
	if table == nil {return}
	for cell, index in table.row_cells {if index < len(table.rows) {rows[cell] = table.rows[index]}}
	return table.columns, rows
}

uptake :: proc(cells: []i32, before, after: ^Dragon_Turn) -> string {
	if len(cells) == 0 {return ""}
	if after == nil {return "Receiver memory not recorded this turn"}
	columns, now := memory_rows(after)
	_, earlier := memory_rows(before)
	if len(columns) == 0 {return "Receiver records no memory table"}
	summary :: proc(columns, row: []string) -> string {
		parts := make([dynamic]string, context.temp_allocator)
		for name, index in columns {if index < len(row) {append(&parts, fmt.tprintf("%s %s", name, row[index]))}}
		return strings.join(parts[:], ", ", context.temp_allocator)
	}
	same :: proc(a, b: []string) -> bool {
		if len(a) != len(b) {return false}
		for value, index in a {if value != b[index] {return false}}
		return true
	}
	lines := make([dynamic]string, context.temp_allocator)
	for cell in cells {
		old, had := earlier[cell]
		new, has := now[cell]
		if !has {
			append(&lines, fmt.tprintf("cell %d: no memory row", cell))
		} else if had && same(old, new) {
			append(&lines, fmt.tprintf("cell %d: unchanged, %s", cell, summary(columns, new)))
		} else {
			append(&lines, fmt.tprintf("cell %d: %s -> %s", cell, had ? summary(columns, old) : "no row", summary(columns, new)))
		}
	}
	return strings.join(lines[:], "; ", context.temp_allocator)
}

// The turn's sonar records that match no ping: sends the replay never
// transmitted, and receipts no delivered ping accounts for.
radio_errors :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> []string {
	errors := make([dynamic]string, context.temp_allocator)
	start, stop := ping_rows_of_rounds(game, turn.round - 1, turn.round)
	view := &game.view
	reported := make(map[string]bool, context.temp_allocator)
	// Sonar follows the action only if the dragon survives it
	// (planning/rules.md), so a dragon its own turn killed sent nothing.
	died := false
	if index, found := dragon_turn_in_round(game, turn.dragon, turn.round); found {
		stop_event := index + 1 < len(view.turn_event) ? int(view.turn_event[index + 1]) : len(view.event_kind)
		for event in int(view.turn_event[index]) ..< stop_event {
			died = died || view.event_kind[event] == EVENT_DEATH && view.event_a[event] == turn.dragon
		}
	}
	for row in sonar_rows(turn, "sent") {
		if died {break}
		if reported[row.value] {continue}
		reported[row.value] = true
		transmitted := false
		for ping in start ..< stop {
			transmitted =
				transmitted ||
				view.ping_sender[ping] == turn.dragon && view.ping_round[ping] == turn.round && fmt.tprintf("%d", view.ping_value[ping]) == row.value
		}
		if !transmitted {append(&errors, fmt.tprintf("Recorded send of %s has no ping in the replay", row.value))}
	}
	delivered := make(map[string]int, context.temp_allocator)
	for ping in start ..< stop {
		if view.ping_hit[ping] != turn.dragon || view.ping_received_round[ping] != turn.round {continue}
		if legacy_input(turn) && view.ping_value[ping] >= LEGACY_VALUE_LIMIT {continue}
		delivered[fmt.tprintf("%d", view.ping_value[ping])] += 1
	}
	for row in sonar_rows(turn, "received") {
		if delivered[row.value] > 0 {delivered[row.value] -= 1; continue}
		append(&errors, fmt.tprintf("Recorded receipt of %s has no delivered ping", row.value))
	}
	return errors[:]
}

// The pings around one decision, as ping rows: those the dragon read on its
// turn and the echoes it read then: its previous turn's sends, whose hit counts
// arrive now. What it sends this turn only reaches it as next turn's echoes.
Decision_Pings :: struct {
	received, echoes: [dynamic]int,
}

decision_pings :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> Decision_Pings {
	pings := Decision_Pings {
		received = make([dynamic]int, context.temp_allocator),
		echoes   = make([dynamic]int, context.temp_allocator),
	}
	view := &game.view
	start, stop := ping_rows_of_rounds(game, turn.round - 1, turn.round)
	for row in start ..< stop {
		if view.ping_hit[row] == turn.dragon && view.ping_received_round[row] == turn.round {append(&pings.received, row)}
	}
	previous: i32 = -1
	for index in game.turn_indices_by_dragon[turn.dragon] {
		round := i32(view.turn_round[index])
		if round < turn.round {previous = round}
	}
	if previous < 0 {return pings}
	start, stop = ping_rows_of_rounds(game, previous, previous)
	for row in start ..< stop {
		if view.ping_sender[row] == turn.dragon && view.ping_round[row] == previous {append(&pings.echoes, row)}
	}
	return pings
}

// What a sonar ray hit, as its echo reports it to the sender.
@(rodata)
HIT_KIND_NAMES := [7]string{"nothing", "nothing", "kelp", "an allied body", "an allied head", "an enemy body", "an enemy head"}
