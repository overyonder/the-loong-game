package viewer

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The selected dragon's declared mental map (diagnostics.md, Mental map
// accuracy): what it believes of each side, from its own edge claims, and
// where the replay proves a claim wrong. Cells it gives no value for are black;
// nothing is drawn from truth in their place, except the dragons.

COLOR_CORRECT :: rl.Color{127, 176, 105, 255}
COLOR_WRONG :: rl.Color{251, 73, 52, 255}
// Beliefs are drawn just inside their cell, apart from the true edges on its border.
BELIEF_KELP :: rl.Color{178, 226, 96, 255}
BELIEF_POSSIBLE_KELP :: rl.Color{255, 128, 80, 255}
BELIEF_PORTAL :: rl.Color{190, 140, 255, 255}

// One side's claim: `?` unknown, `s` suspected kelp, `.` open, `w` kelp, `c`
// passable or `p` a portal, with its bot-local ID and landing when stated.
Edge_Claim :: struct {
	code:            u8,
	portal, landing: i32,
}

// The four claims of an `edges` value such as `N. Ew S? Wp3>45`.
parse_edge_claims :: proc(value: string) -> (claims: [4]Edge_Claim, ok: bool) {
	tokens := strings.fields(value, context.temp_allocator)
	if len(tokens) != 4 {return}
	letters := "NESW"
	for token, direction in tokens {
		if len(token) < 2 || token[0] != letters[direction] {return}
		claim := Edge_Claim{code = token[1], portal = -1, landing = -1}
		rest := token[2:]
		if claim.code == 'p' {
			id, _, landing := strings.partition(rest, ">")
			if number, parsed := strconv.parse_int(id); parsed {claim.portal = i32(number)}
			if number, parsed := strconv.parse_int(landing); parsed {claim.landing = i32(number)}
		}
		claims[direction] = claim
	}
	return claims, true
}

// Whether the board shows the focused dragon's mental map, which also hides
// the replay's own marks such as sonar, deaths and fog.
mental_view :: proc(viewer: ^Viewer_State, turn: ^Dragon_Turn, found: bool) -> bool {
	return viewer.overlays.mental_map && found && turn.gizmo_reliable && turn.accuracy.table != ""
}

// Whether a cell was in the dragon's 7×7 window at the start of its turn.
in_sight :: proc(geometry: Board_Geometry, head, cell: i32) -> bool {
	dx := abs(cell % geometry.width - head % geometry.width)
	dy := abs(cell / geometry.width - head / geometry.width)
	return min(dx, geometry.width - dx) <= WINDOW_RADIUS && min(dy, geometry.height - dy) <= WINDOW_RADIUS
}

// Diagonal hatching across a rectangle, for beliefs about cells out of sight,
// so they don't read as the replay's own solid marks.
draw_hatch :: proc(r: rl.Rectangle, color: rl.Color) {
	spacing := max(5, r.width / 3)
	for offset := spacing / 2; offset < r.width + r.height; offset += spacing {
		a := rl.Vector2{r.x + offset, r.y}
		b := rl.Vector2{r.x, r.y + offset}
		if offset > r.width {a = {r.x + r.width, r.y + offset - r.width}}
		if offset > r.height {b = {r.x + offset - r.height, r.y + r.height}}
		rl.DrawLineEx(a, b, 1, color)
	}
}

draw_mental_map :: proc(viewer: ^Viewer_State, geometry: Board_Geometry, turn: ^Dragon_Turn) {
	if !mental_view(viewer, turn, true) {return}
	area := geometry.width * geometry.height
	claimed := make([]bool, area, context.temp_allocator)
	for entry in turn.accuracy.cells {
		if entry[0] >= 0 && entry[0] < area && entry[1] != 0 {claimed[entry[0]] = true}
	}
	for cell in 0 ..< area {
		if !claimed[cell] {rl.DrawRectangleRec(cell_rectangle(geometry, cell), rl.BLACK)}
	}
	inset := max(2, geometry.cell_size / 8)
	side_line :: proc(r: rl.Rectangle, inset: f32, direction: int) -> [2]rl.Vector2 {
		sides := [4][2]rl.Vector2 {
			{{r.x + inset, r.y + inset}, {r.x + r.width - inset, r.y + inset}},
			{{r.x + r.width - inset, r.y + inset}, {r.x + r.width - inset, r.y + r.height - inset}},
			{{r.x + inset, r.y + r.height - inset}, {r.x + r.width - inset, r.y + r.height - inset}},
			{{r.x + inset, r.y + inset}, {r.x + inset, r.y + r.height - inset}},
		}
		return sides[direction]
	}
	for entry in turn.accuracy.cells {
		if entry[0] < 0 || entry[0] >= area || entry[1] == 0 {continue}
		// A cell it knows rightly is simply not black; a wrong one is red, solid
		// in sight and hatched beyond it.
		if entry[1] == 2 {
			if in_sight(geometry, turn.head, entry[0]) {
				rl.DrawRectangleRec(cell_rectangle(geometry, entry[0]), rl.Fade(COLOR_WRONG, 0.35))
			} else {draw_hatch(cell_rectangle(geometry, entry[0]), rl.Fade(COLOR_WRONG, 0.8))}
		}
		if entry[2] == 2 {
			rl.DrawCircleLinesV(cell_center(geometry, entry[0]), geometry.cell_size * 0.3, COLOR_WRONG)
		}
	}
	// What it believes of each side, from the graded table's own edge claims.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" || gizmo.label != turn.accuracy.table {continue}
		column := -1
		for quantity, index in gizmo.truth_columns {if quantity == "edges" {column = index}}
		if column < 0 {continue}
		for row, index in gizmo.rows {
			if index >= len(gizmo.row_cells) || column >= len(row) {continue}
			cell := gizmo.row_cells[index]
			claims, ok := parse_edge_claims(row[column])
			if !ok || cell < 0 || cell >= area {continue}
			r := cell_rectangle(geometry, cell)
			for claim, direction in claims {
				line := side_line(r, inset, direction)
				switch claim.code {
				case 'w':
					rl.DrawLineEx(line[0], line[1], max(2, geometry.cell_size / 10), BELIEF_KELP)
				case 's':
					for dash in 0 ..< 3 {
						a := line[0] + (line[1] - line[0]) * (f32(dash) / 3)
						b := line[0] + (line[1] - line[0]) * ((f32(dash) + 0.5) / 3)
						rl.DrawLineEx(a, b, 2, BELIEF_POSSIBLE_KELP)
					}
				case 'p':
					rl.DrawLineEx(line[0], line[1], 2, BELIEF_PORTAL)
					// The selected cell's portals lead to their remembered landings.
					if cell == viewer.selected_cell && claim.landing >= 0 && claim.landing < area {
						rl.DrawLineEx((line[0] + line[1]) / 2, cell_center(geometry, claim.landing), 1.5, BELIEF_PORTAL)
						rl.DrawCircleLinesV(cell_center(geometry, claim.landing), geometry.cell_size * 0.35, BELIEF_PORTAL)
					}
				}
			}
		}
	}
	// Pearls as the dragon holds them: those its table remembers in its window
	// now, then its beliefs out of sight.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "table" || gizmo.label != turn.accuracy.table {continue}
		column := -1
		for quantity, index in gizmo.truth_columns {if quantity == "pearl" {column = index}}
		if column < 0 {continue}
		for row, index in gizmo.rows {
			if index >= len(gizmo.row_cells) || column >= len(row) || row[column] != "1" {continue}
			cell := gizmo.row_cells[index]
			if cell >= 0 && cell < area && in_sight(geometry, turn.head, cell) {rl.DrawCircleV(cell_center(geometry, cell), geometry.cell_size * 0.23, COLOR_PEARL)}
		}
	}
	// Maps the bot marks for the mental map hold what it believes out of
	// sight, drawn in its own colours so their opacity is its confidence:
	// each edge a line inside its cell, each cell a dot.
	for &gizmo in turn.gizmos {
		if gizmo.kind != "map" || gizmo.display_overlay != "mental" {continue}
		for edge in gizmo.edges {
			if edge.cell < 0 || edge.cell >= area || edge.direction < 0 || edge.direction > 3 {continue}
			line := side_line(cell_rectangle(geometry, edge.cell), inset, int(edge.direction))
			rl.DrawLineEx(line[0], line[1], max(2, geometry.cell_size / 10), gizmo_color(edge.color))
		}
		for cell in gizmo.cells {
			if cell.cell < 0 || cell.cell >= area {continue}
			rl.DrawCircleV(cell_center(geometry, cell.cell), geometry.cell_size * 0.23, gizmo_color(cell.color))
		}
	}
	// Sides the replay proves wrong, over the beliefs.
	for entry in turn.accuracy.cells {
		if entry[0] < 0 || entry[0] >= area {continue}
		r := cell_rectangle(geometry, entry[0])
		for direction in 0 ..< 4 {
			if entry[3 + direction] != 2 {continue}
			line := side_line(r, inset, direction)
			rl.DrawLineEx(line[0], line[1], 3, COLOR_WRONG)
		}
	}
}

// Totals for the turn, then the selected cell's grades and any wrong claims.
draw_accuracy_summary :: proc(
	viewer: ^Viewer_State,
	cursor: ^rl.Vector2,
	width: f32,
	turn: ^Dragon_Turn,
) {
	accuracy := &turn.accuracy
	if accuracy.table == "" {return}
	inspector_paragraph(
		viewer,
		cursor,
		width,
		fmt.tprintf(
			"Mental map (%s): cells %d correct, %d wrong, %d unknown; edges %d / %d / %d; pearls %d / %d / %d",
			accuracy.table,
			accuracy.cell_totals[1],
			accuracy.cell_totals[2],
			accuracy.cell_totals[0],
			accuracy.edges[1],
			accuracy.edges[2],
			accuracy.edges[0],
			accuracy.pearls[1],
			accuracy.pearls[2],
			accuracy.pearls[0],
		),
		UI_ACCENT,
	)
	cell := viewer.selected_cell
	if cell < 0 {return}
	grade_names := [3]string{"unknown", "correct", "wrong"}
	for entry in accuracy.cells {
		if entry[0] != cell {continue}
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf(
				"Remembered cell: %s; pearl %s; N %s, E %s, S %s, W %s",
				grade_names[entry[1]],
				grade_names[entry[2]],
				grade_names[entry[3]],
				grade_names[entry[4]],
				grade_names[entry[5]],
				grade_names[entry[6]],
			),
		)
		for wrong in accuracy.wrong {if wrong.cell == cell {inspector_paragraph(viewer, cursor, width, wrong.reason, WARNING_COLOR)}}
		return
	}
	inspector_paragraph(viewer, cursor, width, "Remembered cell: no record (unknown)", MUTED_TEXT_COLOR)
}

// The pings around this decision: the echoes of its previous sonar, each with
// what it meant by it, then the pings it read on its turn, each joined with the
// sender's own reading and the receiver's reading, outcome and memory rows,
// then its own sends this turn, which come back as echoes on its next turn.
draw_radio :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, turn: ^Dragon_Turn) {
	for error in radio_errors(&viewer.game, turn) {inspector_paragraph(viewer, cursor, width, error, WARNING_COLOR)}
	pings := decision_pings(&viewer.game, turn)
	for row in pings.echoes {
		ping := game_ping(&viewer.game, row)
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf("Echo of its r%d sonar %s: hit %s", ping.round, ping.direction, HIT_KIND_NAMES[clamp(int(ping.hit_kind), 0, len(HIT_KIND_NAMES) - 1)]),
			CORRECT_TIMER_COLOR,
			"ping",
			ping.id,
		)
		if ping.decoded != "" {inspector_paragraph(viewer, cursor, width, fmt.tprintf("Sent as: %s", ping.decoded))}
	}
	for row in pings.received {
		ping := game_ping(&viewer.game, row)
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf(
				"Received D%d %s -> %s, sent r%d%s",
				ping.sender,
				ping.direction,
				ping.hit < 0 ? "lost" : fmt.tprintf("D%d", ping.hit),
				ping.round,
				ping.received_round >= 0 ? fmt.tprintf(", read r%d", ping.received_round) : "",
			),
			UI_ACCENT,
			"ping",
			ping.id,
		)
		inspector_paragraph(
			viewer,
			cursor,
			width,
			ping.decoded != "" ? fmt.tprintf("Sender: %s", ping.decoded) : fmt.tprintf("Sender recorded no meaning for %s", ping.value),
			ping.decoded != "" ? TEXT_COLOR : MUTED_TEXT_COLOR,
		)
		if ping.hit < 0 {continue}
		if ping.receiver_meaning != "" {
			inspector_paragraph(
				viewer,
				cursor,
				width,
				fmt.tprintf("Receiver D%d: %s", ping.hit, ping.receiver_meaning),
			)
		}
		inspector_paragraph(
			viewer,
			cursor,
			width,
			fmt.tprintf("Receiver outcome: %s", ping.acceptance),
			MUTED_TEXT_COLOR,
		)
		if ping.memory_evidence != "" {
			inspector_paragraph(
				viewer,
				cursor,
				width,
				fmt.tprintf("Receiver memory: %s", ping.memory_evidence),
				MUTED_TEXT_COLOR,
			)
		}
	}
	if len(pings.received) == 0 && len(pings.echoes) == 0 {inspector_paragraph(viewer, cursor, width, "No pings read or echoed on this turn", MUTED_TEXT_COLOR)}
	// Then what it chose to send, ray by ray, and the rays it left unsent,
	// in either phase: the choice is part of the decision. Where the rays
	// land arrives as next turn's echoes.
	if !turn.gizmo_reliable {return}
	for &gizmo, index in turn.gizmos {
		if gizmo.sonar.role == "sent" && gizmo.parent == "" {draw_gizmo(viewer, turn, &gizmo, index, cursor, width)}
	}
}

// The mental map's view of a positions record: each believed dragon where the
// dragon thinks it is, green if the replay's head lies among the cells it may
// occupy and red if not, graded as beliefs.odin grades positions. A champion is
// a square, any other dragon a ring inside its cell. The cells it may occupy
// are hatched, since they are out-of-sight beliefs.
draw_believed_positions :: proc(viewer: ^Viewer_State, gizmo: ^Gizmo, geometry: Board_Geometry, turn: ^Dragon_Turn) {
	width, height := geometry.width, geometry.height
	for entry in gizmo.positions {
		color := gizmo_color(entry.color != ([4]u8{}) ? entry.color : gizmo.color)
		if subject, named := entry.dragon.?; named {
			if subject == turn.dragon {continue}
			area := position_area(entry, width, height)
			right := false
			for dragon in turn.dragons {if dragon.id == subject && dragon.head >= 0 {right = area[dragon.head]}}
			// Graded, at the opacity the bot gave its confidence.
			graded := right ? COLOR_CORRECT : COLOR_WRONG
			color = {graded.r, graded.g, graded.b, color.a}
		}
		// What the dragon chose to believe, its centre, and when opened the
		// cells it may occupy (gizmos.odin, position_opened).
		if position_opened(viewer, entry) && (entry.radius > 0 || len(entry.cells) > 0) {draw_position_extents(entry, geometry, color)}
		draw_position_centre(entry, geometry, color)
		if entry.label != "" {
			label := entry.age > 0 ? fmt.ctprintf("%s, %d ago", entry.label, entry.age) : fmt.ctprintf("%s", entry.label)
			draw_text_with_backdrop(label, cell_center(geometry, entry.cell) + {geometry.cell_size * 0.3, -geometry.cell_size * 0.6}, CELL_TEXT, color)
		}
	}
}

// Whether the focused dragon knows of a dragon: itself, one its window showed
// at the start of its turn, or one a positions record names.
dragon_known :: proc(turn: ^Dragon_Turn, geometry: Board_Geometry, dragon: ^Board_Dragon) -> bool {
	if dragon.id == turn.dragon {return true}
	for cell in dragon.body {if in_sight(geometry, turn.head, cell) {return true}}
	for &gizmo in turn.gizmos {
		if gizmo.kind != "positions" {continue}
		for entry in gizmo.positions {if subject, named := entry.dragon.?; named && subject == dragon.id {return true}}
	}
	return false
}
