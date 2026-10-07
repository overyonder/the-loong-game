package viewer

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Each team's decision breakdown (diagnostics.md, Brain placement): in every
// round, how many of the team's turns its Brain roots classed under each
// value, and how the producer has its dragons drawn. The producer names the
// levels, values and looks; the viewer only counts and draws.
Team_Breakdown :: struct {
	team:                      i32,
	group_level, detail_level: string,
	// In order of first appearance, which fixes each group's palette slot,
	// and each group's look as its latest turn named it.
	groups:                    [dynamic]string,
	group_looks:               [dynamic]Breakdown_Look,
	pairs:                     [dynamic]Breakdown_Pair,
	// Per pair, the turns classed under it in each round.
	counts:                    [dynamic][]u16,
	// The turns classed in each round, and the most in any one.
	totals:                    []u16,
	peak:                      int,
}
// A group and a value beneath it, with the look the value's entry names.
Breakdown_Pair :: struct {
	group:  int,
	detail: string,
	look:   Breakdown_Look,
}
// One level of a turn's breakdown, as the recovery streams it.
Breakdown_Entry :: struct {
	level, value:  string,
	color:         []int,
	icon, pattern: string,
}
// How the dragons a value classes are drawn, where its entry says.
Breakdown_Look :: struct {
	color:   Maybe(rl.Color),
	icon:    Maybe(Head_Icon),
	pattern: Maybe(Body_Pattern),
}
// A turn's place in its team's breakdown: its pair, -1 until the recovery
// sends one, and whether the rebuilt turn matched the replay.
Turn_Breakdown :: struct {
	pair:     int,
	reliable: bool,
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

// Count one turn's breakdown, its first one or two entries, as the recovery
// streams it, and keep the looks its entries name.
add_breakdown :: proc(game: ^Loaded_Game, row: int, reliable: bool, entries: []Breakdown_Entry) {
	view := &game.view
	if row < 0 || row >= len(view.turn_team) || len(entries) == 0 {return}
	allocator := game_allocator(game)
	rounds := len(view.round_event)
	round := int(view.turn_round[row])
	if round >= rounds {return}
	coarse := entries[0]
	fine := len(entries) > 1 ? entries[1] : Breakdown_Entry{}
	team := i32(view.turn_team[row])
	breakdown: ^Team_Breakdown
	for &candidate in view.breakdowns {if candidate.team == team {breakdown = &candidate}}
	if breakdown == nil {
		append(&view.breakdowns, Team_Breakdown {
			team         = team,
			group_level  = strings.clone(coarse.level, allocator),
			detail_level = strings.clone(fine.level, allocator),
			groups       = make([dynamic]string, allocator),
			group_looks  = make([dynamic]Breakdown_Look, allocator),
			pairs        = make([dynamic]Breakdown_Pair, allocator),
			counts       = make([dynamic][]u16, allocator),
			totals       = make([]u16, rounds, allocator),
		})
		breakdown = &view.breakdowns[len(view.breakdowns) - 1]
	}
	// A dragon rebuilt again sends its turns again, so a turn counts once.
	if previous := view.turn_breakdown[row].pair; previous >= 0 {
		breakdown.counts[previous][round] -= 1
		breakdown.totals[round] -= 1
	}
	group := -1
	for name, position in breakdown.groups {if name == coarse.value {group = position}}
	if group < 0 {
		append(&breakdown.groups, strings.clone(coarse.value, allocator))
		append(&breakdown.group_looks, Breakdown_Look{})
		group = len(breakdown.groups) - 1
	}
	breakdown.group_looks[group] = entry_look(coarse)
	pair := -1
	for candidate, position in breakdown.pairs {if candidate.group == group && candidate.detail == fine.value {pair = position}}
	if pair < 0 {
		append(&breakdown.pairs, Breakdown_Pair{group = group, detail = strings.clone(fine.value, allocator)})
		append(&breakdown.counts, make([]u16, rounds, allocator))
		pair = len(breakdown.pairs) - 1
	}
	breakdown.pairs[pair].look = entry_look(fine)
	breakdown.counts[pair][round] += 1
	breakdown.totals[round] += 1
	breakdown.peak = max(breakdown.peak, int(breakdown.totals[round]))
	view.turn_breakdown[row] = {pair, reliable}
}

// The look an entry names: a colour of three or four components, and an icon
// and pattern by their names. Anything else names nothing.
entry_look :: proc(entry: Breakdown_Entry) -> (look: Breakdown_Look) {
	if len(entry.color) == 3 || len(entry.color) == 4 {
		component :: proc(value: int) -> u8 {return u8(clamp(value, 0, 255))}
		look.color = rl.Color {
			component(entry.color[0]),
			component(entry.color[1]),
			component(entry.color[2]),
			len(entry.color) == 4 ? component(entry.color[3]) : 255,
		}
	}
	for name, icon in HEAD_ICON_NAMES {if entry.icon == name {look.icon = icon}}
	for name, pattern in BODY_PATTERN_NAMES {if entry.pattern == name {look.pattern = pattern}}
	return
}

// A group's colour: the one its entry names, else its palette slot.
group_color :: proc(breakdown: ^Team_Breakdown, group: int) -> rl.Color {
	return breakdown.group_looks[group].color.? or_else BREAKDOWN_COLORS[min(group, len(BREAKDOWN_COLORS) - 1)]
}

// How a pair's dragons are drawn: each part from the coarsest entry that
// names it, else the group's colour, a plain head and a solid body.
pair_look :: proc(breakdown: ^Team_Breakdown, pair: int) -> (color: rl.Color, icon: Head_Icon, pattern: Body_Pattern) {
	entry := breakdown.pairs[pair]
	coarse, fine := breakdown.group_looks[entry.group], entry.look
	color = coarse.color.? or_else (fine.color.? or_else group_color(breakdown, entry.group))
	icon = coarse.icon.? or_else (fine.icon.? or_else .Plain)
	pattern = coarse.pattern.? or_else (fine.pattern.? or_else .Solid)
	return
}

// The pair the breakdown's team classed the dragon under in its latest turn
// before row `shown`, the turn that put it where the board draws it; -1 when
// that turn has no breakdown yet, diverged from the replay or is another
// team's.
shown_breakdown_pair :: proc(game: ^Loaded_Game, breakdown: ^Team_Breakdown, dragon: i32, shown: int) -> int {
	indices, found := game.turn_indices_by_dragon[dragon]
	if !found {return -1}
	position, _ := slice.binary_search(indices[:], shown)
	if position == 0 {return -1}
	row := indices[position - 1]
	entry := game.view.turn_breakdown[row]
	if i32(game.view.turn_team[row]) != breakdown.team || entry.pair < 0 || !entry.reliable {return -1}
	return entry.pair
}

// The rows before the board on screen: before the active turn in Turns mode,
// else to the end of the round.
shown_turns :: proc(viewer: ^Viewer_State) -> int {
	active := active_turn_index(viewer)
	return active >= 0 ? active : turn_count_before_frame(&viewer.game, current_frame(viewer) + 1)
}

// The head shapes a breakdown entry can name, by the names it uses. The viewer
// itself reserves the solid crown for initial IDs 0/1 (board_drawing.odin).
Head_Icon :: enum {
	Plain,
	Crown,
	Hollow_Crown,
	Arrow,
	Magnifier,
	Shield,
	Inverted_Shield,
}
@(rodata)
HEAD_ICON_NAMES := [Head_Icon]string {
	.Plain           = "plain",
	.Crown           = "crown",
	.Hollow_Crown    = "hollow_crown",
	.Arrow           = "arrow",
	.Magnifier       = "magnifier",
	.Shield          = "shield",
	.Inverted_Shield = "inverted_shield",
}

// A head of radius `r` at `c`, shaped by its icon. A shaped head has a dark
// outline, so it stands out against a body of its own colour.
draw_head :: proc(c: rl.Vector2, r: f32, icon: Head_Icon, color: rl.Color, facing: rl.Vector2) {
	if icon != .Plain {draw_head_shape(c, r * 1.18, icon, color_lerp(color, BACKGROUND, 0.7), facing)}
	draw_head_shape(c, r, icon, color, facing)
}

// An icon's shape round a disc that keeps room for the dragon's ID. An arrow
// points along `facing`, a unit step.
draw_head_shape :: proc(c: rl.Vector2, r: f32, icon: Head_Icon, color: rl.Color, facing: rl.Vector2) {
	// Raylib fills triangles wound one way only.
	triangle :: proc(a, b, c: rl.Vector2, color: rl.Color) {
		if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0 {rl.DrawTriangle(a, c, b, color)} else {rl.DrawTriangle(a, b, c, color)}
	}
	// Points in units of r from the centre.
	at :: proc(c: rl.Vector2, r, x, y: f32) -> rl.Vector2 {return c + {x, y} * r}
	switch icon {
	case .Plain:
		rl.DrawCircleV(c, r, color)
	case .Crown, .Hollow_Crown:
		// Three points above a band that sinks into the head.
		rl.DrawCircleV(c, r, color)
		outline := [?]rl.Vector2 {
			at(c, r, -0.9, -0.5),
			at(c, r, -0.9, -1.6),
			at(c, r, -0.45, -1.05),
			at(c, r, 0, -1.75),
			at(c, r, 0.45, -1.05),
			at(c, r, 0.9, -1.6),
			at(c, r, 0.9, -0.5),
		}
		if icon == .Crown {
			rl.DrawRectangleRec({c.x - 0.9 * r, c.y - 1.05 * r, 1.8 * r, 0.55 * r}, color)
			for point in 0 ..< 3 {triangle(outline[point * 2], outline[point * 2 + 1], outline[point * 2 + 2], color)}
		} else {
			thickness := max(1.5, r * 0.28)
			for point in 1 ..< len(outline) - 1 {rl.DrawLineEx(outline[point], outline[point + 1], thickness, color)}
			rl.DrawLineEx(outline[1], outline[0], thickness, color)
		}
	case .Arrow:
		// An arrowhead round the head, pointing where it moved.
		rl.DrawCircleV(c, r, color)
		across := rl.Vector2{-facing.y, facing.x}
		triangle(c + facing * 1.65 * r, c + (facing * 0.3 + across * 1.15) * r, c + (facing * 0.3 - across * 1.15) * r, color)
	case .Magnifier:
		// A lens inside a rim, and a handle.
		rl.DrawCircleV(c, r * 0.78, color)
		rl.DrawRing(c, r * 0.95, r * 1.2, 0, 360, 36, color)
		handle := rl.Vector2{0.7071, 0.7071}
		rl.DrawLineEx(c + handle * 1.1 * r, c + handle * 1.75 * r, max(2, r * 0.45), color)
	case .Shield:
		// Flat on top, pointed below.
		rl.DrawRectangleRec({c.x - 0.9 * r, c.y - 0.9 * r, 1.8 * r, 1.15 * r}, color)
		triangle(at(c, r, -0.9, 0.25), at(c, r, 0.9, 0.25), at(c, r, 0, 1.5), color)
	case .Inverted_Shield:
		// Pointed on top, flat below.
		rl.DrawRectangleRec({c.x - 0.9 * r, c.y - 0.25 * r, 1.8 * r, 1.15 * r}, color)
		triangle(at(c, r, -0.9, -0.25), at(c, r, 0.9, -0.25), at(c, r, 0, -1.5), color)
	}
}

// The body patterns a breakdown entry can name, by the names it uses.
Body_Pattern :: enum {
	Solid,
	Stripes,
	Crosshatch,
	Dots,
	Dither,
}
@(rodata)
BODY_PATTERN_NAMES := [Body_Pattern]string {
	.Solid      = "solid",
	.Stripes    = "stripes",
	.Crosshatch = "crosshatch",
	.Dots       = "dots",
	.Dither     = "dither",
}

// A pattern's marks over a rectangle, clipped to it and aligned to the screen
// so neighbouring cells' marks join, `spacing` apart.
draw_body_pattern :: proc(area: rl.Rectangle, pattern: Body_Pattern, spacing: f32, color: rl.Color) {
	left, top, right, bottom := area.x, area.y, area.x + area.width, area.y + area.height
	thickness := max(1, spacing * 0.3)
	switch pattern {
	case .Solid:
	case .Stripes, .Crosshatch:
		// Lines x + y = c, and for crosshatch also x - y = c.
		for c := f32(int((left + top) / spacing)) * spacing; c <= right + bottom; c += spacing {
			start, end := max(left, c - bottom), min(right, c - top)
			if start < end {rl.DrawLineEx({start, c - start}, {end, c - end}, thickness, color)}
		}
		if pattern == .Stripes {break}
		for c := f32(int((left - bottom) / spacing) - 1) * spacing; c <= right - top; c += spacing {
			start, end := max(left, c + top), min(right, c + bottom)
			if start < end {rl.DrawLineEx({start, start - c}, {end, end - c}, thickness, color)}
		}
	case .Dots, .Dither:
		// Dots on a grid, or a checkerboard of squares half as far apart.
		step := pattern == .Dots ? spacing : spacing / 2
		for y := f32(int(top / step)) * step; y < bottom; y += step {
			for x := f32(int(left / step)) * step; x < right; x += step {
				if pattern == .Dots {
					centre := rl.Vector2{x + step / 2, y + step / 2}
					if centre.x >= left && centre.y >= top && centre.x < right && centre.y < bottom {
						rl.DrawCircleV(centre, step * 0.28, color)
					}
				} else if (int(x / step) + int(y / step)) % 2 == 0 {
					square := rl.Rectangle{max(x, left), max(y, top), 0, 0}
					square.width = min(x + step, right) - square.x
					square.height = min(y + step, bottom) - square.y
					if square.width > 0 && square.height > 0 {rl.DrawRectangleRec(square, color)}
				}
			}
		}
	}
}

// Drawn opaque under raylib's multiplied blend, a mark scales what is already
// drawn: a body darkens to 40% of its colour and an empty pixel stays empty.
BODY_MARKS :: rl.Color{102, 102, 102, 255}

// A unit step from a dragon's neck to its head, across a torus seam if need
// be; straight up after a portal, where the two aren't neighbours.
head_facing :: proc(dragon: ^Board_Dragon, width, height: i32) -> rl.Vector2 {
	if len(dragon.body) < 2 {return {0, -1}}
	head, neck := dragon.body[0], dragon.body[1]
	dx := head % width - neck % width
	dy := head / width - neck / width
	if abs(dx) == width - 1 {dx = dx > 0 ? -1 : 1}
	if abs(dy) == height - 1 {dy = dy > 0 ? -1 : 1}
	if abs(dx) + abs(dy) != 1 {return {0, -1}}
	return {f32(dx), f32(dy)}
}

// Our team's breakdown (controls.odin, our_team), or nil until one arrives.
our_breakdown :: proc(viewer: ^Viewer_State) -> ^Team_Breakdown {
	team := i32(our_team(viewer))
	for &breakdown in viewer.game.view.breakdowns {if breakdown.team == team {return &breakdown}}
	return nil
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
			rl.DrawRectangleRec({x, y, bar, f32(count) * unit}, group_color(breakdown, group))
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
		// The group's colour, in the shape of its head with Icons on.
		icon := Head_Icon.Plain
		if viewer.overlays.icons {icon = breakdown.group_looks[group].icon.? or_else .Plain}
		if icon == .Plain {
			rl.DrawRectangleRec({cursor.x, cursor.y + 3, 10, 10}, group_color(breakdown, group))
		} else {
			draw_head({cursor.x + 5, cursor.y + 9}, 4, icon, group_color(breakdown, group), {0, -1})
		}
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
	if viewer.overlays.patterns {draw_pattern_legend(viewer, breakdown, cursor, width)}
}

// Which values each body pattern their entries name marks, separated by
// semicolons since values may hold commas. Nothing when no entry names one.
draw_pattern_legend :: proc(viewer: ^Viewer_State, breakdown: ^Team_Breakdown, cursor: ^rl.Vector2, width: f32) {
	named := false
	for pair in breakdown.pairs {named = named || pair.look.pattern != nil || breakdown.group_looks[pair.group].pattern != nil}
	if !named {return}
	cursor.y += 4
	inspector_paragraph(viewer, cursor, width, "Patterns", UI_ACCENT)
	for pattern in Body_Pattern {
		names := make([dynamic]string, context.temp_allocator)
		// In order of first appearance, as the lines above list them: a value
		// beneath its group, else the group.
		for pair, position in breakdown.pairs {
			_, _, drawn := pair_look(breakdown, position)
			name := pair.detail != "" ? pair.detail : breakdown.groups[pair.group]
			if drawn == pattern && !slice.contains(names[:], name) {append(&names, name)}
		}
		if len(names) == 0 {continue}
		swatch := rl.Rectangle{cursor.x, cursor.y + 2, 14, 14}
		rl.DrawRectangleRec(swatch, MUTED_TEXT_COLOR)
		draw_body_pattern(swatch, pattern, 5, BACKGROUND)
		saved := cursor.x
		cursor.x += 20
		inspector_paragraph(viewer, cursor, width - 20, strings.join(names[:], "; ", context.temp_allocator), TEXT_COLOR)
		cursor.x = saved
	}
}

// Our team's breakdown, then, beside a recovery server, which of the round's
// dragons have their decisions rebuilt, waiting or still to be asked for, ours
// first.
draw_team_breakdown :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, frame: i32) {
	breakdown := our_breakdown(viewer)
	if breakdown != nil {draw_breakdown_chart(viewer, breakdown, cursor, width, frame)}
	if !viewer.recovery.running {return}
	view := &viewer.game.view
	team := i32(our_team(viewer))
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
