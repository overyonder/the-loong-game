package viewer

import "core:testing"

@(test)
remembered_deadlines_do_not_gain_future_knowledge :: proc(t: ^testing.T) {
	testing.expect(t, cell_diagnostic_label("12", "round_delta", 5, true) == "7")
	testing.expect(t, cell_diagnostic_label("12", "round_delta", 15, true) == "-3")
	testing.expect(t, cell_diagnostic_label("-1", "round_delta", 5, true) == "?")
	testing.expect(t, cell_diagnostic_label("12", "round_delta", 5, false) == "")
	testing.expect(t, cell_diagnostic_label("0", "number", 5, true) == "0.0")
}


@(test)
edge_claims_carry_beliefs_and_portal_landings :: proc(t: ^testing.T) {
	claims, ok := parse_edge_claims("N. Ew Ss Wp3>45")
	testing.expect(t, ok)
	testing.expect_value(t, claims[1].code, 'w')
	testing.expect_value(t, claims[2].code, 's')
	testing.expect_value(t, claims[3].portal, 3)
	testing.expect_value(t, claims[3].landing, 45)
	_, bad := parse_edge_claims("E. N. S. W.")
	testing.expect(t, !bad)
}
