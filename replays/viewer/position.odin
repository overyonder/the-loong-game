package viewer

import "core:encoding/json"
import "core:os"
import "core:strings"

// Where the viewer is and everything selected in it, as JSON in
// GAME.cols.position, rewritten whenever it changes while playback is paused.
// A caller can reopen a viewer from it with `--position`, and anyone
// following the review, such as an agent, reads it. Cells are `y * width + x`.
Viewer_Position :: struct {
	replay:      string,
	round:       i32,
	// Turns mode, and its turn index; -1 in Rounds mode.
	turns:       bool,
	turn:        i32,
	// The focused dragon, -1 for none, and whether the board shows all of it
	// rather than the focused dragon's area.
	dragon:      i32,
	whole_board: bool,
	// The last cell clicked, which the inspectors describe; -1 for none.
	cell:        i32,
	highlights:  []Position_Highlight,
	// The inspector's selected node or row, its open tab (brain, signals or
	// memory) and whether the Brain view is open.
	record:      string,
	tab:         string,
	brain_open:  bool,
	// The open detail dialog's title, and the cell selected on its belief
	// map, -1 for none. Neither is restored: the dialog is reopened by hand.
	dialog:      string,
	dialog_cell: i32,
	overlays:    Overlay_Toggles,
	// The team the viewer treats as ours, -1 when not yet settled.
	our_team:    i32,
	// The comment being typed and not yet saved.
	comment:     string,
}
// A highlight with its description, such as `cell (3,4)`.
Position_Highlight :: struct {
	kind: string,
	id:   i32,
	text: string,
}

viewer_position :: proc(viewer: ^Viewer_State) -> Viewer_Position {
	highlights := make([]Position_Highlight, len(viewer.highlights), context.temp_allocator)
	for item, index in viewer.highlights {
		highlights[index] = {item.kind, item.id, describe_highlight(viewer, item)}
	}
	return {
		replay = viewer.comment_context.replay,
		round = current_frame(viewer),
		turns = viewer.playback.substeps,
		turn = viewer.playback.substeps ? i32(viewer.playback.turn_position) : -1,
		dragon = viewer.selected_dragon,
		whole_board = !viewer.area_view,
		cell = viewer.selected_cell,
		highlights = highlights,
		record = viewer.gizmo_selection,
		tab = viewer.generic_memory_tab ? "memory" : viewer.generic_signals_tab ? "signals" : "brain",
		brain_open = viewer.brain_open,
		dialog = viewer.detail_open ? viewer.detail_title : "",
		dialog_cell = viewer.detail_open ? viewer.detail_map.cell : -1,
		overlays = viewer.overlays,
		our_team = viewer.our_team,
		comment = string(cstring(raw_data(viewer.comment[:]))),
	}
}

// The position as one JSON line, "" if it can't be encoded.
encode_position :: proc(viewer: ^Viewer_State) -> string {
	data, error := json.marshal(viewer_position(viewer), allocator = context.temp_allocator)
	return error == nil ? string(data) : ""
}

// A saved position, false when the file is missing or isn't one. An overlay
// the file doesn't name, such as one added since, keeps its default.
read_position :: proc(path: string, overlays: Overlay_Toggles) -> (position: Viewer_Position, ok: bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return}
	position.overlays = overlays
	position.our_team = -1
	if json.unmarshal(data, &position) != nil {return}
	return position, true
}

// The startup settings a saved position gives: where playback opens.
position_startup :: proc(position: Viewer_Position, startup: ^Startup_Settings) {
	startup.dragon = position.dragon
	startup.round = position.round
	startup.turn = position.turns ? int(position.turn) : -1
	startup.whole_board = position.whole_board
	startup.rounds = !position.turns
}

// The selections a saved position gives, applied once playback is where it
// says, since moving between turns clears them.
restore_selections :: proc(viewer: ^Viewer_State, position: Viewer_Position) {
	viewer.selected_cell = position.cell
	clear(&viewer.highlights)
	for item in position.highlights {append(&viewer.highlights, Highlight{strings.clone(item.kind), item.id})}
	delete(viewer.gizmo_selection)
	viewer.gizmo_selection = strings.clone(position.record)
	viewer.generic_signals_tab = position.tab == "signals"
	viewer.generic_memory_tab = position.tab == "memory"
	viewer.brain_open = position.brain_open
	viewer.overlays = position.overlays
	viewer.our_team = position.our_team
	viewer.comment = {}
	copy(viewer.comment[:len(viewer.comment) - 1], position.comment)
}
