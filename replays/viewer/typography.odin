package viewer

import rl "vendor:raylib"

viewer_font: rl.Font
font_scale: f32 = 1
// Raylib DrawText defaults to its embedded 10px bitmap font. Use an embedded
// scalable DejaVu Sans face for both raygui controls and board/inspector text.
FONT_DATA :: #load("fonts/DejaVuSans.ttf")
initialize_typography :: proc() {
	viewer_font = rl.LoadFontFromMemory(
		".ttf",
		raw_data(FONT_DATA),
		i32(len(FONT_DATA)),
		48,
		nil,
		0,
	)
	rl.SetTextureFilter(viewer_font.texture, .BILINEAR)
	rl.GuiSetFont(viewer_font)
	// Paper controls, forest ink, warm focus: no raygui default blue states.
	properties := [9]rl.GuiControlProperty {
		.TEXT_COLOR_NORMAL,
		.BASE_COLOR_NORMAL,
		.BORDER_COLOR_NORMAL,
		.TEXT_COLOR_FOCUSED,
		.BASE_COLOR_FOCUSED,
		.BORDER_COLOR_FOCUSED,
		.TEXT_COLOR_PRESSED,
		.BASE_COLOR_PRESSED,
		.BORDER_COLOR_PRESSED,
	}
	colors := [9]u32 {
		0x20251fff,
		0xede5d5ff,
		0x9caa96ff,
		0x20251fff,
		0xe4d8bfff,
		0x775319ff,
		0xf3ecdfff,
		0x1d3027ff,
		0x1d3027ff,
	}
	for property, index in properties {rl.GuiSetStyle(.DEFAULT, i32(property), i32(colors[index]))}
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 18)
}
draw_text :: proc(text: cstring, x, y, size: i32, color: rl.Color) {
	rl.DrawTextEx(viewer_font, text, {f32(x), f32(y)}, f32(size) * font_scale, 0, color)
}
measure_text :: proc(text: cstring, size: i32) -> i32 {
	return i32(rl.MeasureTextEx(viewer_font, text, f32(size) * font_scale, 0).x)
}
