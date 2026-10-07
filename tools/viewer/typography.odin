package viewer

import rl "vendor:raylib"

viewer_font: rl.Font
font_scale: f32 = 1
// Interface text is 12 pt: 16 px at 96 dpi. Board labels scale with the board.
UI_TEXT :: 16
// Line advance for UI_TEXT, and the height of every button and text field.
UI_LINE :: 20
CONTROL_HEIGHT :: 24
// Horizontal room a button's label leaves inside its border.
BUTTON_PADDING :: 24
// Raylib DrawText defaults to its embedded 10px bitmap font. Use an embedded
// scalable DejaVu Sans face for both raygui controls and board/inspector text.
FONT_DATA :: #load("fonts/DejaVuSans.ttf")
// Printable ASCII and Latin-1, and the punctuation and signs bots write in
// labels and formulas, such as × and −.
@(rodata)
EXTRA_CODEPOINTS := [?]rune{'−', '–', '—', '‘', '’', '“', '”', '…', '·', '•', '→', '←', '↑', '↓', '≤', '≥', '≠', '≈', '∞', '√', 'Δ', 'π'}
initialize_typography :: proc() {
	codepoints := make([dynamic]rune, context.temp_allocator)
	for codepoint in rune(32) ..= 126 {append(&codepoints, codepoint)}
	for codepoint in rune(160) ..= 255 {append(&codepoints, codepoint)}
	append(&codepoints, ..EXTRA_CODEPOINTS[:])
	viewer_font = rl.LoadFontFromMemory(
		".ttf",
		raw_data(FONT_DATA),
		i32(len(FONT_DATA)),
		48,
		raw_data(codepoints),
		i32(len(codepoints)),
	)
	rl.SetTextureFilter(viewer_font.texture, .BILINEAR)
	rl.GuiSetFont(viewer_font)
	// Dark controls with cream text and gold focus, including disabled states.
	properties := [12]rl.GuiControlProperty {
		.TEXT_COLOR_NORMAL,
		.BASE_COLOR_NORMAL,
		.BORDER_COLOR_NORMAL,
		.TEXT_COLOR_FOCUSED,
		.BASE_COLOR_FOCUSED,
		.BORDER_COLOR_FOCUSED,
		.TEXT_COLOR_PRESSED,
		.BASE_COLOR_PRESSED,
		.BORDER_COLOR_PRESSED,
		.TEXT_COLOR_DISABLED,
		.BASE_COLOR_DISABLED,
		.BORDER_COLOR_DISABLED,
	}
	colors := [12]u32 {
		0xf3ecdfff,
		0x1d3027ff,
		0x596b5fff,
		0xf3ecdfff,
		0x304438ff,
		0xe8c872ff,
		0xf3ecdfff,
		0x405442ff,
		0xe8c872ff,
		0x788479ff,
		0x1b2420ff,
		0x39453dff,
	}
	for property, index in properties {rl.GuiSetStyle(.DEFAULT, i32(property), i32(colors[index]))}
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), UI_TEXT)
}
draw_text :: proc(text: cstring, x, y, size: i32, color: rl.Color) {
	rl.DrawTextEx(viewer_font, text, {f32(x), f32(y)}, f32(size) * font_scale, 0, color)
}
measure_text :: proc(text: cstring, size: i32) -> i32 {
	return i32(rl.MeasureTextEx(viewer_font, text, f32(size) * font_scale, 0).x)
}
