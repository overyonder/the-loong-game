package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// Team knowledge (diagnostics.md, Team knowledge), for each belief over the
// living dragons of one team, each judged by its latest usable record.
// Agreement and validity are a consensus protocol's properties, coverage
// stands for its termination (Lynch, Distributed Algorithms, chapters 5 and
// 6), and connectivity is how far a fact has spread, as in epidemic
// dissemination (Demers et al., 1987):
//
// - Connectivity: how widely each stated fact is shared, and which dragons
//   share most of what they know.
// - Agreement: how often two dragons stating the same fact contradict each
//   other.
// - Coverage: how much of what exists the team states.
// - Validity: how much of what it states is true, and how often a fact
//   several dragons hold is false for most of them.
//
// Only facts the replay can grade take part, and truth never fills one in.

// What a belief's facts are about, which decides what exists to be known and
// how two dragons' values for one fact are compared.
Fact_Kind :: enum {
	Sides, // each side of each cell, four a cell
	Cells, // one a cell, such as its pearl or next spawn
	Positions, // where each other dragon's head is
	Lengths, // how long each other dragon is
	Queen, // where the enemy queen is, one fact for the team
}

// One graded fact a dragon states: its key within the belief, its value and
// whether the replay bears it out. A length may be a lower bound; a position
// is a set of cells, listed or within `radius` of the cell in `value`. A fact
// `gone` is about a dragon that isn't alive: false, and outside what exists to
// be known.
Stated_Fact :: struct {
	key:     i32,
	value:   i64,
	correct: bool,
	bound:   bool,
	gone:    bool,
	cells:   []i32,
	radius:  i32,
}

// A belief's graded facts in one dragon turn, and, when asked for, a line
// describing each wrong one.
Stated_Belief :: struct {
	category: string,
	kind:     Fact_Kind,
	// The truth column's quantity for a map belief, such as `spawn_due`.
	quantity: string,
	facts:    [dynamic]Stated_Fact,
	errors:   [dynamic]string,
}

// The name a truth column's belief goes by: the consensus category annotating
// the column or its parts (columns named after it with a `.` suffix, such as
// `belief: edges.N`), else the column's own name.
truth_category :: proc(gizmo: ^Gizmo, column: int, quantity: string) -> string {
	name := column < len(gizmo.columns) ? gizmo.columns[column] : quantity
	for field in gizmo.consensus {
		annotated := int(field.column) < len(gizmo.columns) ? gizmo.columns[field.column] : ""
		if int(field.column) == column || column < len(gizmo.columns) && strings.has_prefix(annotated, fmt.tprintf("%s.", gizmo.columns[column])) {name = field.category}
	}
	return name
}

// Whether a position fact allows the head on `cell`.
position_holds :: proc(fact: Stated_Fact, cell, width, height: i32) -> bool {
	if len(fact.cells) > 0 {return slice.contains(fact.cells, cell)}
	centre := i32(fact.value)
	dx := abs(cell % width - centre % width)
	dy := abs(cell / width - centre / width)
	return min(dx, width - dx) + min(dy, height - dy) <= fact.radius
}

// Every graded fact the turn's records state, belief by belief, in the order
// the records give them. `describe` also words each wrong fact, and `only`
// keeps one map quantity alone. Map facts are graded as Mental map accuracy
// grades them (accuracy.odin), the rest as Belief correctness says
// (diagnostics.md).
stated_beliefs :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn, describe: bool, only := "", allocator := context.temp_allocator) -> [dynamic]Stated_Belief {
	beliefs := make([dynamic]Stated_Belief, allocator)
	if !turn.has_record || !turn.gizmo_reliable {return beliefs}
	belief_of :: proc(beliefs: ^[dynamic]Stated_Belief, category: string, kind: Fact_Kind, allocator := context.allocator) -> ^Stated_Belief {
		for &belief in beliefs {if belief.category == category {return &belief}}
		append(beliefs, Stated_Belief{category = category, kind = kind, facts = make([dynamic]Stated_Fact, allocator), errors = make([dynamic]string, allocator)})
		return &beliefs[len(beliefs) - 1]
	}
	state :: proc(belief: ^Stated_Belief, fact: Stated_Fact, describe: bool, error: string) {
		append(&belief.facts, fact)
		if !fact.correct && describe {append(&belief.errors, error)}
	}
	width, height := game.view.width, game.view.height
	cell_name :: proc(cell, width: i32) -> string {return fmt.tprintf("(%d,%d)", cell % width, cell / width)}
	letters := "NESW"
	// The mental map. Sides and pearls carry their grades from the turn's
	// graded table, the first with those truth columns, and each spawn round
	// is graded here.
	graded := make(map[i32][7]i32, context.temp_allocator)
	for entry in turn.accuracy.cells {graded[entry[0]] = entry}
	truth := map_truth(game)
	pearls := make(map[i32]bool, context.temp_allocator)
	for pearl in turn.pearls {pearls[pearl] = true}
	due := make(map[i32]i32, context.temp_allocator)
	for spawn in turn.spawns {due[spawn[0]] = spawn[1]}
	spawning := make(map[i32]bool, context.temp_allocator)
	for rule in game.view.spawn_rules {spawning[rule.cell] = rule.maximum > 0}
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" || len(gizmo.truth_columns) == 0 || len(gizmo.row_cells) == 0 {continue}
		accurate := gizmo.label == turn.accuracy.table
		for quantity, column in gizmo.truth_columns {
			if quantity != "edges" && quantity != "pearl" && quantity != "spawn_due" {continue}
			if quantity != "spawn_due" && !accurate || only != "" && quantity != only {continue}
			name := truth_category(&gizmo, column, quantity)
			belief := belief_of(&beliefs, name, quantity == "edges" ? .Sides : .Cells, allocator)
			belief.quantity = quantity
			for row, index in gizmo.rows {
				if index >= len(gizmo.row_cells) || column >= len(row) {break}
				cell := gizmo.row_cells[index]
				switch quantity {
				case "edges":
					grades, found := graded[cell]
					claims, ok := parse_edge_claims(row[column])
					if !found || !ok {continue}
					for claim, direction in claims {
						grade := grades[3 + direction]
						if grade == GRADE_UNKNOWN {continue}
						fact := Stated_Fact{key = cell * 4 + i32(direction), value = i64(claim.code) | i64(claim.landing + 1) << 8, correct = grade == GRADE_CORRECT}
						state(belief, fact, describe, fact.correct ? "" : fmt.tprintf("%s %c %s", cell_name(cell, width), letters[direction], edge_text(claim, truth.kinds[cell][direction], truth.landings[cell][direction])))
					}
				case "pearl":
					grades, found := graded[cell]
					if !found || grades[2] == GRADE_UNKNOWN {continue}
					remembered := row[column] == "1"
					fact := Stated_Fact{key = cell, value = remembered ? 1 : 0, correct = grades[2] == GRADE_CORRECT}
					state(belief, fact, describe, fact.correct ? "" : fmt.tprintf("%s pearl remembered %s, replay %s", cell_name(cell, width), remembered ? "present" : "absent", pearls[cell] ? "present" : "absent"))
				case "spawn_due":
					value := row[column]
					if value == "?" || value == "" {continue}
					truth_round, timed := due[cell]
					if value == "never" {
						fact := Stated_Fact{key = cell, value = -1, correct = !spawning[cell]}
						state(belief, fact, describe, fmt.tprintf("%s never spawns, replay spawns", cell_name(cell, width)))
					} else if stated, parsed := parse_int_field(row, i32(column)); parsed && stated >= 0 {
						if timed {
							fact := Stated_Fact{key = cell, value = i64(stated), correct = stated == truth_round}
							state(belief, fact, describe, fmt.tprintf("%s next spawn r%d, replay r%d", cell_name(cell, width), stated, truth_round))
						} else if !spawning[cell] {
							state(belief, Stated_Fact{key = cell, value = i64(stated)}, describe, fmt.tprintf("%s next spawn r%d, replay never spawns", cell_name(cell, width), stated))
						}
					}
				}
			}
		}
	}
	// Dragons: where each is, how long, and where the enemy queen is.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "positions" || only != "" {continue}
		for entry in gizmo.positions {
			subject, named := entry.dragon.?
			if !named {continue}
			truth_dragon: Dragon_Fact
			alive := false
			for dragon in turn.dragons {if dragon.id == subject {truth_dragon, alive = dragon, true}}
			// A dragon knows its own place and length, so neither is graded.
			own := subject == turn.dragon
			if !own {
				positions := belief_of(&beliefs, "Positions", .Positions, allocator)
				fact := Stated_Fact{key = subject, value = i64(entry.cell), cells = entry.cells, radius = entry.radius}
				place := len(entry.cells) > 0 ? fmt.tprintf("in %d cells from %s", len(entry.cells), cell_name(entry.cell, width)) : fmt.tprintf("within %d of %s", entry.radius, cell_name(entry.cell, width))
				if !alive {
					fact.gone = true
					state(positions, fact, describe, fmt.tprintf("D%d at %s: dead or not yet born", subject, cell_name(entry.cell, width)))
				} else {
					fact.correct = truth_dragon.head >= 0 && position_holds(fact, truth_dragon.head, width, height)
					state(positions, fact, describe, fmt.tprintf("D%d %s: head at %s", subject, place, cell_name(truth_dragon.head, width)))
				}
			}
			if length, stated := entry.length.?; stated && alive && !own {
				lengths := belief_of(&beliefs, "Lengths", .Lengths, allocator)
				fact := Stated_Fact{key = subject, value = i64(length), bound = !entry.length_exact}
				fact.correct = entry.length_exact ? truth_dragon.length == length : truth_dragon.length >= length
				state(lengths, fact, describe, fmt.tprintf("D%d length %s%d, replay %d", subject, entry.length_exact ? "" : "at least ", length, truth_dragon.length))
			}
			if subject != enemy_queen(turn) || own {continue}
			// The same position again, as the team's one fact about the enemy queen.
			queen := belief_of(&beliefs, "Enemy queen", .Queen, allocator)
			fact := Stated_Fact{key = subject, value = i64(entry.cell), cells = entry.cells, radius = entry.radius}
			if !alive {
				fact.gone = true
				state(queen, fact, describe, fmt.tprintf("Enemy queen D%d at %s: dead", subject, cell_name(entry.cell, width)))
			} else {
				fact.correct = truth_dragon.head >= 0 && position_holds(fact, truth_dragon.head, width, height)
				state(queen, fact, describe, fmt.tprintf("Enemy queen D%d near %s: head at %s", subject, cell_name(entry.cell, width), cell_name(truth_dragon.head, width)))
			}
		}
	}
	return beliefs
}

// The enemy's queen, one of the initial dragons 0 and 1: the one on the other
// team, or the other of the two when this dragon's own queen is the one alive.
// -1 when neither lives.
enemy_queen :: proc(turn: ^Dragon_Turn) -> i32 {
	for dragon in turn.dragons {
		if dragon.id != 0 && dragon.id != 1 {continue}
		return dragon.team != turn.team ? dragon.id : 1 - dragon.id
	}
	return -1
}

// One belief's knowledge across a team at one turn. The raw counts are kept
// so that rounds and games pool: each measure below is a ratio of sums.
Knowledge_Row :: struct {
	category:               string,
	kind:                   Fact_Kind,
	// Graded living dragons, and those stating any fact of the belief.
	dragons, stating:       i32,
	// Facts that exist for the team to know, and for one dragon to know.
	possible, each:         i32,
	// Facts stated, every dragon's counted, and those correct.
	facts, correct:         i64,
	// Of those, the facts about what exists, and the distinct ones.
	covered:                i64,
	known:                  i32,
	// With two or more graded dragons: the facts stated, and over them the
	// share of the other graded dragons stating each too. One dragon alone
	// shares nothing and counts in neither.
	sharable:               i64,
	shared:                 f64,
	// With two or more graded dragons: how many, and those at least half of
	// whose facts another dragon states too.
	linkable, linked:       i32,
	// Pairs of dragons stating one fact, and those whose values contradict.
	comparisons, conflicts: i64,
	// Dragons in at least one contradiction, of `linkable`.
	disputing:              i32,
	// Facts two or more dragons state, and those most of whose holders are wrong.
	agreed, misled:         i32,
}

// The four measures, each a share in [0, 1], with -1 where nothing was there
// to measure.
Knowledge_Measures :: struct {
	connectivity, linked, agreement, disputing, coverage, each, validity, misled: f64,
}

share_of :: proc(part, whole: f64) -> f64 {return whole > 0 ? part / whole : -1}

knowledge_measures :: proc(row: Knowledge_Row) -> Knowledge_Measures {
	agreement := share_of(f64(row.comparisons - row.conflicts), f64(row.comparisons))
	return {
		connectivity = share_of(row.shared, f64(row.sharable)),
		linked = share_of(f64(row.linked), f64(row.linkable)),
		agreement = agreement,
		disputing = share_of(f64(row.disputing), f64(row.linkable)),
		coverage = share_of(f64(row.known), f64(row.possible)),
		each = share_of(f64(row.covered), f64(row.dragons) * f64(row.each)),
		validity = share_of(f64(row.correct), f64(row.facts)),
		misled = share_of(f64(row.misled), f64(row.agreed)),
	}
}

// A share as a whole percentage, or a dash where nothing was measured.
percent_text :: proc(share: f64) -> string {
	return share < 0 ? "–" : fmt.tprintf("%d%%", int(100 * share + 0.5))
}

// Each living dragon of `team` at the end of turn `index` with its latest
// usable record, and those without one and why.
team_records :: proc(game: ^Loaded_Game, index, team: int) -> (alive: [dynamic]i32, latest: map[i32]^Dragon_Turn, living: int, unread: Unread_Dragons) {
	view := &game.view
	stop := index + 1 < len(view.turn_event) ? int(view.turn_event[index + 1]) : len(view.event_kind)
	board := board_after_events(game, &game.consensus_board, stop, false)
	alive = make([dynamic]i32, context.temp_allocator)
	unread = {
		yet_to_act = make([dynamic]i32, context.temp_allocator),
		rebuilding = make([dynamic]i32, context.temp_allocator),
		without    = make([dynamic]i32, context.temp_allocator),
	}
	living = len(board.dragons)
	for dragon in board.dragons {if int(dragon.team) == team {append(&alive, dragon.id)}}
	slice.sort(alive[:])
	latest = make(map[i32]^Dragon_Turn, context.temp_allocator)
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
		if dragon in latest {continue}
		if !acted {append(&unread.yet_to_act, dragon)
		} else if game.view.pending_dragons[dragon] {append(&unread.rebuilding, dragon)
		} else {append(&unread.without, dragon)}
	}
	return
}

// Mark `cell` as allowed by the holders in `bit`.
mark :: proc(marks: []u64, touched: ^[dynamic]i32, cell: i32, bit: u64) {
	if marks[cell] == 0 {append(touched, cell)}
	marks[cell] |= bit
}

// Every belief's knowledge across the graded dragons in `latest`, with
// `living` dragons of both teams on the board.
knowledge_rows :: proc(game: ^Loaded_Game, alive: []i32, latest: map[i32]^Dragon_Turn, living: int) -> [dynamic]Knowledge_Row {
	rows := make([dynamic]Knowledge_Row, context.temp_allocator)
	width, height := game.view.width, game.view.height
	area := width * height
	// One slot a graded dragon, below 64 since a team holds at most 64.
	Holding :: struct {
		key, slot: i32,
		fact:      ^Stated_Fact,
	}
	Category :: struct {
		kind:     Fact_Kind,
		holdings: [dynamic]Holding,
		facts:    [64]i64,
	}
	categories := make(map[string]^Category, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	slots := i32(0)
	for dragon in alive {
		turn := latest[dragon] or_continue
		if slots >= 64 {break}
		slot := slots
		slots += 1
		beliefs := stated_beliefs(game, turn, false)
		for &belief in beliefs {
			if belief.category not_in categories {
				categories[belief.category] = new_clone(Category{kind = belief.kind, holdings = make([dynamic]Holding, context.temp_allocator)}, context.temp_allocator)
				append(&order, belief.category)
			}
			category := categories[belief.category]
			for &fact in belief.facts {append(&category.holdings, Holding{fact.key, slot, &fact})}
			category.facts[slot] += i64(len(belief.facts))
		}
	}
	marks := make([]u64, area, context.temp_allocator)
	touched := make([dynamic]i32, context.temp_allocator)
	for name in order {
		category := categories[name]
		row := Knowledge_Row{category = name, kind = category.kind, dragons = slots}
		switch category.kind {
		case .Sides:
			row.possible, row.each = 4 * area, 4 * area
		case .Cells:
			row.possible, row.each = area, area
		case .Positions, .Lengths:
			row.possible, row.each = i32(living), i32(max(living - 1, 0))
		case .Queen:
			row.possible, row.each = 1, 1
		}
		for count in category.facts[:slots] {if count > 0 {row.stating += 1}}
		shared_facts: [64]i64
		disputing: u64
		holdings := category.holdings[:]
		slice.sort_by(holdings, proc(a, b: Holding) -> bool {return a.key < b.key || a.key == b.key && a.slot < b.slot})
		start := 0
		for start < len(holdings) {
			stop := start
			for stop < len(holdings) && holdings[stop].key == holdings[start].key {stop += 1}
			group := holdings[start:stop]
			start = stop
			holders := i64(len(group))
			// A key's facts are all about one thing, so share its standing.
			exists := !group[0].fact.gone
			if exists {row.known += 1}
			wrong := 0
			for holding in group {
				row.facts += 1
				if exists {row.covered += 1}
				if holding.fact.correct {row.correct += 1} else {wrong += 1}
				if slots > 1 {
					row.sharable += 1
					row.shared += f64(holders - 1) / f64(slots - 1)
				}
				if holders > 1 {shared_facts[holding.slot] += 1}
			}
			if holders < 2 {continue}
			row.agreed += 1
			if wrong * 2 > len(group) {row.misled += 1}
			row.comparisons += holders * (holders - 1) / 2
			// Which pairs of holders contradict each other.
			switch category.kind {
			case .Sides, .Cells:
				// Equal values agree: sort by value and count each run's pairs.
				values := make([]Holding, len(group), context.temp_allocator)
				copy(values, group)
				slice.sort_by(values, proc(a, b: Holding) -> bool {return a.fact.value < b.fact.value})
				run := 0
				for run < len(values) {
					end := run
					for end < len(values) && values[end].fact.value == values[run].fact.value {end += 1}
					same := i64(end - run)
					row.conflicts -= same * (same - 1) / 2
					if same < holders {for holding in values[run:end] {disputing |= u64(1) << u64(holding.slot)}}
					run = end
				}
				row.conflicts += holders * (holders - 1) / 2
			case .Lengths:
				// Two exact lengths must be equal, and an exact length can't be
				// under another's lower bound.
				for first, position in group {
					for second in group[position + 1:] {
						a, b := first.fact, second.fact
						clash := !a.bound && !b.bound && a.value != b.value || !a.bound && b.bound && a.value < b.value || a.bound && !b.bound && b.value < a.value
						if clash {
							row.conflicts += 1
							disputing |= u64(1) << u64(first.slot) | u64(1) << u64(second.slot)
						}
					}
				}
			case .Positions, .Queen:
				// Two positions agree when some cell is in both: mark each cell
				// with the holders allowing it, then gather who meets whom.
				for holding in group {
					fact := holding.fact
					bit := u64(1) << u64(holding.slot)
					if len(fact.cells) > 0 {
						for cell in fact.cells {if cell >= 0 && cell < area {mark(marks, &touched, cell, bit)}}
					} else if fact.radius >= width + height {
						for cell in 0 ..< area {mark(marks, &touched, cell, bit)}
					} else {
						centre := i32(fact.value)
						for dy in -fact.radius ..= fact.radius {
							reach := fact.radius - abs(dy)
							for dx in -reach ..= reach {
								x := ((centre % width + dx) % width + width) % width
								y := ((centre / width + dy) % height + height) % height
								mark(marks, &touched, y * width + x, bit)
							}
						}
					}
				}
				meets: [64]u64
				for cell in touched {
					held := marks[cell]
					for slot in u64(0) ..< 64 {if held & (u64(1) << slot) != 0 {meets[slot] |= held}}
					marks[cell] = 0
				}
				clear(&touched)
				for first, position in group {
					for second in group[position + 1:] {
						if meets[first.slot] & (u64(1) << u64(second.slot)) == 0 {
							row.conflicts += 1
							disputing |= u64(1) << u64(first.slot) | u64(1) << u64(second.slot)
						}
					}
				}
			}
		}
		if slots > 1 {
			row.linkable = slots
			for slot in 0 ..< slots {
				facts := category.facts[slot]
				if facts > 0 && 2 * shared_facts[slot] >= facts {row.linked += 1}
				if disputing & (u64(1) << u64(slot)) != 0 {row.disputing += 1}
			}
		}
		append(&rows, row)
	}
	return rows
}

// `viewer --knowledge FILE`: rebuild every dragon the recovery can, then
// write each round's knowledge for each team it rebuilt as a `knowledge`
// columns file (tools/gamedata/format.md), measured at the end of the round.
export_knowledge :: proc(viewer: ^Viewer_State, path: string) -> bool {
	game := &viewer.game
	view := &game.view
	start_recovery(viewer, whole = true)
	defer stop_recovery(viewer)
	asked := false
	reported := time.tick_now()
	for viewer.recovery.running {
		poll_recovery(viewer)
		if view.recovery_starting {time.sleep(20 * time.Millisecond); continue}
		waiting := make([dynamic]i32, context.temp_allocator)
		for dragon, pending in view.pending_dragons {if pending {append(&waiting, dragon)}}
		if len(waiting) == 0 {break}
		if !asked {
			slice.sort(waiting[:])
			request_recovery(viewer, waiting[:])
			asked = true
		}
		if time.tick_since(reported) > 15 * time.Second {
			fmt.eprintfln("knowledge: rebuilt %d of %d dragons", view.recoverable_dragons - len(waiting), view.recoverable_dragons)
			reported = time.tick_now()
		}
		free_all(context.temp_allocator)
		time.sleep(20 * time.Millisecond)
	}
	if viewer.recovery.stopped_early {fmt.eprintln("knowledge: the recovery ended before every dragon was rebuilt")}
	writer := Columns_Writer{kind = "knowledge"}
	append_column_value(&writer, "meta.version", u32(1))
	declare_string_list(&writer, "enum.category")
	declare_string_list(&writer, "enum.kind")
	for kind in Fact_Kind {append_column_string(&writer, "enum.kind", fmt.tprint(kind))}
	categories := make([dynamic]string)
	for round in 0 ..< frame_count(viewer) {
		index := turn_count_before_frame(game, round + 1) - 1
		if index < 0 {continue}
		for team in 0 ..< 2 {
			if !view.recoverable_teams[team] {continue}
			alive, latest, living, _ := team_records(game, index, team)
			for row in knowledge_rows(game, alive[:], latest, living) {
				category, found := slice.linear_search(categories[:], row.category)
				if !found {
					category = len(categories)
					append(&categories, strings.clone(row.category))
					append_column_string(&writer, "enum.category", row.category)
				}
				append_column_value(&writer, "row.round", i32(round))
				append_column_value(&writer, "row.team", u8(team))
				append_column_value(&writer, "row.category", u8(category))
				append_column_value(&writer, "row.kind", u8(row.kind))
				append_column_value(&writer, "row.alive", i32(len(alive)))
				append_column_value(&writer, "row.dragons", row.dragons)
				append_column_value(&writer, "row.stating", row.stating)
				append_column_value(&writer, "row.possible", row.possible)
				append_column_value(&writer, "row.each", row.each)
				append_column_value(&writer, "row.facts", row.facts)
				append_column_value(&writer, "row.correct", row.correct)
				append_column_value(&writer, "row.covered", row.covered)
				append_column_value(&writer, "row.known", row.known)
				append_column_value(&writer, "row.sharable", row.sharable)
				append_column_value(&writer, "row.linkable", row.linkable)
				append_column_value(&writer, "row.shared", row.shared)
				append_column_value(&writer, "row.linked", row.linked)
				append_column_value(&writer, "row.comparisons", row.comparisons)
				append_column_value(&writer, "row.conflicts", row.conflicts)
				append_column_value(&writer, "row.disputing", row.disputing)
				append_column_value(&writer, "row.agreed", row.agreed)
				append_column_value(&writer, "row.misled", row.misled)
			}
		}
		free_all(context.temp_allocator)
	}
	return write_columns_file(&writer, path)
}

// A belief's knowledge in words, for its detail dialog.
knowledge_text :: proc(row: Knowledge_Row) -> string {
	measures := knowledge_measures(row)
	return fmt.tprintf(
		"Team knowledge, over %d graded dragons, %d stating it:\n" +
		"Connectivity %s: a stated fact is stated by %s of the other graded dragons too, and %d of %d dragons share at least half of what they state. One dragon alone shares nothing to measure.\n" +
		"Agreement %s: %d of %d pairs of dragons stating the same fact contradict each other, and %d dragons are in a contradiction.\n" +
		"Coverage %s: the team states %d of %d facts that exist, and each dragon %s of the %d it could. Facts about dragons no longer alive are left out here and count as false below.\n" +
		"Validity %s: %d of %d stated facts are true, and %d of the %d facts two or more dragons state are false for most of them (%s).\n",
		row.dragons, row.stating,
		percent_text(measures.connectivity), percent_text(measures.connectivity), row.linked, row.linkable,
		percent_text(measures.agreement), row.conflicts, row.comparisons, row.disputing,
		percent_text(measures.coverage), row.known, row.possible, percent_text(measures.each), row.each,
		percent_text(measures.validity), row.correct, row.facts, row.misled, row.agreed, percent_text(measures.misled),
	)
}
