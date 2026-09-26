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
	rl.GuiSetStyle(
		.DEFAULT,
		i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
		transmute(i32)u32(0xebdbb2ff),
	)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiControlProperty.BASE_COLOR_NORMAL), i32(0x1d3027ff))
	rl.GuiSetStyle(
		.DEFAULT,
		i32(rl.GuiControlProperty.BORDER_COLOR_NORMAL),
		transmute(i32)u32(0x928374ff),
	)
	rl.GuiSetStyle(
		.DEFAULT,
		i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
		transmute(i32)u32(0xe8c872ff),
	)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 18)
}
draw_text :: proc(text: cstring, x, y, size: i32, color: rl.Color) {
	rl.DrawTextEx(viewer_font, text, {f32(x), f32(y)}, f32(size) * font_scale, 0, color)
}
measure_text :: proc(text: cstring, size: i32) -> i32 {
	return i32(rl.MeasureTextEx(viewer_font, text, f32(size) * font_scale, 0).x)
}
