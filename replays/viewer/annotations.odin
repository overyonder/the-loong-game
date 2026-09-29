package viewer

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

highlighted :: proc(viewer: ^Viewer_State, kind: string, id: i32) -> bool {
	for item in viewer.highlights {if item.kind == kind && item.id == id {return true}}
	return false
}
toggle_highlight :: proc(viewer: ^Viewer_State, kind: string, id: i32) {
	for item, index in viewer.highlights {
		if item.kind == kind && item.id == id {ordered_remove(&viewer.highlights, index); return}
	}
	append(&viewer.highlights, Highlight{kind, id})
}
// One highlight in words, for the inbox line.
describe_highlight :: proc(viewer: ^Viewer_State, item: Highlight) -> string {
	view := &viewer.game.view
	switch item.kind {
	case "cell":
		return fmt.tprintf("cell (%d,%d)", item.id % view.width, item.id / view.width)
	case "edge":
		if item.id >= 0 && int(item.id) < len(view.edges) {
			edge := view.edges[item.id]
			return fmt.tprintf("%s edge of (%d,%d)", edge.side == 0 ? "top" : "left", edge.x, edge.y)
		}
	case "dragon":
		return fmt.tprintf("dragon %d", item.id)
	}
	return fmt.tprintf("%s %d", item.kind, item.id)
}

// A comment appends one line to the inbox, a Markdown file (--inbox):
// the replay, round, turn, dragon and highlights in words, the text, and the
// same context as JSON in an HTML comment, which Previous/Next saved restores.
INBOX_MARKER :: " <!-- viewer "
save_annotation :: proc(viewer: ^Viewer_State) {
	text := strings.trim_space(string(cstring(raw_data(viewer.comment[:]))))
	if len(text) == 0 {viewer.status = "Enter a comment before saving"; return}
	path := viewer.comment_context.inbox_path
	if len(path) == 0 {viewer.status = "Inbox path unavailable"; return}
	record := Annotation {
		replay     = viewer.comment_context.replay,
		version    = 3,
		frame      = current_frame(viewer),
		dragon     = viewer.selected_dragon,
		highlights = viewer.highlights[:],
		turn_index = i32(active_turn_index(viewer)),
		substeps   = viewer.playback.substeps,
	}
	data, encode_error := json.marshal(record, allocator = context.temp_allocator)
	if encode_error != nil {viewer.status = "Could not encode comment"; return}
	details := make([dynamic]string, context.temp_allocator)
	append(&details, fmt.tprintf("round %d", record.frame))
	if record.substeps {append(&details, fmt.tprintf("turn %d", record.turn_index + 1))}
	if record.dragon >= 0 {append(&details, fmt.tprintf("dragon %d", record.dragon))}
	for item in record.highlights {append(&details, describe_highlight(viewer, item))}
	existing, _ := os.read_entire_file(path, context.temp_allocator)
	separator := len(existing) > 0 && existing[len(existing) - 1] != '\n' ? "\n" : ""
	line := fmt.tprintf(
		"%s- Viewer comment on `%s`, %s: %s%s%s -->\n",
		separator,
		record.replay,
		strings.join(details[:], ", ", context.temp_allocator),
		text,
		INBOX_MARKER,
		string(data),
	)
	file, open_error := os.open(path, {.Write, .Create, .Append})
	if open_error != nil {viewer.status = fmt.aprintf("Cannot save: %v", open_error); return}
	defer os.close(file)
	count, write_error := os.write_string(file, line)
	if write_error != nil ||
	   count != len(line) {viewer.status = "Comment write failed; text retained"; return}
	load_annotations(viewer)
	viewer.comment = {}
	viewer.status = "Comment saved to the inbox"
}
draw_annotation_editor :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	h := f32(CONTROL_HEIGHT)
	label := fmt.ctprintf("Comment (%d highlights)", len(viewer.highlights))
	label_width := f32(measure_text("Comment (00 highlights)", UI_TEXT)) + 12
	draw_text(label, i32(area.x), i32(area.y + (h - UI_TEXT) / 2), UI_TEXT, TEXT_COLOR)
	right := area.x + area.width
	for action in ([?]struct {
			label: cstring,
			step:  int,
		}{{"Next saved", 1}, {"Previous saved", -1}}) {
		width := f32(measure_text(action.label, UI_TEXT)) + BUTTON_PADDING
		right -= width
		if rl.GuiButton({right, area.y, width, h}, action.label) {
			restore_annotation(viewer, viewer.annotation_index + action.step)
		}
		right -= 4
	}
	save_width := f32(measure_text("Save comment", UI_TEXT)) + BUTTON_PADDING
	right -= save_width + 8
	save := rl.Rectangle{right, area.y, save_width, h}
	field := rl.Rectangle{area.x + label_width, area.y, right - area.x - label_width - 6, h}
	if rl.IsMouseButtonPressed(.LEFT) {
		// Saving keeps the field focused for the next comment.
		mouse := rl.GetMousePosition()
		viewer.comment_editing =
			rl.CheckCollisionPointRec(mouse, field) ||
			viewer.comment_editing && rl.CheckCollisionPointRec(mouse, save)
		if viewer.comment_editing {viewer.playback.playing = false}
	}
	if viewer.comment_editing {
		control := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if control && rl.IsKeyPressed(.A) {viewer.comment = {}}
		length := len(string(cstring(raw_data(viewer.comment[:]))))
		if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && length > 0 {
			_, count := utf8.decode_last_rune(viewer.comment[:length])
			length -= count
			viewer.comment[length] = 0
		}
		if control && rl.IsKeyPressed(.V) {
			pasted := string(rl.GetClipboardText())
			length += copy(viewer.comment[length:len(viewer.comment) - 1], pasted)
			viewer.comment[length] = 0
		}
		for character := rl.GetCharPressed(); character > 0; character = rl.GetCharPressed() {
			if character < 32 {continue}
			encoded, count := utf8.encode_rune(rune(character))
			if length + count <
			   len(
				   viewer.comment,
			   ) {copy(viewer.comment[length:length + count], encoded[:count]); length += count; viewer.comment[length] = 0}
		}
	}
	rl.GuiTextBox(field, cstring(raw_data(viewer.comment[:])), len(viewer.comment), false)
	if viewer.comment_editing {rl.DrawRectangleLinesEx(field, 2, COLOR_SELECTED)}
	if rl.GuiButton(save, "Save comment") ||
	   viewer.comment_editing && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
		save_annotation(viewer)
	}
	// The match, its info button, then the latest message.
	line_y := area.y + h + 2
	match := fmt.ctprintf("%s", match_line(viewer))
	x := area.x
	draw_text(match, i32(x), i32(line_y), UI_TEXT - 2, TEXT_COLOR)
	x += f32(measure_text(match, UI_TEXT - 2)) + 6
	info := rl.Rectangle{x, line_y, UI_TEXT - 1, UI_TEXT - 1}
	if rl.GuiButton(info, "i") {open_diagnostic_detail(viewer, "Match", match_details(viewer))}
	x += info.width + 8
	// The kinds of issue across every rebuilt dragon so far: amber with a
	// count, else muted. The dialog adds the focused decision's own.
	{
		current: []string
		if turn, found := focused_dragon_turn(viewer, current_frame(viewer)); found && turn.has_record {current = turn_issues(&viewer.game, turn)}
		kinds := len(viewer.game.issues)
		issues_label := kinds > 0 ? fmt.ctprintf("Issues %d", kinds) : "No issues"
		button := rl.Rectangle{x, line_y - 1, f32(measure_text(issues_label, UI_TEXT)) + 12, UI_TEXT + 1}
		if rl.GuiButton(button, issues_label) {open_diagnostic_detail(viewer, "Issues", issues_text(viewer, current))}
		if kinds > 0 {rl.DrawRectangleLinesEx(button, 1, WARNING_COLOR)}
		x += button.width + 12
	}
	if status := footer_status(viewer); status != "" {draw_text(fmt.ctprintf("%s", status), i32(x), i32(line_y), UI_TEXT - 2, MUTED_TEXT_COLOR)}
}
// Left-click toggles a cell; shift-click a body toggles that dragon. Edges
// have precedence within six screen pixels of their actual drawn line.
highlight_board_item :: proc(viewer: ^Viewer_State, g: Board_Geometry, frame: i32) {
	mouse := rl.GetMousePosition()
	cell := cell_at_point(g, mouse)
	if cell < 0 {return}
	viewer.selected_cell = cell
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
		for dragon in board_at_selection(viewer, frame).dragons {
			for part in dragon.body {
				if part == cell {toggle_highlight(viewer, "dragon", dragon.id); return}
			}
		}
	}
	for edge, index in viewer.game.view.edges {
		r := cell_rectangle(g, edge.y * g.width + edge.x)
		if edge.side == 0 &&
			   abs(mouse.y - r.y) < 6 &&
			   mouse.x >= r.x &&
			   mouse.x <= r.x + r.width ||
		   edge.side == 1 &&
			   abs(mouse.x - r.x) < 6 &&
			   mouse.y >= r.y &&
			   mouse.y <= r.y + r.height {
			toggle_highlight(viewer, "edge", i32(index)); return
		}
	}
	toggle_highlight(viewer, "cell", cell)
}

// This replay's comments still in the inbox; ones moved out have left it.
load_annotations :: proc(viewer: ^Viewer_State) {
	clear(&viewer.annotations)
	data, err := os.read_entire_file(viewer.comment_context.inbox_path, context.temp_allocator)
	if err != nil {return}
	for line in strings.split(string(data), "\n", context.temp_allocator) {
		marker := strings.last_index(line, INBOX_MARKER)
		start := strings.index(line, ": ")
		end := strings.last_index(line, " -->")
		if marker < 0 || start < 0 || start > marker || end < marker {continue}
		record: Annotation
		encoded := line[marker + len(INBOX_MARKER):end]
		if json.unmarshal_string(encoded, &record) != nil || record.version != 3 {
			viewer.status = "Skipped an unreadable viewer comment in the inbox"
			continue
		}
		if record.replay != viewer.comment_context.replay {continue}
		record.text = strings.clone(line[start + 2:marker])
		append(&viewer.annotations, record)
	}
}

restore_annotation :: proc(viewer: ^Viewer_State, index: int) {
	if len(viewer.annotations) == 0 {return}
	viewer.annotation_index = (index + len(viewer.annotations)) % len(viewer.annotations)
	record := viewer.annotations[viewer.annotation_index]
	step_to_frame(viewer, record.frame)
	select_dragon_turn(viewer, record.dragon)
	if record.substeps &&
	   record.turn_index >= 0 &&
	   int(record.turn_index) < turn_count(&viewer.game) {
		viewer.playback.substeps = true
		viewer.playback.turn_position = f32(record.turn_index)
		synchronize_active_turn(viewer)
	}
	clear(&viewer.highlights)
	append(&viewer.highlights, ..record.highlights)
	viewer.comment = {}
	copy(viewer.comment[:len(viewer.comment) - 1], record.text)
	viewer.comment_editing = false
	viewer.status = fmt.aprintf(
		"Showing saved comment %d/%d",
		viewer.annotation_index + 1,
		len(viewer.annotations),
	)
}

// The latest message under the comment field; the load message is left to
// the match line.
footer_status :: proc(viewer: ^Viewer_State) -> string {
	return strings.has_prefix(viewer.status, "Loaded ") ? "" : viewer.status
}

// The match under the comment field: its name, each side's bot as the replay
// records it with the build displayed and the evidence for it, the map,
// length and winner.
match_line :: proc(viewer: ^Viewer_State) -> string {
	view := &viewer.game.view
	name := viewer.comment_context.replay
	name = name[strings.last_index_byte(name, '/') + 1:]
	if dot := strings.index_byte(name, '.'); dot > 0 {name = name[:dot]}
	return fmt.tprintf("%s: A %s (%s) vs B %s (%s) on %s, %d rounds, winner %s", name, bot_name(view.bot_a), build_evidence(viewer, 0), bot_name(view.bot_b), build_evidence(viewer, 1), view.map_name, len(view.round_event), view.winner)
}

// A team's build and how far it is established: none, asserted by the caller
// (--seat or --build), and confirmed by
// rebuilt turns matching the replay.
build_evidence :: proc(viewer: ^Viewer_State, team: int) -> string {
	view := &viewer.game.view
	build: Dragon_Build
	for dragon, indices in viewer.game.turn_indices_by_dragon {
		if len(indices) > 0 && int(view.turn_team[indices[0]]) & 1 == team {build = view.dragon_builds[dragon]; break}
	}
	if build.guid == "" {return "no build"}
	// The recovery's status names the record the build came from.
	source := build.status
	if start := strings.index(source, "taken from "); start >= 0 {source = source[start + len("taken from "):]}
	if end := strings.index_byte(source, ';'); end >= 0 {source = source[:end]}
	text := fmt.tprintf("%s from %s", build.guid[:min(8, len(build.guid))], source)
	rebuilt, matching := view.rebuilt_turns[team], view.matching_turns[team]
	if rebuilt == 0 {return fmt.tprintf("%s, asserted", text)}
	return fmt.tprintf("%s, %d/%d rebuilt turns match", text, matching, rebuilt)
}

// The match's info dialog: the replay, the recorded bots and the build the
// recovery gives each team.
match_details :: proc(viewer: ^Viewer_State) -> string {
	view := &viewer.game.view
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "Replay: %s\nBot A: %s\nBot B: %s\n", viewer.comment_context.replay, view.bot_a, view.bot_b)
	for team in 0 ..< 2 {
		for dragon, indices in viewer.game.turn_indices_by_dragon {
			if len(indices) == 0 || int(view.turn_team[indices[0]]) != team {continue}
			build := view.dragon_builds[dragon]
			if build.guid == "" {fmt.sbprintf(&text, "Team %c build: none (%s)\n", 'A' + team, build.status)
			} else {fmt.sbprintf(&text, "Team %c build: %s %s (%s)\n", 'A' + team, build.guid, build.variant, build.status)}
			break
		}
	}
	return strings.to_string(text)
}
