-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md

-- TODO
--
--  Job Control:
--    [ ] completion oracle (default + command specific), asynch
--        e.g. for cd, find prefix -maxdepth 1 -type d
--
--    [ ] 'on data' hook (alert jobid data pattern trigger)
--    [ ] 'on finished' hook (alert jobid ok trigger)
--    [ ] 'on failed' hook (alert jobid errc trigger)
--
--  CLI help:
--    [ ] command- information message display on completion
--    [ ] lastmsg queue rather than one-slot
--    [ ] visibility/focus state into loop
--    [ ] alert / notifications
--
--  Data Processing:
--    [ ] Pipelined  |   implementation
--    [ ] Copy command (job to clip, to file, to ..)
--    [ ] Paste / drag and drop (add as 'job')
--        -> but mark it as something without data if bchunk (and just hold descriptor)
--
--  Exec:
--    [ ] exec with embed
--    [ ] handover exec with split
--    [ ] handover exec to vt100 (afsrv_terminal)
--    [ ] Open (media, handover exec to afsrv_decode)
--    [ ]   -> autodetect arcan appl (lwa)
--    [ ] pty- exec (!...)
--    [ ] explicit exec (!! e.g. sh -c soft-expand rest)
--    [ ] controlling env per job
--    [ ] pattern expand from file glob
--
--  [ ] data dependent expand print:
--      [ ] hex
--      [ ] simplified 'in house' vt100
--
--  [ ] expanded scroll
--  [ ] job history scroll
--  [ ] alias
--  [ ] history / alias persistence
--
local builtins   = {}   -- commands that we handle here
local suggest    = {}   -- resolve / helper functions for completion based on first command

local handlers   = {}   -- event handlers for window events

local rowtojob   = {}   -- for mouse selection, when a job is rendered its rows are registered
local activejobs = {}   -- distinguish between the shared lash.jobs and what is processing
local selectedjob = nil -- used for mouse-motion and cursor-selection

local lastdir = ""      -- cache for building prompt
local lastmsg = nil     -- command error result to show once
local laststr = ""      -- cached readline input in order to restore
local maxrows = 0       -- updated on job-completion, job action and window resize
local idcounter = 0     -- for referencing old outputs as part of pipeline/expansion

-- simpler toggles for dynamically controlling presentation
local config =
{
	autoexpand_latest = true,
	autoexpand_ratio  = 0.5,
	debug = true,

-- all clicks can also be bound as m1_header_index_click where index is the item group,
-- and the binding value will be handled just as typed (with csel substituted for cursor
-- position)
	m1_click = "view #csel out toggle",
	m2_click = "open #csel",
	m3_click = "open #csel hex",

	hex_mode = "hex_detail_meta", -- hex, hex_detail hex_detail_meta
	content_offset = 1, -- columns to skip when drawing contents
	job_pad        = 1, -- space after job data and next job header
	collapsed_rows = 1, -- number of rows of contents to show when collapsed
	autoclear_empty = true, -- forget jobs without output
}

local cat9 = {} -- vtable for local support functions
local root = lash.root
local alive = true

function builtins.cd(step)
	root:chdir(step)
	cat9.update_lastdir()
-- queue asynch cd / ls (and possibly thereafter inotify for new files)
end

local sigmsg = "[default:kill,hup,user1,user2,stop,quit,continue]"
local oksig = {
	kill = true,
	hup = true,
	user1 = true,
	user2 = true,
	stop  = true,
	quit = true,
	continue = true
}

-- alias for handover into vt100
builtins["!"] =
function(a, ...)
	root:new_window("handover",
	function(wnd, new)
		if not new then
			return
		end
		wnd:phandover("/usr/bin/afsrv_terminal", "", {}, {})
	end)
end

function builtins.forget(...)
	local forget =
	function(job, sig)
		local found
		for i,v in ipairs(lash.jobs) do
			if (type(job) == "number" and v.id == job) or v == job then
				job = v
				found = true
				table.remove(lash.jobs, i)
				break
			end
		end
-- kill the thing, can't remove it yet but mark it as hidden
		if found and job.pid then
			root:pkill(job.pid, sig)
			job.hidden = true
		end
	end

	local set = {...}
	local signal = "hup"
	local lastid
	local in_range = false

	for _, v in ipairs(set) do
		if type(v) == "table" then
			if in_range then
				in_range = false
				if lastid then
					local start = lastid+1
					for i=lastid,v.id do
						forget(i, signal)
					end
				end
			end
			lastid = v.id
			forget(v, signal)
		elseif type(v) == "string" then
			if v == ".." then
				in_range = true
			elseif v == "all" then
				while #lash.jobs > 0 do
					local item = table.remove(lash.jobs, 1)
					if item.pid then
						root:pkill(item.pid, signal)
						item.hidden = true
					end
				end
			else
				signal = v
			end
		end
	end
end

builtins["repeat"] =
function(job, cmd)
	if type(job) ~= "table" then
		lastmsg = "repeat >#jobid< [flush] missing job reference"
		return
	end

	if job.pid then
		lastmsg = "job still running, terminate/stop first (signal #jobid kill)"
		return
	end

	if not job["repeat"] then
		lastmsg = "job not repeatable"
		return
	end

	if cmd and type(cmd) == "string" then
		if cmd == "flush" then
			job:reset()
		end
	end

	job["repeat"](job)
end

function builtins.signal(job, sig)
	if not sig then
		lastmsg = string.format("signal (#jobid or pid) >signal< missing: %s", sigmsg)
		return
	end

	if type(sig) == "string" then
		if not oksig[sig] then
			lastmsg = string.format(
				"signal (#jobid or pid) >signal< unknown signal (%s) %s", sig, sigmsg)
			return
		end
	elseif type(sig) == "number" then
	else
		lastmsg = "signal (#jobid or pid) >signal< unexpected type (string or number)"
		return
	end

	local pid
	if type(job) == "table" then
		if not job.pid then
			lastmsg = "signal #jobid - job is not tied to a process"
			return
		end
		pid = job.pid
	elseif type(job) == "number" then
		pid = job
	else
		pid = tonumber(job)
		if not pid then
			lastmsg = "signal (#jobid or pid) - unexpected type (" .. type(job) .. ")"
			return
		end
	end

	root:psignal(pid, sig)
end

function builtins.open(file, ...)
	local trigger
	local opts = {...}
	local spawn = false

	if type(file) == "table" then
		trigger =
		function(wnd)
			local arg = {read_only = true}
			for _,v in ipairs(opts) do
				if v == "hex" then
					arg[config.hex_mode] = true
				end
			end
			wnd:revert()
			local buf = file.view == "out" and file.data or file.err_buffer
			buf = table.concat(buf, "")

			if not spawn then
				wnd:bufferview(buf, cat9.reset, arg)
			else
				wnd:bufferview(buf,
					function()
						wnd:close()
					end, arg
				)
			end
		end
	else
		lastmsg = "missing handover-exec-open"
		return
	end

	local spawn = false
	for _,v in ipairs(opts) do
		local opt = cat9.vl_to_dir(v)
		if opt then
			spawn = opt
		end
	end

	if spawn then
		root:new_window("tui",
			function(par, wnd)
				if not wnd then
					lastmsg  = "window request rejected"
					return
				end
				trigger(wnd)
			end, spawn
		)
		return false
	else
		cat9.readline = nil
		trigger(root)
		return true
	end
end

local view_hlp_str = "view #job output(out|err) [form=expand|collapse|toggle]"
function builtins.view(job, output, form)
	if type(job) ~= "table" then
		lastmsg = view_hlP_str
		return
	end

	if type(output) ~= "string" then
		lastmsg = view_hlp_str
		return
	end

-- draw_job when it creates the wrap buffer will take care of details
	if output == "out" or output == "stdout" then
		job.view = "out"
	elseif output == "err" or output == "stderr" then
		job.view = "err"
-- if not histogram tracking is enabled, we first need to build it
-- and the presentation is special
	elseif output == "histogram" then
	end

	if form and type(form) == "string" then
		if form == "expand" then
			job.expanded = -1
		elseif form == "collapse" then
			job.expanded = nil
		elseif form == "toggle" then
			if job.expanded then
				job.expanded = nil
			else
				job.expanded = -1
			end
		end
	end

	cat9.flag_dirty()
end

-- new window requests can add window hints on tabbing, sizing and positions,
-- those are rather annoying to write so have this alias table
function cat9.vl_to_dir(v)
	local spawn
	if v == "new" then
		spawn = "split"
	elseif v == "tnew" then
		spawn = "split-t"
	elseif v == "lnew" then
		spawn = "split-l"
	elseif v == "dnew" then
		spawn = "split-d"
	elseif v == "rnew" then
		spawn = "split-r"
	elseif v == "tab" then
		spawn = "tab"
	end
	return spawn
end

function builtins.copy(src, dst)
-- #job(l1,l2..l5) [clipboard, #jobid, ./file]
end

-- use for monotonic scrolling (drag+select on expanded?) and dynamic prompt
local clock = 10
function handlers.tick()
	clock = clock - 1

	if clock == 0 then
		cat9.flag_dirty()
		clock = 10
	end
end

function handlers.recolor()
	cat9.redraw()
end

function handlers.resized()
-- rebuild caches for wrapping, picking, ...
	local cols, _ = root:dimensions()

-- only rewrap job that is expanded and marked for wrap due to the cost
	for _, job in ipairs(lash.jobs) do
		job.line_cache = nil
	end

	rowtojob = {}
	cat9.redraw()
end

function handlers.key(self, sub, keysym, code, mods)
-- navigation key? otherwise feed into readline again
end

function handlers.utf8(self, ch)
-- setup readline, cancel current selection activity and inject ch
end

local mstate = {}
function handlers.mouse_motion(self, rel, x, y)
	if rel then
		return
	end

	local job = rowtojob[y]
	local cols, rows = root:dimensions()

-- deselect current unless the same
	if selectedjob then
		if job and selectedjob == job then
			return
		end

		selectedjob.selected = nil
		selectedjob = nil
		cat9.flag_dirty()

		return
	end

-- early out common case
	if not job then
		selectedjob = nil
		return
	end

-- select new
	job.selected = true
	selectedjob = job
	job.mouse_x = x
	cat9.flag_dirty()
end

function handlers.mouse_button(self, index, x, y, mods, active)
-- motion will update current selection so no need to do the lookup twice
	if not selectedjob then
		return
	end

-- track for drag
	if not active and mstate[index] then
		mstate[index] = nil
		local cols, _ = root:dimensions()

		local try =
		function(...)
			local str = string.format(...)
			if config[str] then
				cat9.parse_string(nil, config[str])
				return true
			end
		end

-- several possible 'on click' targets:
-- 'header', 'header-column-item group and data (expanded or not)
-- with a generic fallback for just any click
		if (
			try("m%d_header_%d_click", index, cat9.xy_to_hdr(x, y)) or
			(cat9.xy_to_data(x, y) ~= nil and try("m%d_data_click", index)) or
			try("m%d_click", index)) then
			return
		end

	elseif active then
		mstate[index] = active
	end
end

function cat9.get_prompt()
-- context sensitive information? (e.g. git check on cd, ...)
	local wdstr = "[ " .. lastdir .. " ]"
	local res = {}

-- only show if we have jobs going
	table.insert(res, tui.attr({bold = false, fc = tui.colors.label}))
	table.insert(res, "[" .. tostring(#activejobs) .. "]")

-- decent spot for some more analytics - is there a .git directory etc.
	table.insert(res, tui.attr({bold = false, fc = tui.colors.passive}))
	table.insert(res, os.date("[%H:%M:%S]"))
	table.insert(res, tui.attr({bold = false, fc = tui.colors.text}))
	table.insert(res, wdstr)
	table.insert(res, "$ ")

	return res
end

-- resolve a grid coordinate to the header of a job,
-- return the item header index (or -1 if these are not tracked)
function cat9.xy_to_hdr(x, y)
	local job = rowtojob[y]

	if not job then
		return
	end

	local id = -1
	if not job.hdr_to_id then
		return id, job
	end

	for i=1,#job.hdr_to_id do
		if x < job.hdr_to_id[i] then
			break
		end
		id = i
	end

	print(id, job)
	return id, job
end

function cat9.xy_to_data(x, y)
	local job = rowtojob[y]
	if job and y >= job.last_row then
		return job
	end
end

--
-- This takes a job that is to be presented 'expanded' and make sure that the
-- output follows wrapping rules. It should be rougly windowed so that the
-- output isn't much larger than the actual
--
local function get_wrapped_job(job, rows, col)
-- There can be (at least) two different content 'streams' to work with, the
-- main being [stdout] and [stderr]. Others would be the histogram (if enabled)
-- or an attachable post-process "filter" or the even more decadent 'MiM-pipe'
-- where each individual part of a pipeline would be observable.

	local cols, rows = root:dimensions()
	if job.data_cache then
		if job.data_cache.rows == rows and job.data_cache.cols == cols and job.data_cache.view == job.view then
			return job.data_cache
		end
	end

	if job.view == "err" then
		return job.err_buffer
	end

	return job.data
end

--
-- Draw the [metadata][command(short | raw)] interactable one-line 'titlebar'
--
local function draw_job_header(x, y, cols, rows, job)
	local hdrattr  = {fc = tui.colors.ui, bc = tui.colors.ui}

	if job.selected then
		hdrattr.fc = tui.colors.highlight
		hdrattr.bc = tui.colors.highlight
	end

	rowtojob[y] = job
	job.hdr_to_id = {}

	local hdr_exp_ch = function()
		return job.expanded and "[-]" or "[+]"
	end

	local id = function()
		return "[#" .. tostring(job.id) .. "]"
	end

	local pid_or_exit = function()
		local extid = -1
		if job.pid then
			extid = job.pid
		elseif job.exit then
			extid = job.exit
		end
		return "[" .. tostring(extid) .. "]"
	end

	local data = function()
		return string.format("[#%d:%d]", job.data.linecount, #job.err_buffer)
	end

	local memory_use = function()
		if job.data.bytecount > 0 then
			local kb = job.data.bytecount / 1024
			if kb > 1024 then
				local mb = kb / 1024
				if mb > 1024 then
					local gb = mb / 1024
					return string.format("[%.2f GiB]", gb)
				else
					return string.format("[%.2f MiB]", mb)
				end
			else
				return string.format("[%.2f KiB]", kb)
			end
		else
			return "[No Data]"
		end
	end

	local hdr_data = function()
		if cols - x > #job.raw then
			if cols - x > #job.dir + #job.raw then
				return job.dir .. "> " .. job.raw
			else
				return job.raw
			end
		else
			return job.short
		end
	end

-- This should really be populated by a format string in config
	local itemstack =
	{
		hdr_exp_ch,
		id,
		pid_or_exit,
		data,
		memory_use,
		hdr_data
	}

	for i,v in ipairs(itemstack) do
		if type(v) == "function" then
			v = v()
		end
		job.hdr_to_id[i] = x
		root:write_to(x, y, v, hdrattr)
		x = x + #v
	end
end

local function draw_job(x, y, cols, rows, job)
	local len = 0
	local dataattr = {fc = tui.colors.inactive, bc = tui.colors.background}
	draw_job_header(x, y, cols, rows, job)

	job.last_row = y
	job.last_col = x

--
-- Two ways of drawing the contents, expanded or collapsed.
--
-- Expanded tries to fill as much as possible (or up to a threshold) of
-- contents, respecting wrapping. Wrapping is difficult as the proper form has
-- contents/locale specific rules and should be reapplied when the wrap-width
-- is invalidated on a resize in order for 'scrollbar' like annotations to be
-- accurate.
--
-- A heuristic is needed - for a lower amount of lines (n < 1000 or so) the
-- wrapping can be recalculated each resize for job on expand/collapse. When
-- larger than that, having a sliding window of wrapped seems the best. Then
-- there are cases where you want compact (lots of empty linefeeds, ...)
-- presentation so no vertical space is wasted.
--
	if job.expanded then
		local limit = job.expanded > 0 and job.expanded or (rows - y)

-- draw as much as we can to fill screen, the wrapped_job is supposed to return
-- 'the right data' (multiple possible streams) wrapped based on contents and
-- window columns
		local lst = get_wrapped_job(job, limit, cols - config.content_offset)
		local lc = #lst
		local index = 1 -- + job.data_offset

		if lc - (index) > limit then
			limit = limit - 1
		else
			limit = lc - 1
		end

	-- drawing from the most recent to the least recent (within the window)
	-- adjusting for possible data-offset ('index')
		for i=limit,0,-1 do
			root:write_to(config.content_offset, y+i+1, lst[lc - (limit - i)], dataattr)
			rowtojob[y+i+1] = job
		end

		return y + limit + 2
	end

-- save the currently drawn rows for a reverse mapping (mouse action)
	local ey = y + job.collapsed_rows
	local line = #job.data

	for i=y,ey do
		rowtojob[i] = job
		if line > 0 and i > y then
			local len = root:utf8_len(job.data[line])
			root:write_to(1, i, job.data[line], dataattr)
			if len > cols then
				root:write_to(cols-3, i, "...")
			end
			line = line - 1
		end
	end

-- return the number of consumed rows to the renderer
	return y + job.collapsed_rows + 1
end

local draw_cookie = 0
function cat9.redraw()
	local cols, rows = root:dimensions()
	draw_cookie = draw_cookie + 1
	root:erase()

-- prority:
-- alerts > active jobs > job history + scrolling offset
	local left = rows

-- walk active jobs and then jobs (not covered this frame) to figure out how many we fit
	local lst = {}
	local counter = (lastmsg ~= nil and 1 or 0)
	if cat9.readline then
		counter = counter + 1
	end

-- always put the active first
	for i=#activejobs,1,-1 do
		if not activejobs[i].hidden then
			table.insert(lst, activejobs[i])
			counter = counter + activejobs[i].collapsed_rows
			activejobs[i].cookie = draw_cookie
		end
	end

-- then fill / pad with the others, don't duplicated aliased active/other jobs
	local jobs = lash.jobs
	for i=#jobs,1,-1 do
		if jobs[i].cookie ~= draw_cookie and not jobs[i].hidden then
			counter = counter + jobs[i].collapsed_rows
			table.insert(lst, jobs[i])
			jobs[i].cookie = draw_cookie
		end

-- but stop when we have overcommitted
		if counter > rows then
			break
		end
	end

-- reserve space for possible readline prompt and alert message
	local last_row = 0
	local reserved = (cat9.readline and 1 or 0) + (lastmsg and 1 or 0)

-- draw the jobs from bottom to top, this goes against the 'regular' prompt
-- starts top until filled then always stays bottom.

-- underflow? start from the top
	if counter < rows then
		for i=#lst,1,-1 do
			if not lst[i].hidden then
				last_row = draw_job(0, last_row, cols, rows - reserved, lst[i])
			end
		end
-- otherwise start drawing from the bottom
	else
		for _,v in ipairs(lst) do

		end
	end

-- add the last notification / warning
	if lastmsg then
		root:write_to(0, last_row, lastmsg)
		last_row = last_row + 1
	end

-- and the actual input / readline field
	if cat9.readline then
		cat9.readline:bounding_box(0, last_row, cols, last_row)
	end

-- update content-hint for scrollbars
end

local builtin_completion = {}
for k, _ in pairs(builtins) do
	table.insert(builtin_completion, k)
end
table.sort(builtin_completion)

--
-- Higher level parsing
--
--  take a stream of tokens from the lexer and use to build a command table
--  or a completion set helper where applicable (e.g. #<tab> job IDs)
--
-- Special token handling:
--
--  |  ->  set new destination table that grabs input from previous output
--  ;  ->  set new 'post job swap', when job is finished, take the next one
--  #  ->  set execution mode (vt100 by default, or next sym)
--  $  ->  set source address (next sym)
--

-- ptable
-- [OP_POUND, {SYMBOL, STRING}]
-- [SYMBOL,
-- [STRING,
-- [NUMBER]

local ptable, ttable

function cat9.lookup_job(s, v)
	local job = cat9.idtojob(s[2][2])
	if job then
		table.insert(v, job)
	else
		return "no job matching ID " .. s[2][2]
	end
end

local function build_ptable(t)
	ptable = {}
	ptable[t.OP_POUND] = {{t.SYMBOL, t.STRING, t.NUMBER}, cat9.lookup_job} -- #sym -> [job]
	ptable[t.SYMBOL  ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.STRING  ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.NUMBER  ] = {function(s, v) table.insert(v, tostring(s[1][2])); end}
	ptable[t.OP_NOT  ] = {function(s, v) table.insert(v, "!"); end}

	ttable = {}
	for k,v in pairs(t) do
		ttable[v] = k
	end
end

local function tokens_to_commands(tokens, types, suggest)
	local res = {}
	local cmd = nil
	local state = nil

	local fail = function(msg)
-- just parsing debugging
		if config.debug then
			local lst = ""
				for _,v in ipairs(tokens) do
					if v[1] == types.OPERATOR then
						lst = lst .. ttable[v[2]] .. " "
					else
						lst = lst .. ttable[v[1]] .. " "
					end
				end
				print(lst)
		end

		if not suggest then
			lastmsg = msg
		end
		return
	end

-- deferred building the product table as the type mapping isn't
-- known in beforehand the first time.
	if not ptable then
		build_ptable(types)
	end

-- just walk the sequence of the ptable until it reaches a consumer
	local ind = 1
	local seq = {}
	local ent = nil

	for _,v in ipairs(tokens) do
		local ttype = v[1] == types.OPERATOR and v[2] or v[1]
		local tdata = v[2]
		if not ent then
			ent = ptable[ttype]
			if not ent then
				return fail("token not supported")
			end
			table.insert(seq, v)
			ind = 1
		else
			local tgt = ent[ind]
-- multiple possible token types
			if type(tgt) == "table" then
				local found = false
				for _,v in ipairs(tgt) do
					if v == ttype then
						found = true
						break
					end
				end

				if not found then
					return fail("unexpected token in expression")
				end
				table.insert(seq, v)
	-- direct match, queue
			elseif tgt == ttype then
				table.insert(seq, v)
			else
				return fail("unexpected token in expression")
			end

			ind = ind + 1
		end

-- when the sequence progress to the execution function that
-- consumes the queue then reset the state tracking
		if type(ent[ind]) == "function" then
			local msg = ent[ind](seq, res)
			if msg then
				return fail(msg)
			end
			seq = {}
			ent = nil
		end
	end

	return res
end

local function suggest_for_context(tok, types)
	if #tok == 0 then
		cat9.readline:suggest(builtin_completion)
		return
	end

	cat9.readline:suggest({})
	local res = tokens_to_commands(tok, types, true)
	if not res then
		return
	end

-- these can be delivered asynchronously, entirely based on the command
-- also need to prefix filter the first part of the token ..
	if res[1] and suggest[res[1][1]] then
		suggest[res[1][1]]()
	end
end

local function rl_verify(self, prefix, msg, suggest)
	if suggest then
		local tokens, msg, ofs, types = lash.tokenize_command(prefix, true)
		suggest_for_context(tokens, types)
	end

	laststr = msg
	local tokens, msg, ofs, types = lash.tokenize_command(msg, true)
	if msg then
		return ofs
	end
end

function cat9.idtojob(id)
	if string.lower(id) == "csel" then
		return selectedjob
	end

	local num = tonumber(id)
	if not num then
		return
	end

-- with a large N here a lookup cache might be useful, (one-two elements)
-- as typing with verification will cause retoken-reparse on every input
	for _,v in ipairs(lash.jobs) do
		if v.id == num then
			return v
		end
	end
end

local readline_opts =
{
	forward_mouse = true,
	cancellable = true, -- cancel removes readline until we starts typing
	forward_meta = false,
	verify = rl_verify
}

function cat9.reset()
	root:revert()
	root:set_flags(tui.flags.mouse_full)

	cat9.readline = root:readline(
		function(self, line)
			local block_reset = cat9.parse_string(self, line)

-- ensure that we do not have duplicates, but keep the line as most recent
			if not lash.history[line] then
				lash.history[line] = true
			else
				for i=#lash.history,1,-1 do
					if lash.history[i] == line then
						table.remove(lash.history, i)
						break
					end
				end
			end
			table.insert(lash.history, 1, line)
			if not block_reset then
				cat9.reset()
			end
		end, readline_opts)

	cat9.readline:set(laststr);
	cat9.readline:set_prompt(cat9.get_prompt())
	cat9.readline:set_history(lash.history)
end

local function flush_job(job, finish, limit)
	local upd = false

-- stdout, slightly more involved to build histogram
	local outlim = limit
	local falive = true

	while outlim > 0 and (finish or falive) do
		outlim = outlim - 1
		_, falive = job.out:read(false,
		function(line, eof)
				if eof then
					outlim = 0
				end

				if config.histogram then
					for i=1,#line do
						local bv = string.byte(msg, i)
						local vl = job.data.histogram[bv]
						job.data.histogram[bv] = vl + 1
					end
				end

				job.data.linecount = job.data.linecount + 1
				if #line > 0 then
					job.data.bytecount = job.data.bytecount + #line
					table.insert(job.data, line)
				end
		end)

		if outlim > 0 then
			outlim = outlim - 1
		end
	end

-- stderr
	falive = true
	while job.err and falive do
		_, falive = job.err:read(false, job.err_buffer)
		if not finish then
			break
		end
	end

	return upd
end

local function process_jobs()
	local upd = false
	for i=#activejobs,1,-1 do
		local job = activejobs[i]
		local running, code = root:pwait(job.pid)
		if not running then
			job.exit = code

			if job.out then
				flush_job(job, true, 1)
				job.out:close()
				job.out = nil
				job.pid = nil
			end

-- allow whatever 'on completion' handler one might attach to trigger
			if job.closure then
				job:closure()
			end

-- avoid polluting output history with simple commands that succeeded and did
-- not return anything
			if config.autoclear_empty and job.data.bytecount == 0 then
				if job.exit ~= 0 then
					lastmsg = string.format("#%d failed, code: %d (%s)", job.id, job.exit, job.raw)
				end
				for i, v in ipairs(lash.jobs) do
					if v == job then
						table.remove(lash.jobs, i)
						break
					end
				end
			end

			table.remove(activejobs, i)
			upd = true

-- the '10' here should really be balanced against time and not a set amount of
-- reads / lines but the actual buffer sizes are up for question to balance
-- responsiveness of the shell vs throughput. If it is visible and in focus we
-- should perhaps allow more.
		elseif job.out then
			upd = flush_job(job, false, 10) or upd
		end
	end

	return upd
end

function cat9.update_lastdir()
	local wd = root:chdir()
	local path_limit = 8

	local dirs = string.split(wd, "/")
	local dir = "/"
	if #dirs then
		lastdir = dirs[#dirs]
	end
end

-- make sure the expected fields are in a job, used both when importing
-- from an outer context and when one has been created by parsing through
-- 'cat9.parse_string'.
function cat9.import_job(v)
	if not v.collapsed_rows then
		v.collapsed_rows = config.collapsed_rows
	end
	v.view = "out"
	v.reset =
	function(v)
		v.data = {
			bytecount = 0,
			linecount = 0,
			histogram = {}
		}
		for i=0,255 do
			v.data.histogram[i] = 0
		end
		v.err_buffer = {}
	end
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
	if v.pid then
		table.insert(activejobs, v)
	elseif not v.code then
		v.code = 0
	end
	if not v.id then
		v.id = idcounter
	end

	if idcounter <= v.id then
		idcounter = v.id + 1
	end

-- mark latest one as expanded, and the previously 'latest' back to collapsed
	if config.autoexpand_latest then
		if latestjob then
			latestjob.expanded = nil
			latestjob = v
		end
		latestjob = v

-- don't let latest 'fill' screen though, allocate a ratio
		local _, rows = root:dimensions()
		v.expanded = math.ceil(rows * config.autoexpand_ratio)
	end

	if v.out then
		v.out:lf_strip(false)
	end

	table.insert(lash.jobs, v)
end

function cat9.flag_dirty()
	if cat9.readline then
		cat9.readline:set_prompt(cat9.get_prompt())
	end
	cat9.dirty = true
end

function cat9.parse_string(rl, line)
	if rl then
		cat9.readline = nil
	end

	if not line or #line == 0 then
		return
	end

	laststr = ""
	local tokens, msg, ofs, types = lash.tokenize_command(line, true)
	if msg then
		lastmsg = msg
		return
	end
	lastmsg = nil

-- build job
	local commands = tokens_to_commands(tokens, types)
	if not commands or #commands == 0 then
		return
	end

-- this prevents the builtins from being part of a pipeline
-- is there a strong case for mixing the two?
	if builtins[commands[1]] then
		return builtins[commands[1]](unpack(commands, 2))
	end

-- could pick some other 'input' here, e.g.
-- .in:stdin .env:key1=env;key2=env mycmd $2 arg ..
	local lst = string.split(commands[1], "/")
	table.insert(commands, 2, lst[#lst])
	local _, outf, errf, pid = root:popen(commands, "re")
	if not pid then
		lastmsg = commands[1] .. " failed in " .. line
		return
	end

-- insert/spawn
	local job =
	{
		pid = pid,
		out = outf,
		err = errf,
		raw = line,
		err_buffer = {},
		dir = root:chdir(),
		short = lst[#lst],
	}

	job["repeat"] =
	function()
		if job.pid then
			return
		end
		_, job.out, job.err, job.pid = root:popen(commands, "re")
		if job.pid then
			table.insert(activejobs, job)
		end
	end

	cat9.import_job(job)
end

-- use mouse-forward mode, implement our own selection / picking
root:set_handlers(handlers)
cat9.reset()
cat9.update_lastdir()

-- import job-table and add whatever metadata we want to track
local old = lash.jobs
lash.jobs = {}
for _, v in ipairs(old) do
	cat9.import_job(v)
end

while root:process() and alive do
	if (process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		cat9.flag_dirty()
	end

	if cat9.dirty then
		root:refresh()
	end
end
