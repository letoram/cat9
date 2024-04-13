return
{
	stash = {
		file = {fc = tui.colors.ref_green, bc = tui.colors.text},
		descriptor = {fc = tui.colors.ref_yellow, bc = tui.colors.text},
		directory = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		bchunk = true,
		autocheck = false,
		checksum = {"/usr/bin/env", "/usr/bin/env", "sha256sum", "$path"}
	},
	list =
	{
		file = {fc = tui.colors.ref_green, bc = tui.colors.text},
		directory = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		link = {fc = tui.colors.ref_yellow, bc = tui.colors.text},
		executable = {fc = tui.colors.ref_red, bc = tui.colors.text},
		socket = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		shift_m1 = "open #csel($=crow) new",
		m2 = "stash add #csel($=crow)",
		m1 = "open #csel($=crow) swallow",
		m4 = "view #csel scroll -5",
		m5 = "view #csel scroll +5",
		verbose = false,
		hidden = false,
		watch = {
			"/usr/bin/env",
			"/usr/bin/env",
			"inotifywait",
			"-e", "move",
			"-e", "create",
			"-e", "delete",
			"-e", "unmount",
			"$path"
		}
	}
}
