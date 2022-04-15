local viewlut
local function build_lut()
	lut = {}
	function lut.out(set, i, job)
		job.view = job.data
		return i + 1
	end
	lut.stdout = lut.out

	function lut.err(set, i, job)
		job.view = job.err_buffer
		return i + 1
	end
	lut.stderr = lut.err

	function lut.exp(set, i, job)
		job.expanded = -1
		return i + 1
	end
	lut.expand = lut.exp

	function lut.tog(set, i, job)
		if job.expanded ~= nil then
			job.expanded = nil
		else
			job.expanded = -1
		end
	end
	lut.toggle = lut.tog

	function lut.col(set, i, job)
		job.expanded = nil
	end
	lut.collapse = lut.col
	viewlut = lut
-- also need scroll, filter, ...
end

build_lut()

return
function(cat9, root, builtins, suggest)

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
		table.insert(job.data, msg)
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
		elseif job == "color" then
-- create a job with just the labels
-- then add a colorizer / shaper
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
		return
	end

	if type(args[2]) ~= "table" then
		return
	end

-- view [job] +mode (out, err, tog, exp, scroll, wrap)
-- view monitor
end

end
