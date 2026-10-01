package viewer

import "core:testing"

@(test)
area_view_centres_the_head_and_wraps_round_the_torus :: proc(t: ^testing.T) {
	export := Game_View{width = 40, height = 30}
	// A head in the corner puts the view across both seams.
	g := board_geometry_for_area(&export, {0, 0, 300, 300}, 1 * 40 + 2)
	testing.expect_value(t, g.columns, AREA_VIEW_SIDE)
	testing.expect_value(t, cell_at_point(g, {150, 150}), 1 * 40 + 2)
	testing.expect_value(t, cell_at_point(g, {5, 5}), (30 - 6) * 40 + (40 - 5))
	testing.expect_value(t, cell_at_point(g, {299, 299}), 8 * 40 + 9)
	for cell in ([?]i32{0, 39, 29 * 40, 1 * 40 + 2, (30 - 6) * 40 + 35}) {
		testing.expect_value(t, cell_at_point(g, cell_center(g, cell)), cell)
	}
	whole := board_geometry_for_area(&export, {0, 0, 400, 300})
	testing.expect_value(t, cell_at_point(whole, cell_center(whole, 17 * 40 + 23)), 17 * 40 + 23)
}
