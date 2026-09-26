package viewer

import "core:encoding/json"
import "core:fmt"
import virtual "core:mem/virtual"
import os "core:os"
import "core:strings"

// Replace the viewer's game with the export at path. Keeps the old game on failure.
load_debug_view_export_into_viewer :: proc(
	viewer: ^Viewer_State,
	path: string,
) -> (
	status: string,
) {
	game: Loaded_Game
	if virtual.arena_init_growing(&game.arena) != nil {
		return "Could not reserve memory for the export"
	}
	allocator := virtual.arena_allocator(&game.arena)
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		virtual.arena_destroy(&game.arena)
		return fmt.aprintf("Could not read %s: %v", path, read_error)
	}
	if unmarshal_error := json.unmarshal(data, &game.export, allocator = allocator);
	   unmarshal_error != nil {
		virtual.arena_destroy(&game.arena)
		return fmt.aprintf("Could not parse %s: %v", path, unmarshal_error)
	}
	export := &game.export
	if export.version != 4 || len(export.frames) == 0 || export.width <= 0 || export.height <= 0 {
		virtual.arena_destroy(&game.arena)
		return fmt.aprintf("%s is not a version 4 viewer export", path)
	}

	game.source_path = strings.clone(path, allocator)
	game.turn_indices_by_dragon = make(map[i32][dynamic]int, allocator)
	game.first_turn_of_round = make([]int, len(export.frames) + 1, allocator)
	next_round := 0
	for turn, turn_index in export.turns {
		for next_round <= int(turn.round) {
			game.first_turn_of_round[next_round] = turn_index
			next_round += 1
		}
		if turn.dragon not_in game.turn_indices_by_dragon {
			game.turn_indices_by_dragon[turn.dragon] = make([dynamic]int, allocator)
		}
		append(&game.turn_indices_by_dragon[turn.dragon], turn_index)
	}
	for ; next_round < len(game.first_turn_of_round); next_round += 1 {
		game.first_turn_of_round[next_round] = len(export.turns)
	}

	if viewer.has_game {
		virtual.arena_destroy(&viewer.game.arena)
	}
	viewer.game = game
	viewer.has_game = true
	viewer.playback = {
		frame_position    = 0,
		playing           = false,
		frames_per_second = viewer.playback.frames_per_second,
	}
	viewer.selected_dragon = -1
	return fmt.aprintf(
		"Loaded %s: %s vs %s on %s, %d rounds, winner %s",
		path,
		export.bot_a,
		export.bot_b,
		export.map_name,
		len(export.frames) - 1,
		export.winner,
	)
}

// Number of turns before the given frame: turns in rounds < frame.
turn_count_before_frame :: proc(game: ^Loaded_Game, frame: i32) -> int {
	return game.first_turn_of_round[clamp(int(frame), 0, len(game.first_turn_of_round) - 1)]
}

// The selected dragon's pre-action turn IN this round. No stale fallback.
selected_dragon_turn :: proc(game: ^Loaded_Game, dragon: i32, frame: i32) -> (^Dragon_Turn, bool) {
	indices, found := game.turn_indices_by_dragon[dragon]
	if !found {
		return nil, false
	}
	limit := turn_count_before_frame(game, frame + 1)
	for position := len(indices) - 1; position >= 0; position -= 1 {
		if indices[position] < limit && game.export.turns[indices[position]].round == frame {
			return &game.export.turns[indices[position]], true
		}
	}
	return nil, false
}
