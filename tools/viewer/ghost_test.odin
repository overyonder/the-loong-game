package viewer

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

// Independent examples from the movement/death rules, composed across turns.
@(test)
ghost_split_ram_sprint_and_export :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	view := Game_View{width = 20, height = 10}
	parent := [?]i32{21, 22, 23, 24, 25, 26, 27, 28}
	enemy := [?]i32{29, 49, 69, 89, 109}
	dragons := [?]Board_Dragon{{id = 7, team = 0, body = parent[:]}, {id = 8, team = 1, body = enemy[:]}}
	board := Board_Frame{dragons = dragons[:]}
	viewer: Viewer_State
	ghost := &viewer.ghost
	start_ghost(ghost, &board, 7)
	split_ghost(ghost, 2)
	testing.expect_value(t, ghost.current, 1)
	move_ghost(ghost, &view, 1)
	testing.expect_value(t, len(ghost.bodies[1]), 0)
	testing.expect_value(t, len(ghost.bodies[2]), 0)
	for cell in ([?]i32{28, 29, 69, 109}) {testing.expect(t, slice.contains(ghost.pearls[:], cell))}
	testing.expect_value(t, len(ghost.pearls), 4)
	end_ghost_turn(ghost)
	testing.expect_value(t, ghost.current, 0)
	// Parent goes north then east through the freed enemy column. Its two
	// free steps stay fixed at turn start; pearls pay later movement.
	move_ghost(ghost, &view, 0)
	move_ghost(ghost, &view, 1)
	testing.expect_value(t, len(ghost.bodies[0]), 6)
	for _ in 0 ..< 4 {move_ghost(ghost, &view, 1)}
	testing.expect_value(t, len(ghost.bodies[0]), 2)
	move_ghost(ghost, &view, 1)
	testing.expect_value(t, ghost.refusal, "paid step needs length 3")
	testing.expect_value(t, ghost.steps, 6)
	end_ghost_turn(ghost)
	move_ghost(ghost, &view, 1)
	testing.expect_value(t, len(ghost.bodies[0]), 2)
	// A pearl on the next turn grows length 2 enough to pay another step.
	end_ghost_turn(ghost)
	move_ghost(ghost, &view, 1)
	end_ghost_turn(ghost)
	move_ghost(ghost, &view, 2)
	testing.expect_value(t, len(ghost.bodies[0]), 3)
	move_ghost(ghost, &view, 1)
	testing.expect_value(t, len(ghost.bodies[0]), 3)
	testing.expect_value(t, ghost.bodies[0][0], 29)
	testing.expect_value(t, len(ghost_board(ghost).dragons), 0)

	path := "/tmp/loong-ghost-export-test.md"
	defer os.remove(path)
	_ = os.write_entire_file(path, transmute([]u8)string("Existing inbox item"))
	viewer.comment_context = {inbox_path = path, replay = "game107.replay"}
	ghost.start_round = 51
	copy(viewer.comment[:], "Unsent comment")
	export_ghost(&viewer)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), "Existing inbox item\n- Viewer comment"))
	testing.expect(t, strings.contains(string(data), "round 51, dragon 7: SPLIT 2 / child E / parent NEEEEE / parent E / parent E / parent SE"))
	testing.expect(t, strings.has_prefix(string(viewer.comment[:]), "Unsent comment"))
}

// Optional local replay check: the independently recorded review position is
// game 107, R51, turn index 3102, D71, child head (4,6).
@(test)
ghost_reviewed_game107_kelp :: proc(t: ^testing.T) {
	path, present := os.lookup_env("LOONG_GHOST_REVIEW_GAME", context.temp_allocator)
	if !present {return}
	context.allocator = context.temp_allocator
	viewer: Viewer_State
	status := load_game_into_viewer(&viewer, path)
	testing.expect(t, viewer.has_game, status)
	if !viewer.has_game {return}
	board := turn_board(&viewer.game, 3102)
	start_ghost(&viewer.ghost, board, 71)
	testing.expect(t, viewer.ghost.active)
	if !viewer.ghost.active {return}
	split_ghost(&viewer.ghost, 6)
	ghost := &viewer.ghost
	testing.expect_value(t, ghost.current, 1)
	if ghost.current != 1 {return}
	body := ghost.bodies[ghost.controlled[1]][:]
	testing.expect_value(t, body[0] % viewer.game.view.width, i32(4))
	testing.expect_value(t, body[0] / viewer.game.view.width, i32(6))
	move_ghost(ghost, &viewer.game.view, 0)
	testing.expect_value(t, ghost.refusal, "kelp")
	testing.expect_value(t, ghost.steps, 0)
	testing.expect_value(t, len(ghost.bodies[ghost.controlled[1]]), 6)
	end_ghost_turn(ghost)
	testing.expect_value(t, ghost.current, 0)
}

// These outcomes were independently checked on game 107's R51 replay board.
@(test)
ghost_reviewed_game107_paid_sprints :: proc(t: ^testing.T) {
	path, present := os.lookup_env("LOONG_GHOST_REVIEW_GAME", context.temp_allocator)
	if !present {return}
	context.allocator = context.temp_allocator
	viewer: Viewer_State
	status := load_game_into_viewer(&viewer, path)
	testing.expect(t, viewer.has_game, status)
	if !viewer.has_game {return}
	board := turn_board(&viewer.game, 3102)
	for line, line_index in ([2]string{"ESSENNNEEEENNWSWWWNE", "NNNNNEEEESSWSSWSWWN"}) {
		ghost: Ghost
		start_ghost(&ghost, board, 71)
		defer clear_ghost(&ghost)
		testing.expect(t, ghost.active)
		if !ghost.active {return}
		index := ghost.controlled[0]
		testing.expect_value(t, len(ghost.bodies[index]), 11)
		testing.expect_value(t, ghost.free_steps, 3)
		pearls_before := len(ghost.pearls)
		for direction, step in line {
			move_ghost(&ghost, &viewer.game.view, i32(strings.index_rune("NESW", direction)))
			if line_index == 1 && step == 16 {
				testing.expect_value(t, ghost.refusal, "paid step needs length 3")
				break
			}
			testing.expect_value(t, ghost.refusal, "")
			testing.expect_value(t, ghost.steps, step + 1)
		}
		body := ghost.bodies[index][:]
		testing.expect_value(t, ghost.steps, line_index == 0 ? 20 : 16)
		testing.expect_value(t, len(body), line_index == 0 ? 6 : 2)
		testing.expect_value(t, body[0] % viewer.game.view.width, i32(line_index == 0 ? 3 : 2))
		testing.expect_value(t, body[0] / viewer.game.view.width, i32(line_index == 0 ? 1 : 4))
		if line_index == 0 {testing.expect_value(t, pearls_before - len(ghost.pearls), 12)}
		fmt.printf("game 107 R51 D71 %s: %d steps, length %d at (%d,%d), %d pearls eaten; %s\n",
			line, ghost.steps, len(body), body[0] % viewer.game.view.width,
			body[0] / viewer.game.view.width, pearls_before - len(ghost.pearls), ghost.refusal)
	}
}

// queen_cases.zig: length-2-paid-before-pearl and pearl-on-paid-step.
// The viewer refuses the fatal action so the user can try another line.
@(test)
ghost_paid_step_pearl_cases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	view := Game_View{width = 64, height = 64}
	for length in ([2]int{2, 4}) {
		body := [?]i32{352, 351, 350, 349}
		dragons := [?]Board_Dragon{{id = 0, body = body[:length]}}
		pearls := [?]i32{354}
		board := Board_Frame{dragons = dragons[:], pearls = pearls[:]}
		ghost: Ghost
		start_ghost(&ghost, &board, 0)
		defer clear_ghost(&ghost)
		move_ghost(&ghost, &view, 1)
		move_ghost(&ghost, &view, 1)
		testing.expect_value(t, len(ghost.bodies[0]), length)
		testing.expect_value(t, ghost.free_steps, 1)
		testing.expect_value(t, ghost.steps, length == 2 ? 1 : 2)
		testing.expect_value(t, ghost.bodies[0][0], i32(length == 2 ? 353 : 354))
		testing.expect_value(t, len(ghost.pearls), length == 2 ? 1 : 0)
		testing.expect_value(t, ghost.refusal, length == 2 ? "paid step needs length 3" : "")
	}
}
