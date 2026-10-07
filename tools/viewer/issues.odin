package viewer

import "core:fmt"
import "core:slice"
import "core:strings"

// What the viewer can't use in a turn's records, for the Issues button under
// the comment field: records the recovery rejected, sonar records the replay
// doesn't bear out, turns whose rebuilt actions diverged, and memories that
// name no source, since every memory should say where it came from.
turn_issues :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> []string {
	issues := make([dynamic]string, context.temp_allocator)
	if !turn.gizmo_reliable {append(&issues, fmt.tprintf("Rebuilt actions diverged from the replay: %s", turn.gizmo_status))}
	for error in turn.gizmo_errors {append(&issues, error)}
	for slot in turn.gizmo_rejected_slots {append(&issues, fmt.tprintf("%s root rejected", slot))}
	for error in radio_errors(game, turn) {append(&issues, error)}
	width := game.view.width
	for &gizmo in turn.gizmos {
		if gizmo.kind == "positions" {
			for entry in gizmo.positions {
				if strings.trim_space(entry.source) != "" {continue}
				append(&issues, fmt.tprintf("%s: position %s at (%d,%d) names no source", gizmo.label, entry.label, entry.cell % width, entry.cell / width))
			}
			continue
		}
		if gizmo.kind != "table" || len(gizmo.truth_columns) == 0 {continue}
		for quantity, column in gizmo.truth_columns {
			if quantity == "" || column >= len(gizmo.columns) {continue}
			source := source_column(gizmo.columns[:], column)
			if source < 0 {
				append(&issues, fmt.tprintf("%s: %s has no source column", gizmo.label, gizmo.columns[column]))
				continue
			}
			// A stated belief whose source is blank.
			cells := make([dynamic]string, context.temp_allocator)
			for row, index in gizmo.rows {
				if column >= len(row) || source >= len(row) || !belief_stated(quantity, row[column]) {continue}
				if !slice.contains([]string{"", "-", "?", "none"}, strings.trim_space(row[source])) {continue}
				cell := index < len(gizmo.row_cells) ? gizmo.row_cells[index] : -1
				append(&cells, fmt.tprintf("(%d,%d)", cell % width, cell / width))
			}
			if len(cells) == 0 {continue}
			shown := cells[:min(len(cells), 8)]
			append(&issues, fmt.tprintf("%s: %d cells state %s with no source: %s%s", gizmo.label, len(cells), gizmo.columns[column], strings.join(shown, " ", context.temp_allocator), len(cells) > len(shown) ? " ..." : ""))
		}
	}
	return issues[:]
}

// Whether a belief cell states anything: `?` and blanks state nothing, an edge
// claim needs one known side, and an unmeasured spawn gap is 0.
belief_stated :: proc(quantity, cell: string) -> bool {
	value := strings.trim_space(cell)
	if value == "" || value == "?" {return false}
	switch quantity {
	case "edges":
		claims, ok := parse_edge_claims(value)
		if !ok {return true}
		for claim in claims {if claim.code != '?' {return true}}
		return false
	case "spawn_min", "spawn_max", "spawn_mean":
		return value != "0"
	}
	return true
}

// Issues across the match, from every turn record the recovery has sent so
// far: each kind of issue (its text with numbers blanked, up to any cell
// list) with how many turns and dragons show it and where it first appeared.
// Checking a record costs nothing beyond the rebuild that produced it.
Issue_Tally :: struct {
	turns:                     int,
	dragons:                   map[i32]bool,
	first_dragon, first_round: i32,
	example:                   string,
}

// Tally the records that arrived since the last call, a few hundred a frame.
scan_issues :: proc(game: ^Loaded_Game, budget := 300) {
	allocator := game_allocator(game)
	if game.issues == nil {game.issues = make(map[string]Issue_Tally, allocator)}
	for _ in 0 ..< budget {
		if game.issues_scanned >= len(game.issue_rows) {return}
		row := game.issue_rows[game.issues_scanned]
		game.issues_scanned += 1
		turn := game_turn(game, row)
		for text in turn_issues(game, turn) {
			kind := issue_kind(text)
			tally, known := game.issues[kind]
			if !known {
				kind = strings.clone(kind, allocator)
				tally = {dragons = make(map[i32]bool, allocator), first_dragon = turn.dragon, first_round = turn.round, example = strings.clone(text, allocator)}
			}
			tally.turns += 1
			tally.dragons[turn.dragon] = true
			game.issues[kind] = tally
		}
	}
}

issue_kind :: proc(text: string) -> string {
	prefix := text
	if cut := strings.index_byte(text, '('); cut > 0 {prefix = text[:cut]}
	kind := strings.builder_make(context.temp_allocator)
	digits := false
	for character in strings.trim_space(prefix) {
		if character >= '0' && character <= '9' {
			if !digits {strings.write_byte(&kind, '#')}
			digits = true
			continue
		}
		digits = false
		strings.write_rune(&kind, character)
	}
	return strings.to_string(kind)
}

// The Issues dialog: the match's kinds, most turns first, then this decision's.
issues_text :: proc(viewer: ^Viewer_State, current: []string) -> string {
	game := &viewer.game
	text := strings.builder_make(context.temp_allocator)
	kinds := make([dynamic]string, context.temp_allocator)
	for kind in game.issues {append(&kinds, kind)}
	slice.sort_by(kinds[:], proc(a, b: string) -> bool {return a < b})
	fmt.sbprintf(&text, "Across the match, from %d turn records of rebuilt dragons:\n", len(game.issue_rows))
	if len(kinds) == 0 {strings.write_string(&text, "None\n")}
	for kind in kinds {
		tally := game.issues[kind]
		fmt.sbprintf(&text, "%s\n    %d turns, %d dragons, first D%d r%d: %s\n", kind, tally.turns, len(tally.dragons), tally.first_dragon, tally.first_round, tally.example)
	}
	strings.write_string(&text, "\nThis decision:\n")
	if len(current) == 0 {strings.write_string(&text, "None\n")}
	for issue in current {fmt.sbprintf(&text, "%s\n", issue)}
	return strings.to_string(text)
}

// A column's source column, by the table's own structure: the fact a column
// belongs to is its name up to the first `.`, after any `belief: ` prefix
// that marks a belief derived from that fact, and its source is `FACT.source`.
// -1 when the table has none.
source_column :: proc(columns: []string, column: int) -> int {
	fact := strings.trim_prefix(columns[column], "belief: ")
	if dot := strings.index_byte(fact, '.'); dot >= 0 {fact = fact[:dot]}
	wanted := fmt.tprintf("%s.source", fact)
	for name, index in columns {if name == wanted {return index}}
	return -1
}
