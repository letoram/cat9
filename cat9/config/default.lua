local group_sep = lash.root:has_glyph("") and " " or "> "
local collapse_sym = lash.root:has_glyph("▲") and "▲" or "[-]"
local expand_sym = lash.root:has_glyph("▼") and "▼" or "[+]"
local selected_sym = lash.root:has_glyph("►") and "►" or ">"

-- simpler toggles for dynamically controlling presentation
return
{
	autoexpand_latest = true, -- the latest job always starts view expanded
	autosuggest = true, -- start readline with tab completion enabled
	debug = true, -- dump parsing output / data to the command-line

-- generic mouse handlers for any job, specific actions can be dynamically
-- defined by the job creator, as well as the job-bar mouse handler below.
	m1_click = "view #csel toggle",
	m2_click = "open #csel tab hex",
	m3_click = "open #csel hex",
	m4_data_click = "view #csel scroll -1",
	m5_data_click = "view #csel scroll +1",

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

-- subtables are ignored for the config builtin
--
-- possible job-bar meta entries (cat9/base/layout.lua):
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
		{"X"},
		m1 = {[3] = "forget #csel"}
	},

-- powerline glyphs for easy cut'n'paste:   
	job_bar_expanded =
	{
		{ collapse_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{ group_sep, "$full"},
	},

-- similar to job_bar but no click-groups so only one level of tables
	prompt_focus =
	{
		"[",
		"$jobs",
		"]",
		"$lastdir",
		group_sep,
		function() return os.date("%H:%M:%S") end,
		group_sep,
	},

	prompt =
	{
		"[",
		"$lastdir",
		"]",
	},

	readline =
	{
		cancellable   = true,   -- cancel removes readline until we starts typing
		forward_meta  = false,  -- don't need meta-keys, use default rl behaviour
		forward_paste = true,   -- ignore builtin paste behaviour
		forward_mouse = true,   -- needed for clicking outside the readline area
	},

	styles =
	{
		line_number = {fc = tui.colors.label, bc = tui.colors.label},
		data = {fc = tui.colors.text, bc = tui.colors.text},
	},

	glob =
	{
		dir_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1", "-type", "d"},
		file_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1"}
	}
}
