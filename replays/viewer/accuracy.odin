package viewer

import "core:fmt"
import "core:strings"

// A dragon's declared mental map graded against the replay, claim by claim
// (diagnostics.md, Mental map accuracy). Only facts the bot states are graded:
// a cell or side it gives no value for is unknown, and truth never fills it
// in. Sides are static map facts; pearls are graded against the board the
// dragon faced at the start of its turn.

GRADE_UNKNOWN :: 0
GRADE_CORRECT :: 1
GRADE_WRONG :: 2

// Each cell's four sides in N/E/S/W order: `.` open, `w` kelp or `#` a
// portal, and the cell a move through it lands on (-1 into kelp).
Map_Truth :: struct {
	kinds:    [][4]u8,
	landings: [][4]i32,
}

map_truth :: proc(game: ^Loaded_Game) -> ^Map_Truth {
	truth := &game.truth
	if truth.kinds != nil {return truth}
	view := &game.view
	width, height := view.width, view.height
	allocator := game_allocator(game)
	area := int(width * height)
	truth.kinds = make([][4]u8, area, allocator)
	truth.landings = make([][4]i32, area, allocator)
	// Edges are keyed by a cell's north (side 0) or west (side 1) edge.
	edges := make(map[[3]i32]Board_Edge, context.temp_allocator)
	for edge in view.edges {edges[{edge.x, edge.y, edge.side}] = edge}
	key :: proc(x, y, direction, width, height: i32) -> [3]i32 {
		switch direction {
		case 0:
			return {x, y, 0}
		case 1:
			return {(x + 1) % width, y, 1}
		case 2:
			return {x, (y + 1) % height, 0}
		}
		return {x, y, 1}
	}
	adjacent :: proc(x, y, direction, width, height: i32) -> i32 {
		offsets := [4][2]i32{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
		return ((y + offsets[direction][1] + height) % height) * width + (x + offsets[direction][0] + width) % width
	}
	for cell in 0 ..< i32(area) {
		x, y := cell % width, cell / width
		for direction in i32(0) ..< 4 {
			edge_key := key(x, y, direction, width, height)
			edge, found := edges[edge_key]
			if !found {
				truth.kinds[cell][direction] = '.'
				truth.landings[cell][direction] = adjacent(x, y, direction, width, height)
			} else if edge.kelp {
				truth.kinds[cell][direction] = 'w'
				truth.landings[cell][direction] = -1
			} else {
				truth.kinds[cell][direction] = '#'
				truth.landings[cell][direction] = -1
				// Through the partner edge: beyond it for north and west, since
				// an edge belongs to the cell south or east of it.
				for other in view.edges {
					other_key := [3]i32{other.x, other.y, other.side}
					if other.kelp || other.portal != edge.portal || other_key == edge_key {continue}
					truth.landings[cell][direction] =
						direction == 0 || direction == 3 ? adjacent(other.x, other.y, direction, width, height) : other.y * width + other.x
				}
			}
		}
	}
	return truth
}

// Grade the turn's mental-map table, the first with `edges` or `pearl` truth
// columns, into `turn.accuracy`; left empty when there is none.
grade_turn :: proc(game: ^Loaded_Game, turn: ^Dragon_Turn) {
	if !turn.gizmo_reliable {return}
	table: ^Gizmo
	edges_column, pearl_column := -1, -1
	search: for &gizmo in turn.gizmos {
		if gizmo.kind != "table" {continue}
		for quantity, column in gizmo.truth_columns {
			if quantity == "edges" {edges_column = column}
			if quantity == "pearl" {pearl_column = column}
		}
		if edges_column >= 0 || pearl_column >= 0 {table = &gizmo; break search}
	}
	if table == nil {return}
	allocator := turn_allocator(game)
	truth := map_truth(game)
	area := len(truth.kinds)
	pearls := make(map[i32]bool, context.temp_allocator)
	for pearl in turn.pearls {pearls[pearl] = true}
	accuracy := &turn.accuracy
	accuracy.table = table.label
	cells := make([dynamic][7]i32, allocator)
	wrong := make([dynamic]struct {
			cell:   i32,
			reason: string,
		}, allocator)
	letters := "NESW"
	for row, index in table.rows {
		if index >= len(table.row_cells) {break}
		cell := table.row_cells[index]
		if cell < 0 || int(cell) >= area {continue}
		sides: [4]i32
		reasons := make([dynamic]string, context.temp_allocator)
		if edges_column >= 0 && edges_column < len(row) {
			if claims, ok := parse_edge_claims(row[edges_column]); ok {
				for claim, direction in claims {
					kind := truth.kinds[cell][direction]
					landing := truth.landings[cell][direction]
					grade := grade_edge(claim, kind, landing)
					sides[direction] = grade
					if grade == GRADE_WRONG {
						append(&reasons, fmt.tprintf("%c %s", letters[direction], edge_text(claim, kind, landing)))
					}
				}
			}
		}
		pearl := i32(GRADE_UNKNOWN)
		if pearl_column >= 0 && pearl_column < len(row) && (row[pearl_column] == "0" || row[pearl_column] == "1") {
			remembered := row[pearl_column] == "1"
			pearl = remembered == pearls[cell] ? GRADE_CORRECT : GRADE_WRONG
			if pearl == GRADE_WRONG {
				append(&reasons, fmt.tprintf("pearl remembered %s, replay %s", remembered ? "present" : "absent", pearls[cell] ? "present" : "absent"))
			}
		}
		overall := i32(GRADE_UNKNOWN)
		for grade in ([5]i32{sides[0], sides[1], sides[2], sides[3], pearl}) {
			if grade == GRADE_WRONG {overall = GRADE_WRONG} else if grade == GRADE_CORRECT && overall == GRADE_UNKNOWN {overall = GRADE_CORRECT}
		}
		for grade in sides {accuracy.edges[grade] += 1}
		accuracy.pearls[pearl] += 1
		accuracy.cell_totals[overall] += 1
		append(&cells, [7]i32{cell, overall, pearl, sides[0], sides[1], sides[2], sides[3]})
		if len(reasons) > 0 {
			append(&wrong, struct {
					cell:   i32,
					reason: string,
				}{cell, strings.join(reasons[:], "; ", allocator)})
		}
	}
	// Cells and sides without a row are unknown too.
	silent := i32(area - len(cells))
	accuracy.cell_totals[GRADE_UNKNOWN] += silent
	accuracy.edges[GRADE_UNKNOWN] += 4 * silent
	accuracy.pearls[GRADE_UNKNOWN] += silent
	accuracy.cells = cells[:]
	accuracy.wrong = wrong[:]
}

// A side's grade: `kind` is the truth's `.`, `w` or `#`, `landing` its crossing.
grade_edge :: proc(claim: Edge_Claim, kind: u8, landing: i32) -> i32 {
	switch claim.code {
	case '.':
		return kind == '.' ? GRADE_CORRECT : GRADE_WRONG
	case 'w':
		return kind == 'w' ? GRADE_CORRECT : GRADE_WRONG
	case 'c':
		return kind != 'w' ? GRADE_CORRECT : GRADE_WRONG
	case 'p':
		if kind != '#' {return GRADE_WRONG}
		return claim.landing < 0 || claim.landing == landing ? GRADE_CORRECT : GRADE_WRONG
	}
	// `?` unknown and `s` suspected are hypotheses, not claims.
	return GRADE_UNKNOWN
}

edge_text :: proc(claim: Edge_Claim, kind: u8, landing: i32) -> string {
	truth := kind == '.' ? "open" : kind == 'w' ? "kelp" : fmt.tprintf("portal to %d", landing)
	said := claim.code == '.' ? "open" : claim.code == 'w' ? "kelp" : claim.code == 'c' ? "passable" : "portal"
	if claim.code == 'p' && claim.landing >= 0 {said = fmt.tprintf("portal to %d", claim.landing)}
	return fmt.tprintf("remembered %s, replay %s", said, truth)
}
