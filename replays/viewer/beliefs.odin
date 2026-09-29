package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Each dragon's beliefs graded against the replay at the start of its turn
// (diagnostics.md, Belief correctness), and the team strip that counts, per
// belief, how many living dragons hold it correctly. Only what a bot states is
// graded; truth never fills in a belief.

MAX_BELIEF_ERRORS :: 12 // wrong facts described per dragon and belief; all are counted

// One belief of one dragon turn. `subjects` are the dragons a position,
// length or champion belief is about, with whether it was right.
Belief_Grade :: struct {
	category:       string,
	correct, wrong: i32,
	subjects:       [dynamic]Belief_Subject,
	errors:         [dynamic]string,
}
Belief_Subject :: struct {
	dragon:  i32,
	correct: bool,
}

grade_beliefs :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) {
	if !turn.has_record || !turn.gizmo_reliable {return}
	allocator := game_allocator(game)
	grades := make([dynamic]Belief_Grade, allocator)
	grade_of :: proc(grades: ^[dynamic]Belief_Grade, category: string, allocator := context.allocator) -> ^Belief_Grade {
		for &grade in grades {if grade.category == category {return &grade}}
		append(grades, Belief_Grade{category = category, subjects = make([dynamic]Belief_Subject, allocator), errors = make([dynamic]string, allocator)})
		return &grades[len(grades) - 1]
	}
	record :: proc(grade: ^Belief_Grade, correct: bool, text: string, allocator := context.allocator) {
		if correct {grade.correct += 1; return}
		grade.wrong += 1
		if len(grade.errors) < MAX_BELIEF_ERRORS {append(&grade.errors, strings.clone(text, allocator))}
	}
	width, height := game.view.width, game.view.height
	cell_name :: proc(cell, width: i32) -> string {return fmt.tprintf("(%d,%d)", cell % width, cell / width)}
	// The mental map: a truth column's quantity names its belief, by the
	// consensus category that annotates the same column or its parts where
	// there is one.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" || len(gizmo.truth_columns) == 0 || len(gizmo.row_cells) == 0 {continue}
		for quantity, column in gizmo.truth_columns {
			if quantity != "edges" && quantity != "pearl" && quantity != "spawn_due" {continue}
			name := column < len(gizmo.columns) ? gizmo.columns[column] : quantity
			// Or the category annotating its parts, such as each side of a cell's
			// edges in columns named `belief: edges.N` and so on.
			for field in gizmo.consensus {
				annotated := int(field.column) < len(gizmo.columns) ? gizmo.columns[field.column] : ""
				if int(field.column) == column || column < len(gizmo.columns) && strings.has_prefix(annotated, fmt.tprintf("%s.", gizmo.columns[column])) {name = field.category}
			}
			grade := grade_of(&grades, name, allocator)
			switch quantity {
			case "edges", "pearl":
				// Graded claim by claim in accuracy.odin.
				for entry in turn.accuracy.cells {
					if quantity == "pearl" {
						if entry[2] != GRADE_UNKNOWN {record(grade, entry[2] == GRADE_CORRECT, "", allocator)}
						continue
					}
					for side in ([4]i32{entry[3], entry[4], entry[5], entry[6]}) {if side != GRADE_UNKNOWN {record(grade, side == GRADE_CORRECT, "", allocator)}}
				}
				clear(&grade.errors)
				for wrong in turn.accuracy.wrong {
					for reason in strings.split(wrong.reason, "; ", context.temp_allocator) {
						if strings.has_prefix(reason, "pearl") != (quantity == "pearl") {continue}
						if len(grade.errors) < MAX_BELIEF_ERRORS {
							append(&grade.errors, fmt.aprintf("%s %s", cell_name(wrong.cell, width), reason, allocator = allocator))
						}
					}
				}
			case "spawn_due":
				for row, index in gizmo.rows {
					if index >= len(gizmo.row_cells) || column >= len(row) {break}
					cell, value := gizmo.row_cells[index], row[column]
					if value == "?" || value == "" {continue}
					due: i32 = -1
					for spawn in turn.spawns {if spawn[0] == cell {due = spawn[1]}}
					spawning := false
					for rule in game.view.spawn_rules {if rule.cell == cell {spawning = rule.maximum > 0}}
					if value == "never" {
						record(grade, !spawning, fmt.tprintf("%s never spawns, replay spawns", cell_name(cell, width)), allocator)
					} else if stated, ok := parse_int_field(row, i32(column)); ok {
						if due >= 0 {
							record(grade, stated == due, fmt.tprintf("%s next spawn r%d, replay r%d", cell_name(cell, width), stated, due), allocator)
						} else if !spawning {
							record(grade, false, fmt.tprintf("%s next spawn r%d, replay never spawns", cell_name(cell, width), stated), allocator)
						}
					}
				}
			}
		}
	}
	// Dragons: where each is, how long, and which is each team's champion.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "positions" {continue}
		for entry in gizmo.positions {
			subject, named := entry.dragon.?
			if !named {continue}
			truth: Dragon_Fact
			alive := false
			for dragon in turn.dragons {if dragon.id == subject {truth, alive = dragon, true}}
			// A dragon knows its own place and length, but not whether it is
			// its team's longest, so only its champion belief is graded.
			own := subject == turn.dragon
			positions := grade_of(&grades, "Positions", allocator)
			if own {
			} else if !alive {
				record(positions, false, fmt.tprintf("D%d at %s: dead or not yet born", subject, cell_name(entry.cell, width)), allocator)
				append(&positions.subjects, Belief_Subject{subject, false})
			} else {
				// The true head among the cells the believer says it may occupy.
				right := truth.head >= 0 && position_area(entry, width, height)[truth.head]
				place := len(entry.cells) > 0 ? fmt.tprintf("in %d cells from %s", len(entry.cells), cell_name(entry.cell, width)) : fmt.tprintf("within %d of %s", entry.radius, cell_name(entry.cell, width))
				record(positions, right, fmt.tprintf("D%d %s: head at %s", subject, place, cell_name(truth.head, width)), allocator)
				append(&positions.subjects, Belief_Subject{subject, right})
			}
			if length, stated := entry.length.?; stated && alive && !own {
				right := entry.length_exact ? truth.length == length : truth.length >= length
				lengths := grade_of(&grades, "Lengths", allocator)
				record(lengths, right, fmt.tprintf("D%d length %s%d, replay %d", subject, entry.length_exact ? "" : "at least ", length, truth.length), allocator)
				append(&lengths.subjects, Belief_Subject{subject, right})
			}
			if !entry.champion || (entry.team != "ours" && entry.team != "enemy") {continue}
			team := entry.team == "ours" ? turn.team : 1 - turn.team
			champion := grade_of(&grades, entry.team == "ours" ? "Our champion" : "Enemy champion", allocator)
			longest := Dragon_Fact{id = -1}
			for dragon in turn.dragons {if dragon.team == team && dragon.length > longest.length {longest = dragon}}
			right := alive && truth.team == team && truth.length == longest.length
			length, stated := entry.length.?
			if stated && alive {right = right && (entry.length_exact ? truth.length == length : truth.length >= length)}
			record(champion, right, fmt.tprintf("D%d%s as champion: replay's longest is D%d, length %d", subject, stated ? fmt.tprintf(", length %s%d", entry.length_exact ? "" : "at least ", length) : "", longest.id, longest.length), allocator)
			append(&champion.subjects, Belief_Subject{subject, right})
		}
	}
	turn.beliefs = grades[:]
}

// One belief across a team's living dragons at the end of a turn, each
// judged by its latest usable record, and the team's pairwise agreement on it
// where its table annotates consensus (consensus.odin).
Belief_Row :: struct {
	category, details:                                   string,
	correct, wrong, silent:                              i32, // dragons
	facts_correct, facts_wrong:                          i32,
	agreement:                                           Consensus_Row,
	compared:                                            bool,
}

// The living dragons of a team that hold no graded record at a turn: those yet
// to take a turn, those whose latest turn is still to be rebuilt, and those
// whose latest turn has no usable diagnostics and never will, such as a build
// the recovery refuses.
Unread_Dragons :: struct {
	yet_to_act, rebuilding, without: [dynamic]i32,
}

team_beliefs :: proc(game: ^Loaded_Game, index, team: int) -> (rows: []Belief_Row, alive: [dynamic]i32, graded: int, unread: Unread_Dragons) {
	view := &game.view
	stop := index + 1 < len(view.turn_event) ? int(view.turn_event[index + 1]) : len(view.event_kind)
	board := board_after_events(game, &game.consensus_board, stop, false)
	alive = make([dynamic]i32, context.temp_allocator)
	unread = {
		yet_to_act = make([dynamic]i32, context.temp_allocator),
		rebuilding = make([dynamic]i32, context.temp_allocator),
		without    = make([dynamic]i32, context.temp_allocator),
	}
	for dragon in board.dragons {if int(dragon.team) == team {append(&alive, dragon.id)}}
	slice.sort(alive[:])
	latest := make(map[i32]^Dragon_Turn, context.temp_allocator)
	for dragon in alive {
		indices := game.turn_indices_by_dragon[dragon]
		acted := false
		for position := len(indices) - 1; position >= 0; position -= 1 {
			if indices[position] > index {continue}
			acted = true
			turn := opened_turn(game, indices[position])
			if turn.has_record && turn.gizmo_reliable {latest[dragon] = turn}
			break
		}
		if dragon in latest {graded += 1; continue}
		if !acted {append(&unread.yet_to_act, dragon)
		} else if game.view.pending_dragons[dragon] {append(&unread.rebuilding, dragon)
		} else {append(&unread.without, dragon)}
	}
	list := make([dynamic]Belief_Row, context.temp_allocator)
	row_of :: proc(list: ^[dynamic]Belief_Row, category: string) -> ^Belief_Row {
		for &row in list {if row.category == category {return &row}}
		append(list, Belief_Row{category = category})
		return &list[len(list) - 1]
	}
	for dragon in alive {
		turn := latest[dragon] or_continue
		for grade in turn.beliefs {row_of(&list, grade.category)}
	}
	for agreement in consensus_rows(game, index, team) {
		row := row_of(&list, agreement.category)
		row.agreement, row.compared = agreement, true
	}
	// Who our champion is and how long, compared between dragons as the
	// consensus annotations are, from the dragons' positions records.
	{
		stated := make(map[i32]string, context.temp_allocator)
		for dragon in alive {
			turn := latest[dragon] or_continue
			parts := make([dynamic]string, context.temp_allocator)
			for &gizmo in turn.gizmos {
				if gizmo.kind != "positions" {continue}
				for entry in gizmo.positions {
					subject, named := entry.dragon.?
					if !named || !entry.champion || entry.team != "ours" {continue}
					length, has_length := entry.length.?
					append(&parts, has_length ? fmt.tprintf("D%d length %s%d", subject, entry.length_exact ? "" : "at least ", length) : fmt.tprintf("D%d", subject))
				}
			}
			if len(parts) == 0 {continue}
			slice.sort(parts[:])
			stated[dragon] = strings.join(parts[:], ", ", context.temp_allocator)
		}
		if len(stated) > 0 {
			row := row_of(&list, "Our champion")
			agreement := Consensus_Row{category = "Our champion", reporters = i32(len(stated)), alive = i32(len(alive)), pairs = i32(len(alive) * (len(alive) - 1) / 2)}
			reporters := make([dynamic]i32, context.temp_allocator)
			for dragon in stated {append(&reporters, dragon)}
			slice.sort(reporters[:])
			witnesses := strings.builder_make(context.temp_allocator)
			for dragon in reporters {fmt.sbprintf(&witnesses, "D%d: %s\n", dragon, stated[dragon])}
			for first, position in reporters {
				for second in reporters[position + 1:] {
					agreement.overlapping_pairs += 1
					agreement.comparisons += 1
					if stated[first] != stated[second] {agreement.conflicts += 1}
				}
			}
			agreement.status = agreement.conflicts > 0 ? "DISAGREE" : len(stated) != len(alive) ? "INCOMPLETE" : "AGREE"
			agreement.details = strings.to_string(witnesses)
			row.agreement, row.compared = agreement, true
		}
	}
	for &row in list {
		details := strings.builder_make(context.temp_allocator)
		wrong := strings.builder_make(context.temp_allocator)
		silent := make([dynamic]string, context.temp_allocator)
		// Per subject dragon: who believes it rightly and who wrongly.
		About :: struct {
			right: i32,
			wrong: [dynamic]string,
		}
		about := make(map[i32]About, context.temp_allocator)
		for dragon in alive {
			turn := latest[dragon] or_continue
			grade: ^Belief_Grade
			for &candidate in turn.beliefs {if candidate.category == row.category {grade = &candidate}}
			if grade == nil || grade.correct + grade.wrong == 0 {
				row.silent += 1
				append(&silent, fmt.tprintf("D%d", dragon))
				continue
			}
			row.facts_correct += grade.correct
			row.facts_wrong += grade.wrong
			for subject in grade.subjects {
				if subject.dragon not_in about {about[subject.dragon] = {wrong = make([dynamic]string, context.temp_allocator)}}
				entry := &about[subject.dragon]
				if subject.correct {entry.right += 1} else {append(&entry.wrong, fmt.tprintf("D%d", dragon))}
			}
			if grade.wrong == 0 {row.correct += 1; continue}
			row.wrong += 1
			fmt.sbprintf(&wrong, "D%d (r%d), %d of %d wrong: %s\n", dragon, turn.round, grade.wrong, grade.correct + grade.wrong, strings.join(grade.errors[:], "; ", context.temp_allocator))
		}
		fmt.sbprintf(&details, "%s at the end of this turn, against the replay:\n", row.category)
		fmt.sbprintf(&details, "%d of %d rebuilt dragons hold it correctly, %d hold a false belief, %d state nothing", row.correct, graded, row.wrong, row.silent)
		fmt.sbprintf(&details, ".\n%d of %d stated facts are correct.\n", row.facts_correct, row.facts_correct + row.facts_wrong)
		if len(about) > 0 {
			subjects := make([dynamic]i32, context.temp_allocator)
			for subject in about {append(&subjects, subject)}
			slice.sort(subjects[:])
			for subject in subjects {
				entry := about[subject]
				side := "dead"
				for dragon in board.dragons {if dragon.id == subject {side = int(dragon.team) == team ? "ours" : "enemy"}}
				fmt.sbprintf(&details, "About D%d (%s): %d of %d correct", subject, side, entry.right, entry.right + i32(len(entry.wrong)))
				if len(entry.wrong) > 0 {fmt.sbprintf(&details, "; wrong: %s", strings.join(entry.wrong[:], ", ", context.temp_allocator))}
				fmt.sbprint(&details, "\n")
			}
		}
		fmt.sbprint(&details, strings.to_string(wrong))
		if len(silent) > 0 {fmt.sbprintf(&details, "States nothing: %s\n", strings.join(silent[:], ", ", context.temp_allocator))}
		if line := unread_summary(game, unread); line != "" {fmt.sbprintf(&details, "Not graded: %s\n", line)}
		if row.compared {
			agreement := row.agreement
			fmt.sbprintf(
				&details,
				"\nAgreement between dragons: %s. %d/%d pairs overlap, %d pair-fact comparisons, %d conflicts. Each pair compares the facts both state; unknown facts are not compared.\n%s",
				agreement.status,
				agreement.overlapping_pairs,
				agreement.pairs,
				agreement.comparisons,
				agreement.conflicts,
				agreement.details,
			)
			if meaning := game.consensus_meanings[row.category]; meaning != "" {fmt.sbprintf(&details, "\nSource meaning: %s", meaning)}
			if agreement.known_any > 0 {
				fmt.sbprintf(&details, "\nKnown to any reporting dragon: %d facts. Known to all %d: %d. Each holds %d%% of them on average.", agreement.known_any, agreement.reporters, agreement.known_all, int(100 * agreement.mean_share + 0.5))
			}
		}
		row.details = strings.to_string(details)
	}
	return list[:], alive, graded, unread
}

// The strip under the timeline: one box per belief of the chosen team.
draw_beliefs_panel :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	index := active_turn_index(viewer)
	if index < 0 {index = turn_count_before_frame(&viewer.game, current_frame(viewer) + 1) - 1}
	rl.DrawRectangleLinesEx(area, 1, COLOR_UNKNOWN)
	if index < 0 {
		clipped_text("Beliefs: no turn yet", area.x + 8, area.y + 8, area.width - 16, MUTED_TEXT_COLOR)
		return
	}
	team := our_team(viewer)
	rows, alive, graded, unread := team_beliefs(&viewer.game, index, team)
	header := fmt.tprintf("Team %c beliefs: %d of %d living dragons graded", 'A' + team, graded, len(alive))
	// The strip's progress count covers those not rebuilt yet.
	if line := unread_summary(&viewer.game, unread, rebuilding = false); line != "" {header = fmt.tprintf("%s; %s", header, line)}
	progress, progress_color := rebuild_progress(viewer)
	progress_width: f32 = 0
	if progress != "" {
		progress_width = f32(measure_text(fmt.ctprintf("%s", progress), UI_TEXT)) + 30
		dot := rl.Vector2{area.x + area.width - progress_width + 6, area.y + 4 + UI_TEXT / 2 + 1}
		rl.DrawCircleV(dot, 5, progress_color)
		clipped_text(progress, dot.x + 12, area.y + 4, progress_width - 18, progress_color)
	}
	clipped_text(
		header,
		area.x + 8,
		area.y + 4,
		area.width - 16 - progress_width,
		UI_ACCENT,
	)
	y := area.y + 28
	x := area.x + 6
	if len(rows) == 0 {
		if graded > 0 {clipped_text("No graded beliefs stated", x + 6, y + 3, area.x + area.width - x - 12, MUTED_TEXT_COLOR)}
		return
	}
	// Each box: the graded dragons holding the belief without a false fact, and
	// the share of their stated facts that are correct.
	// Every belief on one line, so the strip stays two lines tall.
	width := (area.x + area.width - 6 - x) / f32(len(rows))
	for row, position in rows {
		left := x + f32(position) * width
		color := row.wrong > 0 ? WARNING_COLOR : row.correct == i32(graded) ? UI_ACCENT : MUTED_TEXT_COLOR
		box := rl.Rectangle{left, y, width - 6, CONTROL_HEIGHT}
		rl.DrawRectangleLinesEx(box, 1, color)
		facts := row.facts_correct + row.facts_wrong
		text := fmt.tprintf("%s %d/%d", row.category, row.correct, graded)
		if facts > 0 {text = fmt.tprintf("%s, %d%%", text, int(100 * i64(row.facts_correct) / i64(facts)))}
		// Facts every reporting dragon holds, of those any holds.
		if row.compared && row.agreement.known_any > 0 && !viewer.game.consensus_singletons[row.category] {
			text = fmt.tprintf("%s, shared %d/%d", text, row.agreement.known_all, row.agreement.known_any)
		}
		clipped_text(text, left + 6, y + (CONTROL_HEIGHT - UI_TEXT) / 2 - 1, box.width - 12, color)
		if rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(rl.GetMousePosition(), box) {
			open_diagnostic_detail(viewer, row.category, row.details)
			// A belief about cells or edges opens as a map of who states what.
			for category in viewer.game.consensus_categories {
				scope := viewer.game.consensus_scopes[category]
				if category == row.category && scope != "singleton" {viewer.detail_map = {category = category, index = index, team = team, cell = -1}}
			}
		}
	}
}

// One cell's next spawn as the decision stated it (a `spawn_due` truth column),
// graded as `grade_beliefs` grades it against the replay at the turn's start.
Remembered_Spawn :: struct {
	stated:         i32,
	never, correct: bool,
}

remembered_spawns :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> map[i32]Remembered_Spawn {
	spawns := make(map[i32]Remembered_Spawn, context.temp_allocator)
	due := make(map[i32]i32, context.temp_allocator)
	for spawn in turn.spawns {due[spawn[0]] = spawn[1]}
	spawning := make(map[i32]bool, context.temp_allocator)
	for rule in game.view.spawn_rules {spawning[rule.cell] = rule.maximum > 0}
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" {continue}
		for quantity, column in gizmo.truth_columns {
			if quantity != "spawn_due" {continue}
			for row, index in gizmo.rows {
				if index >= len(gizmo.row_cells) || column >= len(row) {break}
				cell := gizmo.row_cells[index]
				truth, timed := due[cell]
				if row[column] == "never" {
					spawns[cell] = {never = true, correct = !spawning[cell]}
				} else if stated, ok := parse_int_field(row, i32(column)); ok && stated >= 0 {
					if timed {spawns[cell] = {stated = stated, correct = stated == truth}
					} else if !spawning[cell] {spawns[cell] = {stated = stated}}
				}
			}
		}
	}
	return spawns
}

// The dragons left ungraded, in words: yet to act, still to be rebuilt (the
// queue reaches them in turn), or without diagnostics and why.
unread_summary :: proc(game: ^Loaded_Game, unread: Unread_Dragons, rebuilding := true) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if len(unread.yet_to_act) > 0 {append(&parts, fmt.tprintf("%d yet to act", len(unread.yet_to_act)))}
	if rebuilding && len(unread.rebuilding) > 0 {append(&parts, fmt.tprintf("%d not rebuilt yet", len(unread.rebuilding)))}
	if len(unread.without) > 0 {
		reason := game.view.dragon_builds[unread.without[0]].status
		append(&parts, reason != "" ? fmt.tprintf("%d without diagnostics (%s)", len(unread.without), reason) : fmt.tprintf("%d without diagnostics", len(unread.without)))
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// The match's rebuilding, beside the team buttons: an amber dot counting the
// dragons finished among those the recovery can rebuild, a green one once all
// are rebuilt, and a red one if any failed or the recovery ended first. Builds
// the recovery refuses aren't counted.
rebuild_progress :: proc(viewer: ^Viewer_State) -> (text: string, color: rl.Color) {
	view := &viewer.game.view
	if viewer.recovery.stopped_early {return "Rebuilding stopped", COLOR_DEATH}
	if view.recovery_starting {return "Starting rebuilds", WARNING_COLOR}
	if view.recoverable_dragons == 0 {return "", {}}
	waiting := 0
	for _, pending in view.pending_dragons {if pending {waiting += 1}}
	done := view.recoverable_dragons - waiting
	if waiting > 0 {return fmt.tprintf("Rebuilding %d/%d", done, view.recoverable_dragons), WARNING_COLOR}
	if view.failed_dragons > 0 {return fmt.tprintf("%d of %d rebuilt, %d failed", done - view.failed_dragons, done, view.failed_dragons), COLOR_DEATH}
	return fmt.tprintf("All %d rebuilt", view.recoverable_dragons), REBUILT_COLOR
}

// The team whose beliefs the strip grades: ours, the focused dragon's when the
// recovery can rebuild its team, else the first team it can rebuild.
our_team :: proc(viewer: ^Viewer_State) -> int {
	view := &viewer.game.view
	if indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]; found && len(indices) > 0 {
		team := int(view.turn_team[indices[0]]) & 1
		if view.recoverable_teams[team] {return team}
	}
	return view.recoverable_teams[1] && !view.recoverable_teams[0] ? 1 : 0
}
