package viewer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// One decision of a teacher review (the teacher review): the recorded,
// the network's and the teacher's candidates, each one's option code
// (candidates/0001.h's CandidateOption) and the teacher's completed Q, and the
// value lost, the teacher's Q of its choice less that of the network's.
Review_Row :: struct {
	recorded, network, teacher:                      i32,
	recorded_option, network_option, teacher_option: i32,
	recorded_q, network_q, teacher_q, value_lost:    f64,
}

// The review beside the game's columns, as GAME.review.tsv, keyed by round and
// dragon; none when the file isn't there.
load_teacher_review :: proc(game: ^Loaded_Game, allocator := context.allocator) {
	stem := strings.trim_suffix(game.source_path, filepath.ext(game.source_path))
	path := strings.concatenate({stem, ".review.tsv"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	game.review = make(map[[2]i32]Review_Row, allocator)
	whole :: proc(s: string) -> i32 {v, _ := strconv.parse_int(s); return i32(v)}
	real :: proc(s: string) -> f64 {v, _ := strconv.parse_f64(s); return v}
	for line, k in strings.split(string(data), "\n", context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if k == 0 || len(f) < 12 {continue}
		game.review[{whole(f[0]), whole(f[1])}] = Review_Row {
			whole(f[2]), whole(f[3]), whole(f[4]),
			whole(f[5]), whole(f[6]), whole(f[7]),
			real(f[8]), real(f[9]), real(f[10]), real(f[11]),
		}
	}
}

option_name :: proc(code: i32) -> string {
	switch code {
	case 0: return "primitive"
	case 1: return "harvest"
	case 2: return "escape"
	case 3: return "queen strike"
	case 4: return "feed"
	case 5: return "rearguard"
	case 6: return "accepted play"
	}
	return fmt.tprintf("option %d", code)
}

// The focused dragon's decision this round as the teacher reviewed it: which
// candidate the dragon played, the network's choice and the teacher's, by
// their indices in the decision table's rows, and the value lost.
draw_teacher_review :: proc(viewer: ^Viewer_State, cursor: ^rl.Vector2, width: f32, frame: i32) {
	game := &viewer.game
	if game.review == nil {return}
	turn, found := focused_dragon_turn(viewer, frame)
	if !found {return}
	row, reviewed := game.review[{frame, turn.dragon}]
	if !reviewed {
		inspector_paragraph(viewer, cursor, width, "Teacher review: not reviewed this turn", MUTED_TEXT_COLOR)
		return
	}
	inspector_paragraph(
		viewer,
		cursor,
		width,
		fmt.tprintf(
			"Teacher review: played row %d (%s, Q %.3f); network row %d (%s, Q %.3f); teacher row %d (%s, Q %.3f); value lost %.3f",
			row.recorded,
			option_name(row.recorded_option),
			row.recorded_q,
			row.network,
			option_name(row.network_option),
			row.network_q,
			row.teacher,
			option_name(row.teacher_option),
			row.teacher_q,
			row.value_lost,
		),
		row.value_lost > 0.05 ? WARNING_COLOR : TEXT_COLOR,
	)
}
