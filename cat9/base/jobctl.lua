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

local function default_factory(job, tbl)
-- if a number / boolean type is added to this table, make sure to
-- also update the typemap down by the import function
	local res =
	{
		id = job.id,
		alias = job.alias,
		unbuffered = job.unbuffered,
		factory_mode = job.factory_mode,
		dir = job.dir,
		raw = job.raw,
		short = job.short,

-- currently missing / complicated:
--  views, commands (need some id name to rebuild)
--  command-history
--  input-buffer
--  triggers
	}

-- flatten out env
	for k,v in pairs(job.env) do
		res["env_" .. k] = v
	end

-- same with args
	if job.args then
		for i,v in ipairs(job.args) do
			res["arg_" .. tostring(i)] = v
		end
	end

	return res
end

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

		job.data.bytecount = job.data.bytecount + #line
		job.data[#job.data] = job.data[#job.data] .. lst[1]
	else
		for _,v in ipairs(lst) do
			table.insert(job.data, v)
			job.data.linecount = job.data.linecount + 1
			job.data.bytecount = job.data.bytecount + #line
		end
	end

	cat9.flag_dirty(job)
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
				if not finish then
					outlim = outlim - 1
				end
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
					if not finish then
						outlim = outlim - 1
					end
					return outlim == 0
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
		if not finish then
			outlim = outlim - 1
		end
	end

	return upd
end

local function run_hook(job, a, ...)
	local set = cat9.table_copy_shallow(job.hooks[a])
	for _,v in ipairs(set) do
		v(...)
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

	run_hook(job, "on_closure", true)
		for _,v in ipairs(set) do
			v(job, code)
		end
	run_hook(job, "on_closure", false)

-- avoid polluting output history with simple commands that succeeded or failed
-- without producing any output / explanation or ones that have already been hidden
	if job.hidden then
		cat9.remove_job(job)

	elseif config.autoclear_empty and job.data.bytecount == 0 and not job.block_clear then
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

-- sweep commands,
-- map them to a popen call and when all are consumed, trigger the closure.
-- [cmdopt] specifies the options to the background job processing
-- [arg] is passed verbatim to the handler in the command set and to [closure]
-- which is called last.
function cat9.background_chain(commands, cmdopt, arg, closure)
	local run_command

-- regular chain runner, take the next command in question, setup runner
	run_command =
	function(tbl)
		if not tbl then
			closure(arg)
			return
		end
		local cmd = cat9.table_copy_shallow(tbl)
		table.insert(cmd, 1, "/usr/bin/env")
		table.insert(cmd, 1, "/usr/bin/env")
		local _, out, _, pid = root:popen(cmd, "r")
		cat9.add_background_job(out, pid, cmdopt,
		function(job, code)
			tbl.handler(job, arg, code)
			run_command(table.remove(commands))
		end)
	end

	run_command(table.remove(commands))
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
					if not job.protected then
						table.remove(activejobs, i)
					end
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

function
	cat9.setup_shell_job(args, mode, env, line, opts)
	local inf, outf, errf, pid
	opts = opts and opts or {}

	if not opts.passive then
		inf, outf, errf, pid = root:popen(args, mode, env)
		if not pid then
			cat9.add_message(args[1] .. " failed in " .. line)
			return
		end
	end

	local job = opts.job and opts.job or {}

-- insert/spawn
	job.env = env
	job.pid = pid
	job.inp = inf
	job.out = outf
	job.err = errf
	job.raw = line
	job.args = args
	job.mode = mode
	job.err_buffer = {}
	job.inp_buffer = {}
	job.short = args[2]

	if not job.dir then
		job.dir = root:chdir()
	end
	if not job.factory then
		job.factory = default_factory
	end

	local close
	if opts.close then
		close =
		function()
			job.inp:flush(100)
			job.inp:close()
			job.inp = nil
		end
	end

-- Allow interactive / copy write into the job, track this as well so that
-- repeat will continue to repeat the input that gets sent to the job.
	if inf then
		job.write =
		function(self, data, close)
			job.inp_buffer = {}
			if type(data) == "table" then
				if data.slice then
					data = data:slice()
				end
				for _,v in ipairs(data) do
					table.insert(job.inp_buffer, v)
				end
			elseif type(data) == "string" then
				table.insert(job.inp_buffer, data)
			end
			inf:write(job.inp_buffer, close and close or nil)
		end
		inf:flush()
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
			job.inp:write(job.inp_buffer, close and close or nil)
		end
	end

	cat9.import_job(job)

-- enable vt100
	if mode == "pty" and cat9.views["wrap"] then
		cat9.views["wrap"](job, false, {"cat9", "vt100"}, "")
	end

	return job
end

local function term_handover(mode, env, bin, ...)
	local argtbl = {...}

-- any special !(a,b,c) options go here, mainly embedding or wm open hint
-- more unpacking to be done here, especially overriding env
	local open_mode, cmode = cat9.misc_resolve_mode(argtbl, mode)
	if not open_mode then
		return
	end

-- some arguments may need to be resolved asynchronously, so sweep argv and
-- add to a list of runners that resolve into the final argv
	argv = {}
	local ok, err = cat9.expand_arg(argv, argtbl, {
		{[[\]], [[\\]]},
		{'"', '\\"'},
		{' ', '\\ '}
	})

	if not ok then
		cat9.add_message(err)
		return
	end

	local dir = root:chdir()
	local list = table.concat(argv, " ")

	env["ARCAN_TERMINAL_EXEC"] = list

	if string.find(open_mode, "e") then
			env["ARCAN_ARG"] =
				env["ARCAN_ARG"] and (env["ARCAN_ARG"] .. ":keep_stderr") or "keep_stderr"
		end

	cat9.shmif_handover(cmode, open_mode, bin, env, {})
end

function cat9.term_handover(cmode, ...)
	local env = {}
	local oldenv = cat9.table_copy_shallow(cat9.env)

-- don't want any of these to bleed through unless we open in lash mode
	for k,v in pairs(oldenv) do
		if string.sub(k, 1, 5) ~= "ARCAN" then
			env[k] = v
		end
	end

-- now we can toggle some afsrv_terminal args of our own, since this all
-- goes by quite quickly, keep_alive is useful so one can see that the
-- command/handover stage works

	env["ARCAN_ARG"] = "keep_alive"

	term_handover(cmode, env, "/usr/bin/afsrv_terminal", ...)
end

function cat9.shmif_handover(cmode, omode, bin, env, argv)
	local dir = root:chdir()
	cat9.new_window(root, "handover",
		function(wnd, new)
			if not new then
				return
			end
			wnd:chdir(dir)
			local inp, out, err, pid = wnd:phandover(bin, cmode, argv, env)

-- only create a job entry if we explicitly ask for one
			if #omode > 0 or cmode == "embed" then
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
		end, cmode
	)
end

function cat9.remove_job(job)
	local jc = #cat9.jobs

	if job.protected then
		return
	end

	cat9.remove_match(cat9.timers, job)
	cat9.remove_match(cat9.jobs, job)
	if cat9.remove_match(cat9.activejobs, job) and not job.hidden then
		cat9.activevisible = cat9.activevisible - 1
	end

	local found = jc ~= #cat9.jobs
	if not found then
		return false
	end

	if cat9.clipboard_job == job then
		cat9.clipboard_job = nil
	end

	if job.inp then
		job.inp:close()
		job.inp = nil
	end

	if job.out then
		job.out:close()
		job.out = nil
	end

	if job.err then
		job.err:close()
		job.err = nil
	end

	drop_selection(job)
	run_hook(job, "on_destroy")
	job.dead = true

-- if this job last, let the previous job autofill
	if cat9.latestjob ~= job then
		return true
	end

	cat9.latestjob = nil

	for i=#lash.jobs,1,-1 do
		if not lash.jobs[i].hidden then
			cat9.latestjob = lash.jobs[i]
			break
		end
	end

	if cat9.latestjob and config.autoexpand_latest then
		cat9.latestjob.expanded = true
	end

	return found
end

local function attr_lookup(job, set, i, pos, highlight)
	return highlight and config.styles.data_highlight or config.styles.data
end

local function raw_view(job, set, x, y, cols, rows, probe)
	set.linecount = set.linecount or 0
	local lc = set.linecount
	local root = job.root

-- and if we are probing, don't draw
	if probe then
		return lc
	end

-- the rows will naturally be capped to what we claimed to support
	local lineattr = config.styles.line_number
	local digits = #tostring(job.lineno_offset + set.linecount)
	local ofs = job.row_offset
	lc = lc > rows and rows or lc
	if lc >= set.linecount then
		ofs = 0
	end

	if job.mouse then
		job.mouse.on_row = false
		job.mouse.on_col = false
	end

	local base = ofs

	if job.row_offset_relative then
		base = set.linecount - lc + ofs
		if base <= 0 then
			job.row_offset = job.row_offset - base
			base = 1
		end
	end

-- clamp and adjust row_offset so we stay in data range
	if base <= 0 then
		base = 1
	end

	job.view_base = base

	if job.redraw then
		job:redraw(false, cat9.selectedjob == job)
	end

	for i=1,lc do
		local ind = base + i - 1

-- bad .data early out
		local row = set[ind]
		if not row then
			break
		end

-- apply column offset
		if job.col_offset > 0 and job.col_offset < #row then
			row = string.sub(row, job.col_offset + 1)
		end

		local cx = x + config.content_offset
		local ccols = cols

-- updated on motion
		local on_row = false
		if job.mouse and job.mouse[2] == y+i-1 then
			on_row = true
			job.mouse.on_row = ind
		end

-- printing line numbers?
		if job.show_line_number then
-- left-justify
			local num = string.lpad(tostring(job.lineno_offset + ind), digits)

-- set inverse attribute if mouse cursor is on top of it
			lineattr.inverse = job.mouse and
				                 on_row    and
				                 job.mouse[1] <= cx + 1 + digits

-- this changes the row width and the column lookup
			if on_row then
				job.mouse.on_col = (job.mouse[1] <= cx + 1 + digits + #row) and 2
--  and we might be on the first column
				if lineattr.inverse then
					job.mouse.on_col = 1
				end
			end

			root:write_to(cx, y+i-1, num, lineattr)
			root:write(": ", lineattr)
			cx = cx + 2 + digits
			ccols = cols - digits - 4
		else
			if on_row then
				job.mouse.on_col = job.mouse[1] <= cx + #row and 2
			end
		end

-- expanding tabs should go here, be configured per job and allow
-- shenanigans like tabstobs or other markers e.g. -->
--		row:gsub("\t", "  ")

		if #row > ccols then
			row = string.sub(row, 1, ccols)
		end

	-- some jobs override this to have different formatting for different
	-- offsets and not just 'per line attributes'
		if job.write_override then
			job:write_override(cx,
				y+i-1, row, set, ind, 0, job.selections[ind], ccols)
		else

-- finally print it, hightlight any manually selected lines
			root:write_to(cx, y+i-1, row,
				            job:attr_lookup(set, ind, 0, job.selections[ind]))
		end
	end

	return lc
end

function cat9.view_fmt_job(job, set, ...)
	return raw_view(job, set, ...)
end

function cat9.view_raw(job, ...)
	return raw_view(job, job.data, ...)
end

function cat9.view_err(job, ...)
	job.err_buffer.linecount = #job.err_buffer
	return raw_view(job, job.err_buffer, ...)
end

local function do_line(dst, v, lookup)
	local num = tonumber(v)
	if num then
		local line, bc, lc = lookup(num)
		if line then
			table.insert(dst, line)
			dst.bytecount = dst.bytecount + bc
			dst.linecount = dst.linecount + lc
		end
		return true
	end

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
		local line, bc, lc = lookup(i)
		if line then
			table.insert(dst, line)
			dst.bytecount = dst.bytecount + bc
			dst.linecount = dst.linecount + lc
		end
	end

	return true
end

function cat9.resolve_lines(job, dst, lines, lookup)
	dst.bytecount = dst.bytecount or 0
	dst.linecount = dst.linecount or 0

	if not lines or #lines == 0 then
		return lookup()
	end

	if not dst or not type(dst) == "table" then
		cat9.add_message("resolve_lines:invalid destination")
		return lookup()
	end

-- special case, grab the current picking selection
	if #lines == 1 and lines[1] == "sel" then
		local set = {}
		for k,v in pairs(job.selections) do
			table.insert(set, k)
		end
		table.sort(set)
		for i,v in ipairs(set) do
			local line, bc, lc = lookup(v)
			table.insert(dst, line)
			dst.bytecount = dst.bytecount + bc
			dst.linecount = dst.linecount + lc
		end
		return dst
	end

-- enumerate the set and pass through lookup
	for _, v in ipairs(lines) do

-- special case for nested (1,2,3)
		if string.find(v, ",") then
			for _, v in ipairs(string.split(v, ",")) do
				local ok, err = do_line(dst, v, lookup)
				if not ok then
					return false, err
				end
			end
		else
-- and regular processing for what is num or range as 1-5
			local ok, err = do_line(dst, v, lookup)
			if not ok then
				return nil, err
			end
		end
	end

	return dst
end

-- create a job of job data based on a set of coordinate references (here, line-numbers)
cat9.default_slice =
function(job, lines, set)
	local data = set or job.data
	local res =
	{
		bytecount = 0,
		linecount = 0
	}

-- fixme: if we are viewing historical data, the right buffer needs to be picked and
-- a buffer ID needs to be presented so higher level formats can cache correctly
	if job.view == cat9.view_err then
		data = job.err_buffer
	end

	return
	cat9.resolve_lines(
		job, res, lines,
		function(i)
			if not i then
				return data
			end
			if data[i] then
				return data[i], #data[i], 1
			else
				return nil, 0, 0
			end
		end)
end

local function find_lowest_free()
	local lowest = 0
	for _,v in ipairs(lash.jobs) do
		if v.id and v.id >= lowest then
			lowest = v.id + 1
		end
	end
	return lowest
end

cat9.state.export["jobs"] =
function()
	local res = {}

	for _,v in ipairs(lash.jobs) do
		if v.factory and v.factory_mode == "auto" or v.factory_mode == "manual" then
			table.insert(res, v:factory())
		end
	end

	return res
end

-- conversions based on field name for import
local typemap =
{
	id = tonumber,
	unbuffered = function(x) return x == "true"; end,
}

cat9.state.import["jobs"] =
function(intbl)
	local tbl =
	{
		env = {},
		args = {}
	}

	for k,v in pairs(intbl) do
		local pref = string.sub(k, 1, 4)
		if pref == "env_" then
			tbl.env[string.sub(k, 5)] = v
		elseif pref == "arg_" then
			tbl.args[tonumber(string.sub(k, 5))] = v
		else
			tbl[k] = typemap[k] and typemap[k](v) or v
		end
	end

-- To avoid ID conflicts, we either need to rewrite them or delete on
-- collision or inject a new one.
	if tbl.id then
		for i=1,#lash.jobs do
			if lash.jobs[i].id == tbl.id then
				tbl.id = nil
				break
			end
		end
	end

	local dir = root:chdir(tbl.dir)
	local job2 = cat9.setup_shell_job(
		tbl.args, tbl.mode, tbl.env, tbl.raw, {job = tbl,
		passive = tbl.factory_mode == "manual"}
	)

	root:chdir(dir)
end

function cat9.add_fglob_job(out, path, cbh)
	local ioh = root:fglob(path)
	if not ioh then
		cat9.add_message("fglob: " .. path " rejected")
		return
	end

	local job =
	{
		hidden = true,
		ioh = ioh
	}

	cat9.import_job(job)

	ioh:lf_strip(true, "\0")
	ioh:data_handler(
		function()
			local line, alive = ioh:read()
			while line do
				cbh(line)
				line, alive = ioh:read()
			end

			if not alive then
				cbh()
				cat9.remove_job(job)
			end
		end
	)

	return ioh
end

function cat9.new_window(root, kind, closure, mode)
-- similar to add_background_job, we want the job creation hook
-- to fire when it is a job -> closure -> new_window -> closure so
-- the original hook captures it
	local wndjob = { hidden = true }
	cat9.import_job(wndjob)

	root:new_window(kind,
		function(...)
			run_hook(wndjob, "on_closure", true)
			local ret = closure(...)
			run_hook(wndjob, "on_closure", false)
			cat9.remove_job(wndjob)
			return ret
		end, mode
	)
end

function cat9.add_background_job(out, pid, opts, closure)
	local job =
	{
		out = out,
		pid = pid,
		hidden = true
	}

	cat9.import_job(job)

-- import will reset this
	if opts.lf_strip then
		out:lf_strip(opts.lf_strip)
	end

	table.insert(job.closure, closure)
	return job
end

local function hide_job(job, show)
	if not job.hidden and not show then
		cat9.activevisible = cat9.activevisible - 1
		job.hidden = true
		cat9.flag_dirty()
	elseif job.hidden and show then
		job.hidden = false
		cat9.activevisible = cat9.activevisible + 1
		cat9.flag_dirty()
	end
end

local function view_set(job, view, slice, state, name)
	job.view = view
	job.view_state = state or {linecount = 0, bytecount = 0}
	if name then
		job.view_name = name
	elseif not job.view_name then
		job.view_name = "unknown"
	end
	job.selections = {}

	if slice then
		job.slice = slice
	elseif not job.slice then
		job.slice = cat9.default_slice
	end

	job.row_offset = 0
	job.col_offset = 0
	cat9.flag_dirty()
end

local function add_line(job, line)
	table.insert(job.data, line)
	job.data.linecount = job.data.linecount + 1
	job.data.bytecount = job.data.bytecount + #line
end

local counter = 0

function cat9.hook_import_job(closure)
	local old = cat9.import_hook
	cat9.import_hook = closure
	return old
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
	v.row_offset_relative = true
	v.col_offset = 0
	v.job = true
	v.hide = hide_job
	v.cursor = {0, 0, false} -- relative input cursor, last field is priority over mouse

	if not v.root then
		v.root = root
	end

	if not v.view_name then
		v.view_name = "unknown"
	end

	if not v.add_line then
		v.add_line = add_line
	end

	if not v.set_view then
		v.set_view = view_set
	end

	if not v.attr_lookup then
		v.attr_lookup = attr_lookup
	end

-- save the CLI environment so it can be restored later (or when repeating)
	v.builtins = cat9.builtins
	v.builtin_name = cat9.builtin_name
	v.views = cat9.views
	v.suggest = cat9.suggest

	v.show_line_number = config.show_line_number

	if not v.slice then
		v.slice = cat9.default_slice
	end

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
		on_data = {},
		on_closure = {}
	}

	if not v.handlers then
		v.handlers =
		{
			mouse_motion = job_mm,
			mouse_button = job_mb,
		}
	end

	local set_defaults =
	function()
		v.wrap = true
		v.exit = nil
		v.lineno_offset = 0
		v.row_offset = 0
		v.col_offset = 0
		v.view_base = 0
		v.row_offset_relative = true
		v.bar_color = tui.colors.ui
		v.view = cat9.view_raw
		v.selections = {}
		v.data = {
			bytecount = 0,
			linecount = 0,
		}
		local oe = v.err_buffer
		v.err_buffer = {
			bytecount = 0,
			linecount = 0
		}
	end
	set_defaults()

	if not v.reset then
		v.reset = set_defaults
	end

	v.view = cat9.view_raw

	v.closure = {}
	if not v.data then
	end

	if not v.cookie then
		v.cookie = 0
	end
	if not v.short then
		v.short = "(unknown)"
	end
	if not v.raw then
		v.raw = ""
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
	end

	if not v.id and not v.hidden then
		v.id = find_lowest_free()
	end

	counter = counter + 1
	v.monotonic_id = counter

-- mark latest one as expanded, and the previously 'latest' back to collapsed
	if not v.hidden then
		if config.autocontract_last and cat9.latestjob then
			cat9.latestjob.expanded = false
		end

		cat9.latestjob = v
		if not cat9.selectedjob or config.single_job then
			cat9.selectedjob = v
		end

		if config.autoexpand_latest then
			cat9.latestjob.expanded = true
		end
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

	if cat9.import_hook then
		cat9.import_hook(v)
	end

	return v
end
end
