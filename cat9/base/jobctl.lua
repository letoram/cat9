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

local function drop_selection(job)
-- if this job holds focus, drop it and return to readline
	if cat9.selectedjob ~= job then
		return
	end

	cat9.selectedjob = nil
	if not cat9.readline then
		cat9.setup_readline(root)
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
		else
			_, falive =
			job.out:read(false,
				function(line, eof)
					upd = true
					if eof then
						outlim = 0
					end
					data_buffered(job, line, eof)
				end
				)
-- this form will just flush all buffered in once so no reason for limit
			if not finish then
				outlim = 0
			end
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

local function run_hook(job, a)
	local set = cat9.table_copy_shallow(job.hooks[a])
	for _,v in ipairs(set) do
		v()
	end
end

local function job_mm(job, x, y)
end

local function job_mb(job, ind, x, y, mods, active)
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
		drop_selection(job)
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
			if job.exit and job.exit ~= 0 and not job.hidden then
				cat9.add_message(
					string.format(
						"#%d failed, code: %d (%s)", job.id and job.id or 0, job.exit, job.raw
					)
				)
			end
			cat9.remove_job(job)
		end

-- otherwise switch to error output
		job.view = cat9.view_err
		job.bar_color = tui.colors.alert

-- and possibly add a cleanup timer, the [1] might be reconsiderable
		if #job.err_buffer <= 1 and config.autokill_quiet_bad > 0 then
			local cd = config.autokill_quiet_bad
			table.insert(cat9.timers, function()
				cd = cd - 1
				if cd > 0 then
					return true
				end
				cat9.remove_job(job)
			end)
		end
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

-- since the hooks might decide to modify the set, we need a local copy first
				if code == 0 and job.hooks.on_finish then
					run_hook(job, "on_finish")
				elseif code ~= 0 and job.hooks.on_fail then
					run_hook(job, "on_fail")
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

function cat9.setup_shell_job(args, mode, env)
	local inf, outf, errf, pid = root:popen(args, mode, env)
	if not pid then
		cat9.add_message(args[1] .. " failed in " .. line)
		return
	end

-- insert/spawn
	local job =
	{
		env = env,
		pid = pid,
		inp = inf,
		out = outf,
		err = errf,
		raw = line,
		args = args,
		mode = mode,
		err_buffer = {},
		inp_buffer = {},
		dir = root:chdir(),
		short = args[2],
	}

-- allow interactive / copy write into the job, track this as well so that
-- repeat will continue to repeat the input that gets sent to the job
	if inf then
		job.write =
		function(self, data)
			if type(data) == "table" then
				for _,v in ipairs(data) do
					table.insert(job.inp_buffer, v)
				end
			elseif type(data) == "string" then
				table.insert(job.inp_buffer, data)
			end
			inf:write(data)
		end
	end

	job["repeat"] =
	function(job, repeat_input)
		if job.pid then
			return
		end
		job.exit = nil
		job.inp, job.out, job.err, job.pid = root:popen(job.args, job.mode, job.env)
		if job.pid then
			table.insert(activejobs, job)
			if not job.hidden then
				cat9.activevisible = cat9.activevisible + 1
			end
		end
		if job.inp and repeat_input and #job.inp_buffer > 0 then
			job.inp:write(job.inp_buffer)
		end
	end

	cat9.import_job(job)

-- enable vt100
	if mode == "pty" and cat9.views["wrap"] then
		cat9.views["wrap"](job, false, {"cat9", "vt100"}, "")
	end

	return job
end

function cat9.term_handover(cmode, ...)
	local argtbl = {...}
	local argv = {}
	local env = {}
	local oldenv = cat9.table_copy_shallow(cat9.env)

-- don't want any of these to bleed through
	for k,v in pairs(oldenv) do
		if string.sub(k, 1, 5) ~= "ARCAN" then
			env[k] = v
		end
	end

	local open_mode = ""
	local embed = false

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
	local dir = root:chdir()
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
					out = out,
					env = env,
					dir = dir
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

	cat9.remove_match(cat9.timers, job)
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

	drop_selection(job)
	run_hook(job, "on_destroy")
	job.dead = true

-- if this job last, let the previous job autofill
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

local function raw_view(job, set, x, y, cols, rows, probe)
	set.linecount = set.linecount or 0
	local lc = set.linecount

-- on an empty :view() just return the dataset itself
	if not x or not cols or not rows then
		return set
	end

-- otherwise the amount of consumed rows
	if job.expanded then
		lc = lc > rows and rows or lc
	else
		lc = lc < job.collapsed_rows and lc or job.collapsed_rows
	end

-- and if we are probing, don't draw
	if probe then
		return lc
	end

-- the rows will naturally be capped to what we claimed to support
	local dataattr = config.styles.data
	local lineattr = config.styles.line_number
	local digits = #tostring(set.linecount)
	local ofs = job.row_offset

	if lc >= set.linecount then
		ofs = 0
	end

	for i=1,lc do
		local ind

-- apply offset as either an offset relative to end or absolute position
		if job.row_offset_relative then
			ind = set.linecount - lc + i + ofs
		else
			ind = ofs + i
		end

-- clamp
		if ind <= 0 then
			ind = i
		end

-- bad .data early out
		local row = set[ind]
		if not row then
			break
		end

		local cx = x + config.content_offset
		local ccols = cols

-- printing line numbers?
		if job.show_line_number then

-- left-justify
			local num = tostring(ind)
			if #num < digits then
				num = string.rep(" ", digits - #num) .. num
			end

			root:write_to(cx, y+i-1, num, lineattr)
			root:write(": ", lineattr)
			cx = cx + 3 + digits
			ccols = cols - digits - 4
		end

-- and apply column offset
		if job.col_offset > 0 and job.col_offset < #row then
			row = string.sub(row, job.col_offset + 1)
		end

		if #row > ccols then
			row = string.sub(row, 1, ccols)
		end
		root:write_to(cx, y+i-1, row, dataattr)
	end

	return lc
end

function cat9.view_raw(job, ...)
	return raw_view(job, job.data, ...)
end

function cat9.view_err(job, ...)
	job.err_buffer.linecount = #job.err_buffer
	return raw_view(job, job.err_buffer, ...)
end

-- create a job of job data based on a set of coordinate references (here, line-numbers)
local function slice_view(job, lines)
	local res =
	{
		linecount = 0,
		bytecount = 0
	}

	local data = job.data

	if job.view == cat9.view_err then
		data = job.err_buffer
	end

	if not lines or #lines == 0 then
		return data
	end

	for _,v in ipairs(lines) do
		local num = tonumber(v)
		if num then
			if data[num] then
				table.insert(res, data[num])
			end
		elseif type(v) == "string" then
			local set = string.split(v, "-")
			local err = "bad / malformed range"
			if #set ~= 2 then
				return nil, err
			end
			local a = tonumber(set[1])
			local b = tonumber(set[2])
			if not a or not b then
				return nil, err
			end
			local step = a > b and -1 or 1
			for i=a,b,step do
				if not data[i] then
					break
				end
				table.insert(res, data[i])
			end
		end

		res.linecount = res.linecount + 1
		res.bytecount = res.bytecount + #(res[#res])
	end

	return res
end

local function find_lowest_free()
	local lowest = 0
	for _,v in ipairs(lash.jobs) do
		if not v.hidden and v.id >= lowest then
			lowest = v.id + 1
		end
	end
	return lowest
end

-- make sure the expected fields are in a job, used both when importing from an
-- outer context and when one has been created by parsing through
-- 'cat9.parse_string'.
function cat9.import_job(v, noinsert)
	if not v.collapsed_rows then
		v.collapsed_rows = config.collapsed_rows
	end
	v.bar_color = tui.colors.ui
	v.row_offset = 0
	v.row_offset_relative = tru
	v.col_offset = 0
	v.job = true

-- save the CLI environment so it can be restored later (or when repeating)
	v.builtins = cat9.builtins
	v.views = cat9.views
	v.suggest = cat9.suggest

	v.show_line_number = config.show_line_number
	v.slice = slice_view
	v.region = {0, 0, 0, 0}

	if v.unbuffered == nil then
		v.unbuffered = false
	end

	if not v.env then
		v.env = root:getenv()
	end

	v.hooks =
	{
		on_destroy = {},
		on_finish = {},
		on_fail = {},
		on_data = {}
	}

	if not v.handlers then
		v.handlers =
		{
			mouse_motion = job_mm,
			mouse_button = job_mb,
		}
	end

	v.reset =
	function(v)
		v.wrap = true
		v.row_offset = 0
		v.col_offset = 0
		v.row_offset_relative = true
		v.data = {
			bytecount = 0,
			linecount = 0,
		}
		local oe = v.err_buffer

		v.err_buffer = {}
	end

	v.view = cat9.view_raw

	v.closure = {}
	if not v.data then
		v:reset()
	end

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

	if not noinsert and (v.pid or v.check_status) then
		table.insert(activejobs, v)
		if not v.hidden then
			cat9.activevisible = cat9.activevisible + 1
		end
	elseif not v.code then
		v.code = 0
	end

	if not v.id and not v.hidden then
		v.id = find_lowest_free()
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
		v.view = cat9.view_err
	end

	if not noinsert then
		table.insert(lash.jobs, v)
	end

-- but override view with any default
	if config.default_job_view and cat9.views[config.default_job_view] then
		cat9.views[config.default_job_view](v, false)
	end

	return v
end
end
