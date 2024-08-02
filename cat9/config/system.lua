return
{
	stash = {
		file = {fc = tui.colors.ref_green, bc = tui.colors.text},
		descriptor = {fc = tui.colors.ref_yellow, bc = tui.colors.text},
		directory = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		message = {fc = tui.colors.ref_red, bc = tui.colors.text},
		bchunk = true,
		autocheck = false,
		scratch_prefix = "/tmp/stashXXXXXX", -- for building temp folders
		archive_prefix = "/tmp/stash_archive_XXXXXX",
		fifo_prefix = lash.root:getenv()["HOME"] .. "/Downloads/",
		right_arrow = lash.root:has_glyph("►") and " ► " or "->",
		checksum = {"/usr/bin/env", "/usr/bin/env", "sha256sum", "--tag", "$path"},
		checksum_pending = "P ",
		checksum_ok = "+ ",
		checksum_fail = "- ",
		unresolved = "! ",
		unresolved_fail = "!x ",
		archive = {
			tar = {
				"/usr/bin/env",
				"/usr/bin/env",
				"tar",
				"-C",
				"$dir",
				"--dereference",
				"--append",
				"-f",
				"$file",
				"."
			}
		}
	},
	list =
	{
		file = {fc = tui.colors.ref_green, bc = tui.colors.text},
		directory = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		link = {fc = tui.colors.ref_yellow, bc = tui.colors.text},
		executable = {fc = tui.colors.ref_red, bc = tui.colors.text},
		socket = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		permission = {fc = tui.colors.ref_grey, bc = tui.colors.text},
		user = {fc = tui.colors.ref_light_grey, bc = tui.colors.text},
		group = {fc = tui.colors.ref_light_grey, bc = tui.colors.text},
		time = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		size = {fc = tui.colors.ref_blue, bc = tui.colors.text},
		shift_m1 = "open new #csel($=crow)",
		m2 = "stash add #csel($=crow)",
		m1 = "open swallow #csel($=crow)",
		m4 = "view #csel scroll -5",
		m5 = "view #csel scroll +5",
		time_str = "%x %X",
		time_key = "mtime", -- ctime, atime
		compact = false,
		track_changes = true,
		suffix = {fc = tui.colors.alert, bc = tui.colors.text},
		new_suffix = " [new]",
		sort_group = true,
		sort = "alphabetic",
		size_prefix = true,

		job_bar_selected =
		{
			{"Size"},
			{"Name"},
			m1 = {
				[1] = "list #csel sort size",
				[2] = "list #csel sort alphabetic"
			}
		},

		bindings = {
			up = tui.keys.UP,
			down = tui.keys.DOWN,
			page_down = tui.keys.PAGEDOWN,
			page_up = tui.keys.PAGEUP,
			search = tui.keys.SLASH,
			dir_up = tui.keys.ESCAPE,
			activate = tui.keys.RETURN,
			[tui.keys.PAGEDOWN] = "view #csel scroll page +1",
			[tui.keys.PAGEUP] = "view #csel scroll page -1",
			[tui.keys.HOME] = "view #csel scroll 0",
			[tui.keys.END] = "view #csel scroll page +100000",
			[tui.keys.SPACE] = "view #csel select $=crow",
		},

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
