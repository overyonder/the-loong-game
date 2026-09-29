package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Each team's decision breakdown (diagnostics.md, Brain placement): in every
// round, how many of the team's turns its Brain roots classed under each
// value. The producer names the levels and values; the viewer only counts.
Team_Breakdown :: struct {
	team:                      i32,
	group_level, detail_level: string,
	// In order of first appearance, which fixes each group's colour.
	groups:                    [dynamic]string,
	pairs:                     [dynamic]Breakdown_Pair,
	// Per pair, the turns classed under it in each round.
	counts:                    [dynamic][]u16,
	// The turns classed in each round, and the most in any one.
	totals:                    []u16,
	peak:                      int,
}
Breakdown_Pair :: struct {
	group:  int,
	detail: string,
}

BREAKDOWN_CHART_HEIGHT :: 44
// The dataviz reference palette's categorical dark steps, in slot order.
// Groups past the eighth share the last colour, and the legend names them.
@(rodata)
BREAKDOWN_COLORS := [8]rl.Color {
	{0x39, 0x87, 0xe5, 255},
	{0xd9, 0x59, 0x26, 255},
	{0x19, 0x9e, 0x70, 255},
	{0xc9, 0x85, 0x00, 255},
	{0xd5, 0x51, 0x81, 255},
	{0x00, 0x83, 0x00, 255},
	{0x90, 0x85, 0xe9, 255},
	{0xe6, 0x67, 0x67, 255},
}

// Count one turn's breakdown, as the recovery streams it.
add_breakdown :: proc(game: ^Loaded_Game, row: int, group_level, group_name, detail_level, detail: string) {
	view := &game.view
	if row < 0 || row >= len(view.turn_team) {return}
	allocator := game_allocator(game)
	rounds := len(view.round_event)
	round := int(view.turn_round[row])
	if round >= rounds {return}
	team := i32(view.turn_team[row])
	breakdown: ^Team_Breakdown
	for &candidate in view.breakdowns {if candidate.team == team {breakdown = &candidate}}
	if breakdown == nil {
		append(&view.breakdowns, Team_Breakdown {
			team         = team,
			group_level  = strings.clone(group_level, allocator),
			detail_level = strings.clone(detail_level, allocator),
			groups       = make([dynamic]string, allocator),
			pairs        = make([dynamic]Breakdown_Pair, allocator),
			counts       = make([dynamic][]u16, allocator),
			totals       = make([]u16, rounds, allocator),
		})
		breakdown = &view.breakdowns[len(view.breakdowns) - 1]
	}
	group := -1
	for name, position in breakdown.groups {if name == group_name {group = position}}
	if group < 0 {
		append(&breakdown.groups, strings.clone(group_name, allocator))
		group = len(breakdown.groups) - 1
	}
	pair := -1
	for candidate, position in breakdown.pairs {if candidate.group == group && candidate.detail == detail {pair = position}}
	if pair < 0 {
		append(&breakdown.pairs, Breakdown_Pair{group, strings.clone(detail, allocator)})
		append(&breakdown.counts, make([]u16, rounds, allocator))
		pair = len(breakdown.pairs) - 1
	}
	breakdown.counts[pair][round] += 1
	breakdown.totals[round] += 1
	breakdown.peak = max(breakdown.peak, int(breakdown.totals[round]))
}

breakdown_color :: proc(group: int) -> rl.Color {
	return BREAKDOWN_COLORS[min(group, len(BREAKDOWN_COLORS) - 1)]
}

// The focused dragon's team's breakdown, else the first team that has one.
focused_breakdown :: proc(viewer: ^Viewer_State) -> ^Team_Breakdown {
	view := &viewer.game.view
	if len(view.breakdowns) == 0 {return nil}
	indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]
	if found && len(indices) > 0 {
		team := i32(view.turn_team[indices[0]])
		for &breakdown in view.breakdowns {if breakdown.team == team {return &breakdown}}
	}
	return &view.breakdowns[0]
}

// A stacked strip chart of the team's groups over the game, which seeks on
// click, then this round's count in each group and in each of its details.
draw_breakdown_chart :: proc(
	viewer: ^Viewer_State,
	breakdown: ^Team_Breakdown,
	cursor: ^rl.Vector2,
	width: f32,
	frame: i32,
) {
	view := &viewer.game.view
	pairs := len(breakdown.pairs)
	rounds := len(breakdown.totals)
	if rounds == 0 {return}
	round := clamp(int(frame), 0, rounds - 1)
	now := make([]u16, pairs, context.temp_allocator)
	for position in 0 ..< pairs {now[position] = breakdown.counts[position][round]}
	classed := int(breakdown.totals[round])
	turns := 0
	first := turn_count_before_frame(&viewer.game, i32(round))
	for index in first ..< turn_count_before_frame(&viewer.game, i32(round) + 1) {
		if i32(view.turn_team[index]) == breakdown.team {turns += 1}
	}
	title := breakdown.group_level
	if breakdown.detail_level != "" {title = fmt.tprintf("%s and %s", title, breakdown.detail_level)}
	inspector_paragraph(
		viewer,
		cursor,
		width,
		fmt.tprintf(
			"%s, team %s r%d: %d of %d turns",
			title,
			breakdown.team == 0 ? "A" : "B",
			round,
			classed,
			turns,
		),
		UI_ACCENT,
	)

	chart := rl.Rectangle{cursor.x, cursor.y, width, BREAKDOWN_CHART_HEIGHT}
	rl.DrawRectangleRec(chart, POINTS_CHART_BACKGROUND)
	bar := max(1, chart.width / f32(rounds))
	span := chart.width - bar
	unit := chart.height / f32(max(breakdown.peak, 1))
	for r in 0 ..< rounds {
		x := chart.x + f32(r) / f32(rounds) * span
		y := chart.y + chart.height
		for group in 0 ..< len(breakdown.groups) {
			count := 0
			for pair, position in breakdown.pairs {
				if pair.group == group {count += int(breakdown.counts[position][r])}
			}
			if count == 0 {continue}
			y -= f32(count) * unit
			rl.DrawRectangleRec({x, y, bar, f32(count) * unit}, breakdown_color(group))
		}
	}
	marker := chart.x + f32(round) / f32(rounds) * span + bar / 2
	rl.DrawLineEx({marker, chart.y}, {marker, chart.y + chart.height}, 2, TEXT_COLOR)
	scrub_chart(viewer, .Breakdown, chart, span, f32(rounds))
	cursor.y += chart.height + 6

	for name, group in breakdown.groups {
		count := 0
		details := strings.builder_make(context.temp_allocator)
		for pair, position in breakdown.pairs {
			if pair.group != group || now[position] == 0 {continue}
			count += int(now[position])
			if pair.detail == "" {continue}
			if strings.builder_len(details) > 0 {strings.write_string(&details, ", ")}
			fmt.sbprintf(&details, "%s %d", pair.detail, now[position])
		}
		swatch := rl.Rectangle{cursor.x, cursor.y + 3, 10, 10}
		rl.DrawRectangleRec(swatch, breakdown_color(group))
		saved := cursor.x
		cursor.x += 16
		inspector_paragraph(
			viewer,
			cursor,
			width - 16,
			fmt.tprintf("%s %d", name, count),
			count > 0 ? TEXT_COLOR : MUTED_TEXT_COLOR,
		)
		if strings.builder_len(details) > 0 {
			inspector_paragraph(viewer, cursor, width - 16, strings.to_string(details), MUTED_TEXT_COLOR)
		}
		cursor.x = saved
	}
}

// The breakdown of the focused dragon's team, else of the first team that has
// one, then, beside a recovery server, which of the round's dragons have
// their decisions rebuilt, waiting or still to be asked for.
draw_team_breakdown :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, frame: i32) {
	breakdown := focused_breakdown(viewer)
	if breakdown != nil {draw_breakdown_chart(viewer, breakdown, cursor, width, frame)}
	if !viewer.recovery.running {return}
	view := &viewer.game.view
	team: i32 = breakdown != nil ? breakdown.team : 0
	if indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]; found && len(indices) > 0 {
		team = i32(view.turn_team[indices[0]])
	}
	// Each team's turns and dragons this round.
	turns: [2][dynamic]int
	dragons: [2][dynamic]i32
	for &list in turns {list = make([dynamic]int, context.temp_allocator)}
	for &list in dragons {list = make([dynamic]i32, context.temp_allocator)}
	first := turn_count_before_frame(&viewer.game, frame)
	for index in first ..< turn_count_before_frame(&viewer.game, frame + 1) {
		side := int(view.turn_team[index]) & 1
		dragon := i32(view.turn_dragon[index])
		append(&turns[side], index)
		append(&dragons[side], dragon)
	}
	names := [4]string{"rebuilt", "rebuilding", "waiting", "not asked"}
	for side in ([2]i32{team, 1 - team}) {
		// The other team only while some of its dragons are being rebuilt.
		busy := side == team
		for dragon in dragons[side] {
			state := recovery_state(viewer, dragon)
			busy = busy || state == .Recovering || state == .Waiting
		}
		if !busy || len(turns[side]) == 0 {continue}
		lists: [4]strings.Builder
		for &list in lists {list = strings.builder_make(context.temp_allocator)}
		unrecorded := make(map[string]strings.Builder, context.temp_allocator)
		for index in turns[side] {
			dragon := i32(view.turn_dragon[index])
			kind := 0
			switch recovery_state(viewer, dragon) {
			case .Recovering:
				kind = 1
			case .Waiting:
				kind = 2
			case .Not_Requested:
				kind = 3
			case .Recovered:
				if _, recorded := view.records[index]; !recorded {kind = 4}
			}
			if kind == 4 {
				// Grouped by the recovery's note on the dragon's build, such as
				// a refusal to recover it.
				status := view.dragon_builds[dragon].status
				if !(status in unrecorded) {unrecorded[status] = strings.builder_make(context.temp_allocator)}
				fmt.sbprintf(&unrecorded[status], " D%d", dragon)
				continue
			}
			fmt.sbprintf(&lists[kind], " D%d", dragon)
		}
		summary := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&summary, "Team %s r%d decisions:", side == 0 ? "A" : "B", frame)
		for &list, kind in lists {
			if strings.builder_len(list) == 0 {continue}
			fmt.sbprintf(&summary, " %s%s;", names[kind], strings.to_string(list))
		}
		for status, &list in unrecorded {
			fmt.sbprintf(&summary, " no diagnostics%s%s;", strings.to_string(list), status != "" ? fmt.tprintf(" (%s)", status) : "")
		}
		inspector_paragraph(viewer, cursor, width, strings.trim_right(strings.to_string(summary), ";"), MUTED_TEXT_COLOR)
	}
}
