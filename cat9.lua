-- Prototyping setup for Lash:
--
--  Job Control:
--    [ ] repeat jobid [flush]
--    [ ] forget jobid
--
--    [ ] completion oracle (default + command specific), asynch
--        e.g. for cd, find prefix -maxdepth 1 -type d
--
--    [ ] 'on data' hook (alert jobid data pattern trigger)
--    [ ] 'on finished' hook (alert jobid ok trigger)
--    [ ] 'on failed' hook (alert jobid errc trigger)
--
--  Data Processing:
--    [ ] Copy command
--    [ ] Paste / drag and drop (add as 'job')
--
--  Mouse:
--    [ ] button on header-click into config
--    [ ] button on data-click into config
--    [ ] button on expanded data-click into config
--
--  Exec:
--    [ ] exec with embed
--    [ ] handover exec with split
--    [ ] handover exec to vt100 (afsrv_terminal)
--    [ ] Open (media, handover exec to afsrv_decode)
--    [ ] pty- exec
--
--  [ ] data dependent expand print:
--      [ ] hex
--      [ ] simplified 'in house' vt100
--
--  [ ] expanded scroll
--  [ ] job history scroll
--
local builtins   = {}   -- commands that we handle here
local suggest    = {}   -- resolve / helper functions for completion based on first command

local handlers   = {}   -- event handlers for window events

local rowtojob   = {}   -- for mouse selection, when a job is rendered its rows are registered
local activejobs = {}   -- distinguish between the shared lash.jobs and what is processing
local selectedjob = nil -- used for mouse-motion and cursor-selection

local lastdir = ""      -- cache for building prompt
local lastmsg = nil     -- command error result to show once
local maxrows = 0       -- updated on job-completion, job action and window resize
local idcounter = 0     -- for referencing old outputs as part of pipeline/expansion

-- simpler toggles for dynamically controlling presentation
local config =
{
	autoexpand_latest = true,
}

local on_line, readline, get_prompt, redraw, reset

local alive = true

-- used with the prompt
local function update_lastdir()
	local wd = root:chdir()
	local path_limit = 8

	local dirs = string.split(wd, "/")
	local dir = "/"
	if #dirs then
		lastdir = dirs[#dirs]
	end
end
update_lastdir()

function builtins.cd(step)
	root:chdir(step)
	update_lastdir()
-- queue asynch cd / ls (and possibly thereafter inotify for new files)
end

function builtins.open(file)
-- file or ID?
end

function builtins.hopen(file)
-- just asynch window request + wrap around open
end

function builtins.vopen(file)
end

function builtins.stop(id)

end

function builtins.copy(src, dst)
end

-- use for monotonic scrolling (drag+select on expanded?) and dynamic prompt
local clock = 10
function handlers.tick()
	clock = clock - 1

	if clock == 0 then
		if readline then
			readline:set_prompt(get_prompt())
		end
		clock = 10
	end
end

function handlers.recolor()
	redraw()
end

function handlers.resized()
-- rebuild caches for wrapping, picking, ...
	local cols, _ = root:dimensions()
	maxrows = 0

-- only rewrap job that is expanded due to the cost
	for _, job in ipairs(lash.jobs) do
		job.line_cache = nil
		if job.expanded then
		else
			maxrows = maxrows + job.collapsed_rows
		end
	end

	rowtojob = {}
	redraw()
end

function handlers.key(self, sub, keysym, code, mods)
-- navigation key? otherwise feed into readline again
	print("key", keysym, tui.keysyms[keysym])
end

function handlers.utf8(self, ch)
-- setup readline, cancel current selection activity and inject ch
end

function handlers.mouse_motion(self, rel, col, row)
	if rel then
		return
	end

	local job = rowtojob[row]
	local cols, rows = root:dimensions()

-- deselect current
	if selectedjob then
		if job and selectedjob == job then
			return
		end

		selectedjob.selected = nil
		selectedjob = nil
		return
	end

-- early out common case
	if not job then
		return
	end

-- select new
	job.selected = true
	selectedjob = job
end

function handlers.mouse_button(self, index, x, y)
-- motion will update current selection so no need to do the lookup twice
	if not selectedjob then
		return
	end

-- might need to cache this as it is getting big, but bufferview currently
-- does not accept a table of strings doing the concat itself.
	local buffer = table.concat(selectedjob.data, "")
	root:revert()
	readline = nil
	root:bufferview(buffer, reset)
end

get_prompt =
function()
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

local function job_header(job, cols)

end

local function draw_job(x, y, cols, rows, job)
-- draw status: active? failed? ok? data fit? scrolling? selected?
-- job.exit? number of bytes of data?

-- titebar format should be a user-configurable string really
	local title = {}
	local len = 0
	local cx, cy = root:cursor_pos()

-- x + 0 : status indicator, do we have any icon glyph available or go with color?
--  (primary, secondary, background, text, cursor, altcursor, highlight, label,
--  warning, error, alert, inactive, reference, ui)
--
	local hdrattr  = {fc = tui.colors.ui, bc = tui.colors.ui}
	local dataattr = {fc = tui.colors.inactive, bc = tui.colors.inactive}

	if job.selected then
		hdrattr.fc = tui.colors.highlight
		hdrattr.bc = tui.colors.highlight
	end

	if job.pid then
		root:write_to(x, y, string.format("[%d:%d]", job.id, job.pid), hdrattr)
	else
		root:write_to(x, y, string.format("[%d:%d]", job.id, job.exit), hdrattr)
		if not job.selected then
			hdrattr.fc = tui.colors.inactive
			hdrattr.bc = tui.colors.inactive
		end
	end

-- this (and the contents) come from process-inf
	datastr = "[#" .. tostring(job.data.linecount) .. "]"

	if job.data.bytecount > 0 then
		local kb = job.data.bytecount / 1024
		if kb > 1024 then
			local mb = kb / 1024
			if mb > 1024 then
				local gb = mb / 1024
				datastr = datastr .. string.format("[%.2f GiB]", gb)
			else
				datastr = datastr .. string.format("[%.2f MiB]", mb)
			end
		else
			datastr = datastr .. string.format("[%.2f KiB]", kb)
		end
	end

	root:write(datastr, hdrattr)

-- if we can fit full, then write that otherwise go short.
	cx, cy = root:cursor_pos()
	if cols - cx > #job.raw then
		if cols - cx > #job.dir + #job.raw then
			root:write(job.dir .. "> " .. job.raw, hdrattr)
		else
			root:write(job.raw, hdrattr)
		end
	else
		root:write(job.short, hdrattr)
	end

	job.last_row = y
	job.last_col = x

	if job.expanded then
-- draw as much as we can to fill screen, this takes wrapping into account
-- up to a n threshold (due to the cost) - then we just switch expand
-- to bufferwnd mode.
		return y + job.collapsed_rows
	end

-- save the currently drawn rows for a reverse mapping (mouse action)
	local ey = y + job.collapsed_rows
	local line = #job.data

	for i=y,ey-1 do
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
	return y + job.collapsed_rows
end

local draw_cookie = 0
redraw =
function()
	local cols, rows = root:dimensions()
	draw_cookie = draw_cookie + 1
	root:erase()

-- prority:
-- alerts > active jobs > job history + scrolling offset

	local left = rows
	local margin = 0

	if lastmsg then
		margin = margin + 1
	end

-- walk active jobs and then jobs (not covered this frame) to figure out how many we fit
	local lst = {}
	local counter = (lastmsg ~= nil and 1 or 0)
	if readline then
		counter = counter + 1
	end

-- always put the active first
	for i=#activejobs,1,-1 do
		table.insert(lst, activejobs[i])
		counter = counter + activejobs[i].collapsed_rows
		activejobs[i].cookie = draw_cookie
	end

-- then fill / pad with the others
	local jobs = lash.jobs
	for i=#jobs,1,-1 do
		if jobs[i].cookie ~= draw_cookie then
			counter = counter + jobs[i].collapsed_rows
			table.insert(lst, jobs[i])
			jobs[i].cookie = draw_cookie
		end

-- but stop when we have overcommitted
		if counter > rows then
			break
		end
	end

	local last_row = 0

-- underflow? start from the top
	if counter < rows then
		for i=#lst,1,-1 do
			if not lst[i].hidden then
				last_row = draw_job(0, last_row, cols, rows, lst[i])
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
	if readline then
		readline:bounding_box(0, last_row, cols, last_row)
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
--  take a stream of tokens from the lexer and use to build a command table
--
-- Special token handling:
--
--  |  ->  set new destination table that grabs input from previous output
--  ;  ->  set new 'post job swap', when job is finished, take the next one
--  @  ->  next symbol/string is used to lookup a job by ID
--
local function tokens_to_commands(tokens, types)
	local res = {}
	local cmd = nil

	for _,v in ipairs(tokens) do
		if v[1] == types.SYMBOL or v[1] == types.STRING then
			if not cmd then
				local lst = string.split(v[2], "/")
				cmd = {v[2]}
			else
				table.insert(cmd, v[2])
			end
		elseif v[1] == types.NUMBER then
			table.insert(cmd, tostring(v[2]))

		elseif v[1] == types.OPERATOR then

-- queue subjob
			if v[2] == types.OP_PIPE then
				table.insert(res, cmd)
				cmd = nil

			elseif v[2] == types.OP_STATESEP then
				return res

			else

			end
		end
	end

	if cmd and #cmd > 0 then
		table.insert(res, cmd)
	end

	return res
end

local function suggest_for_context(tok, types)
	if #tok == 0 then
		readline:suggest(builtin_completion)
		return
	end

	readline:suggest({})
	local res = tokens_to_commands(tok, types)

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

	local tokens, msg, ofs, types = lash.tokenize_command(msg, true)
	if msg then
		return ofs
	end
end

local readline_opts =
{
	forward_mouse = true,
	verify = rl_verify
}

reset =
function()
	root:revert()
	readline = root:readline(
		function(...)
			on_line(...)
			reset()
		end, readline_opts)
	readline:set_prompt(get_prompt())
	readline:set_history(lash.history)
end

local function flush_job(job, linebuffer, limit)
	local upd = false
	while true do
		local msg, _, linef = job.out:read(linebuffer)
		if not msg or #msg == 0 then
			break
		end

-- Flush into job buffer, update job histogram, raw linecount and data counter.
		local lc = 0
		local n = #msg

		for i=1,n do
			local bv = string.byte(msg, i)
			local vl = job.data.histogram[bv]
			job.data.histogram[bv] = vl + 1
		end

		job.data.linecount = job.data.linecount + 1
		job.data.bytecount = job.data.bytecount + n
		table.insert(job.data, msg .. (linef and "\n" or ""))
		upd = true

-- Only read a certain amount of lines before returning, this is better handled
-- with a global timer to balance throughput and responsiveness
		if limit then
			limit = limit - 1
			if limit == 0 then
				break
			end
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
			if job.out then
				flush_job(job, true)
				job.exit = code
				job.pid = nil
			end

-- allow whatever 'on completion' handler one might attach to trigger
			if job.closure then
				job:closure()
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

-- make sure the expected fields are in a job, used both when importing
-- from an outer context and when one has been created in on_line
local function import_job(v)
	if not v.collapsed_rows then
		v.collapsed_rows = 2
	end
	if not v.data then
		local histogram = {}
		v.data =
		{
			bytecount = 0,
			histogram = histogram,
			linecount = 0
		}
		for i=0,255 do
			histogram[i] = 0
		end
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

	if idcounter < v.id then
		idcounter = v.id + 1
	end

	table.insert(lash.jobs, v)
end

on_line =
function(rl, line)
	readline = nil
	if not line or #line == 0 then
		return
	end

	local tokens, msg, ofs, types = lash.tokenize_command(line, true)
	if msg then
		lastmsg = msg
		return
	end

	if not lash.history[line] then
		lash.history[line] = true
		table.insert(lash.history, line)
	end

-- build job
	local commands = tokens_to_commands(tokens, types)
	if #commands == 0 then
		return
	end

-- this prevents the builtins from being part of a pipeline
-- is there a strong case for mixing the two?
	if builtins[commands[1][1]] then
		builtins[commands[1][1]](unpack(commands[1], 2))
		return
	end

-- could pick some other 'input' here, e.g.
-- .in:stdin .env:key1=env;key2=env mycmd $2 arg ..
	local lst = string.split(commands[1][1], "/")
	table.insert(commands[1], 2, lst[#lst])
	local _, outf, errf, pid = root:popen(commands[1], "r")
	if not pid then
		lastmsg = commands[1][1] .. " failed in " .. line
		return
	end

	outf:lf_strip(false)
-- insert/spawn
	local job =
	{
		pid = pid,
		out = outf,
		err = errf,
		raw = line,
		dir = root:chdir(),
		short = lst[#lst],
	}

	if #commands > 1 then
		print("FIXME: build pipeline of job")
	end

	import_job(job)
end

-- use mouse-forward mode, implement our own selection / picking
root:set_handlers(handlers)
root:set_flags(tui.flags.mouse_full)
reset()

-- import job-table and add whatever metadata we want to track
for _, v in ipairs(lash.jobs) do
	import_job(v)
end

while root:process() and alive do
	if (process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		if readline then
			readline:set_prompt(get_prompt())
		end
	end
	root:refresh()
end
