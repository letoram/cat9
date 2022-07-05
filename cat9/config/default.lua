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

-- all clicks can also be bound as m1_header_index_click where index is the item group,
-- and the binding value will be handled just as typed (with csel substituted for cursor
-- position)
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

	main_column_width = 120, -- let one column be wider
	min_column_width = 80, -- if we can add more side columns

	open_spawn_default = "embed", -- split, tab, ...
	open_embed_collapsed_rows = 4,

	clipboard_job = true,     -- create a new job that absorbs all paste action

	mouse_mode = tui.flags.mouse, -- tui.flags.mouse_full blocks meta+drag-select

-- subtables are ignored for the config builtin
-- possible job-bar meta entries (cat9/base/layout.lua):
--  $pid_or_exit, $id, $data, $hdr_data, $memory_use, $dir, $full, $short
--
-- the index of each bar property is can also be used with the 'click' binds
-- above e.g. m1_header_n_click referring to the subtable index.
	job_bar_collapsed =
	{
		{expand_sym},
		{"#", "$id", group_sep, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{group_sep, "$short"},
	},

	job_bar_selected =
	{
		{selected_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
		{group_sep, "$short", group_sep},
		{"X"}
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
