return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- other useful extensions: 'github' tool
-- fossil should show timeline, chat, issues to inject into commit message, ...

local in_monitor
local config = cat9.config
local update_prompt

local function parse_fossil_changes(scan, mon, code)
	if mon ~= in_monitor then
		return
	end

	for i,v in ipairs(scan.data) do
		local ma, mb = string.find(v, "%s+")
		if ma and ma > 2 then
			local cat = string.sub(v, 1, ma-1)
			local path = string.sub(v, mb+1)

			if not mon.fossil[cat] then
				mon.fossil[cat] = {}
			end
			table.insert(mon.fossil[cat], path)
		end
	end
end

local function parse_fossil_stash(job, code)
end

-- take in_monitor.fossil / in_monitor.git and pack into .data
-- this is where we add per-line handlers as well
local function build_data()
	in_monitor.data = {linecount = 0, bytecount = 0}
	local promptstr = ""

	if in_monitor.fossil then
		local f = in_monitor.fossil

		promptstr =
			string.format(
				"Fossil(%d:%d:%d:%d:%d)",
					f.CHANGED and #f.CHANGED or 0,
					f.ADDED and #f.ADDED or 0,
					f.EXTRA and #f.EXTRA or 0,
					f.MISSING and #f.MISSING or 0,
					f.DELETED and #f.DELETED or 0
			)

		if not f.expanded then
			if in_monitor.add_line then
				in_monitor:add_line(string.format(
					"Fossil: Changed: %d, Added: %d, Extra: %d, Removed: %d, Missing: %d",
					f.CHANGED and #f.CHANGED or 0,
					f.ADDED and #f.ADDED or 0,
					f.EXTRA and #f.EXTRA or 0,
					f.MISSING and #f.MISSING or 0,
					f.DELETED and #f.DELETED or 0
				))
			end
		else

		end
	end

	if in_monitor.git then
	end

	if in_monitor.prompt then
		in_monitor.prompt = promptstr
	end
end

-- set of fossil external binary commands and their parsers that
-- is used to process the tracking table that is used to generate
-- the active view
local function scan_fossil_output()
	local commands =
	{
		{"fossil", "changes", "--differ", handler = parse_fossil_changes},
		{"fossil", "stash", "list", handler = parse_fossil_stash}
-- check stash
-- check extras
	}

	in_monitor.fossil = {}
	in_monitor.pending = in_monitor.pending + 1
	cat9.background_chain(commands, {lf_strip = true}, in_monitor,
		function(job)
			in_monitor.pending = in_monitor.pending - 1
			if in_monitor.pending == 0 then
				build_data(job)
				last_monitor = nil
			end
		end
	)
end

local function scan_git_output()
	-- git status -s -z with lf_strip = '\0'
	-- short format:
	-- XY PATH
	-- XY ORIG_PATH -> PATH
end

local function refresh_monitor()
	local job = in_monitor
	local set = string.split(in_monitor.dir, "/")
	local got_fossil, got_git
	job.data = {linecount = 0, bytecount = 0}
	job.pending = 0

	while #set > 0 do
		local base = table.concat(set, "/")

		if not got_fossil then
			local ok, _, _ = root:fstatus(base .. "/.fslckout")
			if ok then
				got_fossil = base
			end
		end

		if not got_git then
			ok, kind, _ = root:fstatus(base .. "/.git")
			if kind == "directory" then
				got_git = base
			end
		end
builtins.hint.scm = "Create a job tracking source-control state"

function suggest.scm(args, raw)
	if #args == 2 then
	end
end

function builtins.scm(cmd, ...)
	if cmd and cmds[cmd] then
		return cmds[cmd](...)
	end
end

end
