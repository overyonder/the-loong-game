package viewer

import "core:encoding/json"
import virtual "core:mem/virtual"
import os "core:os"

// Read an export into a fresh arena. Every allocation below goes through the
// context allocator, so the JSON strings and slices all land in the arena.
load_game :: proc(path: string) -> (game: Game, ok: bool) {
	if virtual.arena_init_growing(&game.arena) != nil {
		return
	}
	context.allocator = virtual.arena_allocator(&game.arena)

	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil || json.unmarshal(data, &game.export) != nil || game.version != 1 || len(game.frames) == 0 {
		virtual.arena_destroy(&game.arena)
		return
	}
	game.turns_by_dragon = make(map[i32][dynamic]int)
	for turn, index in game.turns {
		if turn.dragon not_in game.turns_by_dragon {
			game.turns_by_dragon[turn.dragon] = make([dynamic]int)
		}
		append(&game.turns_by_dragon[turn.dragon], index)
	}
	return game, true
}

unload_game :: proc(game: ^Game) {
	virtual.arena_destroy(&game.arena)
}
