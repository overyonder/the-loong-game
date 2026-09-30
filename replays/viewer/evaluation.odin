package viewer

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Each side's chance of winning after every round, from bceval 0.1.0 by
// xCirno1 (MIT, https://github.com/xCirno1/battlecode-eval), copied under
// references/battlecode-eval. This is its model ported to the viewer: the same
// 23 features per team measured on the board at the start of each round, and
// its fitted weights, read from its model.json. The features see the whole
// board, both teams and every tile's spawn gaps, as a replay does; a dragon
// can't compute them in play.

BCEVAL_MODEL :: #load("references/battlecode-eval/bceval/model.json", string)
BCEVAL_RICH_GAP :: 60 // a tile whose mean spawn gap is at most this is rich
BCEVAL_HOT_SHARE :: 0.30 // hot: the fastest tiles that together make this share of the supply
BCEVAL_WINDOW :: 25 // rounds of history behind the rate features
BCEVAL_FAR :: 30 // distance cap for the champion features
BCEVAL_HEAD_TO_HEAD :: 3 // the death reason of a lost head-to-head

Bceval_Feature :: enum {
	alive, total, longest, second, third, big5, big10,
	eat, eat_rich, eat_hot, deaths, lost_len, kills_h2h,
	terr, supply, rich_ctrl, hot_ctrl, pearls_near,
	champ_enemy_d, champ_enemy_n3, champ_enemy_n6, champ_ally_d, champ_exits,
}

Bceval_Group :: enum {bodies, economy, fights, ground, champion, side}

@(rodata)
BCEVAL_GROUP_OF := [Bceval_Feature]Bceval_Group {
	.alive = .bodies, .total = .bodies, .longest = .bodies, .second = .bodies, .third = .bodies, .big5 = .bodies, .big10 = .bodies,
	.eat = .economy, .eat_rich = .economy, .eat_hot = .economy,
	.deaths = .fights, .lost_len = .fights, .kills_h2h = .fights,
	.terr = .ground, .supply = .ground, .rich_ctrl = .ground, .hot_ctrl = .ground, .pearls_near = .ground,
	.champ_enemy_d = .champion, .champ_enemy_n3 = .champion, .champ_enemy_n6 = .champion, .champ_ally_d = .champion, .champ_exits = .champion,
}

Bceval_Model :: struct {
	knots:     []f64,
	features:  map[string]string,
	lin_scale: map[string]f64,
	weights:   map[string][]f64,
}

// Side A's chance after one round, and the log-odds by group behind it.
Evaluation :: struct {
	p_a:   f64,
	parts: [Bceval_Group]f64,
	// Each side on the board the round leaves: its dragons, its longest and
	// their total length.
	dragons, longest, total: [2]i32,
}

// The evaluation after each round of the game, indexed by round, computed on
// first use: one pass over the events, as bceval's replay_features makes.
game_evaluation :: proc(game: ^Loaded_Game) -> []Evaluation {
	if game.evaluated {return game.evaluation[:]}
	game.evaluated = true
	allocator := game_allocator(game)
	model: Bceval_Model
	if json.unmarshal_string(BCEVAL_MODEL, &model, allocator = context.temp_allocator) != nil {return nil}
	view := &game.view
	cells := int(view.width * view.height)
	landings := map_truth(game).landings
	rate := make([]f64, cells, context.temp_allocator)
	rich := make([]bool, cells, context.temp_allocator)
	hot := make([]bool, cells, context.temp_allocator)
	total_rate: f64
	for rule in view.spawn_rules {
		if rule.maximum <= 0 || rule.cell < 0 || int(rule.cell) >= cells {continue}
		rate[rule.cell] = 2.0 / f64(max(1, rule.minimum + rule.maximum))
		rich[rule.cell] = max(1, rule.minimum + rule.maximum) <= BCEVAL_RICH_GAP
		total_rate += rate[rule.cell]
	}
	// Hot tiles: fastest first, equal rates in board order as the map lists its
	// tiles, until they make the share of the supply.
	{
		Spawner :: struct {
			cell: i32,
			rate: f64,
		}
		spawners := make([dynamic]Spawner, context.temp_allocator)
		for value, cell in rate {if value > 0 {append(&spawners, Spawner{i32(cell), value})}}
		slice.stable_sort_by(spawners[:], proc(a, b: Spawner) -> bool {return a.rate > b.rate})
		accumulated: f64
		for spawner in spawners {
			if accumulated >= BCEVAL_HOT_SHARE * total_rate {break}
			hot[spawner.cell] = true
			accumulated += spawner.rate
		}
	}
	History :: struct {
		eat, eat_rich, eat_hot, h2h: [dynamic]i32,
		deaths:                      [dynamic][2]i32, // round, length
	}
	history: [2]History
	for &side in history {
		side.eat = make([dynamic]i32, context.temp_allocator)
		side.eat_rich = make([dynamic]i32, context.temp_allocator)
		side.eat_hot = make([dynamic]i32, context.temp_allocator)
		side.h2h = make([dynamic]i32, context.temp_allocator)
		side.deaths = make([dynamic][2]i32, context.temp_allocator)
	}
	state := initial_board_state(game, context.temp_allocator)
	distance := make([]i32, cells, context.temp_allocator)
	label := make([]i8, cells, context.temp_allocator)
	occupied := make([]bool, cells, context.temp_allocator)
	frontier := make([dynamic]i32, context.temp_allocator)
	next := make([dynamic]i32, context.temp_allocator)
	game.evaluation = make([dynamic]Evaluation, allocator)

	// The board's features for each side at the start of round `round`.
	snapshot :: proc(
		state: ^Board_State, round: i32, history: ^[2]History, rate: []f64, rich, hot: []bool,
		landings: [][4]i32, distance: []i32, label: []i8, occupied: []bool, frontier, next: ^[dynamic]i32,
	) -> (features: [2][Bceval_Feature]f64) {
		for &cell in occupied {cell = false}
		for body in state.bodies {for cell in body {occupied[cell] = true}}
		// Walking distance from the nearest head and whose it is, ties -1.
		for &value in distance {value = -1}
		clear(frontier)
		for dragon, index in state.dragons {
			body := state.bodies[index]
			if len(body) == 0 {continue}
			head := body[0]
			if distance[head] == 0 {
				if label[head] != i8(dragon.team) {label[head] = -1}
				continue
			}
			distance[head], label[head] = 0, i8(dragon.team)
			append(frontier, head)
		}
		for step: i32 = 1; len(frontier) > 0; step += 1 {
			clear(next)
			for cell in frontier {
				for neighbour in landings[cell] {
					if neighbour < 0 {continue}
					if distance[neighbour] < 0 {
						distance[neighbour], label[neighbour] = step, label[cell]
						append(next, neighbour)
					} else if distance[neighbour] == step && label[neighbour] != label[cell] {
						label[neighbour] = -1
					}
				}
			}
			frontier^, next^ = next^, frontier^
		}
		first := round - BCEVAL_WINDOW
		for side in 0 ..< 2 {
			f := &features[side]
			lengths := make([dynamic]i32, context.temp_allocator)
			champion := -1
			for dragon, index in state.dragons {
				if int(dragon.team) != side || len(state.bodies[index]) == 0 {continue}
				length := i32(len(state.bodies[index]))
				append(&lengths, length)
				if champion < 0 || length > i32(len(state.bodies[champion])) {champion = index}
			}
			slice.reverse_sort(lengths[:])
			append(&lengths, 0, 0, 0)
			f[.alive] = f64(len(lengths) - 3)
			for length in lengths {
				f[.total] += f64(length)
				if length >= 5 {f[.big5] += 1}
				if length >= 10 {f[.big10] += 1}
			}
			f[.longest], f[.second], f[.third] = f64(lengths[0]), f64(lengths[1]), f64(lengths[2])
			h := &history[side]
			for r in h.eat {if r >= first {f[.eat] += 1}}
			for r in h.eat_rich {if r >= first {f[.eat_rich] += 1}}
			for r in h.eat_hot {if r >= first {f[.eat_hot] += 1}}
			for death in h.deaths {if death[0] >= first {f[.deaths] += 1; f[.lost_len] += f64(death[1])}}
			for r in h.h2h {if r >= first {f[.kills_h2h] += 1}}
			for cell in 0 ..< len(label) {
				if distance[cell] < 0 || int(label[cell]) != side {continue}
				f[.terr] += 1
				f[.supply] += rate[cell]
				if rich[cell] {f[.rich_ctrl] += 1}
				if hot[cell] {f[.hot_ctrl] += 1}
				if state.pearl[cell] {f[.pearls_near] += 1}
			}
			if champion < 0 {continue}
			// Walking distance from the champion's head, capped.
			head := state.bodies[champion][0]
			reach := make(map[i32]i32, context.temp_allocator)
			reach[head] = 0
			ring := make([dynamic]i32, context.temp_allocator)
			append(&ring, head)
			for step: i32 = 1; step <= BCEVAL_FAR && len(ring) > 0; step += 1 {
				outer := make([dynamic]i32, context.temp_allocator)
				for cell in ring {
					for neighbour in landings[cell] {
						if neighbour < 0 || neighbour in reach {continue}
						reach[neighbour] = step
						append(&outer, neighbour)
					}
				}
				ring = outer
			}
			enemy, ally: i32 = BCEVAL_FAR + 1, BCEVAL_FAR + 1
			for dragon, index in state.dragons {
				if index == champion || len(state.bodies[index]) == 0 {continue}
				steps, reached := reach[state.bodies[index][0]]
				if !reached {continue}
				if int(dragon.team) != side {
					enemy = min(enemy, steps)
					if steps <= 3 {f[.champ_enemy_n3] += 1}
					if steps <= 6 {f[.champ_enemy_n6] += 1}
				} else {ally = min(ally, steps)}
			}
			f[.champ_enemy_d], f[.champ_ally_d] = f64(enemy), f64(ally)
			for neighbour in landings[head] {if neighbour >= 0 && !occupied[neighbour] {f[.champ_exits] += 1}}
		}
		return
	}

	evaluate :: proc(model: ^Bceval_Model, round: i32, features: [2][Bceval_Feature]f64) -> (result: Evaluation) {
		// Each knot's share of the round, interpolated linearly between them.
		knots := model.knots
		r := clamp(f64(round), knots[0], knots[len(knots) - 1])
		hats := make([]f64, len(knots), context.temp_allocator)
		for knot, index in knots {
			if r == knot {hats[index] = 1; continue}
			if index > 0 && knots[index - 1] <= r && r < knot {hats[index] = (r - knots[index - 1]) / (knot - knots[index - 1])}
			if index + 1 < len(knots) && knot < r && r <= knots[index + 1] {hats[index] = (knots[index + 1] - r) / (knots[index + 1] - knot)}
		}
		weight :: proc(weights: []f64, hats: []f64) -> (sum: f64) {
			for w, index in weights {if index < len(hats) {sum += w * hats[index]}}
			return
		}
		for feature in Bceval_Feature {
			name := fmt_feature(feature)
			a, b := max(features[0][feature], 0), max(features[1][feature], 0)
			difference: f64
			switch model.features[name] {
			case "log":
				difference = math.ln(1 + a) - math.ln(1 + b)
			case "share":
				difference = a + b > 0 ? a / (a + b) - 0.5 : 0
			case:
				scale := model.lin_scale[name] if name in model.lin_scale else 1
				difference = (features[0][feature] - features[1][feature]) / scale
			}
			result.parts[BCEVAL_GROUP_OF[feature]] += difference * weight(model.weights[name], hats)
		}
		result.parts[.side] += weight(model.weights["side"], hats)
		z: f64
		for part in result.parts {z += part}
		result.p_a = 1 / (1 + math.exp(-clamp(z, -40, 40)))
		return
	}

	current: i32 = -1
	// bceval lays a move's steps on the body when the dragon acts and trims them
	// at its body update, so a dragon that dies in its own move before any
	// update is counted with the steps it took, up to kelp. Its model was fitted
	// on that length, so the port keeps it.
	provisional: i32
	turn := 0
	for event in 0 ..< len(view.event_kind) {
		a, b := view.event_a[event], view.event_b[event]
		switch view.event_kind[event] {
		case EVENT_ROUND_START:
			// The board at the start of round a is the board after round a - 1.
			if a >= 1 && a <= 500 {
				features := snapshot(&state, a, &history, rate, rich, hot, landings, distance, label, occupied, &frontier, &next)
				for i32(len(game.evaluation)) < a - 1 {append(&game.evaluation, Evaluation{p_a = math.nan_f64()})}
				append(&game.evaluation, with_sides(evaluate(&model, a, features), features))
			}
		case EVENT_TURN_START:
			current, provisional = a, 0
			for turn < len(view.turn_event) && int(view.turn_event[turn]) < event {turn += 1}
			index := board_dragon_index(&state, a)
			if turn >= len(view.turn_event) || int(view.turn_event[turn]) != event || index < 0 || len(state.bodies[index]) == 0 {break}
			action := string_row(&view.columns, "turn.action", "turn.action#", turn)
			if !strings.has_prefix(action, "MOVE ") {break}
			cell := state.bodies[index][0]
			for letter in action[5:] {
				direction := strings.index_rune("NESW", letter)
				if direction < 0 || landings[cell][direction] < 0 {break}
				cell = landings[cell][direction]
				provisional += 1
			}
		case EVENT_MOVE:
			if a == current {provisional = 0}
		case EVENT_TILE:
			// A pearl gone during a turn is the acting dragon's meal.
			if b != 0 || current < 0 {break}
			index := board_dragon_index(&state, current)
			if index < 0 {break}
			side := &history[state.dragons[index].team & 1]
			append(&side.eat, state.round)
			if rich[a] {append(&side.eat_rich, state.round)}
			if hot[a] {append(&side.eat_hot, state.round)}
		case EVENT_DEATH:
			index := board_dragon_index(&state, a)
			if index < 0 {break}
			team := state.dragons[index].team & 1
			length := i32(len(state.bodies[index])) + (a == current ? provisional : 0)
			append(&history[team].deaths, [2]i32{state.round, length})
			if b == BCEVAL_HEAD_TO_HEAD {append(&history[1 - team].h2h, state.round)}
		}
		apply_board_event(game, &state, event)
	}
	// The board after the last round, scored at the model's final knot.
	features := snapshot(&state, state.round, &history, rate, rich, hot, landings, distance, label, occupied, &frontier, &next)
	append(&game.evaluation, with_sides(evaluate(&model, 501, features), features))
	return game.evaluation[:]
}

fmt_feature :: proc(feature: Bceval_Feature) -> string {
	names := [Bceval_Feature]string {
		.alive = "alive", .total = "total", .longest = "longest", .second = "second", .third = "third",
		.big5 = "big5", .big10 = "big10", .eat = "eat", .eat_rich = "eat_rich", .eat_hot = "eat_hot",
		.deaths = "deaths", .lost_len = "lost_len", .kills_h2h = "kills_h2h", .terr = "terr",
		.supply = "supply", .rich_ctrl = "rich_ctrl", .hot_ctrl = "hot_ctrl", .pearls_near = "pearls_near",
		.champ_enemy_d = "champ_enemy_d", .champ_enemy_n3 = "champ_enemy_n3", .champ_enemy_n6 = "champ_enemy_n6",
		.champ_ally_d = "champ_ally_d", .champ_exits = "champ_exits",
	}
	return names[feature]
}

// The round whose evaluation matches the board on screen: in Rounds mode the
// round shown, in Turns mode the last round finished before the active turn.
// -1 before any round has finished.
evaluation_round :: proc(viewer: ^Viewer_State) -> int {
	frame := int(current_frame(viewer))
	return viewer.playback.substeps && active_turn_index(viewer) >= 0 ? frame - 1 : frame
}

// The evaluation bar beside the board, like a chess engine's: side A's share
// from the bottom in A's colour, B's from the top.
draw_evaluation_bar :: proc(viewer: ^Viewer_State, bar: rl.Rectangle) {
	series := game_evaluation(&viewer.game)
	round := evaluation_round(viewer)
	rl.DrawRectangleRec(bar, COLOR_UNKNOWN)
	if round < 0 || round >= len(series) || math.is_nan(series[round].p_a) {return}
	a := f32(series[round].p_a)
	rl.DrawRectangleRec({bar.x, bar.y, bar.width, bar.height * (1 - a)}, TEAM_BODY_COLORS[1])
	rl.DrawRectangleRec({bar.x, bar.y + bar.height * (1 - a), bar.width, bar.height * a}, TEAM_BODY_COLORS[0])
	middle := bar.y + bar.height / 2
	rl.DrawLineEx({bar.x - 2, middle}, {bar.x + bar.width + 2, middle}, 1, BACKGROUND)
}

EVALUATION_CHART_HEIGHT :: 80

// The evaluation pane, beside the board: both sides' chances after the round, A's
// chance across the game as a strip chart that scrubs like the timeline, the
// log-odds each group of features adds for A, and the source.
// The board's dragons, longest and total length per side, from the features
// the evaluation counts.
with_sides :: proc(evaluation: Evaluation, features: [2][Bceval_Feature]f64) -> Evaluation {
	result := evaluation
	for side in 0 ..< 2 {
		result.dragons[side] = i32(features[side][.alive])
		result.longest[side] = i32(features[side][.longest])
		result.total[side] = i32(features[side][.total])
	}
	return result
}

SPARKLINE_HEIGHT :: 28

// Each side's dragons, longest dragon and total length after the round, each
// with a sparkline of both sides over the game, marked at the round.
draw_side_stats :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, series: []Evaluation, round: int) {
	finished := round >= 0 && round < len(series) && !math.is_nan(series[round].p_a)
	inspector_paragraph(viewer, cursor, width, finished ? fmt.tprintf("Stats r%d", round) : "Stats: no round finished", finished ? UI_ACCENT : MUTED_TEXT_COLOR)
	Stat :: enum {Dragons, Longest, Total}
	names := [Stat]string{.Dragons = "Dragons", .Longest = "Longest", .Total = "Length"}
	value :: proc(evaluation: Evaluation, stat: Stat, side: int) -> i32 {
		switch stat {
		case .Dragons:
			return evaluation.dragons[side]
		case .Longest:
			return evaluation.longest[side]
		case .Total:
			return evaluation.total[side]
		}
		return 0
	}
	for stat in Stat {
		parts := make([dynamic]Stat_Text, context.temp_allocator)
		append(&parts, Stat_Text{fmt.tprintf("%s ", names[stat]), TEXT_COLOR})
		if finished {
			append(&parts, Stat_Text{fmt.tprintf("A %d", value(series[round], stat, 0)), TEAM_BODY_COLORS[0]})
			append(&parts, Stat_Text{" · ", MUTED_TEXT_COLOR})
			append(&parts, Stat_Text{fmt.tprintf("B %d", value(series[round], stat, 1)), TEAM_BODY_COLORS[1]})
		}
		draw_stat_line(parts[:], cursor.x, cursor.y, width)
		cursor.y += UI_LINE
		chart := rl.Rectangle{cursor.x, cursor.y, width, SPARKLINE_HEIGHT}
		rl.DrawRectangleRec(chart, POINTS_CHART_BACKGROUND)
		top: i32 = 1
		for evaluation in series {
			if math.is_nan(evaluation.p_a) {continue}
			top = max(top, value(evaluation, stat, 0), value(evaluation, stat, 1))
		}
		rounds := f32(max(1, len(series)))
		span := chart.width - 1
		for side in 0 ..< 2 {
			previous: rl.Vector2
			started := false
			for evaluation, index in series {
				if math.is_nan(evaluation.p_a) {continue}
				point := rl.Vector2{chart.x + f32(index) / rounds * span, chart.y + chart.height * (1 - f32(value(evaluation, stat, side)) / f32(top))}
				if started {rl.DrawLineEx(previous, point, 1.5, TEAM_BODY_COLORS[side])}
				previous, started = point, true
			}
		}
		if round >= 0 {
			marker := chart.x + f32(round) / rounds * span
			rl.DrawLineEx({marker, chart.y}, {marker, chart.y + chart.height}, 1.5, UI_ACCENT)
		}
		scrub_chart(viewer, .Evaluation, chart, span, rounds)
		cursor.y += chart.height + 6
	}
	cursor.y += 4
}

draw_evaluation_pane :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	cursor := rl.Vector2{area.x, area.y}
	width := area.width
	series := game_evaluation(&viewer.game)
	if len(series) == 0 {return}
	round := evaluation_round(viewer)
	draw_side_stats(viewer, &cursor, width, series, round)
	finished := round >= 0 && round < len(series) && !math.is_nan(series[round].p_a)
	if finished {
		evaluation := series[round]
		inspector_paragraph(viewer, &cursor, width, fmt.tprintf("Evaluation r%d", round), UI_ACCENT)
		inspector_paragraph(viewer, &cursor, width, fmt.tprintf("A %.0f%%, B %.0f%%", 100 * evaluation.p_a, 100 * (1 - evaluation.p_a)))
	} else {
		inspector_paragraph(viewer, &cursor, width, "Evaluation: no round finished", MUTED_TEXT_COLOR)
	}
	chart := rl.Rectangle{cursor.x, cursor.y, width, EVALUATION_CHART_HEIGHT}
	rl.DrawRectangleRec(chart, POINTS_CHART_BACKGROUND)
	rounds := f32(max(1, len(series)))
	span := chart.width - 1
	middle := chart.y + chart.height / 2
	rl.DrawLineEx({chart.x, middle}, {chart.x + chart.width, middle}, 1, MUTED_TEXT_COLOR)
	previous: rl.Vector2
	started := false
	for evaluation, index in series {
		if math.is_nan(evaluation.p_a) {continue}
		point := rl.Vector2{chart.x + f32(index) / rounds * span, chart.y + chart.height * (1 - f32(evaluation.p_a))}
		if started {rl.DrawLineEx(previous, point, 1.5, TEAM_BODY_COLORS[0])}
		previous, started = point, true
	}
	if round >= 0 {
		marker := chart.x + f32(round) / rounds * span
		rl.DrawLineEx({marker, chart.y}, {marker, chart.y + chart.height}, 2, UI_ACCENT)
	}
	scrub_chart(viewer, .Evaluation, chart, span, rounds)
	cursor.y += chart.height + 6
	if finished {
		inspector_paragraph(viewer, &cursor, width, "Log-odds for A", UI_ACCENT)
		for group in Bceval_Group {
			inspector_paragraph(viewer, &cursor, width, fmt.tprintf("%v %+.2f", group, series[round].parts[group]))
		}
	}
	inspector_paragraph(viewer, &cursor, width, "bceval 0.1.0 by xCirno1 (MIT)", MUTED_TEXT_COLOR)
	inspector_paragraph(viewer, &cursor, width, "github.com/xCirno1/", MUTED_TEXT_COLOR)
	inspector_paragraph(viewer, &cursor, width, "battlecode-eval", MUTED_TEXT_COLOR)
}
