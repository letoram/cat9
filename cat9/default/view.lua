return
function(cat9, root, builtins, suggest)

local build_detach_handler =
	loadfile(string.format("%s/cat9/base/detach.lua", lash.scriptdir))()

local errors =
{
	bad_scroll_argument = "view #job scroll >...< : expected number"
}

builtins.hint["view"] = "Change job data view mode"
local viewlut = {hint = {}}

viewlut.hint.out = "Set STDOUT as view stream"
function viewlut.out(set, i, job)
	job.view = cat9.view_raw
	job.row_offset = 0
	job.col_offset = 0
	return i + 1
end

local function destroy_wnd(job)
	if job.root ~= lash.root then
		job.root:close()
		job.root = lash.root
	end

	job.redraw = job.detach_redraw
end

local function detach(job, mode)
	if job.root ~= root then
		job.hidden = false
		job.root:close()
		job.root = root
		return
	end

	local keep = cat9.config.detach_keep

	if type(mode) == "string" and mode == "soft" then
		keep = true
	end

	cat9.new_window(root, "tui",
		function(par, wnd)
			if not wnd then
				cat9.add_message("window request rejected")
				return
			end

			job.hidden = true
			if latestjob == job then
				latestjob = nil
			end

			if selectedjob == job then
				selectedjob = nil
			end

			job.detach_handlers = build_detach_handler(cat9, job)
			wnd:set_handlers(job.detach_handlers)
			job.root = wnd

-- handle job terminating versus window being destroyed
			job.detach_destroy = destroy_wnd
			job.detach_keep = keep

-- since the job is hidden layout will call it separately,
			table.insert(job.hooks.on_destroy, function()
				destroy_wnd(job)
			end
			)
			wnd:update_identity(job.name)

		end, "split")
end

viewlut.hint.select = "Toggle a line in the view as selected"
function viewlut.select(set, i, job)
	local ind = set[i+1]
	if type(ind) == "number" then
		job.selections[ind] = not job.selections[ind]
	end

	return i + 2
end

viewlut.hint.err = "Set STDERR as view stream"
function viewlut.err(set, i, job)
	job.view = cat9.view_err
	job.row_offset = 0
	job.col_offset = 0
	return i + 1
end

viewlut.hint.expand = "Set view output as expanded"
function viewlut.expand(set, i, job)
	job.expanded = true
	return i + 1
end

viewlut.hint.toggle = "Toggle view output between expanded and compact"
function viewlut.toggle(set, i, job)
	job.expanded = not job.expanded
	return i + 1
end

viewlut.hint.linenumber = "Toggle showing line number column"
function viewlut.linenumber(set, i, job)
	if set[2] then
		if set[2] == "on" then
			job.show_line_number = true
			return
		elseif set[2] == "off" then
			job.show_line_number = false
			return
		end
	end

	if job.show_line_number then
		job.show_line_number = false
	else
		job.show_line_number = true
	end
end

viewlut.hint.collapse = "Set view output as compact"
function viewlut.collapse(set, i, job)
	job.expanded = false
end

viewlut.hint.scroll = "Change view output starting offset"
function viewlut.scroll(set, i, job)
-- treat +n and -n
	local function is_rel(str)
		if not str then
			return false
		end
		local prefix = string.sub(str, 1, 1)
		return prefix == "+" or prefix == "-"
	end

	local page_bound = 1

	if set[2] == "page" then
		table.remove(set, 2)
		page_bound = job.region[4] - job.region[2] - 2
		page_bound = page_bound < 1 and 1 or page_bound

	elseif set[2] == "relative" then
		table.remove(set, 2)
		job.row_offset_relative = true
		job.row_offset = 0

	elseif set[2] == "absolute" then
		table.remove(set, 2)
		job.row_offset_relative = false
	end

	local row = cat9.opt_number(set, 2, 0) * page_bound
	local col = cat9.opt_number(set, 3, 0)

	sind = sind and sind or 0
	job.row_offset = job.row_offset + row
	job.col_offset = job.col_offset + col

-- clamp relative so we don't go outside actual data range
	if job.row_offset_relative and job.row_offset > 0 then
		job.row_offset = 0

	elseif not job.row_offset_relative and job.row_offset < 0 then
		job.row_offset = 0
	end

	cat9.flag_dirty(job)
end

local function view_monitor()
	for _,v in ipairs(lash.jobs) do
		if v.monitor then
			cat9.add_message("view >monitor< : output job already exists")
			return
		end
	end

	local job =
	{
		monitor = true,
		short = "Monitor: messages",
		raw = "Monitor: messages",
		check_status = function() return true; end
	}
	local job = cat9.import_job(job)
	local oldam = cat9.add_message
	local oldprint = print
	job.expanded = true

	print =
	function(...)
		local tbl = {...}
		local fmtstr = string.rep("%s\t", #tbl)
		for i,v in ipairs(tbl) do
			tbl[i] = tostring(v)
		end
		local msg = string.format(fmtstr, unpack(tbl))
		local lst = string.split(msg, "\n")
		for _,v in ipairs(lst) do
			table.insert(job.data, v)
			job.data.linecount = job.data.linecount + 1
		end
		cat9.flag_dirty()
	end
	cat9.add_message =
	function(msg)
		if msg == job.data[#job.data] then
			return
		end

		if type(msg) == "string" then
			if #msg == 0 then
			else
				table.insert(job.data, msg)
				job.data.linecount = job.data.linecount + 1
				job.data.bytecount = job.data.bytecount + #msg
			end
			cat9.flag_dirty()
		end
--		oldam(msg)
	end
	table.insert(job.hooks.on_destroy,
	function()
		print = oldprint
		cat9.add_message = oldam
	end)
	return
end

local function view_colour()
	local job =
	{
		short = "Colors",
		raw = "Monitor: colors",
		check_status = function() return true; end
	}
	local job = cat9.import_job(job)

-- just step through the colors and draw a line with their respective
-- labels
	local set = {
		"primary", "secondary", "background",
		"text", "cursor", "altcursor", "highlight",
		"label", "warning", "error", "alert", "inactive",
		"reference", "ui", "16", "17", "18", "19", "20",
		"21", "22", "23", "24", "25", "26", "27", "28",
		"29", "30", "31", "32"
	}

	job.view =
	function(job, x, y, cols, rows, probe)
		local lim = #set - 1 < rows and #set - 1 or rows
		if probe then
			return lim
		end

		for i=y,y+lim do
			local lbl = set[i-y+1]
			local col = tui.colors[lbl]
			if not col then
				col = tonumber(lbl)
			end
			local attr = {fc = col, bc = col}
			root:write_to(x, i, lbl, attr)
		end
		return lim
	end
end

function builtins.view(job, ...)
-- special case, assign messages and 'print' calls into a job
	if type(job) == "string" then
		if job == "monitor" then
			view_monitor()

-- help theming and testing viewing, jack in a coloriser for the data
-- and set a custom view handler for the task
		elseif job == "colour" or job == "color" then
			view_colour()
		end
		return
	end

	if type(job) ~= "table" or job.parg then
		cat9:add_message("view >jobid< - invalid job reference")
		return
	end

-- dynamically loaded views take precedence
	local arg = {...}
	local viewer = cat9.views[arg[1]]
	if viewer then
		viewer(job, false, arg)
	end

-- special case the detach as run_lut etc. is designed for and or, .. like filters
	if type(arg[1]) == "string" and arg[1] == "detach" then
		detach(job, arg[2])
		cat9.flag_dirty(job)
		return
	end

	if type(arg[1]) == "string" and arg[1] == "select" then
		cat9.selectedjob = job
		cat9.flag_dirty(job)
	end

	cat9.run_lut("view #job", job, viewlut, arg)
	cat9.flag_dirty()
end

function suggest.view(args, raw)
	if #raw == 4 then
		return
	end

	if #args <= 2 then
		local set = {"monitor", "color"}
		set.hint = {
			"Capture command messages and print() calls into a job",
			"Show a colour swatch of the current scheme"
		}

-- the views are factory functions that provide suggestions or modify
-- job to attach a custom viewer
		cat9.add_job_suggestions(set, false)
		cat9.readline:suggest(cat9.prefix_filter(set, string.sub(raw, 6)), "word")
		return
	end

-- no opts for the non-jobs atm. these should both use the suggest form
-- of calling dynamically loaded views..
	if type(args[2]) ~= "table" then
		return
	end

	if #args > 3 then
		if cat9.views[args[3]] then
			table.remove(args, 1)
			table.remove(args, 1)
			return cat9.views[args[1]](job, true, args, raw)
		end
		return
	end

-- view #0 command [...]
	local set = {"detach", "focus"}
	set.hint = {
		"Bind the job to its own window",
		"Mark the job as being the layout focus"
	}

	for k,v in pairs(cat9.views) do
		if k ~= "hint" then
			table.insert(set, k)
			table.insert(set.hint, cat9.views.hint[k] or "")
		end
	end

	for k, _ in pairs(viewlut) do
		if k ~= "hint" then
			table.insert(set, k)
			table.insert(set.hint, viewlut.hint[k] or "")
		end
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end

end
