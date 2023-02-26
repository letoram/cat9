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
	aliases = {},
	bindings = {},

	config = loadfile(string.format("%s/cat9/config/config.lua", lash.scriptdir))(),
	jobs = lash.jobs,
	timers = {},

	resources = {}, -- used for clipboard and bchunk ops
	state = {export = {}, import = {}, orphan = {}},

	idcounter = 0, -- monotonic increment for each command dispatched
	lastdir = "",
	laststr = "",
	visible = true,
	focused = true,
	time = 0 -- monotonic tick
}

if not cat9.config then
	table.insert(lash.messages, "cat9: error loading/parsing config/default.lua")
	return false
end

-- avoid using the config.lua provided scanner argument as some might want to
-- switch that to fuzzy finder and similar tools
local function glob_builtins(dst)
	local arg =
	{
		"/usr/bin/env",
		"/usr/bin/env",
		"find",
		lash.scriptdir .. "cat9/",
		"-maxdepth", "1",
		"-type", "f"
	}
	local _, scan, _, pid = lash.root:popen(arg, "r", lash.root:getenv())

	if scan then
		scan:lf_strip(true)
			scan:data_handler(
			function()
				local msg, ok = scan:read()
				if msg then
					local base = string.match(msg, "[^/]*.lua$")
					local name = base and string.sub(base, 0, #base - 4) or nil
					if name == "default" then
						table.insert(dst, 1, name)
					else
						table.insert(dst, name)
					end
					return true
				end

				return ok
			end
		)
		lash.root:pwait(pid)
	end
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

local function load_builtins(base, flush)
	cat9.builtin_name = base
	if flush then
		cat9.builtins = {}
		cat9.suggest = {}
		cat9.views = {}
	end

-- first load / overlay any static user config
	if not cat9.config.builtins[base] then
		cat9.config.builtins[base] = {}
	end
	local dcfg = cat9.config.builtins[base]
	local fptr, msg = loadfile(string.format("%s/cat9/config/%s.lua", lash.scriptdir, base))
	if fptr then
		local ret, msg = pcall(fptr)
		if ret and type(msg) == "table" then
			for k,v in pairs(msg) do
				if not dcfg[k] then
					dcfg[k] = v
				end
			end
		else
			cat9.add_message(string.format("builtin: [%s] broken config: %s", base, msg))
		end
	end

-- then load the actual command-description
--
-- the base 'read-only' config is provided in the lash table rather than as argument due
-- to the legacy of the builtin- set expected to return a table and not a function as the
-- case is with the actual commands
  lash.builtin_cfg = dcfg
	local fptr, msg = loadfile(string.format("%s/cat9/%s.lua", lash.scriptdir, base))
	if not fptr then
		return false, string.format("builtin: [%s] failed to load: %s", base, msg)
	end

-- this can fail with an error message if there is some precondition that can't be
-- fulfilled such as a missing support tool binary
	local set = fptr()
	if type(set) ~= "table" then
		msg = type(set) == "string" and set or "unknown"
		return false, string.format( "builtin: [%s] failed to run: %s", base, msg)
	end

-- load each command and append to the builtins/suggestions/views/config
	for _,v in ipairs(set) do
		local fptr, msg = loadfile(string.format("%s/cat9/%s/%s", lash.scriptdir, base, v))
		if fptr then
			pcall(fptr(), cat9, lash.root, cat9.builtins, cat9.suggest, cat9.views, dcfg)
		else
			return false, string.format("builtin: [%s:%s] failed to load: %s", base, v, msg)
		end
	end

-- rescan builtins for the base command
	local set = {}
	glob_builtins(set)
	cat9.suggest["builtin"] =
	function(args, raw)
		if #args > 3 then
			cat9.add_message("builtin [set]: too many arguments")
			return
		elseif #args == 3 then
			set = {"nodef"}
		end

		cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
	end

-- force-inject loading builtin set so swapping works ok
	cat9.builtins["builtin"] =
	function(a, opt)
		if not a or #a == 0 then
			a = "system"
		end

-- We cache the one used initially so hot-reloading a bad new builtin set
-- won't actually break the previous one.
		local ok, msg
		local flush = false
		if opt then
			if opt ~= "nodef" then
				cat9.add_message("builtin [set] [nodef]: unknown option argument")
				return
			end
			flush = true
		else
			if a ~= "default" then
				load_builtins("default", true)
			end
		end
		ok, msg = load_builtins(a, flush)

		if not ok then
			local default = string.format(
				"missing requested builtin set [%s] - revert to system.", a)
			cat9.add_message(msg or default)
			cat9.builtins = safe_builtins
			cat9.builtin_name = "default"
			cat9.suggest = safe_suggest
			cat9.views = safe_views
		end
	end

	builtin_completion = {}
	for k, _ in pairs(cat9.builtins) do
		if string.sub(k, 1, 1) ~= "_" then
			table.insert(builtin_completion, k)
		end
	end
	table.sort(builtin_completion)

	return true
end

local function load_feature(name, base)
	base = base and base or "base"
	fptr, msg = loadfile(
		string.format("%s/cat9/%s/%s", lash.scriptdir, base, name))
	if not fptr then
		return false, msg
	end

	local init = fptr()
	init(cat9, lash.root, cat9.config)
end

-- treat config overloading as injecting additional state
-- (builtin/config config =save/=load maps)
function cat9.reload()
load_feature("misc.lua")    -- support functions that doesn't fit anywhere else
load_feature("ioh.lua")     -- event handlers for display server device/state io
load_feature("scanner.lua") -- running hidden jobs that collect information
load_feature("jobctl.lua")  -- processing / forwarding job input-output
load_feature("parse.lua")   -- breaking up a command-line into actions and suggestions
load_feature("layout.lua")  -- drawing screen, decorations and related handlers
load_feature("vt100.lua")   -- state machine to plugin decoding
load_feature("jobmeta.lua") -- job contextual information providers
load_feature("json.lua")    -- json parsing
load_feature("promptmeta.lua") --  prompt contextual information providers
load_feature("bindings.lua", "config")
load_builtins("default")
cat9.path_set = nil -- binary completion for exec is statically cached
safe_builtins = cat9.builtins
safe_suggest = cat9.suggest
safe_views = cat9.views
load_builtins("system")
end
cat9.reload()

-- now that the builtins are available, load the ingoing state groups
if cat9.config.allow_state and cat9.handlers.state_in then
	lash.root:state_size(1 * 1024)
	local state = lash.root:fopen(
		cat9.system_path("state") .. "/cat9_state.lua", "r")
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

-- make sure :revert() calls always cleans the readline state, this is enough
-- of an annoying thing to debug that this workaround is the least painful
-- option
local old_revert = lash.root.revert
lash.root.revert =
function(...)
	cat9.last_revert = debug.traceback()
	cat9.readline = nil
	return old_revert(...)
end

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

-- update config/state persistence, note that the tmp file and dest
-- need to be on the same filesystem for the atomic rename to work
if cat9.config.allow_state and cat9.handlers.state_out then
	local spath = cat9.system_path("state")
	root:chdir(spath)
	local tpath, tmp = cat9.mktemp(spath)

	if tmp then
		cat9.handlers.state_out(root, tmp, true)
		tmp:flush(-1)
		tmp:close()
		root:frename(tpath, spath .. "/cat9_state.lua")
		root:funlink(tpath)
	end
end
