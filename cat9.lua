-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md

-- TODO
--
--  Job Control:
--    [ ] 'on data' hook (alert jobid data pattern trigger)
--    [ ] 'on finished' hook (alert jobid ok trigger)
--    [ ] 'on failed' hook (alert jobid errc trigger)
--
--  CLI help:
--    [ ] lastmsg queue rather than one-slot for important bits
--    [ ] visibility/focus state into loop for prompt
--    [ ] .desktop like support for open, scanner for bin folders etc.
--
--  Data Processing:
--    [ ] Pipelined  |   implementation
--    [ ] Pipeline with MiM
--    [ ] Copy command (job to clip, to file, to ..)
--    [ ] Paste / drag and drop (add as 'job')
--        -> but mark it as something without data if bchunk (and just hold descriptor)
--  Exec:
--    [ ] exec with embed
--    [ ] Open (media, handover exec to afsrv_decode)
--        [ ]   -> autodetect arcan appl (lwa)
--        [ ]   -> state scratch folder (tar for state store/restore) +
--                 use with browser
--    [ ] arcan-net integration (scan, ...)
--    [ ] pty- exec (!...)
--    [ ] explicit exec (!! e.g. sh -c soft-expand rest)
--    [ ] controlling env per job env name key=val key=val, ...
--    [ ] pattern expand from file glob
--    [ ] nbio- import into popen arg+env
--
--  [ ] data dependent expand print:
--      [ ] hex
--      [ ] simplified 'in house' vt100
--
--  Ui:
--    [ ] expanded scroll
--    [ ] job history scroll
--    [ ] alias
--    [ ] history / alias / config persistence
--
--  Refactor:
--    [ ] split out builtins/cat9/helpers/... (lash.scriptdir / cat9 / ... )
--    [ ] separate out token parser and make it less ugly
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
	autosuggest = true, -- start readline with tab completion enabled
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

local cat9 =  -- vtable for local support functions
{
	scanner = {} -- state for asynch completion scanning
}
local root = lash.root
local alive = true

function builtins.cd(step)
	root:chdir(step)
	cat9.update_lastdir()
end

function suggest.cd(args, raw)
	if #args > 2 then
		lastmsg = "cd - too many arguments"
		return

	elseif #args < 1 then
		return
	end

-- the rules for generating / filtering a file/directory completion set is
-- rather nuanced and shareable so that is abstracted here.
--
-- returned 'path' is what we actually pass to find
-- prefix is what we actually need to add to the command for the value to be right
-- flt is what we need to strip from the returned results to show in the completion box
-- and offset is where to start in each result string to just present what's necessary
--
-- so a dance to get:
--
--    cd ../fo<tab>
--          lder1
--          lder2
--
-- instead of:
--   cd ../fo<tab>
--          ../folder1
--          ../folder2
--
-- and still comleting to:
--  cd ../folder1
--
-- for both / ../ ./ and implicit 'current directory'
--
	local path, prefix, flt, offset = cat9.file_completion(args[2])
	if cat9.scanner.active and cat9.scanner.active ~= path then
		cat9.stop_scanner()
	end

	if not cat9.scanner.active then
		cat9.set_scanner(
			{"/usr/bin/find", "find", path, "-maxdepth", "1", "-type", "d"},
			function(res)
				if res then
					cat9.scanner.last = res
					cat9.readline:suggest(
						cat9.prefix_filter(res, flt, offset),
						"substitute", "cd " .. prefix
					)
				end
			end
		)
	end

	if cat9.scanner.last then
		local suffix = args[2] and args[2] or ""
		cat9.readline:suggest(
			cat9.prefix_filter(cat9.scanner.last, flt, offset),
			"substitute", "cd " .. prefix
		)
	end
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
function(...)
	cat9.term_handover("join-r", ...)
end

builtins["v!"] =
function(...)
	cat9.term_handover("join-d", ...)
end

function builtins.config(key, val)
	if not key or not config[key] then
		lastmsg = "missing / unknown config key"
		return
	end

	if not val then
		lastmsg = "missing value to set for key " .. key
		return
	end

	local t = type(config[key])

	if t == "boolean" then
		if val == "true" or val == "1" then
			config[key] = true
		elseif val == "false" or val == "0" then
			config[key] = false
		else
			lastmsg = key .. " expects boolean (true | false)"
		end
	elseif t == "number" then
		local num = tonumber(val)
		if not num then
			lastmsg = " invalid number value"
		else
			config[key] = num
		end
	elseif t == "string" then
		config[key] = val
	end
end

function suggest.config(args, raw)
	if not cat9.config_cache then
		cat9.config_cache = {}
		for k,_ in pairs(config) do
			table.insert(cat9.config_cache, k)
		end
		table.sort(cat9.config_cache)
	end

	local set = cat9.config_cache

	if #args == 2 then
-- actually finished with the argument but hasn't begun on the next
		if string.sub(raw, #raw) == " " then
			local cfg = config[args[2]]
			lastmsg = cfg ~= nil and tostring(cfg) .. " (" .. type(cfg) .. ")" or ""
			set = {}
		else
			set = cat9.prefix_filter(cat9.config_cache, args[2])
		end
		cat9.readline:suggest(set, "word")
		return

	elseif #args == 1 then
		cat9.readline:suggest(set, "insert")
		return
	end

-- entering the value, just set the message to current/type
	if not config[args[2]] then
		lastmsg = "unknown key"
		return
	end

	local last = config[args[2]]
	lastmsg = tostring(last) .. " (" .. type(last) .. ")"
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

suggest["repeat"] =
function(arg, raw)
	local set = {}
	for _,v in ipairs(lash.jobs) do
		if not v.pid then
			table.insert(set, tostring(v.id))
		end
	end

	cat9.readline:suggest(set, "word")
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

	if type(file) == "table" and file.data then
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
-- this can only be done through handover,
-- some special sources: #.clip
	else
		trigger =
		function(wnd)
		end
		spawn = "new"
		return
	end

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
					lastmsg = "window request rejected"
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
	elseif v == "dnew" or v == "vnew" then
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
	local wdstr = "[ " .. (#lastdir == 0 and "/" or lastdir) .. " ]"
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
local ptable, ttable

local function build_ptable(t)
	ptable = {}
	ptable[t.OP_POUND  ] = {{t.NUMBER, t.STRING}, cat9.lookup_job} -- #sym -> [job]
	ptable[t.OP_RELADDR] = {t.STRING, cat9.lookup_res}
	ptable[t.SYMBOL    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.STRING    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.NUMBER    ] = {function(s, v) table.insert(v, tostring(s[1][2])); end}
	ptable[t.OP_NOT    ] = {function(s, v) table.insert(v, "!"); end}
	ptable[t.OP_MUL    ] = {function(s, v) table.insert(v, "*"); end}
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
		return _, msg
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

-- if there is a scanner running from completion, stop it
	if not suggest then
		cat9.stop_scanner()
	end

	return res
end

local last_count = 0
local function suggest_for_context(prefix, tok, types)
-- empty? just add builtins
	if #tok == 0 then
		cat9.readline:suggest(builtin_completion)
		return
	end

-- still in suggesting the initial command, use prefix to filter builtin
-- a better support script for this would be handy, i.e. prefix tree and
-- a cache on prefix string itself.
	if #tok == 1 and tok[1][1] == types.STRING then
		local set = cat9.prefix_filter(builtin_completion, prefix)
		if #set > 1 or (#set == 1 and #prefix < #set[1]) then
			cat9.readline:suggest(set)
			return
		end
	end

-- clear suggestion by default first
	cat9.readline:suggest({})
	local res, err = tokens_to_commands(tok, types, true)
	if not res then
		return
	end

-- these can be delivered asynchronously, entirely based on the command
-- also need to prefix filter the first part of the token ..
	if res[1] and suggest[res[1]] then
		suggest[res[1]](res, prefix)
	else
-- generic fallback? smosh whatever we find walking ., filter by taking
-- the prefix and step back to whitespace
	end
end

local function rl_verify(self, prefix, msg, suggest)
	if suggest then
		local tokens, msg, ofs, types = lash.tokenize_command(prefix, true)
		suggest_for_context(prefix, tokens, types)
	end

	laststr = msg
	local tokens, msg, ofs, types = lash.tokenize_command(msg, true)
	if msg then
		return ofs
	end
end

function cat9.lookup_job(s, v)
	local job = cat9.idtojob(s[2][2])
	if job then
		table.insert(v, job)
	else
		return "no job matching ID " .. s[2][2]
	end
end

function cat9.lookup_res(s, v)
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
	cat9.readline:suggest(config.autosuggest)
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
				if job.exit ~= 0 and not job.hidden then
					lastmsg = string.format("#%d failed, code: %d (%s)", job.id and job.id or 0, job.exit, job.raw)
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

	if not v.id and not v.hidden then
		v.id = idcounter
	end

	if v.id and idcounter <= v.id then
		idcounter = v.id + 1
	end

-- mark latest one as expanded, and the previously 'latest' back to collapsed
	if config.autoexpand_latest and not v.hidden then
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

-- nop right now, the value later is to allow certain symbols to expand with
-- data from job or other variable references, glob patterns being a typical
-- one. Returns 'false' if there is an error with the expansion
--
-- do that by just adding the 'on-complete' function into dst
function cat9.expand_arg(dst, str)
	return str
end

function cat9.term_handover(cmode, ...)
	local argtbl = {...}
	local argv = {}
	local env = {}

	local dynamic = false
	local runners = {}

	for _,v in ipairs(argtbl) do
		ok, msg = cat9.expand_arg(argv, v)
		if not ok then
			lastmsg = msg
			return
		elseif type(ok) == "function" then
			dynamic = true
		end
		table.insert(runners, ok)
	end

-- Dispatched when the queue of runners is empty - argv is passed in env
-- due to afsrv_terminal being used to implement the vt100 machine. This
-- is a fair point to migrate to another vt100 implementation.
	local run =
	function()
		env["ARCAN_TERMINAL_EXEC"] = table.concat(argv, "")
		root:new_window("handover",
		function(wnd, new)
			if not new then
				return
			end
			wnd:phandover("/usr/bin/afsrv_terminal", "", {}, env)
		end, cmode)
	end

-- Asynch-serialise - each runner is a function (or string) that, on finish,
-- appends arguments to argv and when there are no runners left - hands over
-- and executes. Even if the job can be resolved immediately (static) the same
-- code is reused to avoid further branching.
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
				lastmsg = err
			else
				ret.closure = step_job
			end
		end
	end

	step_job()
end

function cat9.flag_dirty()
	if cat9.readline then
		cat9.readline:set_prompt(cat9.get_prompt())
	end
	cat9.dirty = true
end

function cat9.prefix_filter(intbl, prefix, offset)
	local res = {}
	for _,v in ipairs(intbl) do
		if string.sub(v, 1, #prefix) == prefix then
			local str = v
			if offset then
				str = string.sub(v, offset)
			end
			if #str > 0 then
				table.insert(res, str)
			end
		end
	end

-- special case, we already have what we suggest, set to empty so the readline
-- implementation can autocommit on linefeed
	if #res == 1 then
		local sub = offset and string.sub(prefix, offset) or prefix
		if sub and sub == res[1] then
			return {}
		end
	end
	return res
end

-- This can be called either when invalidating an ongoing scanner by setting a
-- new, or cancelling ongoing scanning due to the results not being interesting
-- anymore. It does not actually stop immediately, but rather kill the related
-- process (if still alive) so the normal job management will flush it out.
function cat9.stop_scanner()
	if not cat9.scanner.active then
		return
	end

	if cat9.scanner.pid then
		root:psignal(cat9.scanner.pid, "kill")
		cat9.scanner.pid = nil
	end

	if cat9.scanner.closure then
		cat9.scanner.closure()
		cat9.scanner.closure = nil
	end

	cat9.scanner.active = nil
end

--
-- run [path (str | argtbl) and trigger closure with the dataset when completed.
-- should only be used for singleton short-lived, line-separated fast commands
-- used for tab completion
--
function cat9.set_scanner(path, closure)
	cat9.stop_scanner()

	local _, out, _, pid = root:popen(path, "r")

	if not pid then
		if config.debug then
			print("failed to spawn scanner job:", path)
		end
		return
	end

-- the pid will be wait():ed / killed as part of job control
	cat9.scanner.pid = pid
	cat9.scanner.closure = closure
	cat9.scanner.active = path

-- mark as hidden so it doesn't clutter the UI or consume job IDs but can still
-- re-use event triggers an asynch processing
	local job =
	{
		out = out,
		pid = pid,
		hidden = true,
	}

-- checking
	function job.closure()
		cat9.scanner.pid = nil
		if cat9.scanner.closure then
			cat9.scanner.closure(job.data)
		end
	end

	cat9.import_job(job)
	out:lf_strip(true)
end

-- calculate the suggestion- set parameters to account for absolute/relative/...
function cat9.file_completion(fn)
	local path   -- actual path to search
	local prefix -- prefix to filter from last path when applying completion
	local flt    -- prefix to filter away from result-set
	local offset -- add item to suggestion starting at offset after prefix match

-- args are #1 (cd) or #2 (cd <path>)
	if not fn or #fn == 0 then
		path = "./"
		prefix = ""
		flt = "./"
		offset = 3
		return path, prefix, flt, offset
	end

-- $env expansion not considered, neither is ~ at the moment
	local elements = string.split(fn, "/")
	local nelem = #elements

	path = table.concat(elements, "/", 1, nelem - 1)
	local ch = string.sub(fn, 1, 1)

-- explicit absolute
	if ch == '/' then
		offset = #path + 2
		if #elements == 2 then
			path = "/" .. path
		end
		prefix = path .. (#path > 1 and "/" or "")

		if nelem == 2 then
			flt = path .. elements[nelem]
		else
			flt = path .. "/" .. elements[nelem]
		end
		return path, prefix, flt, offset
	end

-- explicit relative
	if string.sub(fn, 1, 2) == "./" then
		offset = #path + 2
		prefix = path .. "/"
		flt = path .. "/" .. elements[nelem]
		return path, prefix, flt, offset
	end

	if string.sub(fn, 1, 3) == "../" then
		offset = #path + 2
		prefix = path .. "/"
		flt = path .. "/" .. elements[nelem]
		return path, prefix, flt, offset
	end

	prefix = path
	path = "./" .. path
	if nelem == 1 then
		flt = path .. elements[nelem]
		offset = #path + 1
	else
		flt = path .. "/" .. elements[nelem]
		prefix = prefix .. "/"
		offset = #path + 2
	end
	return path, prefix, flt, offset
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

-- this prevents the builtins from being part of a pipeline which might
-- not be desired - like cat something | process something | open @in vnew
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

cat9.dirty = true
while root:process() and alive do
	if (process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		cat9.flag_dirty()
	end

	if cat9.dirty then
		root:refresh()
	end
end
