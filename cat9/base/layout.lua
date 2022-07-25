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

	rowtojob = {{width = cols, x = 0}}

	cat9.redraw()
end

local function inside(job, x, y)
	return
		x >= job.region[1] and y >= job.region[2] and
		x < job.region[3] and y < job.region[4]
end

function cat9.xy_to_job(x, y)
-- remember last job and check extents for that
-- if not, sweep all jobs and find the one with hit
	for i=#cat9.activejobs,1,-1 do
		local job = cat9.activejobs[i]
		if inside(job, x, y) then
			return job, x - job.region[1], y - job.region[2]
		end
	end

	for _, job in ipairs(cat9.jobs) do
		if inside(job, x, y) then
			return job, x - job.region[1], y - job.region[2]
		end
	end
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
	local job, col = cat9.xy_to_job(x, y)
	local id = -1

	if not job then
		return id, nil
	end

	if not job.hdr_to_id or not job.hdr_to_id.y or y ~= job.hdr_to_id.y then
		return id, job
	end

	for i=1,#job.hdr_to_id do
		if col < job.hdr_to_id[i] then
			break
		end
		id = i
	end

	return id, job
end

function cat9.xy_to_data(x, y)
	local job = cat9.xy_to_job(x, y)
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
-- at the specified location and constraints and the column-id
--
local
function draw_job_header(job, x, y, cols, rows, cc)
	local hdrattr =
	{
		fc = job.bar_color,
		bc = job.bar_color
	}

	local job_key = job.expanded and "job_bar_expanded" or "job_bar_collapsed"
	if job.selected then
		job_key = "job_bar_selected"
		hdrattr.fc = tui.colors.highlight
		hdrattr.bc = tui.colors.highlight
	end

	job.hdr_to_id = {}
	job.hdr_to_id.y = y
	job.last_key = job_key

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

local function rows_for_job(job, cols, rows)
	if job.wnd then
		if job.expanded then
			local _, rows = job.wnd:dimensions()
			return rows + 1
		end
		return config.open_embed_collapsed_rows + 1
	end

	if not job.expanded then
		rows = rows > job.collapsed_rows and job.collapsed_rows or rows
	end

	return job:view(0, 0, cols, rows, true) + 1
end

local function draw_job(job, x, y, cols, rows, cc)
	local rows = rows_for_job(job, cols, rows)
	local len = 0

	job.region = {x, y, x + cols, y}
	draw_job_header(job, x, y, cols, rows, cc)

	job.last_row = y
	job.last_col = x

	y = y + 1
	rows = rows - 1

--- some cache event to block the event+resize propagation might be useful,
-- another detail here is that wrapping at smaller than width and offsetting
-- col anchor if the job has stdio tracked (to show both graphical and text
-- output which is kindof useful for testing / developing graphical apps)
	if job.wnd then
		job.wnd:hint(root,
		{
			anchor_row = y,
			anchor_col = x,
			max_rows = rows - 1,
			max_cols = cols,
			hidden = false -- set if the job is actually out of view
		}
		)
		return rows
	end

-- the default 'raw' view is defined inside jobctl, cap rows
	if not job.expanded then
		rows = rows > job.collapsed_rows and job.collapsed_rows or rows
	end

-- the row to job can probably be ignored eventually by just tracking
-- visual set and scanning based on x, y, cols, rows
	local ay = job:view(x, y, cols, rows)
	job.region[4] = ay + y + 1

-- return the number of consumed rows to the renderer
	return ay + 1
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

-- walk set and draw from bottom up, remove items as consumed
local function
layout_column(set, x, maxy, cols, rows, cc)
	while #set > 0 do
		local job = set[1]
-- if there is no room to meaningfully expand, then just defer
-- to next column (if any)
		if job.expanded then
			if rows < job.collapsed_rows * 2 then
				break
			end
		else
			if rows < job.collapsed_rows + 1 then
				break
			end
		end
		table.remove(set, 1)

-- get the number of rows the job will consume given the set cap (probe)
		local pref = rows_for_job(job, cols, maxy - 1)
		maxy = maxy - pref

-- then set xy based on this and then move up with the padding
		local nc = draw_job(job, x, maxy, cols, pref, cc)
		rows = rows - nc - config.job_pad
		maxy = maxy - config.job_pad
	end
end

local draw_cookie = 0
function cat9.redraw()
	local cols, rows = root:dimensions()
	draw_cookie = draw_cookie + 1
	root:erase()

-- priority:
--
-- active jobs > (job history + scrolling offset)
--
--  might be useful sorting active jobs by alerts, and have a
--  toggle for history jobs to be considered 'always present'
--
-- calculate the column widths by having one 'main' that is wider then add
-- extra columns based on a fixed width for as many as we have,
-- and then expand the main to 'fill'
--
-- [main          ] [extra1] [extra2] [extra3 ]
-- [main                            ] [extra1 ]
--
-- these currently work with static boundaries rather then getting the width
-- from the contents itself - the current jobs and views do not cover current
-- maximum number of columns.
--
	local jobcols = 1
	local sidecol_w = config.min_column_width > 0 and config.min_column_width or 80
	local maincol_w = config.main_column_width > 0 and config.main_column_width or 80
	local left = cols - maincol_w

	if left > 0 then
		if left >= sidecol_w then
			jobcols = jobcols + math.floor(left / sidecol_w)
		end

		maincol_w = cols - ((jobcols - 1) * sidecol_w)
	else
		maincol_w = cols
	end

-- walk active jobs and then jobs (not covered this frame) to figure
-- out how many we fit at a maximum and add them to this lst
	local lst = {}

-- reserved ui area for command-line and other messages
	local message = cat9.get_message(false)
	local reserved = message and 1 or 0
	if cat9.readline then
		reserved = reserved + 1
	end

-- always put the active first
	local activejobs = cat9.activejobs
	for i=#activejobs,1,-1 do
		if not activejobs[i].hidden and activejobs[i].view then
			table.insert(lst, activejobs[i])
			activejobs[i].cookie = draw_cookie
		end
	end

	for i=#cat9.jobs,1,-1 do
		local job = cat9.jobs[i]
		if not job.hidden and job.cookie ~= draw_cookie and job.view then
			table.insert(lst, job)
		end
	end

-- quick pre-pass, do we not have enough jobs to even fill a single column?
-- might be a point in caching this and just re-evaluating on expand-toggle
-- or removal/introduction of more jobs.
	local maxcap = 0
	local simple = true
	for i=1,#lst do
		maxcap = maxcap + rows_for_job(lst[i], cols, rows) + config.job_pad
		if maxcap > rows then
			simple = false
			break
		end
	end

-- then we can draw single-column top-down and just early out, with
-- the detail that we have to step lst in reverse
	if simple or #lst == 1 then
		local last_row = 0

		local cy = 0
		for i=#lst,1,-1 do
			local job = lst[i]
			local nc = draw_job(job, 0, last_row, cols, rows - reserved - 1, 1)
			last_row = last_row + nc + config.job_pad
			rows = rows - nc - config.job_pad
		end

-- add the latest notification / warning, might be better to use either
-- the readline area (shrink with message) for this or a current-item
-- helper (missing syntax in readline, \t or something for sep. item + descr)
		if message and #message > 0 then
			cols, rows = root:dimensions()
			root:write_to(0, last_row, message)
			last_row = last_row + 1
		end

	-- and the actual input / readline field
		if cat9.readline then
			cat9.readline:bounding_box(0, last_row, cols, last_row)
			cat9.readline:set_prompt(cat9.get_prompt())
		end

		return
	end

-- bottom up and multicolumn
	layout_column(lst, 0, rows - reserved - 1, maincol_w, rows - reserved, 1)
	local cx = maincol_w

-- erase the region afterwards to protect against a bad view overstepping its region
	if jobcols > 1 then
		for i=2,jobcols do
			root:erase_region(cx, rows - reserved - 1, cx + maincol_w, rows - reserved)
			layout_column(lst,
				cx,
				rows - reserved - 1,
				sidecol_w,
				rows - reserved,
				i
			)
			cx = cx + sidecol_w

			if #lst == 0 then
				break
			end
		end
	end

	if message then
		root:write_to(0, rows - 2, message)
	end

	if cat9.readline then
		cat9.readline:bounding_box(0, rows - 1, cols, rows - 1)
		cat9.readline:set_prompt(cat9.get_prompt())
	end
end

function cat9.flag_dirty()
	if cat9.readline then
	end
	cat9.dirty = true
end

end
