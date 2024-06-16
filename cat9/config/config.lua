-- powerline glyphs for easy cut'n'paste:   
local group_sep = lash.root:has_glyph("") and " " or "> "
local collapse_sym = lash.root:has_glyph("▲") and "▲" or "[-]"
local expand_sym = lash.root:has_glyph("▼") and "▼" or "[+]"
local selected_sym = lash.root:has_glyph("►") and "►" or ">"

local fmt_sep = {fc = tui.colors.label, bc = tui.colors.text}
local fmt_data = {fc = tui.colors.inactive, bc = tui.colors.text}

-- hints match their config key here
local hintbl = {
	autoexpand_latest = "The latest job always starts as 'view expanded'",
	autocontract_last = "The previous job will contract when a new one is spawned",
	autosuggest = "Toggle completion without manually pressing TAB",
	allow_state = "Permit external WM to control state load/store",
	debug = "Write parser debug information to 'view monitor'",
	hex_mode = "Builtin hex editor default presentation (hex, hex_detail, hex_detail_meta)",
	content_offset = "Number of columns of padding between line column and content",
	job_pad = "Number of empty rows between job views",
	collapsed_rows = "Number of visible rows for a contracted job",
	autoclear_empty = "Automatically forget #jobid for completed silent jobs",
	show_line_number = "Set view linenumber for new jobs",
	autokill_quiet_bad = "Timeout for silent jobs that failed with EXIT_FAILURE",
	plumber = "Binary used for external open",
	main_column_width = "Number of columns for main jobs",
	min_column_width = "Number of columns for side jobs",
	open_spawn_default = "Suggested open mode (embed, split, join-r, tab, swallow)",
	clipboard_job = "Create a new job that absorbs all pasted input",
	sh_runner = "Program to invoke for subshell commands",
	default_job_view = "Default view action for new jobs",
	detach_keep = "Set to reattach detached job on window destruction",
	open_embed_collapsed_rows = "Number of rows for downscaled contract open embed",
	["=reload"] = "Re-parse and apply config.lua",
	accessibility = "Probe display server for accessibility needs at startup",
	mouse_mode = string.format(
		"(Advanced) override mouse mode flag (%d, %d)", tui.flags.mouse, tui.flags.mouse_full),
}
 -- tui.flags.mouse_full blocks meta+drag-select
-- simpler toggles for dynamically controlling presentation
return
{
	hint = hintbl,
	autoexpand_latest = true,
	autocontract_last = false,
	autosuggest = true,
	debug = false,
	hex_mode = "hex_detail_meta",

	content_offset = 1,
	job_pad        = 1,
	collapsed_rows = 4,
	autoclear_empty = true,
	show_line_number = true,
	autokill_quiet_bad = 100,
	detach_keep = false,

	term_plumber = "/usr/bin/nvim",
	plumber = "/usr/bin/afsrv_decode",

	default_job_view = "crop",

-- probe for accessibility segment at startup, adds 10-50ms time so disable if
-- you don't need or want to test for it
	accessibility = true,

	main_column_width = 80,
	min_column_width = 40,

	open_spawn_default = "swallow",
	open_embed_collapsed_rows = 4,
--	open_external = "/usr/bin/nvim", -- set to skip the internal viewer

	clipboard_job = true,
	mouse_mode = tui.flags.mouse,
	allow_state = true,

-- sh-runner is configurable, will be rebuilt into argv through string.split(" ")
-- this means that we can have a privileged root default, but default to run
-- as a targetted user.
	sh_runner = "/bin/sh sh -c",

-- subtables are ignored for the config builtin
--
-- possible job-bar meta entries (cat9/base/jobmeta.lua):
--  $pid_or_exit, $id, $data, $hdr_data, $memory_use, $dir, $full, $short
--
-- the action subtable matches
--
	job_bar_collapsed =
	{
		group_sep = group_sep,
		{expand_sym},
		{"#", "$id", group_sep, group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{"$short"},
	},

	job_bar_selected =
	{
		group_sep = group_sep,
		{selected_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{"$short"},
		{"repeat"},
		{"X"},
		m1 = {
			[3] = "repeat #csel flush",
			[4] = "forget #csel"
		}
	},

	job_bar_expanded =
	{
		group_sep = group_sep,
		{ collapse_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{"$view"},
		{"$full_or_short"},
		prefix = {fmt_sep, "[", fmt_data},
		suffix = {fmt_sep, "]", fmt_data}
	},

-- similar to job_bar but no click-groups so only one level of tables
-- possible specials defined in base/promptmeta.lua
	prompt_focus =
	{
		"$chord_state",
		"$begin",
		function() return os.date("%H:%M:%S") end,
--		"$begin",
--		"$battery_charging $battery_pct % $battery_power W",
		"$begin",
		"$jobs",
		"$begin",
		"$builtin_name",
		"$builtin_status",
		"$dynamic", -- insertion point for any builtins that attach itself
		"$end", -- force stop any remaining group
		" > ",
		fmt_data,
		"$lastdir",
		"# ",
		prefix = {fmt_sep, "[", fmt_data},
		suffix = {fmt_sep, "]", fmt_data}
	},

	prompt =
	{
		"$begin",
		"$lastdir",
		prefix = {fmt_sep, "<", fmt_data},
		suffix = {fmt_sep, ">", fmt_data}
	},

	readline =
	{
		cancellable   = false,  -- cancel removes readline until we starts typing
		forward_meta  = false,  -- don't need meta-keys, use default rl behaviour
		forward_paste = true,   -- ignore builtin paste behaviour
		forward_mouse = true,   -- needed for clicking outside the readline area
		whitespace_expand = false,
		linefeed_expand = false,
	},

	styles =
	{
		line_number = {fc = tui.colors.label, bc = tui.colors.label},
		data = {fc = tui.colors.text, bc = tui.colors.text},
		data_highlight = {fc = tui.colors.alert, bc = tui.colors.alert},
	},

	glob =
	{
		dir_argv = {"/usr/bin/env", "/usr/bin/env", "find", "$path", "-maxdepth", "1", "-type", "d"},
		file_argv = {"/usr/bin/env", "/usr/bin/env", "find", "$path", "-maxdepth", "1"}
	},

-- each set of builtins (including the default) gets a subtable in here that
-- is populated when loading the set itself, and overlayed by config/setname.lua
	builtins = {
	}
}
