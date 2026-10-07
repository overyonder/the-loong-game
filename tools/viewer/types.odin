package viewer
import rl "vendor:raylib"


// A recorded board as the viewer draws it (board_replay.odin).
Board_Edge :: struct {
	x, y, side: i32,
	kelp:       bool,
	portal:     i32,
}
Board_Dragon :: struct {
	id, team: i32,
	body:     []i32,
}
Board_Death :: struct {
	id, team, cell: i32,
	reason:         string,
}
Spawn_Rule :: struct {
	cell, minimum, maximum: i32,
}
Pearl_Timer :: struct {
	cell, remaining: i32,
}
Board_Frame :: struct {
	dragons: []Board_Dragon,
	pearls:  []i32,
	deaths:  []Board_Death,
	timers:  []Pearl_Timer,
}
// A dragon's declared mental map graded against replay truth (accuracy.odin).
// Grades are 0 unknown, 1 correct, 2 wrong; each cell entry is
// [cell, overall, pearl, north, east, south, west].
Accuracy :: struct {
	table:         string,
	cells:         [][7]i32,
	wrong:         []struct {
		cell:   i32,
		reason: string,
	},
	edges, pearls: [3]i32,
	cell_totals:   [3]i32,
}
Dragon_Fact :: struct {
	id, team, head, length: i32,
}
// One dragon turn: its record from the recovery stream (recovery_stream.odin),
// the game's facts about it, and what the viewer derives when it opens it.
Dragon_Turn :: struct {
	// From the turn's record (diagnostics.md).
	gizmos:                             []Gizmo,
	gizmo_errors:                       []string,
	// Display slots whose root record was rejected this turn.
	gizmo_rejected_slots:               []string,
	gizmo_source, gizmo_status:         string,
	gizmo_reliable:                     bool,
	gizmo_input_protocol:               i32,
	// The recovery's note on the dragon's build.
	build_guid, build_variant, build_status: string,
	// Derived when opened: the mental map's grades and the sonar join's errors.
	accuracy:                           Accuracy,
	radio_errors:                       []string,
	dragon, team, round, head, length:  i32,
	action:                             string,
	// Judge points charged to the turn, and the toolkit's reason if it failed.
	points:                             i64,
	point_failure:                      string,
	// The replay at the turn's start, which grades its memory and beliefs:
	// the pearls, each cell's next spawn attempt as {cell, round}, and the
	// living dragons.
	pearls:                             []i32,
	spawns:                             [][2]i32,
	dragons:                            []Dragon_Fact,
	// Its beliefs graded against that (beliefs.odin).
	beliefs:                            []Belief_Grade,
	// Whether the stream had sent this turn's record when it was opened, and
	// whether its memory has been graded since.
	has_record, graded:                 bool,
	// Recoverable, but not recovered yet.
	recovery_pending:                   bool,
	// Its retained gizmos have been rebuilt from their changes.
	retained_expanded:                  bool,
}
Overlay_Toggles :: struct {
	target_lines, vision_windows, deaths, dragon_ids, grid, edges: bool,
	fog:                                                           bool,
	pings, timers, search, path, mental_map, positions:            bool,
	spawn_gaps:                                                    bool,
	mirror:                                                        bool,
	// Our dragons' colours, head icons and body patterns as their breakdown's
	// producer names them (breakdown.odin).
	colors, icons, patterns:                                       bool,
}
Playback_State :: struct {
	substeps:          bool,
	turn_position:     f32,
	frame_position:    f32,
	playing:           bool,
	frames_per_second: f32,
}
Highlight :: struct {
	kind: string,
	id:   i32,
}
// A saved comment's context, carried in its inbox line (annotations.odin).
Annotation :: struct {
	replay:                 string,
	turn_index:             i32,
	substeps:               bool,
	version, frame, dragon: i32,
	highlights:             []Highlight,
	text:                   string `json:"-"`, // the line's visible text
}
Viewer_State :: struct {
	gizmo_graph_y:                                                                                  [1024]f32,
	gizmo_graph_hovered:                                                                            bool,
	gizmo_graph_pan:                                                                                [1024]f32,
	gizmo_selection:                                                                                string,
	generic_signals_tab:                                                                            bool,
	generic_memory_tab:                                                                             bool,
	objective_scroll_limit,
	inspector_scroll_limit,
	detail_scroll_limit: f32,
	brain_open:                                                                                     bool,
	// Whether the board marks which of our dragons know where the enemy queen
	// is, toggled by the beliefs strip's Enemy queen box (beliefs.odin).
	queen_view:                                                                                     bool,
	// The recovery process beside the viewer, and the dragons it is recovering.
	recovery:                                                                                       Recovery_Process,
	// Scroll over the board not yet taken as a step.
	wheel_steps: f32,
	// The dragon Defocus left, for the Focus button to return to.
	last_focused: i32,
	// The team the whole viewer treats as ours, -1 until settled (controls.odin,
	// our_team).
	our_team: i32,
	// The sidebar chart being dragged to seek, if any.
	scrubbing: Scrub_Chart,
	area_view:                                                                                      bool, // `f`: the 15×15 area round the focused head
	objective_scroll:                                                                               f32,
	drag_selecting:                                                                                 bool,
	// How a board drag selects, whether it has left its first cell, and whether a
	// brush stroke erases.
	drag_shape:                                                                                     Drag_Shape,
	drag_moved, brush_erases:                                                                       bool,
	drag_start_cell,
	drag_end_cell:                                                                 i32,
	detail_title,
	detail_text:                                                                      string,
	detail_scroll:                                                                                  f32,
	detail_open:                                                                                    bool,
	// A belief the detail dialog draws as a board (belief_map.odin). With no
	// category, the dialog is text only.
	detail_map:                                                                                     Belief_Map_View,
	inspector_area:                                                                                 rl.Rectangle,
	// The inspector body's scissor, which a sideways-scrolling table narrows
	// and then restores.
	inspector_clip:                                                                                 rl.Rectangle,
	game:                                                                                           Loaded_Game,
	has_game:                                                                                       bool,
	playback:                                                                                       Playback_State,
	overlays:                                                                                       Overlay_Toggles,
	selected_dragon,
	selected_cell:                                                                 i32,
	status:                                                                                         string,
	scale:                                                                                          f32,
	inspector_scroll:                                                                               f32,
	highlights:                                                                                     [dynamic]Highlight,
	comment:                                                                                        [4096]u8,
	comment_editing:                                                                                bool,
	comment_context:                                                                                Comment_Context,
	annotations:                                                                                    [dynamic]Annotation,
	annotation_index:                                                                               int,
	// Manual mode's ghost of the focused dragon (ghost.odin).
	ghost: Ghost,
}
