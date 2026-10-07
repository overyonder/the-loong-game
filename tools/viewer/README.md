# Replay viewer

Input: a game columns file produced by `just gamedata REPLAY`, with optional
recovery arguments for a registered bot. Output: an interactive Odin/raylib
window, or an image or evaluation file when requested.

Build with `just viewer-build`. Open a replay with `just viewer REPLAY`.
The launcher converts the replay and passes additional arguments to the viewer.
Add `--seat A GUID BOT --seat B GUID BOT` to recover decisions for registered builds.

The viewer includes board playback, diagnostic inspection, belief views,
queen knowledge and manual ghost play. The wire records are documented in
[diagnostics.md](diagnostics.md). Recovery runs through
`build/bin/loong-recover` and the registered judge build.

For direct use, run `build/bin/viewer GAME.cols`. Optional output arguments
include `--image OUTPUT.png`, `--size WIDTHxHEIGHT` and
`--evaluation OUTPUT.json`. Graphical operations require a display.
