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
save_annotation :: proc(viewer: ^Viewer_State) {
	text := string(cstring(raw_data(viewer.comment[:])))
	if len(strings.trim_space(text)) == 0 {viewer.status = "Enter a comment before saving"; return}
	path := viewer.game.export.annotation_path
	if len(path) == 0 {viewer.status = "Replay annotation path unavailable"; return}
	record := Annotation {
		1,
		current_frame(viewer),
		viewer.selected_dragon,
		viewer.highlights[:],
		text,
	}
	data, encode_error := json.marshal(record, allocator = context.temp_allocator)
	if encode_error != nil {viewer.status = "Could not encode comment"; return}
	file, open_error := os.open(path, {.Write, .Create, .Append})
	if open_error != nil {viewer.status = fmt.aprintf("Cannot save: %v", open_error); return}
	defer os.close(file)
	line := fmt.tprintf("%s\n", string(data))
	count, write_error := os.write_string(file, line)
	if write_error != nil ||
	   count != len(line) {viewer.status = "Comment write failed; text retained"; return}
	load_annotations(viewer)
	viewer.comment = {}
	viewer.comment_editing = false
	viewer.status = fmt.aprintf("Saved comment to %s", path)
}
draw_annotation_editor :: proc(viewer: ^Viewer_State, area: rl.Rectangle) {
	if rl.GuiButton(
		{area.x + area.width - 350, area.y - 3, 165, 26},
		"Previous saved",
	) {restore_annotation(viewer, viewer.annotation_index - 1)}
	if rl.GuiButton(
		{area.x + area.width - 180, area.y - 3, 170, 26},
		"Next saved",
	) {restore_annotation(viewer, viewer.annotation_index + 1)}
	draw_text(
		fmt.ctprintf(
			"Comment for round %d, dragon %d; %d highlights",
			current_frame(viewer),
			viewer.selected_dragon,
			len(viewer.highlights),
		),
		i32(area.x),
		i32(area.y),
		18,
		TEXT_COLOR,
	)
	field := rl.Rectangle{area.x, area.y + 26, area.width - 170, 34}
	if rl.IsMouseButtonPressed(.LEFT) {
		viewer.comment_editing = rl.CheckCollisionPointRec(rl.GetMousePosition(), field)
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
	if rl.GuiButton(
		{area.x + area.width - 160, area.y + 26, 150, 34},
		"Save comment",
	) {save_annotation(viewer)}
	draw_text(
		fmt.ctprintf("%s", viewer.status),
		i32(area.x),
		i32(area.y + 64),
		14,
		MUTED_TEXT_COLOR,
	)
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
	for edge, index in viewer.game.export.edges {
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

load_annotations :: proc(viewer: ^Viewer_State) {
	clear(&viewer.annotations)
	data, err := os.read_entire_file(viewer.game.export.annotation_path, context.temp_allocator)
	if err != nil {return}
	for line in strings.split(string(data), "\n", context.temp_allocator) {
		if len(strings.trim_space(line)) == 0 {continue}
		record: Annotation
		if json.unmarshal(transmute([]u8)line, &record) == nil && record.version == 1 {
			append(&viewer.annotations, record)
		} else {viewer.status = "Skipped malformed annotation record; original file preserved"}
	}
}

restore_annotation :: proc(viewer: ^Viewer_State, index: int) {
	if len(viewer.annotations) == 0 {return}
	viewer.annotation_index = (index + len(viewer.annotations)) % len(viewer.annotations)
	record := viewer.annotations[viewer.annotation_index]
	step_to_frame(viewer, record.frame)
	viewer.selected_dragon = record.dragon
	clear(&viewer.highlights)
	append(&viewer.highlights, ..record.highlights)
	viewer.comment = {}
	copy(viewer.comment[:len(viewer.comment) - 1], record.text)
	viewer.comment_editing = false
	viewer.status = fmt.aprintf(
		"Loaded saved comment %d/%d",
		viewer.annotation_index + 1,
		len(viewer.annotations),
	)
}
