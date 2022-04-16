--
-- this sets the window event handler for:
--  recolor, visibility, resized
--
-- exposes:
--   flag_dirty()    - contents have been updated (new data on jobs, ...)
--   redraw()        - clear grid and redraw contents
--   get_prompt()    - return a table of attributes/strings for the current prompt
--   id_to_job(id)   - resolve a numeric id (#1) to the corresponding job table
--   xy_to_job(x, y) - resolve the job at a specific coordinate
--   xy_to_hdr       - test if the specific xy hits a job on the job header bar
--   xy_to_data      - test if the specific xy hits a job in its data region
--
return function(cat9, root, config)

-- for mouse selection, when a job is rendered its rows are registered
local rowtojob   = {}
local handlers = cat9.handlers

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

function cat9.xy_to_job(x, y)
	return rowtojob[y]
end

function cat9.id_to_job(id)
	if string.lower(id) == "csel" then
		return cat9.selectedjob
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

local cjob
local job_helpers =
{
	["id"] = function() return tostring(cjob.id); end,
	["pid_or_exit"] = function()
		local extid = -1
		if cjob.pid then
			extid = cjob.pid
		elseif cjob.exit then
			extid = cjob.exit
		end
		return tostring(extid)
	end,
	["data"] = function() return string.format("%d:%d", cjob.data.linecount, #cjob.err_buffer); end,
	["memory_use"] = function() return cat9.bytestr(cjob.data.bytecount);	end,
	["dir"] = function() return cjob.dir; end,
	["full"] = function() return cjob.raw; end,
	["short"] = function() return cjob.short; end,
}

--
-- Draw the [metadata][command(short | raw)] interactable one-line 'titlebar'
--
local
function draw_job_header(x, y, cols, rows, job)
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

-- This should really be populated by a format string in config
	local job_key = job.expanded and "job_bar_expanded" or "job_bar_collapsed"
	if job.selected then
		job_key = "job_bar_selected"
	end

	local itemstack = config[job_key]
	if not itemstack then
		cat9.add_message("bad config: missing job_bar field: " .. job_key)
		return
	end

	local function draw_item(i, cur)
		job.hdr_to_id[i] = x
		root:write_to(x, y, cur, hdrattr)
		x = x + root:utf8_len(cur)
	end

	cjob = job
	for i,v in ipairs(itemstack) do
		if type(v) ~= "table" then
			cat9.add_message("bad config: malformed job_bar field: " .. job_key)
			return
		end
		local res = cat9.template_to_str(v, job_helpers)
-- each entry here is either plain-text string, a special string or hdrattr
		for _,w in ipairs(res) do
			if type(w) == "table" then
				hdrattr = w
			elseif type(w) == "string" then
				draw_item(i, w)
			else
				cat9.add_message("bad config: expected string ot table, not " .. type(w))
				return
			end
		end
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
		if type(lst) == "function" then
			local nc = lst(job, x, y + 1, cols, limit)
			for i=y+1,y+1+nc do
				rowtojob[i] = job
			end
			return y + nc + 2
		end

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

function cat9.get_prompt()
	local helpers =
	{
		lastdir =
		function()
			return #cat9.lastdir > 0 and cat9.lastdir or "/"
		end,
		jobs =
		function()
			return tostring(cat9.activevisible)
		end
	}

	local template = cat9.focused and config.prompt_focus or config.prompt
	local res = cat9.template_to_str(template, helpers)

	return res
end

local draw_cookie = 0
function cat9.redraw()
	local cols, rows = root:dimensions()
	draw_cookie = draw_cookie + 1
	root:erase()
	rowtojob = {}

-- priority:
-- alerts > active jobs > job history + scrolling offset
	local left = rows

-- walk active jobs and then jobs (not covered this frame) to figure out how many we fit
	local lst = {}
	local counter = (cat9.get_message(false) ~= nil and 1 or 0)
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
	local reserved = (cat9.readline and 1 or 0) + (cat9.get_message(false) and 1 or 0)

-- for multicolumn work, calculate the split - signal any PTYs accordingly
-- split jobs into columns and gtg

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
	if cat9.get_message(false) then
		root:write_to(0, last_row, cat9.get_message(false))
		last_row = last_row + 1
	end

-- and the actual input / readline field
	if cat9.readline then
		cat9.readline:bounding_box(0, last_row, cols, last_row)
	end

-- update content-hint for scrollbars
end

function cat9.flag_dirty()
	if cat9.readline then
		cat9.readline:set_prompt(cat9.get_prompt())
	end
	cat9.dirty = true
end

end
