package viewer

import "core:encoding/json"
import "core:testing"
import rl "vendor:raylib"

@(test)
breakdown_entries_carry_the_looks_diagnostics_md_names :: proc(t: ^testing.T) {
	text := `[{"level":"Role","value":"scout","color":[25,158,112],"icon":"magnifier"},{"level":"Task","value":"explore","pattern":"crosshatch","icon":"arrow"}]`
	entries: []Breakdown_Entry
	testing.expect(t, json.unmarshal_string(text, &entries, allocator = context.temp_allocator) == nil)
	coarse, fine := entry_look(entries[0]), entry_look(entries[1])
	testing.expect_value(t, coarse.color.?, rl.Color{25, 158, 112, 255})
	testing.expect_value(t, coarse.icon.?, Head_Icon.Magnifier)
	testing.expect(t, coarse.pattern == nil)
	testing.expect_value(t, fine.pattern.?, Body_Pattern.Crosshatch)
	unnamed := entry_look({icon = "wings", pattern = "plaid", color = {1, 2}})
	testing.expect(t, unnamed.color == nil && unnamed.icon == nil && unnamed.pattern == nil)
}
