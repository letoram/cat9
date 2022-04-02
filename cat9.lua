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
--    [ ] split out parser/dispatch
--    [ ] split out wm-management
--    [ ] split out input handlers
--    [ ] split out job control
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

-- properties exposed for other commands
	config = config,
	activejobs = activejobs,
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
	builtins = {}
	suggest = {}
	local fptr, msg = loadfile(lash.scriptdir .. "./cat9/" .. base)
	if not fptr then
		return false, msg
	end
	local init = fptr()
	init(cat9, root, builtins, suggest)

	builtin_completion = {}
	for k, _ in pairs(builtins) do
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
	table.insert(res, "[" .. tostring(#activejobs) .. "]")

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

--
-- Higher level parsing
--
--  take a stream of tokens from the lexer and use to build a command table
--  this is a fair place to add other forms of expansion, e.g. why[1..5].jpg or
--  why*.jpg.
--
local ptable, ttable

local function build_ptable(t)
	ptable = {}
	ptable[t.OP_POUND  ] = {{t.NUMBER, t.STRING}, cat9.lookup_job} -- #sym -> [job]
	ptable[t.OP_RELADDR] = {t.STRING, cat9.lookup_res}
	ptable[t.SYMBOL    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.STRING    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.NUMBER    ] = {function(s, v) table.insert(v, tostring(s[1][2])); end}
	ptable[t.OP_NOT    ] = {
	function(s, v)
		if #v > 0 and type(v[#v]) == "string" then
			v[#v] = v[#v] .. "!"
		else
			table.insert(v, "!");
		end
	end
	}
	ptable[t.OP_MUL    ] = {function(s, v) table.insert(v, "*"); end}

-- ( ... ) <- context properties (env, ...)
	ptable[t.OP_LPAR   ] = {
		function(s, v)
			if v.in_lpar then
				return "nesting ( prohibited"
			else
				v.in_lpar = #v
			end
		end
	}
	ptable[t.OP_RPAR  ] = {
		function(s, v)
			if not v.in_lpar then
				return "missing opening ("
			end
			local stop = #v
			local pargs =
			{
				types = t,
				parg = true
			}

-- slice out the arguments within (
			local start = v.in_lpar+1
			local ntc = (stop + 1) - start

			while ntc > 0 do
				local rem = table.remove(v, start)
				table.insert(pargs, rem)
				ntc = ntc - 1
			end
			table.insert(v, pargs)

			v.in_lpar = nil
		end
	}

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

function cat9.readline_verify(self, prefix, msg, suggest)
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

local function update_histogram(job, data)
	for i=1,#data do
		local bv = string.byte(data, i)
		local vl = job.data.histogram[bv]
		job.data.histogram[bv] = vl + 1
	end
end

local function data_buffered(job, line, eof)
	if config.histogram then
		update_histogram(job, line)
	end

	job.data.linecount = job.data.linecount + 1
	if #line > 0 then
		job.data.bytecount = job.data.bytecount + #line
		table.insert(job.data, line)
	end
end

local function data_unbuffered(job, line, eof)
	if config.histogram then
		update_histogram(job, line)
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
	while job.out and (outlim > 0 and (finish or falive)) do
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
					end
					data_buffered(job, line, eof)
				end
				)
			outlim = 0
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
				lastmsg = string.format(
				"#%d failed, code: %d (%s)", job.id and job.id or 0, job.exit, job.raw)
			end
			cat9.remove_job(job)
		end

-- otherwise switch to error output
		job.view = job.err_buffer
		job.bar_color = tui.colors.alert
	end
end

local function process_jobs()
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

	v.reset =
	function(v)
		v.wrap = true
		v.line_offset = 0
		v.data = {
			bytecount = 0,
			linecount = 0,
			histogram = {}
		}
		for i=0,255 do
			v.data.histogram[i] = 0
		end
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

function cat9.remove_job(job)
	local jc = #cat9.jobs

	cat9.remove_match(cat9.jobs, job)
	cat9.remove_match(cat9.activejobs, job)

	local found = jc ~= #cat9.jobs

	if cat9.latestjob ~= job then
		return found
	end

	cat9.latestjob = nil

	if not config.autoexpand_latest then
		return found
	end

	for i=#lash.jobs,1,-1 do
		if not lash.jobs[i].hidden then
			cat9.latestjob = lash.jobs[i]
			cat9.latestjob.expanded = -1
			break
		end
	end

	if cat9.clipboard_job == job then
		cat9.clipboard_job = nil
	end

	return found
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
	local open_mode = ""

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
			end
		end

-- more unpacking to be done here, especially overriding env
	end

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

			if #open_mode > 0 then
				local job =
				{
					pid = pid,
					inp = inp,
					err = err,
					out = out
				}
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
				lastmsg = err
			else
				ret.closure = {step_job}
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

function cat9.setup_shell_job(args, mode, envv)
-- could pick some other 'input' here, e.g.
-- .in:stdin .env:key1=env;key2=env mycmd $2 arg ..
	local inf, outf, errf, pid = root:popen(args, mode)
	if not pid then
		lastmsg = args[1] .. " failed in " .. line
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
		end
	end

	cat9.import_job(job)
	return job
end

function cat9.remove_match(tbl, ent)
	for i, v in ipairs(tbl) do
		if v == ent then
			table.remove(tbl, i)
			return
		end
	end
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

-- build job, special case !! as prefix for 'verbatim string'
	local commands
	if string.sub(line, 1, 2) == "!!" then
		commands = {"!!"}
		commands[2] = string.sub(line, 3)
	else
		commands = tokens_to_commands(tokens, types)
		if not commands or #commands == 0 then
			return
		end
	end

-- this prevents the builtins from being part of a pipeline which might
-- not be desired - like cat something | process something | open @in vnew
	if builtins[commands[1]] then
		return builtins[commands[1]](unpack(commands, 2))
	end

-- validation, all entries in commands should be strings now - otherwise the
-- data needs to be extracted as argument (with certain constraints on length,
-- ...)
	for _,v in ipairs(commands) do
		if type(v) ~= "string" then
			lastmsg = "parsing error in commands, non-string in argument list"
			return
		end
	end

-- throw in that awkward and uncivilised unixy 'application name' in argv
	local lst = string.split(commands[1], "/")
	table.insert(commands, 2, lst[#lst])

	local job = cat9.setup_shell_job(commands, "re")
	if job then
		job.raw = line
	end
end

load_feature("scanner.lua")
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
	if (process_jobs()) then
-- updating the current prompt will also cause the contents to redraw
		cat9.flag_dirty()
	end

	if cat9.dirty then
		root:refresh()
	end
end
