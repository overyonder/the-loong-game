package viewer
import rl "vendor:raylib"

import virtual "core:mem/virtual"

// Version 4 exports preserve recorded pre-action boards separately from rerun
// memory. Diagnostic types follow LOG K001_STATE v1 without reshaping its data.
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
Pearl_Timer :: struct {
	cell, remaining: i32,
}
Board_Frame :: struct {
	dragons: []Board_Dragon,
	pearls:  []i32,
	deaths:  []Board_Death,
	timers:  []Pearl_Timer,
}
Memory_Edge :: struct {
	kind,
	confidence,
	destination,
	portal,
	source,
	record_round,
	destination_source,
	destination_round: i32,
}
Memory_Cell :: struct {
	cell:                                                                                      i32,
	observed:                                                                                  bool,
	observed_round:                                                                            i32,
	edges:                                                                                     []Memory_Edge,
	pearl:                                                                                     bool,
	pearl_round, pearl_source, spawn_round, spawn_period, spawn_samples, source, record_round: i32,
	topology_only:                                                                             bool,
	occupant, occupant_team:                                                                   i32,
	occupant_head:                                                                             bool,
	accuracy:                                                                                  string,
}
Candidate :: struct {
	directions:                       []i32,
	score, risk:                      f32,
	survival_depth, survival_horizon: i32,
	reason:                           string,
}
Search_Cell :: struct {
	utility_evaluated: bool,
	cell, cost:        i32,
	utility:           f32,
}
Receiver_Effect :: struct {
	value, kind:                string,
	accepted:                   bool,
	effect:                     string,
	cell, source, record_round: i32,
}
Diagnostic :: struct {
	version, round, dragon:                         i32,
	role, regime, reason, target_reason, path_kind: string,
	owned_cells:                                    []i32,
	target:                                         i32,
	previous_role, previous_regime:                 string,
	moves:                                          []i32,
	child_length, link_partner:                     i32,
	selected_score:                                 f32,
	search_objective:                               string,
	farm:                                           struct {
		cycle:           []i32,
		estimated_yield: f32,
	},
	lobe:                                           struct {
		doors:           []i32,
		estimated_value: f32,
	},
	memory:                                         []Memory_Cell,
	candidates:                                     []Candidate,
	path:                                           []i32,
	search:                                         []Search_Cell,
	sonar_constraints:                              []struct {
		origin, direction, round:      i32,
		conditional_on_unseen_portals: bool,
	},
	coverage:                                       struct {
		target, owned_unknown: i32,
		complete:              bool,
	},
	rx:                                             []Receiver_Effect,
}
Dragon_Turn :: struct {
	dragon, team, round, head, length:                            i32,
	action, window:                                               string,
	board:                                                        Board_Frame,
	report_present, reliable, action_matches:                     bool,
	recovered_action, memory_source, known_mask:                  string,
	exact_cells, wrong_cells, partial_cells:                      i32,
	regime, role:                                                 string,
	target:                                                       i32,
	anchor, terminal:                                             bool,
	exits, space, reported_known_cells, reported_believed_pearls: i32,
	score:                                                        f32,
	memory:                                                       []Memory_Cell,
	diagnostic:                                                   Diagnostic,
}
Export_Build :: struct {
	bot:                      string,
	submission:               i32,
	commit, how, wasm_sha256: string,
	identified:               bool,
	mismatch_rate:            f32,
	notes:                    []string,
}
Export_Ping :: struct {
	id, round, received_round, sender, hit, hit_kind, origin, end: i32,
	direction, value, protocol, carries, decoded, acceptance:      string,
	reflected:                                                     bool,
}
Debug_View_Export :: struct {
	version:                      i32,
	recorded_traces:              bool,
	map_name:                     string,
	width, height:                i32,
	bot_a, bot_b, winner:         string,
	edges:                        []Board_Edge,
	frames:                       []Board_Frame,
	turns:                        []Dragon_Turn,
	team:                         string,
	selected_dragon, start_frame: i32,
	start_playing:                bool,
	start_frames_per_second:      f32,
	build:                        Export_Build,
	pings:                        []Export_Ping,
	annotation_path:              string,
}
Loaded_Game :: struct {
	arena:                  virtual.Arena,
	export:                 Debug_View_Export,
	source_path:            string,
	turn_indices_by_dragon: map[i32][dynamic]int,
	first_turn_of_round:    []int,
}
Overlay_Toggles :: struct {
	strategy_labels, target_lines, vision_windows, deaths, dragon_ids, grid, edges: bool,
	pings, timers, search, path, coverage:                                          bool,
}
Playback_State :: struct {
	frame_position:    f32,
	playing:           bool,
	frames_per_second: f32,
}
Highlight :: struct {
	kind: string,
	id:   i32,
}
Annotation :: struct {
	version, frame, dragon: i32,
	highlights:             []Highlight,
	text:                   string,
}
Viewer_State :: struct {
	inspector_area:                 rl.Rectangle,
	game:                           Loaded_Game,
	has_game:                       bool,
	playback:                       Playback_State,
	overlays:                       Overlay_Toggles,
	selected_dragon, selected_cell: i32,
	status:                         string,
	scale:                          f32,
	inspector_scroll:               f32,
	highlights:                     [dynamic]Highlight,
	comment:                        [4096]u8,
	comment_editing:                bool,
	annotations:                    [dynamic]Annotation,
	annotation_index:               int,
}
