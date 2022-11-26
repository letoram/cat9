return
{
	list =
	{
		file = {fc = tui.colors.ref_green, bc = tui.colors.text},
		directory = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		link = {fc = tui.colors.ref_yellow, bc = tui.colors.text},
		verbose = false,
		watch = {
			"/usr/bin/inotifywait", "inotifywait",
			"-e", "move",
			"-e", "create",
			"-e", "delete",
			"-e", "unmount",
			"$path"
		}
	}
}
