package viewer

import "core:os"
import "core:strings"
import "core:testing"

@(test)
comments_append_to_the_inbox_and_restore_per_replay :: proc(t: ^testing.T) {
	// Loaded comments live as long as the viewer.
	context.allocator = context.temp_allocator
	path := "/tmp/loong-viewer-inbox-test.md"
	defer os.remove(path)
	_ = os.write_entire_file(path, transmute([]u8)string("# Inbox\n\n- An existing item"))
	viewer: Viewer_State
	viewer.comment_context.inbox_path = path
	viewer.game.view.width = 10
	viewer.selected_dragon = 7
	for replay, index in ([?]string{"results/local/a.replay", "results/local/b.replay"}) {
		viewer.comment_context.replay = replay
		clear(&viewer.highlights)
		append(&viewer.highlights, Highlight{"cell", 23})
		copy(viewer.comment[:], index == 0 ? "Why turn here?" : "Other game")
		viewer.comment_editing = true
		save_annotation(&viewer)
		// The field stays focused for the next comment.
		testing.expect(t, viewer.comment_editing)
	}
	data, _ := os.read_entire_file(path, context.temp_allocator)
	lines := strings.split(strings.trim_space(string(data)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 5)
	testing.expect(
		t,
		strings.has_prefix(
			lines[3],
			"- Viewer comment on `results/local/a.replay`, round 0, dragon 7, cell (3,2): Why turn here? <!-- viewer ",
		),
	)
	viewer.comment_context.replay = "results/local/a.replay"
	load_annotations(&viewer)
	testing.expect_value(t, len(viewer.annotations), 1)
	if len(viewer.annotations) == 1 {
		testing.expect_value(t, viewer.annotations[0].text, "Why turn here?")
		testing.expect_value(t, viewer.annotations[0].dragon, 7)
		testing.expect_value(t, len(viewer.annotations[0].highlights), 1)
	}
}
