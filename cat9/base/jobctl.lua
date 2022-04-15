--
-- provides basic job controls for spawning, processing, ...
--
-- setup_shell_job(args, mode, [env]):
-- spin up a new process according to [args] (single sh -c friendly string or
-- complete argv table), creating/mapping pipe to the set specified in the
-- modestring (rwe, rw, re, wr) - or the special 'pty' for a legacy pseudoterm
-- device.
-- env is an optional key=value table that will be set as the new process
-- environment.
--
-- term_handover(cmode, ...) -> job:
-- asynchronously request a new window that gets bound to a legacy pseudoterm
-- device, with cmode controlling the window creation request (e.g. tab,
-- split-l, split-r, join-l, join-r). The variadic is expected to contain the
-- set of arguments as strings, with any tables being treated as parsing
-- options (e.g. 'err' to persist stderr).
--
-- remove_job(tbl):
-- unregister a job from being processed or drawn. iostreams won't be
-- closed immediately but deferred to garbage collection.
--
--
-- import_job(tbl) -> tbl:
--
-- take a job table and ensure that necessary fields are present or are
-- added.
--
-- process_jobs(): run periodically to pump/flush ingoing/outgoing buffers
--
return
function(cat9, root)

local activejobs = {}
local config = cat9.config
cat9.activejobs = activejobs
cat9.activevisible = 0

local function data_buffered(job, line, eof)
	for _,v in ipairs(job.hooks.on_data) do
		v(line, true, eof)
	end

	if job.block_buffer then
		return
	end

	job.data.linecount = job.data.linecount + 1
	if #line > 0 then
		job.data.bytecount = job.data.bytecount + #line
		table.insert(job.data, line)
	end
end

local function data_unbuffered(job, line, eof)
	for _,v in ipairs(job.hooks.on_data) do
		v(line, false, eof)
	end

	if job.block_buffer then
		return
	end

	local lst = line.split(line, "\n")
	if #lst == 1 then
		if #job.data == 0 then
			job.data[1] = ""
			job.data.linecount = 1
		end

		job.data.bytecount = job.data.bytecount + #lst
		job.data[#job.data] = job.data[#job.data] .. lst[1]
	else
		for _,v in ipairs(lst) do
			table.insert(job.data, v)
			job.data.linecount = job.data.linecount + 1
		end
	end
end

local function flush_job(job, finish, limit)
	local upd = false
	local outlim = limit
	local falive = true

-- cap to outlim number of read-calls (at most) or until feof
	while job.out and outlim > 0 and falive do
		if job.unbuffered then
			line, falive = job.out:read(true)
			if line then
				data_unbuffered(job, line)
				upd = true
				outlim = outlim - 1
			else
				outlim = 0
			end
-- this form will just flush all buffered in once so no reason for limit
		else
			_, falive =
			job.out:read(false,
				function(line, eof)
					upd = true
					if eof then
						outlim = 0
					else
						if not finish then
							outlim = outlim - 1
						end
					end
					data_buffered(job, line, eof)
				end
				)
		end
	end

-- stderr, always linebuffered and direct flush into - the outlim is to make
-- sure a dangling lock on the err-pipe won't have us spin forever
	outlim = finish and 1 or limit
	falive = true
	local count = #job.err_buffer
	while job.err and falive and outlim > 0 do
		_, falive = job.err:read(false, job.err_buffer)
		if #job.err_buffer == count then
			break
		end
		count = #job.err_buffer
		outlim = outlim - 1
	end

	return upd
end


local function finish_job(job, code)
	job.exit = code

	if job.wnd then
		job.wnd:close()
		job.wnd = nil
	end

	if job.out or job.err then
		flush_job(job, true, 1)

		if job.out then
			job.out:close()
			job.out = nil
		end

		if job.err then
			job.err:close()
			job.err = nil
		end

		job.pid = nil
	end

	if job.inp then
		job.inp:close()
		job.inp = nil
	end

-- allow whatever 'on completion' handler one might attach to trigger
	local set = job.closure
	job.closure = {}
	for _,v in ipairs(set) do
		v(job.id, code)
	end

-- avoid polluting output history with simple commands that succeeded or failed
-- without producing any output / explanation
	if config.autoclear_empty and job.data.bytecount == 0 then
		if #job.err_buffer == 0 then
			if job.exit ~= 0 and not job.hidden then
				cat9.add_message(
					string.format(
						"#%d failed, code: %d (%s)", job.id and job.id or 0, job.exit, job.raw
					)
				)
			end
			cat9.remove_job(job)
		end

-- otherwise switch to error output
		job.view = job.err_buffer
		job.bar_color = tui.colors.alert
	end
end

function cat9.process_jobs()
	local upd = false

	for i=#activejobs,1,-1 do
		local job = activejobs[i]

-- other jobs are tracked through separate timers/event handlers, only ext.
-- processes are intended to be polled right now
		if job.pid then
			local running, code = root:pwait(job.pid)
			if not running then
				upd = true

-- finish might remove the job, but that is if we autoclear, if not the entry
-- should be removed manually or jobs will 'ghost' away
				finish_job(job, code)
				if activejobs[i] == job then
					if not job.hidden then
						cat9.activevisible = cat9.activevisible - 1
					end
					table.remove(activejobs, i)
				end

-- the '10' here should really be balanced against time and not a set amount of
-- reads / lines but the actual buffer sizes are up for question to balance
-- responsiveness of the shell vs throughput. If it is visible and in focus we
-- should perhaps allow more.
			elseif job.out or job.err then
				upd = flush_job(job, false, 10) or upd
			end
		end
	end

	return upd
end

function cat9.setup_shell_job(args, mode, envv)
-- could pick some other 'input' here, e.g.
-- .in:stdin .env:key1=env;key2=env mycmd $2 arg ..
	local inf, outf, errf, pid = root:popen(args, mode)
	if not pid then
		cat9.add_message(args[1] .. " failed in " .. line)
		return
	end

-- insert/spawn
	local job =
	{
		pid = pid,
		inp = inf,
		out = outf,
		err = errf,
		raw = line,
		err_buffer = {},
		dir = root:chdir(),
		short = args[2],
	}

	job["repeat"] =
	function()
		if job.pid then
			return
		end
		job.inp, job.out, job.err, job.pid = root:popen(args, mode)
		if job.pid then
			table.insert(activejobs, job)
			if not job.hidden then
				cat9.activevisible = cat9.activevisible + 1
			end
		end
	end

	cat9.import_job(job)
	return job
end

function cat9.term_handover(cmode, ...)
	local argtbl = {...}
	local argv = {}
	local env = {}
	local open_mode = ""
	local embed = false

-- copy in global env
	for k,v in pairs(cat9.env) do
		env[k] = v
	end

-- any special !(a,b,c) options go here, this is tied to each | group,
	if type(argtbl[1]) == "table" then
		local t = table.remove(argtbl, 1)
		if not t.parg then
			cat9.add_message("spurious #job argument in subshell command")
			return
		end

		for _,v in ipairs(t) do
			if v == "err" then
				open_mode = "e"
			elseif v == "embed" then
				embed = true
				cmode = "embed"
			end
		end

-- more unpacking to be done here, especially overriding env
	end

	local dynamic = false
	local runners = {}

	for _,v in ipairs(argtbl) do
		ok, msg = cat9.expand_arg(argv, v)
		if not ok then
			cat9.add_message(msg)
			return
		end
		table.insert(runners, ok)
	end

-- Dispatched when the queue of runners is empty - argv is passed in env due to
-- afsrv_terminal being used to implement the vt100 machine. This is a fair
-- place to migrate to another vt100 implementation.
	local run =
	function()
		env["ARCAN_TERMINAL_EXEC"] = table.concat(argv, " ")
		if string.find(open_mode, "e") then
			env["ARCAN_ARG"] =
				env["ARCAN_ARG"] and (env["ARCAN_ARG"] .. ":keep_stderr") or "keep_stderr"
		end

		root:new_window("handover",
		function(wnd, new)
			if not new then
				return
			end

			local inp, out, err, pid =
				wnd:phandover("/usr/bin/afsrv_terminal", open_mode, {}, env)

			if #open_mode > 0 or embed then
				local job =
				{
					pid = pid,
					inp = inp,
					err = err,
					out = out
				}
				job.wnd = new
				cat9.import_job(job)
			end

		end, cmode)
	end

-- Asynch-serialise - each runner is a function (or string) that, on finish,
-- appends arguments to argv and when there are no runners left - hands over
-- and executes. Even if the job can be resolved immediately (static) the same
-- code is reused to avoid further branching.
--
-- This method should probably be generalised / moved in order to provide
-- sequenced jobs [ a ; b ; c ]
	local step_job
	step_job =
	function()
		if #runners == 0 then
			run()
			return
		end

		local job = table.remove(runners, 1)
		if type(job) == "string" then
			local res = string.gsub(job, "\"", "\\\"")
			table.insert(argv, res)
			step_job()
		else
			local ret, err = job()
			if not ret then
				cat9.add_message(err)
			else
				ret.closure = {step_job}
			end
		end
	end

	step_job()
end

function cat9.remove_job(job)
	local jc = #cat9.jobs

	cat9.remove_match(cat9.jobs, job)
	if cat9.remove_match(cat9.activejobs, job) and not job.hidden then
		cat9.activevisible = cat9.activevisible - 1
	end

	local found = jc ~= #cat9.jobs
	if not found then
		return false
	end

	cat9.latestjob = nil

	if cat9.clipboard_job == job then
		cat9.clipboard_job = nil
	end

	for _,v in ipairs(job.hooks.on_destroy) do
		v()
	end

	if cat9.latestjob ~= job or not config.autoexpand_latest then
		return true
	end

	for i=#lash.jobs,1,-1 do
		if not lash.jobs[i].hidden then
			cat9.latestjob = lash.jobs[i]
			cat9.latestjob.expanded = -1
			break
		end
	end

	return found
end

-- make sure the expected fields are in a job, used both when importing from an
-- outer context and when one has been created by parsing through
-- 'cat9.parse_string'.
function cat9.import_job(v)
	if not v.collapsed_rows then
		v.collapsed_rows = config.collapsed_rows
	end
	v.bar_color = tui.colors.ui
	v.line_offset = 0

	if v.unbuffered == nil then
		v.unbuffered = false
	end

	v.hooks =
	{
		on_destroy = {},
		on_finish = {},
		on_data = {}
	}

	v.reset =
	function(v)
		v.wrap = true
		v.line_offset = 0
		v.data = {
			bytecount = 0,
			linecount = 0,
		}
		local oe = v.err_buffer

		v.err_buffer = {}
		if v.view == oe then
			v.view = v.err_buffer
		else
			v.view = v.data
		end
	end

	v.closure = {}
	if not v.data then
		v:reset()
	end
	v.view = v.data
	if not v.cookie then
		v.cookie = 0
	end
	if not v.short then
		v.short = "(unknown)"
	end
	if not v.raw then
		v.raw = "(unknown)"
	end
	if not v.dir then
		v.dir = root:chdir()
	end
	if not v.pipe then
		v.pipe = {}
	end
-- track both as active (for processing) and part of the tracked
-- jobs (for reset and UI layouting)
	if v.pid or v.check_status then
		table.insert(activejobs, v)
		if not v.hidden then
			cat9.activevisible = cat9.activevisible + 1
		end
	elseif not v.code then
		v.code = 0
	end

	if not v.id and not v.hidden then
		v.id = cat9.idcounter
	end

	if v.id and cat9.idcounter <= v.id then
		cat9.idcounter = v.id + 1
	end

-- mark latest one as expanded, and the previously 'latest' back to collapsed
	if config.autoexpand_latest and not v.hidden then
		if cat9.latestjob then
			cat9.latestjob.expanded = nil
			cat9.latestjob = v
		end
		cat9.latestjob = v
		v.expanded = -1
	end

-- keep linefeeds, we strip ourselves
	if v.out then
		v.out:lf_strip(false)
	end

-- if no stdout was provided, but stderr was, set that as the default view
	if not v.out and v.err then
		v.view = v.err_buffer
	end

	table.insert(lash.jobs, v)
	return v
end

end
