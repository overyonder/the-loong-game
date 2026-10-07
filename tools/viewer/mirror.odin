package viewer

import rl "vendor:raylib"

// The Mirror overlay: every dragon's image under the map's symmetry, drawn as a
// ghost in its own team's colour. Each team starts on the image of the other's
// start, so on either half the ghosts are what the other team did from the
// matching start, and two openings can be read against each other on the same
// ground, move by move.

Mirror_Kind :: enum {
	None,
	Flip_X, // x reflected: x' = (ax - x) mod width
	Flip_Y, // y reflected: y' = (ay - y) mod height
	Rotate, // both, a half turn
}

Mirror_Transform :: struct {
	kind:   Mirror_Kind,
	ax, ay: i32,
}

mirror_cell :: proc(view: ^Game_View, transform: Mirror_Transform, cell: i32) -> i32 {
	x, y := cell % view.width, cell / view.width
	if transform.kind == .Flip_X || transform.kind == .Rotate {x = ((transform.ax - x) % view.width + view.width) % view.width}
	if transform.kind == .Flip_Y || transform.kind == .Rotate {y = ((transform.ay - y) % view.height + view.height) % view.height}
	return y * view.width + x
}

// The replay's game columns don't name the symmetry, so it is found from the
// starting bodies: the reflection or half turn that carries every team A body,
// cell by cell, onto a team B body. Pairing A's first head with each B head
// gives the candidate axes. None when no transform fits.
infer_mirror :: proc(view: ^Game_View) -> Mirror_Transform {
	dragons := column_values(&view.columns, "start.dragon", u32)
	teams := column_values(&view.columns, "start.team", u8)
	bodies := make([][]u32, len(dragons), context.temp_allocator)
	for _, index in dragons {bodies[index] = list_row(&view.columns, "start.body", "start.body#", index, u32)}
	first := -1
	for team, index in teams {if team == 0 && len(bodies[index]) > 0 {first = index; break}}
	if first < 0 {return {}}
	fits :: proc(view: ^Game_View, transform: Mirror_Transform, teams: []u8, bodies: [][]u32) -> bool {
		for team, index in teams {
			if team != 0 {continue}
			matched := false
			for other_team, other in teams {
				if other_team != 1 || len(bodies[other]) != len(bodies[index]) {continue}
				same := true
				for cell, position in bodies[index] {
					if mirror_cell(view, transform, i32(cell)) != i32(bodies[other][position]) {same = false; break}
				}
				if same {matched = true; break}
			}
			if !matched {return false}
		}
		return true
	}
	head := i32(bodies[first][0])
	hx, hy := head % view.width, head / view.width
	for kind in Mirror_Kind {
		if kind == .None {continue}
		for team, index in teams {
			if team != 1 || len(bodies[index]) == 0 {continue}
			other := i32(bodies[index][0])
			transform := Mirror_Transform{kind, (hx + other % view.width) % view.width, (hy + other / view.width) % view.height}
			if fits(view, transform, teams, bodies) {return transform}
		}
	}
	return {}
}

// Ghosts under the real dragons: bodies as small translucent dots and links,
// heads as rings, so the dragons actually there stay readable on top.
draw_mirror_ghosts :: proc(viewer: ^Viewer_State, board: ^Board_Frame, g: Board_Geometry) {
	view := &viewer.game.view
	if view.mirror.kind == .None {return}
	for &dragon in board.dragons {
		if len(dragon.body) == 0 {continue}
		color := rl.Fade(TEAM_BODY_COLORS[dragon.team], 0.45)
		previous: i32 = -1
		for cell in dragon.body {
			image := mirror_cell(view, view.mirror, cell)
			rl.DrawCircleV(cell_center(g, image), g.cell_size * 0.17, color)
			if previous >= 0 {
				dx := abs(previous % g.width - image % g.width)
				dy := abs(previous / g.width - image / g.width)
				if dx + dy == 1 || (dy == 0 && dx == g.width - 1) || (dx == 0 && dy == g.height - 1) {
					draw_cell_link(g, previous, image, color, g.cell_size * 0.22)
				}
			}
			previous = image
		}
		center := cell_center(g, mirror_cell(view, view.mirror, dragon.body[0]))
		rl.DrawRing(center, g.cell_size * 0.26, g.cell_size * 0.36, 0, 360, 32, rl.Fade(TEAM_HEAD_COLORS[dragon.team], 0.8))
	}
}
