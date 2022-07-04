return
function(cat9, root, builtins, suggest)
local viewlut = {}
function viewlut.out(set, i, job)
	job.view = cat9.view_raw
	return i + 1
end

function viewlut.err(set, i, job)
	job.view = cat9.view_err
	return i + 1
end

function viewlut.expand(set, i, job)
	job.expanded = -1
	return i + 1
end

function viewlut.toggle(set, i, job)
	if job.expanded ~= nil then
		job.expanded = nil
	else
		job.expanded = -1
	end
end

function viewlut.linenumber(set, i, job)
	if set[2] and set[2] == "on" then
		job.show_linenumber = true
		return
	elseif set[2] and set[2] == "off" then
		job.show_linenumber = false
	end

	if job.show_linenumber then
		job.show_linenumber = false
	else
		job.show_linenumber = true
	end
end

function viewlut.collapse(set, i, job)
	job.expanded = nil
end

function viewlut.scroll(set, i, job)
-- something to go to beginning/end?
	local row = cat9.opt_number(set, 2, 0)
	local col = cat9.opt_number(set, 3, 0)
	sind = sind and sind or 0
	job.row_offset = row
	job.col_offset = col
end

local function view_monitor()
	for _,v in ipairs(lash.jobs) do
		if v.monitor then
			print("view >monitor< : output job already exists")
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
	job.expanded = -1

	print =
	function(...)
		local tbl = {...}
		local fmtstr = string.rep("%s\t", #tbl)
		local msg = string.format(fmtstr, ...)
		local lst = string.split(msg, "\n")
		for _,v in ipairs(lst) do
			table.insert(job.data, v)
		end
		cat9.flag_dirty()
	end
	cat9.add_message =
	function(msg)
		if type(msg) == "string" then
			local list = string.split(msg, "\n")
			for _v in ipairs(list) do
				table.insert(job.data, v)
			end
		end
		cat9.flag_dirty()
		oldam(msg)
	end
	table.insert(job.hooks.on_destroy,
	function()
		print = oldprint
		cat9.add_message = oldam
	end)
	return
end

function builtins.view(job, ...)
-- special case, assign messages and 'print' calls into a job
	if type(job)== "string" then
		if job == "monitor" then
			view_monitor()

-- help theming and testing viewing, jack in a coloriser for the data
-- and set a custom view handler for the task
		elseif job == "colour" or job == "color" then
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
		return
	end

	if type(job) ~= "table" then
		cat9:add_message("view >jobid< - invalid job reference")
		return
	end

	cat9.run_lut("view #job", job, viewlut, {...})
	cat9.flag_dirty()
end

function suggest.view(args, raw)
	if #args <= 2 then
		local set = {"monitor", "color"}
		if cat9.selectedjob then
			table.insert(set, "#csel")
		end

		for _,v in ipairs(lash.jobs) do
			if not v.hidden then
				table.insert(set, "#" .. tostring(v.id))
			end
		end
		cat9.readline:suggest(cat9.prefix_filter(set, string.sub(raw, 6)), "word")
		return
	end

-- no opts for the non-jobs atm.
	if type(args[2]) ~= "table" then
		return
	end

	local set = {}
	for k, _ in pairs(viewlut) do
		table.insert(set, k)
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end

end
