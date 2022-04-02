-- Description: Cat9 - reference user shell for Lash
-- License:     Unlicense
-- Reference:   https://github.com/letoram/cat9
-- See also:    HACKING.md

-- TODO (for first release)
--
--  Job Control:
--    [ ] 'on data' hook (trigger jobid data pattern trigger)
--    [ ] 'on finished' hook (trigger jobid ok trigger)
--    [ ] 'on failed' hook (trigger jobid errc trigger)
--
--  CLI help:
--    [ ] lastmsg queue rather than one-slot for important bits
--    [ ] track most used directories for execution and expose to cd h [set]
--
--  Data Processing:
--    [ ] Pipelined  |   implementation
--    [ ] Sequenced (a ; b ; c)
--    [ ] Conditionally sequenced (a && b && c)
--    [ ] Pipeline with MiM
--    [p] Copy command (job to clip, to file, to ..)
--
--  Exec:
--    [p] Open (media, handover exec to afsrv_decode)
--        [ ] .desktop like support for open, scanner for bin folders etc.
--        [ ]   -> autodetect arcan appl (lwa)
--        [ ]   -> state scratch folder (tar for state store/restore) + use with browser
--    [ ] arcan-net integration (scan, ...)
--    [ ] env control (env=bla in=#4) action_a | (env=bla2) action_b
--        should translate to "take the contents from job 4, map as input and run action_a)"
--    [ ] pattern expand from file glob
--
--  [ ] data dependent expand print:
--      [ ] hex
--      [ ] simplified 'in house' vt100
--
--  Ui:
--    [ ] view #jobid scroll n-step
--    [ ] view #jobid wrap
--    [ ] view #jobid unwrap
--    [ ] histogram viewing mode
--    [ ] job history scroll
--    [ ] alias
--    [ ] history / alias / config persistence
--    [ ] format string to prompt
--    [ ] format string to job-bar
--    [ ] keyboard job selected / stepping (escape out of readline)
--
--  Refactor:
--    [ ] split out wm-management
--    [ ] split out input handlers
--
local handlers   = {}   -- event handlers for window events
local rowtojob   = {}   -- for mouse selection, when a job is rendered its rows are registered
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
	autosuggest = true, -- start readline with tab completion enabled
	debug = true,

-- all clicks can also be bound as m1_header_index_click where index is the item group,
-- and the binding value will be handled just as typed (with csel substituted for cursor
-- position)
	m1_click = "view #csel toggle",
	m2_click = "open #csel tab hex",
	m3_click = "open #csel hex",

	hex_mode = "hex_detail_meta", -- hex, hex_detail hex_detail_meta
	content_offset = 1, -- columns to skip when drawing contents
	job_pad        = 1, -- space after job data and next job header
	collapsed_rows = 1, -- number of rows of contents to show when collapsed
	autoclear_empty = true, -- forget jobs without output

	open_spawn_default = "embed", -- split, tab, ...
	open_embed_collapsed_rows = 4,

	clipboard_job = true,     -- create a new job that absorbs all paste action

	readline =
	{
		cancellable   = true,   -- cancel removes readline until we starts typing
		forward_meta  = false,  -- don't need meta-keys, use default rl behaviour
		forward_paste = true,   -- ignore builtin paste behaviour
		forward_mouse = true,   -- needed for clicking outside the readline area
	}
}

local cat9 =  -- vtable for local support functions
{
	scanner = {}, -- state for asynch completion scanning
	env = {},
	builtins = {},
	suggest = {},

-- properties exposed for other commands
	config = config,
	jobs = lash.jobs,

	resources = {}, -- used for clipboard and bchunk ops

	visible = true,
	focused = true
}

local root = lash.root
local alive = true
local builtin_completions

-- all builtin commands are split out into a separate 'command-set' dir
-- in order to have interchangeable sets for expanding cli/argv of others
local function load_builtins(base)
	cat9.builtins = {}
	cat9.suggest = {}
	local fptr, msg = loadfile(lash.scriptdir .. "./cat9/" .. base)
	if not fptr then
		return false, msg
	end
	local init = fptr()
	init(cat9, root, cat9.builtins, cat9.suggest)

	builtin_completion = {}
	for k, _ in pairs(cat9.builtins) do
		table.insert(builtin_completion, k)
	end

	table.sort(builtin_completion)
end

local function load_feature(name)
	fptr, msg = loadfile(lash.scriptdir .. "./cat9/base/" .. name)
	if not fptr then
		return false, msg
	end
	local init = fptr()
	init(cat9, root)
end

function cat9.run_lut(cmd, tgt, lut, set)
	local i = 1
	while i and i <= #set do
		local opt = set[i]

		if type(opt) ~= "string" then
			lastmsg = string.format("view #job >...< %d argument invalid", i)
			return
		end

-- ignore invalid
		if not lut[opt] then
			i = i + 1
		else
			i = lut[opt](set, i, tgt)
		end
	end
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
	cat9.flag_dirty()
end

function handlers.visibility(self, visible, focus)
	cat9.visible = visible
	cat9.focused = focus
	cat9.redraw()
	cat9.flag_dirty()
end

-- these are accessible to the copy command via $res
function handlers.paste(self, str)
	if config.clipboard_job then
		if not cat9.clipboard_job then
			cat9.clipboard_job = cat9.import_job({short = "clipboard", raw = "clipboard [paste]"})
		end
		local job = cat9.clipboard_job

-- have the paste behave as line-buffered input
		if #str > 0 then
			for _,v in ipairs(string.split(str, "\n")) do
				job.data.bytecount = job.data.bytecount + #str
				job.data.linecount = job.data.linecount + 1
				table.insert(job.data, v .. "\n")
			end
		end

		cat9.redraw()
		cat9.flag_dirty()
	else
		cat9.readline:suggest({str}, "insert")
	end
end

--
-- two options for this, one is a prefill copy [$blobin] >test.id
-- and move cursor in there and prepare prompt (possibly save last / current line)
--
function handlers.bchunk_out(self, blob, id)
	if type(cat9.resources.bout) == "function" then
		cat9.resources.bout(id, blob)
	else
		cat9.add_message("request for outbound binary blob")
		cat9.resources.bout = {id, blob}
	end
end

function handlers.bchunk_in(self, blob, id)
	if type(cat9.resources.bin) == "function" then
		cat9.resources.bin(id, blob)
	else
		cat9.add_message("got incoming binary blob")
		cat9.resources.bin = {id, blob}
	end
end

function handlers.state_in(self, blob)
end

function handlers.state_out(self, blob)
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
	table.insert(res, "[" .. tostring(#cat9.activejobs) .. "]")

	if not cat9.focused then
		table.insert(res, wdstr)
		return res
	end

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
		if
			job.data_cache.rows == rows and
			job.data_cache.cols == cols and
			job.data_cache.view == job.view then
			return job.data_cache
		end
	end

	return job.view and job.view or {}
end

--
-- Draw the [metadata][command(short | raw)] interactable one-line 'titlebar'
--
local function draw_job_header(x, y, cols, rows, job)
	local hdrattr =
	{
		fc = job.bar_color,
		bc = job.bar_color
	}

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
		return "[" .. cat9.bytestr(job.data.bytecount) .. "]"
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
		local limit = (job.expanded > 0) and job.expanded or (rows - y - 2)

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

-- some cache event to block the event+resize propagation might be useful,
-- another detail here is that wrapping at smaller than width and offsetting
-- col anchor if the job has stdio tracked (to show both graphical and text
-- output which is kindof useful for testing / developing graphical apps)
		if job.wnd then
			limit = rows - y - 4
			job.wnd:hint(root,
			{
				anchor_row = y+1,
				anchor_col = x,
				max_rows = limit,
				max_cols = cols,
				hidden = false -- set if the job is actually out of view
			}
			)
		end

		return y + limit + 2
	end

-- save the currently drawn rows for a reverse mapping (mouse action)
	local ey = y + job.collapsed_rows
	local line = #job.data

	if job.wnd then
		job.wnd:hint(root,
		{
			anchor_row = y+1,
			max_rows = job.collapsed_rows,
			max_cols = cols,
			hidden = false -- set if the job is actually out of view
		}
		)
	end

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

-- priority:
-- alerts > active jobs > job history + scrolling offset
	local left = rows

-- walk active jobs and then jobs (not covered this frame) to figure out how many we fit
	local lst = {}
	local counter = (lastmsg ~= nil and 1 or 0)
	if cat9.readline then
		counter = counter + 1
	end

-- always put the active first
	local activejobs = cat9.activejobs
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

-- rough estimate for bars / log output etc.
function cat9.bytestr(count)
	if count <= 0 then
		return "No Data"
	end

	local kb = count / 1024
	if kb < 1024 then
		return "< 1 KiB"
	end

	local mb = kb / 1024
	if mb > 1024 then
		local gb = mb / 1024
		return string.format("[%.2f GiB]", gb)
	else
		return string.format("[%.2f MiB]", mb)
	end

	return string.format("[%.2f KiB]", kb)
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
-- first major use: $env
	local base = s[2][2]
	local split_i = string.find(base, "/")
	local split = ""

	if split_i then
		split = string.sub(base, split_i)
		base = string.sub(base, 1, split_i-1)
	end

	local env = root:getenv(base)
	if not env then
		env = cat9.env[base]
	end

	if env then
		table.insert(v, env .. split)
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
		end, config.readline)

	cat9.readline:set(laststr);
	cat9.readline:set_prompt(cat9.get_prompt())
	cat9.readline:set_history(lash.history)
	cat9.readline:suggest(config.autosuggest)
end

-- expected to return nil (block_reset) to fit in with expectations of builtins
function cat9.add_message(msg)
	lastmsg = msg
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

function cat9.flag_dirty()
	if cat9.readline then
		cat9.readline:set_prompt(cat9.get_prompt())
	end
	cat9.dirty = true
end

function cat9.remove_match(tbl, ent)
	for i, v in ipairs(tbl) do
		if v == ent then
			table.remove(tbl, i)
			return
		end
	end
end

load_feature("scanner.lua")
load_feature("jobctl.lua")
load_feature("parse.lua")

-- use mouse-forward mode, implement our own selection / picking
load_builtins("default.lua")
config.readline.verify = cat9.readline_verify

root:set_handlers(handlers)
cat9.reset()
cat9.update_lastdir()

-- import job-table and add whatever metadata we want to track
local old = lash.jobs
lash.jobs = {}
cat9.jobs = lash.jobs
for _, v in ipairs(old) do
	cat9.import_job(v)
end

cat9.dirty = true
while root:process() and alive do
	if (cat9.process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		cat9.flag_dirty()
	end

	if cat9.dirty then
		root:refresh()
	end
end
