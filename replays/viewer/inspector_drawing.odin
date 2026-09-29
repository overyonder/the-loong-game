package viewer

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Wrap every diagnostic, including packet fields, and scroll the complete
// inspector. No fixed ping count or clipped final records.
inspector_paragraph :: proc(
	viewer: ^Viewer_State,
	cursor: ^rl.Vector2,
	width: f32,
	text: string,
	color := TEXT_COLOR,
	kind := "",
	id: i32 = -1,
) {
	start := cursor.y
	display := text
	if len(text) > 240 && !viewer.detail_open {
		display = fmt.tprintf("%s...", text[:180])
		if rl.GuiButton(
			{cursor.x + width - 25, start, 24, 22},
			"+",
		) {open_diagnostic_detail(viewer, "Diagnostic explanation", text)}
	}
	line := ""
	for word in strings.split(display, " ", context.temp_allocator) {
		next := fmt.tprintf("%s%s%s", line, len(line) > 0 ? " " : "", word)
		if len(line) > 0 && measure_text(fmt.ctprintf("%s", next), UI_TEXT) > i32(width) {
			draw_text(fmt.ctprintf("%s", line), i32(cursor.x), i32(cursor.y), UI_TEXT, color)
			cursor.y += UI_LINE * font_scale
			line = word
		} else {line = next}
	}
	draw_text(fmt.ctprintf("%s", line), i32(cursor.x), i32(cursor.y), UI_TEXT, color)
	cursor.y += (UI_LINE + 4) * font_scale
	if kind != "" {
		r := rl.Rectangle{cursor.x, start, width, cursor.y - start}
		if highlighted(viewer, kind, id) {rl.DrawRectangleLinesEx(r, 2, UI_ACCENT)}
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), viewer.inspector_area) &&
		   rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {toggle_highlight(viewer, kind, id)}
	}
}


// One line of text, cut short with an ellipsis to fit `width`.
clipped_text :: proc(input_text: string, x, y: f32, width: f32, color := TEXT_COLOR) {
	text, _ := strings.replace_all(input_text, "\n", " ", context.temp_allocator)
	length := len(text)
	for length > 0 &&
	    measure_text(fmt.ctprintf("%s%s", text[:length], length < len(text) ? "..." : ""), UI_TEXT) >
		    i32(width) {length -= 1}
	draw_text(
		fmt.ctprintf("%s%s", text[:length], length < len(text) ? "..." : ""),
		i32(x),
		i32(y),
		UI_TEXT,
		color,
	)
}

// The right sidebar: the focused dragon's decision records this round.
draw_dragon_inspector :: proc(viewer: ^Viewer_State, area: rl.Rectangle, frame: i32) {
	viewer.inspector_area = area
	turn, found := focused_dragon_turn(viewer, frame)
	if !found {
		clipped_text("No decision at this round", area.x, area.y, area.width, MUTED_TEXT_COLOR)
		return
	}
	draw_generic_inspector(viewer, area, turn)
}
