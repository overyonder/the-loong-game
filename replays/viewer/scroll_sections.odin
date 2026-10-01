package viewer

import rl "vendor:raylib"

// Clamp before drawing; measuring after drawing must not expose overscroll.
finish_scroll_section :: proc(offset, limit: ^f32, area: rl.Rectangle, maximum: f32) {
	limit^ = max(0, maximum)
	offset^ = clamp(offset^, 0, limit^)
	rl.DrawRectangleLinesEx(area, 1, PANE_BORDER)
	if limit^ <= 0 || area.height <= 0 {return}
	height := max(16, area.height * area.height / (area.height + limit^))
	if rl.IsMouseButtonDown(.LEFT) &&
	   rl.CheckCollisionPointRec(
		   rl.GetMousePosition(),
		   {area.x + area.width - 8, area.y, 8, area.height},
	   ) {
		offset^ =
			clamp(
				(rl.GetMousePosition().y - area.y - height * 0.5) / max(1, area.height - height),
				0,
				1,
			) *
			limit^
	}
	y := area.y + (area.height - height) * offset^ / limit^
	rl.DrawRectangleRec({area.x + area.width - 4, y, 3, height}, MUTED_TEXT_COLOR)
}

draw_graph_curve :: proc(start, end: rl.Vector2, thickness: f32, color: rl.Color) {
	direction: f32 = end.y >= start.y ? 1 : -1
	bend := max(24, abs(end.y - start.y) * 0.5)
	rl.DrawSplineSegmentBezierCubic(
		start,
		start + rl.Vector2{0, bend * direction},
		end - rl.Vector2{0, bend * direction},
		end,
		thickness,
		color,
	)
}

draw_compact_legend :: proc(origin: rl.Vector2, width: f32) -> f32 {
	y := origin.y + 10
	Glyph :: enum {
		Digit,
		Line,
		Dashes,
		Box,
		Dot,
		Crown,
	}
	entries := [?]struct {
		label: string,
		color: rl.Color,
		glyph: Glyph,
	} {
		{"Search score", BOARD_TEXT, .Digit},
		{"Spawn countdown", {224, 182, 73, 255}, .Digit},
		{"Remembered spawn", CORRECT_TIMER_COLOR, .Digit},
		{"Wrong spawn memory", COLOR_WRONG, .Digit},
		{"Remembered kelp", BELIEF_KELP, .Line},
		{"Possible kelp", BELIEF_POSSIBLE_KELP, .Dashes},
		{"Remembered portal", BELIEF_PORTAL, .Line},
		{"Wrong memory", COLOR_WRONG, .Line},
		{"Planned path", UI_ACCENT, .Line},
		{"Sonar received", SONAR_RECEIVED, .Dashes},
		{"Sonar echo", SONAR_ECHO, .Dashes},
		{"Outside vision", {55, 61, 69, 255}, .Box},
		{"Team A", TEAM_HEAD_COLORS[0], .Dot},
		{"Team B", TEAM_HEAD_COLORS[1], .Dot},
		{"Enemy champion", ENEMY_CHAMPION_COLOR, .Crown},
	}
	for entry in entries {
		x := origin.x + 4
		switch entry.glyph {
		case .Digit:
			clipped_text("7", x, y, 22, entry.color)
		case .Line:
			rl.DrawLineEx({x, y + 7}, {x + 20, y + 7}, 2, entry.color)
		case .Dashes:
			for i in 0 ..< 3 {rl.DrawLineEx({x + f32(i) * 8, y + 7}, {x + f32(i) * 8 + 4, y + 7}, 2, entry.color)}
		case .Box:
			rl.DrawRectangleRec({x, y, 20, 16}, entry.color)
		case .Dot:
			rl.DrawCircleV({x + 10, y + 7}, 6, entry.color)
		case .Crown:
			draw_head({x + 10, y + 10}, 5, .Crown, entry.color, {0, -1})
		}
		clipped_text(entry.label, x + 30, y, width - 40, MUTED_TEXT_COLOR)
		y += UI_LINE
	}
	return y
}
