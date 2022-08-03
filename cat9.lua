-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md, TODO.md

local cat9 =  -- vtable for local support functions
{
	scanner = {}, -- state for asynch completion scanning
	env = lash.root:getenv(),

-- all these tables are built / populated through the various builtin
-- sets currently available, as well as the dynamic scanning in jobmeta/promptmeta
	builtins = {},
	suggest = {},
	handlers = {},
	views = {},
	jobmeta = {},
	promptmeta = {},

-- properties exposed for other commands
	config = loadfile(string.format("%s/cat9/config/default.lua", lash.scriptdir))(),
	jobs = lash.jobs,
	timers = {},

	lastdir = "",
	laststr = "",
	resources = {}, -- used for clipboard and bchunk ops
	state = {export = {}, import = {}, orphan = {}},
	idcounter = 0, -- monotonic increment for each command dispatched
	visible = true,
	focused = true
}

if not cat9.config then
	table.insert(lash.messages, "cat9: error loading/parsing config/default.lua")
	return false
end

-- zero env out so our launch properties doesn't propagate
cat9.env["ARCAN_ARG"] = nil
cat9.env["ARCAN_CONNPATH"] = nil

-- all builtin commands are split out into a separate 'command-set' dir
-- in order to have interchangeable sets for expanding cli/argv of others
local safe_builtins
local safe_suggest
local safe_views
builtin_completion = {}

local function load_builtins(base)
	cat9.builtins = {}
	cat9.suggest = {}
	cat9.views = {}

	local fptr, msg = loadfile(string.format("%s/cat9/%s.lua", lash.scriptdir, base))

	if not fptr then
		cat9.add_message(string.format("builtin: [" .. base .. "] failed to load: %s", msg))
		return false
	end
	local set = fptr()

	for _,v in ipairs(set) do
		local fptr, msg = loadfile(string.format("%s/cat9/%s/%s", lash.scriptdir, base, v))

		if fptr then
			pcall(fptr(), cat9, lash.root, cat9.builtins, cat9.suggest, cat9.views)
		else
			cat9.add_message(string.format("builtin{%s:%s} failed to load: %s", base, v, msg))
			return false
		end
	end

-- force-inject loading builtin set so swapping works ok
	cat9.builtins["builtin"] =
	function(a)
		if not a or #a == 0 then
			a = "default"
			return
		end

		if not load_builtins(a) then
			cat9.add_message(string.format(
				"missing requested builtin set [%s] - revert to default.", a))
			cat9.builtins = safe_builtins
			cat9.suggest = safe_suggest
			cat9.views = safe_views
		end
	end

	builtin_completion = {}
	for k, _ in pairs(cat9.builtins) do
		table.insert(builtin_completion, k)
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

-- treat config overloading as injecting additional state
-- (builtin/config config =save/=load maps)
load_feature("misc.lua")    -- support functions that doesn't fit anywhere else
load_feature("ioh.lua")     -- event handlers for display server device/state io
load_feature("scanner.lua") -- running hidden jobs that collect information
load_feature("jobctl.lua")  -- processing / forwarding job input-output
load_feature("parse.lua")   -- breaking up a command-line into actions and suggestions
load_feature("layout.lua")  -- drawing screen, decorations and related handlers
load_feature("vt100.lua")   -- state machine to plugin decoding
load_feature("jobmeta.lua") -- job contextual information providers
load_feature("promptmeta.lua") --  prompt contextual information providers

-- use mouse-forward mode, implement our own selection / picking
load_builtins("default")
safe_builtins = cat9.builtins
safe_suggest = cat9.suggest

-- now that the builtins are available, load the ingoing state groups
if cat9.config.allow_state and cat9.handlers.state_in then
	lash.root:state_size(1 * 1024)
	local state = lash.root:fopen(lash.scriptdir .. "/cat9/config/state.lua", "r")
	if state then
		cat9.handlers.state_in(lash.root, state)
	end
end

cat9.config.readline.verify = cat9.readline_verify

lash.root:set_flags(tui.flags.mouse_full)
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
		cat9.redraw()
		cat9.dirty = false
	end

	root:refresh()
end

if cat9.config.allow_state then
	local state = root:fopen(lash.scriptdir .. "/cat9/config/state.lua", "w")
	if state then
		cat9.handlers.state_out(root, state)
		state:flush()
	end
end
