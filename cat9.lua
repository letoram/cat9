-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md, TODO.md

-- simpler toggles for dynamically controlling presentation
local config =
{
	autoexpand_latest = true,
	autosuggest = true, -- start readline with tab completion enabled
	debug = true,

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

	readline =
	{
		cancellable   = true,   -- cancel removes readline until we starts typing
		forward_meta  = false,  -- don't need meta-keys, use default rl behaviour
		forward_paste = true,   -- ignore builtin paste behaviour
		forward_mouse = true,   -- needed for clicking outside the readline area
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

	visible = true,
	focused = true
}

-- all builtin commands are split out into a separate 'command-set' dir
-- in order to have interchangeable sets for expanding cli/argv of others
local function load_builtins(base)
	cat9.builtins = {}
	cat9.suggest = {}
	local fptr, msg = loadfile(lash.scriptdir .. "./cat9/" .. base)
	if not fptr then
		return false, msg
	end
	local init = fptr()
	init(cat9, lash.root, cat9.builtins, cat9.suggest)

	builtin_completion = {}
	for k, _ in pairs(cat9.builtins) do
		table.insert(builtin_completion, k)
	end

	table.sort(builtin_completion)
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
load_builtins("default.lua")

config.readline.verify = cat9.readline_verify

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
