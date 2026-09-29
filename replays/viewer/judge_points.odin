package viewer

import "core:fmt"
import "core:slice"
import rl "vendor:raylib"

POINTS_CHART_HEIGHT :: 44
// Share of the judge's limit from which a turn is drawn as close to it.
POINTS_WARNING_SHARE :: 0.9
POINTS_CHART_BACKGROUND :: rl.Color{36, 40, 42, 255}

turn_points_color :: proc(points: i64, failed: bool, limit: i64) -> rl.Color {
	if failed {return COLOR_DEATH}
	if f64(points) >= POINTS_WARNING_SHARE * f64(limit) {return WARNING_COLOR}
	return MUTED_TEXT_COLOR
}

// Whether turn `index` produced no reply (its failure reason is recorded).
turn_failed :: proc(game: ^Loaded_Game, index: int) -> bool {
	starts := column_values(&game.view.columns, "turn.failure#", u64)
	return starts[index + 1] > starts[index]
}

// The focused dragon's judge points: this turn against the limit, its whole
// life as a strip chart that seeks on click, and the costliest teammate this round.
draw_judge_points :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, frame: i32) {
	export := &viewer.game.view
	if !export.points_recorded {
		inspector_paragraph(
			viewer,
			cursor,
			width,
			"Judge points: not recorded",
			MUTED_TEXT_COLOR,
		)
		return
	}
	indices, found := viewer.game.turn_indices_by_dragon[viewer.selected_dragon]
	if !found || len(indices) == 0 {return}
	limit := max(export.point_limit, 1)
	turn, current := focused_dragon_turn(viewer, frame)
	if current {
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf(
				"Judge points, dragon %d r%d: %.1fM of %.0fM (%.0f%%)",
				turn.dragon,
				frame,
				f64(turn.points) / 1e6,
				f64(limit) / 1e6,
				100 * f64(turn.points) / f64(limit),
			),
			turn.point_failure != "" ? COLOR_DEATH : TEXT_COLOR,
		)
		if turn.point_failure != "" {
			inspector_paragraph(
				viewer,
				cursor,
				width,
				fmt.tprintf("Turn failed: %s", turn.point_failure),
				COLOR_DEATH,
			)
		}
	} else {
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf("Judge points, dragon %d: no turn in r%d", viewer.selected_dragon, frame),
			MUTED_TEXT_COLOR,
		)
	}

	chart := rl.Rectangle{cursor.x, cursor.y, width, POINTS_CHART_HEIGHT}
	rl.DrawRectangleRec(chart, POINTS_CHART_BACKGROUND)
	rounds := f32(max(1, len(export.round_event)))
	bar := max(1, chart.width / rounds)
	span := chart.width - bar
	life := make([]i64, len(indices), context.temp_allocator)
	peak, peak_round, failed := i64(0), i32(0), 0
	for index, position in indices {
		points := i64(export.turn_points[index])
		turn_round := i32(export.turn_round[index])
		turn_did_fail := turn_failed(&viewer.game, index)
		life[position] = points
		if points > peak {peak, peak_round = points, turn_round}
		if turn_did_fail {failed += 1}
		share := clamp(f32(points) / f32(limit), 0, 1)
		x := chart.x + f32(turn_round) / rounds * span
		rl.DrawRectangleRec(
			{x, chart.y + chart.height * (1 - share), bar, chart.height * share},
			turn_points_color(points, turn_did_fail, limit),
		)
		if turn_did_fail {rl.DrawRectangleRec({x - 1, chart.y, bar + 2, chart.height}, COLOR_DEATH)}
	}
	warning_y := chart.y + chart.height * (1 - POINTS_WARNING_SHARE)
	rl.DrawLineEx({chart.x, warning_y}, {chart.x + chart.width, warning_y}, 1, WARNING_COLOR)
	rl.DrawLineEx({chart.x, chart.y}, {chart.x + chart.width, chart.y}, 1, COLOR_DEATH)
	marker := chart.x + f32(frame) / rounds * span + bar / 2
	rl.DrawLineEx({marker, chart.y}, {marker, chart.y + chart.height}, 2, UI_ACCENT)
	scrub_chart(viewer, .Judge_Points, chart, span, rounds)
	cursor.y += chart.height + 6

	slice.sort(life)
	inspector_paragraph(
		viewer,
		cursor,
		width,
		fmt.tprintf(
			"Life: peak %.1fM at r%d, median %.1fM over %d turns, %d failed. Red line is the limit, orange 90%%.",
			f64(peak) / 1e6,
			peak_round,
			f64(life[len(life) / 2]) / 1e6,
			len(life),
			failed,
		),
		MUTED_TEXT_COLOR,
	)
	team := export.turn_team[indices[0]]
	costliest := -1
	first := turn_count_before_frame(&viewer.game, frame)
	for index in first ..< turn_count_before_frame(&viewer.game, frame + 1) {
		if export.turn_team[index] != team {continue}
		if costliest < 0 || export.turn_points[index] > export.turn_points[costliest] {costliest = index}
	}
	if costliest >= 0 {
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf(
				"Costliest teammate this round: dragon %d, %.1fM",
				export.turn_dragon[costliest],
				f64(export.turn_points[costliest]) / 1e6,
			),
			turn_points_color(i64(export.turn_points[costliest]), turn_failed(&viewer.game, costliest), limit),
		)
	}
}
