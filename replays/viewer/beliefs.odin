package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Each dragon's beliefs graded against the replay at the start of its turn
// (diagnostics.md, Belief correctness), and the team strip that counts, per
// belief, how many living dragons hold it correctly and measures the team's
// knowledge of it (knowledge.odin). Only what a bot states is graded; truth
// never fills in a belief.

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

// The turn's stated facts, counted belief by belief and kept with the turn.
grade_beliefs :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) {
	if !turn.has_record || !turn.gizmo_reliable {return}
	allocator := game_allocator(game)
	grades := make([dynamic]Belief_Grade, allocator)
	for belief in stated_beliefs(game, turn, true) {
		grade := Belief_Grade {
			category = strings.clone(belief.category, allocator),
			subjects = make([dynamic]Belief_Subject, allocator),
			errors   = make([dynamic]string, allocator),
		}
		about := belief.kind == .Positions || belief.kind == .Lengths || belief.kind == .Claim
		for fact in belief.facts {
			if fact.correct {grade.correct += 1} else {grade.wrong += 1}
			// A champion claim is about the dragon it names.
			if about {append(&grade.subjects, Belief_Subject{belief.kind == .Claim ? i32(fact.value) : fact.key, fact.correct})}
		}
		for error in belief.errors[:min(len(belief.errors), MAX_BELIEF_ERRORS)] {append(&grade.errors, strings.clone(error, allocator))}
		append(&grades, grade)
	}
	turn.beliefs = grades[:]
}

// One belief across a team's living dragons at the end of a turn, each
// judged by its latest usable record: its grades, the team's knowledge of it,
// and the pairwise agreement its table annotates for consensus (consensus.odin).
Belief_Row :: struct {
	category, details:                                   string,
	correct, wrong, silent:                              i32, // dragons
	facts_correct, facts_wrong:                          i32,
	knowledge:                                           Knowledge_Row,
	measured:                                            bool,
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
	latest: map[i32]^Dragon_Turn
	living: int
	alive, latest, living, unread = team_records(game, index, team)
	graded = len(latest)
	stop := index + 1 < len(game.view.turn_event) ? int(game.view.turn_event[index + 1]) : len(game.view.event_kind)
	board := board_after_events(game, &game.consensus_board, stop, false)
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
	for knowledge in knowledge_rows(game, alive[:], latest, living) {
		row := row_of(&list, knowledge.category)
		row.knowledge, row.measured = knowledge, true
	}
	for agreement in consensus_rows(game, index, team) {
		row := row_of(&list, agreement.category)
		row.agreement, row.compared = agreement, true
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
		if row.measured {fmt.sbprintf(&details, "\n%s\n", knowledge_text(row.knowledge))}
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
			// The annotated columns, which may include facts the replay can't
			// grade: the contradictions themselves, and the counts where the
			// belief has no graded facts to measure.
			agreement := row.agreement
			fmt.sbprintf(&details, "\nConsensus annotations: %s.", agreement.status)
			if !row.measured {
				fmt.sbprintf(&details, " %d/%d pairs overlap, %d pair-fact comparisons, %d conflicts. Each pair compares the facts both state; unknown facts are not compared.", agreement.overlapping_pairs, agreement.pairs, agreement.comparisons, agreement.conflicts)
			}
			fmt.sbprintf(&details, "\n%s", agreement.details)
			if meaning := game.consensus_meanings[row.category]; meaning != "" {fmt.sbprintf(&details, "\nSource meaning: %s", meaning)}
		}
		row.details = strings.to_string(details)
	}
	return list[:], alive, graded, unread
}

// The four measures' rows in the strip, under the beliefs' boxes.
KNOWLEDGE_MEASURES :: [4]string{"Connectivity", "Agreement", "Coverage", "Validity"}
KNOWLEDGE_LABEL_WIDTH :: 112

// The strip under the timeline: one column per belief of the chosen team, its
// box counting the dragons that hold it without a false fact, then the team's
// connectivity, agreement, coverage and validity for it (knowledge.odin).
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
	for measure, line in KNOWLEDGE_MEASURES {
		clipped_text(measure, x + 6, y + CONTROL_HEIGHT + 4 + f32(line) * UI_LINE, KNOWLEDGE_LABEL_WIDTH - 12, MUTED_TEXT_COLOR)
	}
	x += KNOWLEDGE_LABEL_WIDTH
	width := (area.x + area.width - 6 - x) / f32(len(rows))
	for row, position in rows {
		left := x + f32(position) * width
		box := rl.Rectangle{left, y, width - 6, CONTROL_HEIGHT}
		rl.DrawRectangleLinesEx(box, 1, PANE_BORDER)
		// The label stays neutral and each figure takes its own colour.
		facts := row.facts_correct + row.facts_wrong
		parts := make([dynamic]Stat_Text, context.temp_allocator)
		append(&parts, Stat_Text{fmt.tprintf("%s ", row.category), TEXT_COLOR})
		append(&parts, Stat_Text{fmt.tprintf("%d/%d", row.correct, graded), share_color(share_of(f64(row.correct), f64(graded)))})
		if facts > 0 {
			append(&parts, Stat_Text{", ", TEXT_COLOR})
			share := share_of(f64(row.facts_correct), f64(facts))
			append(&parts, Stat_Text{percent_text(share), share_color(share)})
		}
		draw_stat_line(parts[:], left + 6, y + (CONTROL_HEIGHT - UI_TEXT) / 2 - 1, box.width - 12)
		// Each measure, then its second figure: the dragons sharing most of
		// what they state, those in a contradiction, each dragon's coverage,
		// and the shared facts false for most holders.
		if row.measured {
			knowledge := row.knowledge
			measures := knowledge_measures(knowledge)
			lines := [4][3]Stat_Text {
				{
					{percent_text(measures.connectivity), share_color(measures.connectivity)},
					{", ", TEXT_COLOR},
					{fmt.tprintf("%d/%d share", knowledge.linked, knowledge.linkable), share_color(measures.linked)},
				},
				{
					{percent_text(measures.agreement), share_color(measures.agreement)},
					{", ", TEXT_COLOR},
					{fmt.tprintf("%d disputing", knowledge.disputing), share_color(measures.disputing, fewer = true)},
				},
				{
					{percent_text(measures.coverage), share_color(measures.coverage)},
					{", each ", TEXT_COLOR},
					{percent_text(measures.each), share_color(measures.each)},
				},
				{
					{percent_text(measures.validity), share_color(measures.validity)},
					{", ", TEXT_COLOR},
					{fmt.tprintf("%d/%d misled", knowledge.misled, knowledge.agreed), share_color(measures.misled, fewer = true)},
				},
			}
			for &pieces, line in lines {
				draw_stat_line(pieces[:], left + 6, y + CONTROL_HEIGHT + 4 + f32(line) * UI_LINE, box.width - 12)
			}
		}
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

// A piece of a strip line with its own colour.
Stat_Text :: struct {
	text:  string,
	color: rl.Color,
}

// A share's colour: green when complete, yellow when partial, red at none,
// muted where nothing was measured. `fewer` is for counts where less is
// better, such as dragons in a contradiction.
share_color :: proc(share: f64, fewer := false) -> rl.Color {
	if share < 0 {return MUTED_TEXT_COLOR}
	value := fewer ? 1 - share : share
	return value >= 1 ? REBUILT_COLOR : value <= 0 ? COLOR_WRONG : UI_ACCENT
}

// Pieces drawn one after another, the last clipped to `width`.
draw_stat_line :: proc(parts: []Stat_Text, x, y, width: f32) {
	cursor := x
	for part in parts {
		if cursor >= x + width {break}
		clipped_text(part.text, cursor, y, x + width - cursor, part.color)
		cursor += f32(measure_text(fmt.ctprintf("%s", part.text), UI_TEXT))
	}
}

// One cell's next spawn as the decision stated it (a `spawn_due` truth column),
// graded as `stated_beliefs` grades it against the replay at the turn's start.
Remembered_Spawn :: struct {
	stated:         i32,
	never, correct: bool,
}

remembered_spawns :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) -> map[i32]Remembered_Spawn {
	spawns := make(map[i32]Remembered_Spawn, context.temp_allocator)
	for belief in stated_beliefs(game, turn, false, only = "spawn_due") {
		for fact in belief.facts {
			spawns[fact.key] = fact.value < 0 ? {never = true, correct = fact.correct} : {stated = i32(fact.value), correct = fact.correct}
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
