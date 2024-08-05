return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- other useful extensions: 'github' tool
-- fossil should show timeline, chat, issues to inject into commit message, ...
--
-- show the active tagset and use them on commit.
--
-- for the 'chat' we need to figure out the database and have sqlite3
--     .find fslckout -> grab 'repository' from vvar;
--     SELECT fmime FROM chat WHERE msgid=%d
--     SELECT file FROM chat WHERE msgid=%d
--     SELECT xfrom FROM chat WHERE msgid=%d
--     SELECT julianday('now')/mtime FROM chat ORDER BY msgid LIMIT 1
--     SELECT msgid FROM chat ORDER BY msgid DESC LIMIT 1 OFFSET %d
--     PRAGMA secure_delete=ON
--     SELECT msgid, datetime(mtime), xfrom, xmsg, octet_length(file), fname, fmime, %s, lmtime FROM chat
--     SELECT msgid FROM chat WHERE mdel IS NOT true ORDER BY msgid DESC LIMIT 1 OFFSET %d (-msgid)
--
-- a viewer for .pikchr is also useful, can do that via export to SVG then media embed
--

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
local prompt_kvt =
{
	ADDED = "A:", CHANGED = "C:", EXTRA = "E:", MISSING = "M:", DELETED = "D:"
}

local function build_data()
	in_monitor.data = {linecount = 0, bytecount = 0}
	local promptstr = ""

	if in_monitor.fossil then
		local f = in_monitor.fossil
		local prompttbl = {}

		for k,v in pairs(prompt_kvt) do
			if f[k] and #f[k] > 0 then
				table.insert(prompttbl, v .. tostring(#f[k]))
			end
		end
		promptstr = string.format("Fossil(%s)", table.concat(prompttbl, " "))

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

		table.remove(set, #set)
	end

-- it is possible to have both SCMs active at once so need to scan
-- separately then join together into data and flag dirty accordingly
	job.got_fossil = got_fossil
	if got_fossil then
		if job.add_line then
			job:add_line("Fossil:")
		end
		scan_fossil_output()
	end

	job.got_git = got_git
	if got_git then
		if job.add_line then
			job:add_line("Git:")
		end
		scan_git_output()
	end

	if not got_fossil and not got_git then
		if job.add_line then
			job:add_line("No source control active")
		end
		if job.prompt then
			job.prompt = "dev.scm:none"
		end
	end

	cat9.flag_dirty(job)
end

local function drop_prompt()
	if not in_monitor or not in_monitor.prompt then
		return
	end

	local tgt_i
	for i=1,#config.prompt_focus do
		if config.prompt_focus[i] == update_prompt then
			tgt_i = i
			break
		end
	end

	if tgt_i then
		table.remove(config.prompt_focus, tgt_i-1) -- drop $begin
		table.remove(config.prompt_focus, tgt_i-1) -- drop update_prompt
		table.remove(config.prompt_focus, tgt_i-1) -- drop $end
	end

-- if we own the monitor, just clear it and the handles
	if not in_monitor.imported then
		cat9.dir_monitor[in_monitor] = nil
		in_monitor = nil
	else -- otherwise just remove the prompt tracking
		in_monitor.prompt = nil
	end
end

update_prompt =
function()
	if in_monitor then
		return in_monitor.prompt
	else
		return "dev:scm()"
	end
end

local function attach_prompt()
	local insert_ind

	for i,v in ipairs(config.prompt_focus) do
		if v == '$dynamic' then
			insert_ind = i
			break
		end
	end
	if not insert_ind then
		cat9.add_message("dev:scm prompt - config.prompt_focus lacks $dynamic slot")
	else
		table.insert(config.prompt_focus, insert_ind, "$begin")
		table.insert(config.prompt_focus, insert_ind+1, update_prompt)
		table.insert(config.prompt_focus, insert_ind+2, "$end")
		return true
	end
end

local function cmd_monitor(arg)
-- 'prompt' form
	local prompt = (arg and arg == "prompt") or nil

-- toggle prompt form on / off
	if in_monitor and in_monitor.prompt then
		if prompt then
			drop_prompt()
			return
		end
	end

-- necessary tracking: where we are
	local cdir = root:chdir()
	local job = {
		short = string.format("dev:scm monitor(%s)", cdir),
		raw = "dev:scm monitor",
		dir = cdir,
		check_status = function() return true; end,
		prompt = prompt
	}

-- find where in the prompt we can attach
	if prompt then
		if not attach_prompt() then
			return
		end

-- already got a monitor session, mark prompt as available
		if in_monitor then
			in_monitor.prompt = prompt
			return
		end

-- or import the job as a 'proper' one
	else
		if in_monitor then
			if in_monitor.imported then -- unless it already is
				return
			end

			job = in_monitor
		end

		cat9.import_job(job)
		job.imported = true
		table.insert(
			job.hooks.on_destroy,
			function()
				job.imported = false

				if not job.prompt then -- only release if we don't also have a prompt monitor
					in_monitor = nil
					cat9.dir_monitor[job] = nil
				end
			end
		)
	end

-- attach to directory changes and use it to trigger rescan
	cat9.dir_monitor[job] =
		function(new, old)
			job.dir = new
			refresh_monitor()
		end

	in_monitor = job
	refresh_monitor()
end

local cmds =
{
	monitor = cmd_monitor
}

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
