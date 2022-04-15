-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md, TODO.md

local group_sep = lash.root:has_glyph("") and " " or "> "
local collapse_sym = lash.root:has_glyph("▲") and "▲" or "[-]"
local expand_sym = lash.root:has_glyph("▼") and "▼" or "[+]"
local selected_sym = lash.root:has_glyph("►") and "►" or ">"
-- simpler toggles for dynamically controlling presentation
local config =
{
	autoexpand_latest = true,
	autosuggest = true, -- start readline with tab completion enabled
	debug = true, -- dump parsing output / data to the command-line

-- all clicks can also be bound as m1_header_index_click where index is the item group,
-- and the binding value will be handled just as typed (with csel substituted for cursor
-- position)
	m1_click = "view #csel toggle",
	m2_click = "open #csel tab hex",
	m3_click = "open #csel hex",
	hex_mode = "hex_detail_meta", -- hex, hex_detail hex_detail_meta

	content_offset = 1, -- columns to skip when drawing contents
	job_pad        = 1, -- space after job data and next job header
	collapsed_rows = 1, -- number of rows of contents to show when collapsed
	autoclear_empty = true, -- forget jobs without output

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
		{ selected_sym, "#", "$id", group_sep, "$pid_or_exit", group_sep, "$memory_use"},
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

	glob =
	{
		dir_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1", "-type", "d"},
		file_argv = {"/usr/bin/find", "find", "$path", "-maxdepth", "1"}
	}
}

local cat9 =  -- vtable for local support functions
{
	scanner = {}, -- state for asynch completion scanning
	env = {},
	builtins = {},
	suggest = {},
	handlers = {},

-- properties exposed for other commands
	config = config,
	jobs = lash.jobs,

	lastdir = "",
	laststr = "",
	resources = {}, -- used for clipboard and bchunk ops

	idcounter = 0, -- monotonic increment for each command dispatched
	visible = true,
	focused = true
}

-- all builtin commands are split out into a separate 'command-set' dir
-- in order to have interchangeable sets for expanding cli/argv of others
local safe_builtins
local safe_suggest
local function load_builtins(base)
	cat9.builtins = {}
	cat9.suggest = {}

	local fptr, msg = loadfile(string.format("%s/cat9/%s.lua", lash.scriptdir, base))
	if not fptr then
		cat9.add_message(string.format("builtin: [" .. base .. "] failed to load: %s", msg))
		return false
	end
	local set = fptr()

	for _,v in ipairs(set) do
		local fptr, msg = loadfile(string.format("%s/cat9/%s/%s", lash.scriptdir, base, v))
		if fptr then
			pcall(fptr(), cat9, lash.root, cat9.builtins, cat9.suggest)
		else
			cat9.add_message(string.format("builtin{%s:%s} failed to load: %s", base, v, msg))
			return false
		end
	end

	builtin_completion = {}
	for k, _ in pairs(cat9.builtins) do
		table.insert(builtin_completion, k)
	end

-- force-inject loading builtin set so swapping works ok
	cat9.builtins["builtin"] =
	function(a)
		if not a or #a == 0 then
			cat9.add_message("builtin - missing set name")
			return
		end

		if not load_builtins(a) then
			cat9.add_message(string.format(
				"missing requested builtin set [%s] - revert to default.", a))
			cat9.builtins = safe_builtins
			cat9.suggest = safe_suggest
		end
	end

	table.sort(builtin_completion)
	return true
end

local function load_feature(name)
	fptr, msg = loadfile(lash.scriptdir .. "./cat9/base/" .. name)
	if not fptr then
		return false, msg
	end
	local init = fptr()
	init(cat9, lash.root, cat9.config)
end

load_feature("scanner.lua") -- running hidden jobs that collect information
load_feature("jobctl.lua")  -- processing / forwarding job input-output
load_feature("parse.lua")   -- breaking up a command-line into actions and suggestions
load_feature("layout.lua")  -- drawing screen, decorations and related handlers
load_feature("misc.lua")    -- support functions that doesn't fit anywhere else
load_feature("ioh.lua")     -- event handlers for display server device/state io

-- use mouse-forward mode, implement our own selection / picking
load_builtins("default")
safe_builtins = cat9.builtins
safe_suggest = cat9.suggest

config.readline.verify = cat9.readline_verify

lash.root:set_flags(tui.flags.mouse)
lash.root:set_handlers(cat9.handlers)
cat9.reset()
cat9.update_lastdir()
cat9.flag_dirty()

-- import job-table and add whatever metadata we want to track
local old = lash.jobs
lash.jobs = {}
cat9.jobs = lash.jobs
for _, v in ipairs(old) do
	cat9.import_job(v)
end

local root = lash.root
while root:process() do
	if (cat9.process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		cat9.flag_dirty()
	end

	if cat9.dirty then
		root:refresh()
	end
end
