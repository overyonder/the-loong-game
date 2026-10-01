package viewer

// Rebuild a turn's retained records (`retain`), which the bot emits as the
// entries that changed since the record's previous appearance for that dragon,
// by rebuilding that appearance first. The first rebuild walks back through
// the dragon's earlier turns once; each rebuilt turn keeps its whole records.
expand_retained_gizmos :: proc(game: ^Loaded_Game, indices: []int, position: int) {
	turn := game_turn(game, indices[position])
	if turn.retained_expanded {return}
	turn.retained_expanded = true
	allocator := turn_allocator(game)
	for &gizmo in turn.gizmos {
		if !gizmo.retain {continue}
		previous: ^Gizmo
		search: for earlier := position - 1; earlier >= 0; earlier -= 1 {
			for &candidate in game_turn(game, indices[earlier]).gizmos {
				if candidate.retain && candidate.kind == gizmo.kind && candidate.label == gizmo.label {
					expand_retained_gizmos(game, indices, earlier)
					previous = &candidate
					break search
				}
			}
		}
		if previous == nil {continue}
		if gizmo.kind == "map" {
			cells := make([dynamic]Gizmo_Cell, 0, len(previous.cells) + len(gizmo.cells), allocator)
			append(&cells, ..previous.cells)
			changed: for cell in gizmo.cells {
				for &existing in cells {if existing.cell == cell.cell {existing = cell; continue changed}}
				append(&cells, cell)
			}
			edges := make([dynamic]Gizmo_Edge, 0, len(previous.edges) + len(gizmo.edges), allocator)
			append(&edges, ..previous.edges)
			changed_edges: for edge in gizmo.edges {
				for &existing in edges {
					if existing.cell == edge.cell && existing.direction == edge.direction {
						existing = edge
						continue changed_edges
					}
				}
				append(&edges, edge)
			}
			gizmo.cells, gizmo.edges = cells[:], edges[:]
		} else {
			row_cells := make([dynamic]i32, 0, len(previous.row_cells) + len(gizmo.row_cells), allocator)
			rows := make([dynamic][]string, 0, len(previous.rows) + len(gizmo.rows), allocator)
			append(&row_cells, ..previous.row_cells)
			append(&rows, ..previous.rows)
			changed_rows: for cell, row in gizmo.row_cells {
				for existing, slot in row_cells {if existing == cell {rows[slot] = gizmo.rows[row]; continue changed_rows}}
				append(&row_cells, cell)
				append(&rows, gizmo.rows[row])
			}
			gizmo.row_cells, gizmo.rows = row_cells[:], rows[:]
		}
	}
}
