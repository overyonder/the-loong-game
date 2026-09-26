package viewer

import rl "vendor:raylib"

// The published viewer's palette, so one game looks the same wherever it is
// read. public/viewer/drawing.odin is where these came from.
BACKGROUND :: rl.Color{29, 32, 33, 255}
COLOR_CELL :: rl.Color{29, 48, 39, 255}
COLOR_GRID :: rl.Color{243, 236, 223, 18}
COLOR_KELP :: rl.Color{127, 176, 105, 255}
COLOR_PORTAL :: rl.Color{232, 200, 114, 255}
COLOR_PEARL :: rl.Color{232, 200, 114, 255}
COLOR_SELECTED :: rl.Color{232, 200, 114, 255}
COLOR_DEATH :: rl.Color{251, 73, 52, 255}
COLOR_UNKNOWN :: rl.Color{22, 24, 25, 255}
TEXT_COLOR :: rl.Color{235, 219, 178, 255}
MUTED_TEXT_COLOR :: rl.Color{146, 131, 116, 255}
WARNING_COLOR :: rl.Color{254, 128, 25, 255}
@(rodata)
TEAM_BODY_COLORS := [2]rl.Color{{255, 122, 61, 255}, {243, 236, 223, 255}}
@(rodata)
TEAM_HEAD_COLORS := [2]rl.Color{{255, 170, 120, 255}, {255, 255, 245, 255}}
