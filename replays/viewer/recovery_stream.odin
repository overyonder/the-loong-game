package viewer

import "core:encoding/json"
import "core:fmt"
import os "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// The recovery process beside the viewer (replays/recovery/serve.nim,
// `loong-recover`), which reruns dragons' registered builds over their
// recorded observations and streams each turn's record as it is recovered.
// The viewer keeps every record in memory, so seeking needs no rerun; nothing
// is written to disk. Its protocol is in serve.nim's header.
Recovery_Process :: struct {
	// How to start it, from the command line; empty when the viewer has no
	// replay to recover from.
	command:       []string,
	process:       os.Process,
	input, output: ^os.File,
	running:       bool,
	// Bytes read that don't make a whole message yet.
	unread:        [dynamic]u8,
	// The dragons being recovered, several at once, and those waiting.
	rebuilding:    [dynamic]i32,
	waiting:       [dynamic]i32,
	// What prioritise_recovery last asked for: every dragon, and the focus and
	// round it last put first.
	asked_all:     bool,
	asked_dragon:  i32,
	asked_frame:   i32,
	// Whether it ended with dragons still to rebuild.
	stopped_early: bool,
}

// Start the recovery for the loaded game, focused on the selected dragon,
// ending any earlier one.
start_recovery :: proc(viewer: ^Viewer_State) {
	stop_recovery(viewer)
	recovery := &viewer.recovery
	clear(&recovery.rebuilding)
	clear(&recovery.waiting)
	recovery.asked_all, recovery.asked_dragon, recovery.asked_frame = false, -1, -1
	recovery.stopped_early = false
	clear(&recovery.unread)
	if len(recovery.command) == 0 || !viewer.has_game {return}
	child_input, input, input_error := os.pipe()
	if input_error != nil {return}
	output, child_output, output_error := os.pipe()
	if output_error != nil {os.close(child_input); os.close(input); return}
	command := make([dynamic]string, context.temp_allocator)
	// Rebuilding runs on the workstation, so it yields to everything else.
	append(&command, "nice", "-n", "10")
	append(&command, ..recovery.command)
	append(&command, "--game", viewer.game.source_path)
	if viewer.selected_dragon >= 0 {append(&command, "--focus", fmt.tprintf("%d", viewer.selected_dragon))}
	process, error := os.process_start({command = command[:], stdin = child_input, stdout = child_output, stderr = os.stderr})
	os.close(child_input)
	os.close(child_output)
	if error != nil {
		os.close(input)
		os.close(output)
		viewer.status = fmt.aprintf("Could not start the recovery: %v", error)
		return
	}
	recovery.process, recovery.input, recovery.output, recovery.running = process, input, output, true
	viewer.game.view.recovery_starting = true
	viewer.game.view.recoverable_dragons = 0
	viewer.game.view.recoverable_teams = {}
	viewer.game.view.failed_dragons = 0
}

// Closing its input ends the recovery and the judge servers it started.
stop_recovery :: proc(viewer: ^Viewer_State) {
	recovery := &viewer.recovery
	if !recovery.running {return}
	os.close(recovery.input)
	os.close(recovery.output)
	_, _ = os.process_wait(recovery.process)
	recovery.running = false
}

// Ask for these dragons, skipping any not waiting for recovery. One dragon,
// the newly focused one, goes to the front of the recovery's queue; several
// wait behind it.
request_recovery :: proc(viewer: ^Viewer_State, dragons: []i32) {
	if !viewer.recovery.running {return}
	line := strings.builder_make(context.temp_allocator)
	for dragon in dragons {
		if !viewer.game.view.pending_dragons[dragon] {continue}
		fmt.sbprintf(&line, " %d", dragon)
	}
	if strings.builder_len(line) == 0 {return}
	_, _ = os.write_string(viewer.recovery.input, fmt.tprintf("recover%s\n", strings.to_string(line)))
}

// The rebuild order: the focused dragon, then the other dragons on the board
// this round, then every other dragon in the match. Everything is queued once
// the recovery has listed the dragons. Whenever the focus or round changes,
// that dragon and the round's dragons move back to the front, except the
// round's while playing.
prioritise_recovery :: proc(viewer: ^Viewer_State) {
	recovery := &viewer.recovery
	if !recovery.running || viewer.game.view.recovery_starting {return}
	if !recovery.asked_all {
		everyone := make([dynamic]i32, context.temp_allocator)
		for dragon, pending in viewer.game.view.pending_dragons {if pending {append(&everyone, dragon)}}
		slice.sort(everyone[:])
		request_recovery(viewer, everyone[:])
		recovery.asked_all = true
	}
	frame := current_frame(viewer)
	if viewer.selected_dragon == recovery.asked_dragon && (frame == recovery.asked_frame || viewer.playback.playing) {return}
	// A single dragon asked for goes to the front, so the last asked leads.
	if frame != recovery.asked_frame && !viewer.playback.playing {
		dragons := board_at_selection(viewer, frame).dragons
		#reverse for dragon in dragons {if dragon.id != viewer.selected_dragon {request_recovery(viewer, {dragon.id})}}
		recovery.asked_frame = frame
	}
	if viewer.selected_dragon >= 0 {request_recovery(viewer, {viewer.selected_dragon})}
	recovery.asked_dragon = viewer.selected_dragon
}

// Take every message the recovery has written since the last frame; true
// when any changed what the viewer shows.
poll_recovery :: proc(viewer: ^Viewer_State) -> (changed: bool) {
	recovery := &viewer.recovery
	if !recovery.running {return false}
	buffer: [65536]u8
	ended := false
	for {
		ready, error := os.pipe_has_data(recovery.output)
		if error == .Broken_Pipe {ended = true; break}
		if !ready || error != nil {break}
		count, read_error := os.read(recovery.output, buffer[:])
		if count <= 0 || read_error != nil {break}
		changed = true
		append(&recovery.unread, ..buffer[:count])
	}
	consumed := 0
	for {
		rest := recovery.unread[consumed:]
		newline := -1
		for byte, index in rest {if byte == '\n' {newline = index; break}}
		if newline < 0 {break}
		header := string(rest[:newline])
		fields := strings.fields(header, context.temp_allocator)
		if len(fields) >= 3 && fields[0] == "turn" {
			size, _ := strconv.parse_int(fields[2])
			if len(rest) < newline + 1 + size {break}
			row, _ := strconv.parse_int(fields[1])
			receive_record(&viewer.game, row, string(rest[newline + 1:][:size]))
			consumed += newline + 1 + size
		} else {
			receive_message(viewer, header, fields)
			consumed += newline + 1
		}
		changed = true
	}
	remove_range(&recovery.unread, 0, consumed)
	if ended {
		// The recovery ended, as it does on a replay it can't read; nothing
		// more is coming.
		stop_recovery(viewer)
		viewer.game.view.recovery_starting = false
		for _, pending in viewer.game.view.pending_dragons {if pending {viewer.recovery.stopped_early = true}}
		clear(&viewer.game.view.pending_dragons)
		for dragon in viewer.game.turn_indices_by_dragon {forget_unrecorded_turns(&viewer.game, dragon)}
		changed = true
	}
	return changed
}

receive_record :: proc(game: ^Loaded_Game, row: int, record: string) {
	if row < 0 || row >= len(game.view.turn_dragon) {return}
	game.view.records[row] = strings.clone(record, game_allocator(game))
	team := int(game.view.turn_team[row]) & 1
	game.view.rebuilt_turns[team] += 1
	if strings.contains(record, `"gizmo_reliable":true`) {game.view.matching_turns[team] += 1}
	append(&game.issue_rows, row)
	forget_unrecorded_turns(game, i32(game.view.turn_dragon[row]))
}

receive_message :: proc(viewer: ^Viewer_State, header: string, fields: []string) {
	view := &viewer.game.view
	allocator := game_allocator(&viewer.game)
	if len(fields) == 0 {return}
	number := proc(text: string) -> i32 {value, _ := strconv.parse_int(text); return i32(value)}
	switch fields[0] {
	case "dragon":
		// dragon ID TEAM RECOVERABLE GUID VARIANT STATUS...
		if len(fields) < 7 {return}
		dragon := number(fields[1])
		status := header
		for _ in 0 ..< 6 {_, _, status = strings.partition(strings.trim_left_space(status), " ")}
		view.dragon_builds[dragon] = {
			guid    = fields[4] == "-" ? "" : strings.clone(fields[4], allocator),
			variant = fields[5] == "-" ? "" : strings.clone(fields[5], allocator),
			status  = strings.clone(status, allocator),
		}
		view.pending_dragons[dragon] = fields[3] == "1"
		if fields[3] == "1" {
			view.recoverable_dragons += 1
			view.recoverable_teams[number(fields[2]) & 1] = true
		}
	case "breakdown":
		// breakdown ROW JSON
		if len(fields) < 3 {return}
		row := int(number(fields[1]))
		_, _, text := strings.partition(header, fields[1])
		entries: []struct {
			level, value: string,
		}
		if json.unmarshal_string(strings.trim_space(text), &entries, allocator = context.temp_allocator) != nil {return}
		if len(entries) == 0 {return}
		add_breakdown(&viewer.game, row, entries[0].level, entries[0].value, len(entries) > 1 ? entries[1].level : "", len(entries) > 1 ? entries[1].value : "")
	case "queue":
		// The first queue follows every dragon's announcement.
		if view.recovery_starting {
			view.recovery_starting = false
			for dragon in viewer.game.turn_indices_by_dragon {forget_unrecorded_turns(&viewer.game, dragon)}
		}
		recovery := &viewer.recovery
		clear(&recovery.rebuilding)
		if len(fields) > 1 && fields[1] != "-" {
			for field in strings.split(fields[1], ",", context.temp_allocator) {append(&recovery.rebuilding, number(field))}
		}
		clear(&recovery.waiting)
		for field in fields[min(2, len(fields)):] {append(&recovery.waiting, number(field))}
	case "done", "failed":
		if len(fields) < 2 {return}
		dragon := number(fields[1])
		view.pending_dragons[dragon] = false
		if fields[0] == "failed" {
			view.failed_dragons += 1
			_, _, reason := strings.partition(header, fields[1])
			build := view.dragon_builds[dragon]
			build.status = fmt.aprintf("Recovery failed: %s", strings.trim_space(reason), allocator = allocator)
			view.dragon_builds[dragon] = build
		}
		forget_unrecorded_turns(&viewer.game, dragon)
	}
}

// Drop a dragon's turns opened before their record arrived, so they are
// rebuilt when next opened. Records arrive in the dragon's order, so a turn
// that had its record already, and its retained expansion, stays valid.
forget_unrecorded_turns :: proc(game: ^Loaded_Game, dragon: i32) {
	indices, found := game.turn_indices_by_dragon[dragon]
	if !found {return}
	for index in indices {
		if turn, cached := game.turn_cache[index]; cached && !turn.has_record {delete_key(&game.turn_cache, index)}
	}
}

Recovery_State :: enum {
	Recovered, // it has diagnostics, or never will: nothing is pending
	Recovering,
	Waiting,
	Not_Requested,
}

recovery_state :: proc(viewer: ^Viewer_State, dragon: i32) -> Recovery_State {
	if viewer.game.view.recovery_starting {return .Waiting}
	if !viewer.game.view.pending_dragons[dragon] {return .Recovered}
	for rebuilding in viewer.recovery.rebuilding {if rebuilding == dragon {return .Recovering}}
	for waiting in viewer.recovery.waiting {if waiting == dragon {return .Waiting}}
	return .Not_Requested
}

// What the inspector says in place of a dragon's decisions until they arrive.
recovery_notice :: proc(viewer: ^Viewer_State, dragon: i32) -> string {
	if viewer.game.view.recovery_starting {return "Starting the recovery: reading the replay..."}
	switch recovery_state(viewer, dragon) {
	case .Recovering:
		return "Rebuilding this dragon's decisions..."
	case .Waiting:
		ahead := 1
		for waiting in viewer.recovery.waiting {
			if waiting == dragon {break}
			ahead += 1
		}
		return fmt.tprintf("Waiting to rebuild this dragon's decisions, %d ahead...", ahead)
	case .Not_Requested:
		if viewer.recovery.running {return "Asking for this dragon's decisions to be rebuilt..."}
	case .Recovered:
	}
	if len(viewer.recovery.command) > 0 {return "Not rebuilt: recovery ended"}
	return "Not rebuilt"
}
