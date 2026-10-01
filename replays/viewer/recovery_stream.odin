package viewer

import "core:encoding/json"
import "core:fmt"
import os "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The recovery process beside the viewer (replays/viewer/recovery/serve.nim,
// `loong-recover`), which reruns dragons' registered builds over their
// recorded observations and streams each turn's record as it is recovered.
// Only the turns in a window of rounds around the current one come with their
// diagnostics, and every other turn brings only its breakdown, so memory holds
// one window's records. Moving out of the window moves it, and the dragons in
// the new one are rebuilt for it. Nothing is written to disk. Its protocol is
// in serve.nim's header.


// How long a frame keeps reading while the recovery keeps writing.
READ_BUDGET :: 8 * time.Millisecond
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
	// Dragons asked to be rebuilt again showing their state.
	stated:        map[i32]bool,
	// Whether the recovery has said it took the last window asked for.
	window_acknowledged: bool,
	// The rounds kept either side of the current one, so stepping a few
	// rounds needs no rebuild (`--buffer`).
	buffer:        i32,
}

// Start the recovery for the loaded game, focused on the selected dragon,
// ending any earlier one: its window around the current round, or every round
// when `whole`.
start_recovery :: proc(viewer: ^Viewer_State, whole := false) {
	stop_recovery(viewer)
	recovery := &viewer.recovery
	clear(&recovery.rebuilding)
	clear(&recovery.waiting)
	recovery.asked_all, recovery.asked_dragon, recovery.asked_frame = false, -1, -1
	clear(&recovery.stated)
	recovery.stopped_early = false
	clear(&recovery.unread)
	if len(recovery.command) == 0 || !viewer.has_game {return}
	child_input, input, input_error := os.pipe()
	if input_error != nil {return}
	output, child_output, output_error := os.pipe()
	if output_error != nil {os.close(child_input); os.close(input); return}
	// The recovery waits whenever this pipe is full, so it gets the most room
	// the system allows.
	_, _ = linux.fcntl(linux.Fd(os.fd(output)), linux.F_SETPIPE_SZ, i32(1 << 20))
	command := make([dynamic]string, context.temp_allocator)
	// Rebuilding runs on the workstation, so it yields to everything else.
	append(&command, "nice", "-n", "10")
	append(&command, ..recovery.command)
	append(&command, "--game", viewer.game.source_path)
	view := &viewer.game.view
	frame := current_frame(viewer)
	view.window_first, view.window_last = max(frame - recovery.buffer, 0), frame + recovery.buffer
	if whole {view.window_first, view.window_last = 0, max(i32)
	} else {append(&command, "--rounds", fmt.tprintf("%d-%d", view.window_first, view.window_last))}
	recovery.window_acknowledged = true
	clear(&view.recoverable)
	clear(&view.kept)
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

// Whether a turn of a dragon the recovery can rebuild lies outside the
// window, so it has only its breakdown until the window comes to it. A kept
// dragon's turns all come whole.
outside_window :: proc(view: ^Game_View, dragon, round: i32) -> bool {
	return view.recoverable[dragon] && !view.kept[dragon] && (round < view.window_first || round > view.window_last)
}

// Whether the dragon has a turn in the window.
has_turn_in_window :: proc(game: ^Loaded_Game, dragon: i32) -> bool {
	for index in game.turn_indices_by_dragon[dragon] {
		round := i32(game.view.turn_round[index])
		if round >= game.view.window_first && round <= game.view.window_last {return true}
	}
	return false
}

// Centre the window on `frame`. The last window's rebuilt records and every
// turn opened from them are freed; a dragon's own recorded ones stay. Each
// dragon with a turn in the new window waits to be rebuilt for it, apart from
// those whose recovery failed.
move_window :: proc(viewer: ^Viewer_State, frame: i32) {
	game := &viewer.game
	view := &game.view
	view.window_first, view.window_last = max(frame - viewer.recovery.buffer, 0), frame + viewer.recovery.buffer
	_, _ = os.write_string(viewer.recovery.input, fmt.tprintf("window %d %d\n", view.window_first, view.window_last))
	viewer.recovery.window_acknowledged = false
	rebuilt := make([dynamic]int, context.temp_allocator)
	for row in view.records {if .Lasting not_in view.turn_evidence[row] {append(&rebuilt, row)}}
	for row in rebuilt {delete_key(&view.records, row)}
	clear(&game.turn_cache)
	free_all(turn_allocator(game))
	for dragon in game.turn_indices_by_dragon {
		if !view.recoverable[dragon] || view.kept[dragon] || strings.has_prefix(view.dragon_builds[dragon].status, "Recovery failed") {continue}
		if has_turn_in_window(game, dragon) {view.pending_dragons[dragon] = true}
	}
	// Everything is asked for again, the focused dragon first even while playing.
	viewer.recovery.asked_all, viewer.recovery.asked_frame, viewer.recovery.asked_dragon = false, -1, -1
}

// The rebuild order: the focused dragon, then the other dragons on the board
// this round, then every other dragon in the match. Everything is queued once
// the recovery has listed the dragons, and again whenever the window moves.
// Whenever the focus or round changes, that dragon and the round's dragons
// move back to the front, except the round's while playing.
prioritise_recovery :: proc(viewer: ^Viewer_State) {
	recovery := &viewer.recovery
	if !recovery.running || viewer.game.view.recovery_starting {return}
	if frame := current_frame(viewer); frame < viewer.game.view.window_first || frame > viewer.game.view.window_last {
		move_window(viewer, frame)
	}
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
	// A focused dragon rebuilt without its state is rebuilt again with it. The
	// recovery ignores one whose bot shows none, or that already shows it.
	dragon := viewer.selected_dragon
	if dragon >= 0 && !viewer.game.view.pending_dragons[dragon] && !recovery.stated[dragon] {
		recovery.stated[dragon] = true
		_, _ = os.write_string(recovery.input, fmt.tprintf("state %d\n", dragon))
	}
}

// Take every message the recovery has written since the last frame; true
// when any changed what the viewer shows.
poll_recovery :: proc(viewer: ^Viewer_State) -> (changed: bool) {
	recovery := &viewer.recovery
	if !recovery.running {return false}
	buffer: [65536]u8 = ---
	ended := false
	// While the recovery is writing, more follows at once, so a frame that
	// reads anything keeps reading for up to READ_BUDGET.
	started := time.tick_now()
	for {
		ready, error := os.pipe_has_data(recovery.output)
		if error == .Broken_Pipe {ended = true; break}
		if error != nil {break}
		if !ready {
			if !changed || time.tick_since(started) > READ_BUDGET {break}
			time.sleep(200 * time.Microsecond)
			continue
		}
		count, read_error := os.read(recovery.output, buffer[:])
		if count <= 0 || read_error != nil {break}
		changed = true
		append(&recovery.unread, ..buffer[:count])
		if time.tick_since(started) > READ_BUDGET {break}
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

// Count a rebuilt turn once, however often it arrives.
count_rebuilt :: proc(view: ^Game_View, row: int, reliable: bool) {
	team := int(view.turn_team[row]) & 1
	evidence := &view.turn_evidence[row]
	if .Rebuilt not_in evidence^ {view.rebuilt_turns[team] += 1}
	if .Matched in evidence^ {view.matching_turns[team] -= 1}
	evidence^ += {.Rebuilt}
	evidence^ -= {.Matched}
	if reliable {
		view.matching_turns[team] += 1
		evidence^ += {.Matched}
	}
}

// Keep a turn's record: one from the dragon's own log or a kept dragon for
// good, any other while its round is in the window.
receive_record :: proc(game: ^Loaded_Game, row: int, record: string) {
	view := &game.view
	if row < 0 || row >= len(view.turn_dragon) {return}
	dragon := i32(view.turn_dragon[row])
	count_rebuilt(view, row, strings.contains(record, `"gizmo_reliable":true`))
	lasting := view.kept[dragon] || strings.contains(record, `"gizmo_source":"recorded"`)
	if !lasting && outside_window(view, dragon, i32(view.turn_round[row])) {return}
	_, again := view.records[row]
	if lasting {view.turn_evidence[row] += {.Lasting}}
	view.records[row] = strings.clone(record, lasting ? game_allocator(game) : turn_allocator(game))
	if again {
		// A dragon rebuilt again, showing its state: its turns come again from
		// its first, so every turn opened is rebuilt from the new records.
		if indices, known := game.turn_indices_by_dragon[dragon]; known {
			for index in indices {delete_key(&game.turn_cache, index)}
		}
		return
	}
	if .Tallied not_in view.turn_evidence[row] {
		view.turn_evidence[row] += {.Tallied}
		append(&game.issue_rows, row)
	}
	forget_unrecorded_turns(game, dragon)
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
		view.recoverable[dragon] = fields[3] == "1"
		if fields[3] == "1" {
			view.recoverable_dragons += 1
			view.recoverable_teams[number(fields[2]) & 1] = true
		}
	case "breakdown":
		// breakdown ROW RELIABLE JSON
		if len(fields) < 4 {return}
		row := int(number(fields[1]))
		if row < 0 || row >= len(view.turn_team) {return}
		start := strings.index_byte(header, '[')
		if start < 0 {return}
		entries: []Breakdown_Entry
		if json.unmarshal_string(header[start:], &entries, allocator = context.temp_allocator) != nil {return}
		if len(entries) == 0 {return}
		reliable := fields[2] == "1"
		count_rebuilt(view, row, reliable)
		add_breakdown(&viewer.game, row, reliable, entries[:min(len(entries), 2)])
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
	case "kept":
		// Every turn of this dragon comes whole: its records stay for the game.
		if len(fields) < 2 {return}
		dragon := number(fields[1])
		view.kept[dragon] = true
		for index in viewer.game.turn_indices_by_dragon[dragon] {
			record, found := view.records[index]
			if !found || .Lasting in view.turn_evidence[index] {continue}
			view.records[index] = strings.clone(record, allocator)
			view.turn_evidence[index] += {.Lasting}
		}
	case "window":
		if len(fields) == 3 && number(fields[1]) == view.window_first && number(fields[2]) == view.window_last {
			viewer.recovery.window_acknowledged = true
		}
	case "done", "failed":
		if len(fields) < 2 {return}
		dragon := number(fields[1])
		// Said of the last window, about a dragon the recovery rebuilds again
		// for this one.
		if !viewer.recovery.window_acknowledged && has_turn_in_window(&viewer.game, dragon) {return}
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

// What the inspector says in place of a turn's decisions until they arrive.
recovery_notice :: proc(viewer: ^Viewer_State, turn: ^Dragon_Turn) -> string {
	dragon := turn.dragon
	if viewer.game.view.recovery_starting {return "Starting the recovery: reading the replay..."}
	if outside_window(&viewer.game.view, dragon, turn.round) {return "Rebuilt once the view comes to this round..."}
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
