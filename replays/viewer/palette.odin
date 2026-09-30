package viewer

import rl "vendor:raylib"

// The reference board colours sit inside a dark viewer; cream and gold
// remain foreground marks rather than window backgrounds.
BACKGROUND :: rl.Color{22, 24, 25, 255}
// The one-pixel border round every pane and scroll section.
PANE_BORDER :: rl.Color{68, 78, 74, 255}
COLOR_CELL :: rl.Color{29, 48, 39, 255}
// The Spawn gaps overlay blends a cell's background this share of the way
// towards SPAWN_TINT by its maximum reset gap, first band that holds it. The
// bands follow where our maps' maxima cluster: pods at 1 to 10, then 20, 30 to
// 100, up to 200, and the slow background from 250 up, left untinted.
SPAWN_TINT :: rl.Color{240, 214, 64, 255}
@(rodata)
SPAWN_BANDS := [?]struct {
	maximum: i32,
	share:   f32,
}{{10, 0.45}, {20, 0.32}, {100, 0.20}, {200, 0.09}}
COLOR_GRID :: rl.Color{243, 236, 223, 18}
COLOR_KELP :: rl.Color{127, 176, 105, 255}
COLOR_PORTAL :: rl.Color{232, 200, 114, 255}
COLOR_PEARL :: rl.Color{232, 200, 114, 255}
COLOR_SELECTED :: rl.Color{232, 200, 114, 255}
COLOR_DEATH :: rl.Color{251, 73, 52, 255}
COLOR_UNKNOWN :: rl.Color{22, 24, 25, 255}
TEXT_COLOR :: rl.Color{243, 236, 223, 255}
MUTED_TEXT_COLOR :: rl.Color{169, 181, 166, 255}
WARNING_COLOR :: rl.Color{255, 155, 104, 255}
UI_ACCENT :: rl.Color{232, 200, 114, 255}
// A dragon the mental map's dragon doesn't know of.
UNKNOWN_DRAGON_COLOR :: rl.Color{120, 124, 122, 255}
// The beliefs strip's dot once every dragon in the match is rebuilt.
REBUILT_COLOR :: rl.Color{120, 200, 120, 255}
// The inspector band for a decision whose result the board shows.
DECIDED_COLOR :: rl.Color{126, 178, 230, 255}
BOARD_TEXT :: rl.Color{243, 236, 223, 170}
@(rodata)
TEAM_BODY_COLORS := [2]rl.Color{{255, 122, 61, 255}, {243, 236, 223, 255}}
@(rodata)
TEAM_HEAD_COLORS := [2]rl.Color{{255, 122, 61, 255}, {243, 236, 223, 255}}
// A true countdown the focused dragon remembers correctly, and other
// remembered timer columns.
CORRECT_TIMER_COLOR :: rl.Color{80, 210, 230, 255}
// Sonar the focused dragon read, and its own sonar coming back as echoes,
// both dashed, apart from the solid gold of a planned path.
SONAR_RECEIVED :: rl.Color{170, 150, 230, 255}
SONAR_ECHO :: rl.Color{155, 189, 181, 150}
