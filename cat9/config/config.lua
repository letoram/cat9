local group_sep = lash.root:has_glyph("") and " " or "> "
local collapse_sym = lash.root:has_glyph("▲") and "▲" or "[-]"
local expand_sym = lash.root:has_glyph("▼") and "▼" or "[+]"
local selected_sym = lash.root:has_glyph("►") and "►" or ">"

local fmt_sep = {fc = tui.colors.label, bc = tui.colors.text}
local fmt_data = {fc = tui.colors.inactive, bc = tui.colors.text}

-- simpler toggles for dynamically controlling presentation
return
{
	autoexpand_latest = true, -- the latest job always starts view expanded
	autosuggest = true, -- start readline with tab completion enabled
	debug = true, -- dump parsing output / data to the command-line

	hex_mode = "hex_detail_meta", -- hex, hex_detail hex_detail_meta

	content_offset = 1, -- columns to skip when drawing contents
	job_pad        = 1, -- space after job data and next job header
	collapsed_rows = 4, -- number of rows of contents to show when collapsed
	autoclear_empty = true, -- forget jobs without output
	show_line_number = true, -- default line number view
	autokill_quiet_bad = 100, -- timeout for jobs that failed with just errc.

	default_job_view = "crop",

	main_column_width = 80, -- let one column be wider
	min_column_width = 40, -- if we can add more side columns

	open_spawn_default = "embed", -- split, tab, ...
	open_embed_collapsed_rows = 4,

	clipboard_job = true,     -- create a new job that absorbs all paste action
	mouse_mode = tui.flags.mouse, -- tui.flags.mouse_full blocks meta+drag-select

	allow_state = true, -- load/store persistent state at startup or at wm request

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
		{expand_sym},
		{"#", "$id", group_sep, group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{group_sep, "$short"},
	},

	job_bar_selected =
	{
		{selected_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{group_sep, "$short", group_sep},
		{group_sep, "repeat/flush", group_sep},
		{"X"},
		m1 = {
			[3] = "repeat #csel flush",
			[4] = "forget #csel"
		}
	},

-- powerline glyphs for easy cut'n'paste:   
	job_bar_expanded =
	{
		{ collapse_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{ group_sep, "$view"},
		{ group_sep, "$full"},
		prefix = {fmt_sep, "[", fmt_data},
		suffix = {fmt_sep, "]", fmt_data}
	},

-- similar to job_bar but no click-groups so only one level of tables
-- possible specials defined in base/promptmeta.lua
	prompt_focus =
	{
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
	},

	styles =
	{
		line_number = {fc = tui.colors.label, bc = tui.colors.label},
		data = {fc = tui.colors.text, bc = tui.colors.text},
		data_highlight = {fc = tui.colors.alert, bc = tui.colors.alert},
	},

	glob =
	{
		dir_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1", "-type", "d"},
		file_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1"}
	},

-- each set of builtins (including the default) gets a subtable in here that
-- is populated when loading the set itself, and overlayed by config/setname.lua
	builtins = {}
}
