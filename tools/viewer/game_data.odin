package viewer

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:slice"
import "core:strings"

// One game in view: its mapped `game` columns (tools/gamedata/format.md), the
// column slices the viewer reads, the few small facts derived from them at
// load, and what the recovery has streamed so far (recovery_stream.odin).
// Turns, pings and boards stay in the columns; a turn's record is built only
// when the viewer opens it (game_turn).
Game_View :: struct {
	columns:                                 Columns_File, // kind "game"
	width, height:                           i32,
	map_name, bot_a, bot_b, winner:          string,
	edges:                                   []Board_Edge,
	spawn_rules:                             []Spawn_Rule,
	// Each cell's maximum reset gap, 0 where it never spawns and -1 where the
	// replay records no rule for it.
	spawn_maximum:                           []i32,
	// The map's symmetry, from the starting bodies (mirror.odin).
	mirror:                                  Mirror_Transform,
	point_limit:                            i64,
	points_recorded:                         bool,
	event_kind:                              []u8,
	event_a, event_b, event_c, event_d:      []i32,
	round_event:                             []u32,
	turn_round, turn_dragon, turn_event:     []u32,
	turn_team:                               []u8,
	turn_points:                             []u64,
	turn_points_known:                       []u8,
	ping_round, ping_sender, ping_hit:       []i32,
	ping_received_round:                     []i32,
	ping_hit_kind:                           []u16,
	ping_direction:                          []u8,
	ping_origin, ping_end:                   []u32,
	ping_value:                              []u64,
	// From the recovery stream. Until it has announced every dragon, every
	// turn waits for it.
	recovery_starting:                       bool,
	records:                                 map[int]string,       // game turn row to its record (JSON)
	// The rounds whose turns the recovery rebuilds with diagnostics; the rest
	// bring only their breakdown (recovery_stream.odin).
	window_first, window_last:               i32,
	recoverable:                             map[i32]bool,         // dragons the recovery can rebuild
	kept:                                    map[i32]bool,         // dragons whose every record stays (`kept`)
	pending_dragons:                         map[i32]bool,         // recoverable, not recovered yet
	recoverable_dragons:                     int,                  // how many the recovery announced it can rebuild
	recoverable_teams:                       [2]bool,              // the teams with a build it can rebuild
	failed_dragons:                          int,                  // how many of those its rebuild failed
	// Per team, the rebuilt turns received and those whose action and sonar
	// match the replay, the evidence that the build is the one that played,
	// each counted once from the turn's evidence.
	rebuilt_turns, matching_turns:           [2]int,
	turn_evidence:                           []bit_set[Turn_Evidence;u8],
	dragon_builds:                           map[i32]Dragon_Build, // each dragon's recorded build
	breakdowns:                              [dynamic]Team_Breakdown,
	// Per game turn row, its place in its team's breakdown (breakdown.odin).
	turn_breakdown:                          []Turn_Breakdown,
	// Where the viewer opens (command line).
	selected_dragon, start_frame:            i32,
	start_playing:                           bool,
	start_frames_per_second:                 f32,
}

// What has arrived for a game turn row: it was rebuilt, its rebuilt action
// matched the replay, its record stays for the game, coming from the dragon's
// own log or a kept dragon, and its record was tallied into the match's
// issues.
Turn_Evidence :: enum u8 {
	Rebuilt,
	Matched,
	Lasting,
	Tallied,
}

// A dragon's recorded build identity and whether it could be resolved.
Dragon_Build :: struct {
	guid, variant, status: string,
}

// Where a saved comment goes and the replay it names (annotations.odin), from
// the command line.
Comment_Context :: struct {
	inbox_path: string, // planning/inbox.md
	replay:     string,
}

// One sonar ping as drawn and joined: recorded fields, then any joined notes.
Game_Ping :: struct {
	id, round, received_round, sender, hit, hit_kind, origin, end: i32,
	direction, value:                                             string,
	decoded, acceptance, receiver_meaning, memory_evidence:       string,
}

Loaded_Game :: struct {
	arena:                  virtual.Arena,
	view:                   Game_View,
	source_path:            string,
	// The teacher's review of one side's decisions, GAME.review.tsv (teacher_review.odin).
	review:                 map[[2]i32]Review_Row,
	turn_indices_by_dragon: map[i32][dynamic]int,
	first_turn_of_round:    []int,
	first_ping_of_round:    []int,
	turn_cache:             map[int]^Dragon_Turn, // turns opened so far
	// Rebuilt records and every turn opened, freed when the window moves.
	turn_arena:             virtual.Arena,
	// Every turn record received, in arrival order, and how many are tallied
	// into the match's issues (issues.odin).
	issue_rows:             [dynamic]int,
	issues_scanned:         int,
	issues:                 map[string]Issue_Tally,
	// bceval's evaluation after each round (evaluation.odin), computed on first use.
	evaluation:             [dynamic]Evaluation,
	evaluated:              bool,
	keyframes:              [dynamic]Board_Keyframe,
	turn_board:             Board_Replay,
	frame_board:            Board_Replay,
	// Where opened turns and the team consensus replay boards, apart from
	// what is drawn.
	facts_board:            Board_Replay,
	consensus_board:        Board_Replay,
	// Consensus categories in order of first appearance, each one's meaning
	// and whether it is a singleton claim.
	consensus_categories:   [dynamic]string,
	consensus_meanings:     map[string]string,
	consensus_singletons:   map[string]bool,
	consensus_scopes:       map[string]string,
	truth:                  Map_Truth,                       // built when first graded
}

@(rodata)
DIRECTION_NAMES := [4]string{"north", "east", "south", "west"}

game_allocator :: proc(game: ^Loaded_Game) -> mem.Allocator {
	return virtual.arena_allocator(&game.arena)
}

turn_allocator :: proc(game: ^Loaded_Game) -> mem.Allocator {
	return virtual.arena_allocator(&game.turn_arena)
}

// Replace the game, keeping the old one if the new files don't open. The
// files are mapped and checked first; the old game is destroyed only then, and
// the new one is built inside `viewer.game`, so everything that grows later
// allocates from the arena in its final place. Caller owns the returned string.
load_game_into_viewer :: proc(viewer: ^Viewer_State, path: string) -> (status: string) {
	columns, columns_ok := open_columns_file(path, context.temp_allocator)
	if !columns_ok || columns.kind != "game" {
		if columns_ok {close_columns_file(&columns)}
		return fmt.aprintf("%s is not a game columns file (just gamedata)", path)
	}
	close_columns_file(&columns)

	previous_playback := viewer.playback
	previous_dragon := viewer.selected_dragon
	previous_settings := viewer.game.view
	was_loaded := viewer.has_game
	if viewer.has_game {
		close_columns_file(&viewer.game.view.columns)
		virtual.arena_destroy(&viewer.game.arena)
		virtual.arena_destroy(&viewer.game.turn_arena)
	}
	viewer.game = {}
	clear_ghost(&viewer.ghost)
	game := &viewer.game
	if virtual.arena_init_growing(&game.arena) != nil || virtual.arena_init_growing(&game.turn_arena) != nil {
		viewer.has_game = false
		return strings.clone("Could not reserve memory for the game")
	}
	allocator := game_allocator(game)
	view := &game.view
	view.columns, _ = open_columns_file(path, allocator)
	game.source_path = strings.clone(path, allocator)
	read_game_columns(game, allocator)
	load_teacher_review(game, allocator)
	view.records = make(map[int]string, allocator)
	view.recoverable = make(map[i32]bool, allocator)
	view.kept = make(map[i32]bool, allocator)
	view.pending_dragons = make(map[i32]bool, allocator)
	view.turn_evidence = make([]bit_set[Turn_Evidence;u8], len(view.turn_team), allocator)
	view.dragon_builds = make(map[i32]Dragon_Build, allocator)
	view.breakdowns = make([dynamic]Team_Breakdown, allocator)
	view.turn_breakdown = make([]Turn_Breakdown, len(view.turn_team), allocator)
	for &entry in view.turn_breakdown {entry.pair = -1}

	view.selected_dragon = previous_settings.selected_dragon
	view.start_frame = previous_settings.start_frame
	view.start_playing = previous_settings.start_playing
	view.start_frames_per_second = previous_settings.start_frames_per_second
	viewer.has_game = true
	viewer.playback = {
		frame_position    = 0,
		playing           = false,
		frames_per_second = viewer.playback.frames_per_second,
	}
	if was_loaded {
		viewer.playback = previous_playback
		viewer.playback.frame_position = clamp(previous_playback.frame_position, 0, f32(frame_count(viewer) - 1))
		viewer.selected_dragon = previous_dragon if previous_dragon in game.turn_indices_by_dragon else -1
		if previous_playback.substeps {select_dragon_turn(viewer, viewer.selected_dragon)}
		clear(&viewer.highlights)
		viewer.selected_cell = -1
	} else if len(view.turn_dragon) > 0 {
		viewer.selected_dragon = i32(view.turn_dragon[0])
	}
	return fmt.aprintf(
		"Loaded %s: %s vs %s on %s, %d rounds, winner %s",
		path,
		bot_name(view.bot_a),
		bot_name(view.bot_b),
		view.map_name,
		len(view.round_event),
		view.winner,
	)
}

read_game_columns :: proc(game: ^Loaded_Game, allocator: mem.Allocator) {
	view := &game.view
	file := &view.columns
	view.width = i32(column_values(file, "meta.width", u32)[0])
	view.height = i32(column_values(file, "meta.height", u32)[0])
	view.map_name = string_row(file, "meta.map_name", "meta.map_name#", 0)
	view.bot_a = string_row(file, "meta.bot_a", "meta.bot_a#", 0)
	view.bot_b = string_row(file, "meta.bot_b", "meta.bot_b#", 0)
	winner := column_values(file, "meta.winner", i8)[0]
	view.winner = winner == 0 ? "A" : winner == 1 ? "B" : "draw"
	view.point_limit = 100_000_000
	view.event_kind = column_values(file, "event.kind", u8)
	view.event_a = column_values(file, "event.a", i32)
	view.event_b = column_values(file, "event.b", i32)
	view.event_c = column_values(file, "event.c", i32)
	view.event_d = column_values(file, "event.d", i32)
	view.round_event = column_values(file, "round.event", u32)
	view.turn_round = column_values(file, "turn.round", u32)
	view.turn_dragon = column_values(file, "turn.dragon", u32)
	view.turn_event = column_values(file, "turn.event", u32)
	view.turn_team = column_values(file, "turn.team", u8)
	view.turn_points = column_values(file, "turn.points", u64)
	view.turn_points_known = column_values(file, "turn.points?", u8)
	for known in view.turn_points_known {if known != 0 {view.points_recorded = true; break}}
	view.ping_round = column_values(file, "ping.round", i32)
	view.ping_sender = column_values(file, "ping.sender", i32)
	view.ping_hit = column_values(file, "ping.hit", i32)
	view.ping_received_round = column_values(file, "ping.received_round", i32)
	view.ping_hit_kind = column_values(file, "ping.hit_kind", u16)
	view.ping_direction = column_values(file, "ping.direction", u8)
	view.ping_origin = column_values(file, "ping.origin", u32)
	view.ping_end = column_values(file, "ping.end", u32)
	view.ping_value = column_values(file, "ping.value", u64)
	edge_x := column_values(file, "edge.x", u32)
	edge_y := column_values(file, "edge.y", u32)
	edge_side := column_values(file, "edge.side", u8)
	edge_portal := column_values(file, "edge.portal", i32)
	view.edges = make([]Board_Edge, len(edge_x), allocator)
	for &edge, index in view.edges {
		edge = {
			x      = i32(edge_x[index]),
			y      = i32(edge_y[index]),
			side   = i32(edge_side[index]),
			kelp   = edge_portal[index] < 0,
			portal = edge_portal[index],
		}
	}
	spawn_cell := column_values(file, "spawn.cell", u32)
	spawn_minimum := column_values(file, "spawn.minimum", i32)
	spawn_maximum := column_values(file, "spawn.maximum", i32)
	view.spawn_rules = make([]Spawn_Rule, len(spawn_cell), allocator)
	for &rule, index in view.spawn_rules {
		rule = {i32(spawn_cell[index]), spawn_minimum[index], spawn_maximum[index]}
	}
	view.spawn_maximum = make([]i32, int(view.width * view.height), allocator)
	for &maximum in view.spawn_maximum {maximum = -1}
	for rule in view.spawn_rules {
		if rule.cell >= 0 && int(rule.cell) < len(view.spawn_maximum) {view.spawn_maximum[rule.cell] = rule.maximum}
	}
	view.mirror = infer_mirror(view)

	rounds := len(view.round_event)
	game.first_turn_of_round = make([]int, rounds + 2, allocator)
	game.turn_indices_by_dragon = make(map[i32][dynamic]int, allocator)
	game.issue_rows = make([dynamic]int, allocator)
	next_round := 0
	for round_number, turn_index in view.turn_round {
		for next_round <= int(round_number) {
			game.first_turn_of_round[next_round] = turn_index
			next_round += 1
		}
		dragon := i32(view.turn_dragon[turn_index])
		if dragon not_in game.turn_indices_by_dragon {
			game.turn_indices_by_dragon[dragon] = make([dynamic]int, allocator)
		}
		append(&game.turn_indices_by_dragon[dragon], turn_index)
	}
	for ; next_round < len(game.first_turn_of_round); next_round += 1 {
		game.first_turn_of_round[next_round] = len(view.turn_round)
	}
	game.first_ping_of_round = make([]int, rounds + 2, allocator)
	next_round = 0
	for round_number, ping_index in view.ping_round {
		for next_round <= int(round_number) && next_round < len(game.first_ping_of_round) {
			game.first_ping_of_round[next_round] = ping_index
			next_round += 1
		}
	}
	for ; next_round < len(game.first_ping_of_round); next_round += 1 {
		game.first_ping_of_round[next_round] = len(view.ping_round)
	}
	game.turn_cache = make(map[int]^Dragon_Turn, allocator)
	game.keyframes = make([dynamic]Board_Keyframe, allocator)
	game.turn_board.pearls = make([dynamic]i32, allocator)
	game.turn_board.timers = make([dynamic]Pearl_Timer, allocator)
	game.frame_board.pearls = make([dynamic]i32, allocator)
	game.frame_board.timers = make([dynamic]Pearl_Timer, allocator)
}

turn_count :: proc(game: ^Loaded_Game) -> int {
	return len(game.view.turn_round)
}

// Number of turns before the given frame: turns in rounds < frame.
turn_count_before_frame :: proc(game: ^Loaded_Game, frame: i32) -> int {
	return game.first_turn_of_round[clamp(int(frame), 0, len(game.first_turn_of_round) - 1)]
}

// A turn's record: its recorded facts from the game columns, its board's head
// and length, its diagnostic record when the recovery has streamed it, and the
// mental map's grades. Built when first opened and kept for the life of the
// loaded game, until a record arrives for a turn opened without one.
game_turn :: proc(game: ^Loaded_Game, index: int) -> ^Dragon_Turn {
	if cached, found := game.turn_cache[index]; found {return cached}
	allocator := turn_allocator(game)
	view := &game.view
	turn := new(Dragon_Turn, allocator)
	if record, found := view.records[index]; found {
		if error := json.unmarshal_string(record, turn, allocator = allocator); error != nil {
			turn^ = {gizmo_status = fmt.aprintf("Diagnostics record unreadable: %v", error, allocator = allocator)}
		}
		turn.has_record = true
	} else {
		dragon, round := i32(view.turn_dragon[index]), i32(view.turn_round[index])
		pending := view.recovery_starting || view.pending_dragons[dragon] || outside_window(view, dragon, round)
		turn.gizmo_reliable = true
		turn.recovery_pending = pending
		turn.gizmo_status = pending ? "Not recovered yet" : "No diagnostics recorded for this turn"
	}
	turn.dragon = i32(view.turn_dragon[index])
	turn.team = i32(view.turn_team[index])
	turn.round = i32(view.turn_round[index])
	turn.action = strings.clone(string_row(&view.columns, "turn.action", "turn.action#", index), allocator)
	turn.points = i64(view.turn_points[index])
	turn.point_failure = strings.clone(string_row(&view.columns, "turn.failure", "turn.failure#", index), allocator)
	if build, found := view.dragon_builds[turn.dragon]; found {
		turn.build_guid, turn.build_variant, turn.build_status = build.guid, build.variant, build.status
	}
	// A replay of its own, so opening a turn never moves the board being drawn.
	board := board_after_events(game, &game.facts_board, int(view.turn_event[index]), false)
	for dragon in board.dragons {
		if dragon.id == turn.dragon && len(dragon.body) > 0 {
			turn.head, turn.length = dragon.body[0], i32(len(dragon.body))
		}
	}
	turn.pearls = slice.clone(board.pearls, allocator)
	spawns := make([dynamic][2]i32, allocator)
	for due, cell in game.facts_board.state.due {if due >= 0 {append(&spawns, [2]i32{i32(cell), due})}}
	turn.spawns = spawns[:]
	dragons := make([]Dragon_Fact, len(board.dragons), allocator)
	for dragon, position in board.dragons {
		dragons[position] = {dragon.id, dragon.team, len(dragon.body) > 0 ? dragon.body[0] : -1, i32(len(dragon.body))}
	}
	turn.dragons = dragons
	game.turn_cache[index] = turn
	return turn
}

// The selected dragon's pre-action turn IN this round. No stale fallback.
selected_dragon_turn :: proc(game: ^Loaded_Game, dragon: i32, frame: i32) -> (^Dragon_Turn, bool) {
	indices, found := game.turn_indices_by_dragon[dragon]
	if !found {return nil, false}
	limit := turn_count_before_frame(game, frame + 1)
	for position := len(indices) - 1; position >= 0; position -= 1 {
		if indices[position] < limit && i32(game.view.turn_round[indices[position]]) == frame {
			return opened_turn(game, indices[position]), true
		}
	}
	return nil, false
}

// A turn with its retained records rebuilt and its memory graded, as the
// viewer shows it and the joins read it.
opened_turn :: proc(game: ^Loaded_Game, index: int) -> ^Dragon_Turn {
	indices := game.turn_indices_by_dragon[i32(game.view.turn_dragon[index])]
	position, _ := slice.binary_search(indices[:], index)
	expand_retained_gizmos(game, indices[:], position)
	turn := game_turn(game, index)
	if !turn.graded {
		grade_turn(game, turn)
		grade_beliefs(game, turn)
		turn.graded = true
	}
	return turn
}

// Ping `index`, joined with both ends' sonar records (radio.odin).
game_ping :: proc(game: ^Loaded_Game, index: int) -> Game_Ping {
	view := &game.view
	ping := Game_Ping {
		id             = i32(index),
		round          = view.ping_round[index],
		received_round = view.ping_received_round[index],
		sender         = view.ping_sender[index],
		hit            = view.ping_hit[index],
		hit_kind       = i32(view.ping_hit_kind[index]),
		origin         = i32(view.ping_origin[index]),
		end            = i32(view.ping_end[index]),
		direction      = DIRECTION_NAMES[view.ping_direction[index] & 3],
		value          = fmt.tprintf("%d", view.ping_value[index]),
		acceptance     = "not reported",
	}
	join_ping(game, &ping)
	return ping
}

// The pings sent in rounds `first` through `last`, as ping rows.
ping_rows_of_rounds :: proc(game: ^Loaded_Game, first, last: i32) -> (start, stop: int) {
	rows := game.first_ping_of_round
	return rows[clamp(int(first), 0, len(rows) - 1)], rows[clamp(int(last) + 1, 0, len(rows) - 1)]
}

// A runner may record a bot by its directory path, such as
// /work/out/results/ladder/bots/room-c. A bot version's path, ending in
// <line>/<kind>/<nnnn>[-purpose], gives its identifier, such as
// foil-0039 (AGENTS.md); any other gives its last part. Details keeps the
// recorded path.
bot_name :: proc(recorded: string) -> string {
	trimmed := strings.trim_right(recorded, "/")
	parts := strings.split(trimmed, "/", context.temp_allocator)
	if len(parts) >= 3 {
		line, kind, version := parts[len(parts) - 3], parts[len(parts) - 2], parts[len(parts) - 1]
		numbered := len(version) >= 4 && strings.trim_left(version[:4], "0123456789") == ""
		if (kind == "main" || kind == "test" || kind == "utils") && numbered {
			return fmt.tprintf("%s-%s-%s", line, kind, version)
		}
	}
	return parts[len(parts) - 1]
}
