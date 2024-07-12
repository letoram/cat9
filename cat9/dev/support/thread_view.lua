return
function(cat9, cfg, job)

local function slice_threads(job, lines)
	local res = {}

-- return a more informed view of each thread so that we can use it
-- to copy out all resolved information about an execution thread
	return cat9.resolve_lines(
		job, res, lines,
		function(i)
			return job.data
		end
	)
end

local function view_threads(job, x, y, cols, rows, probe)
	local dbg = job.parent.debugger

	local set = {}
	local lc = 0
	local bc = 0
	local max = 0

-- convert debugger data model to window view one
	for k,v in pairs(dbg.data.threads) do
		table.insert(set, k)
		local kl = #tostring(k)
		max = kl > max and kl or max
		bc = bc + kl

		if v.expanded then
			lc = lc + v.stack and #v.stack or 0
		else
			lc = lc + 1
		end
	end

-- also need to cover the currently expanded thread (if any) for
-- additional linecount
	if probe then
		return #set > rows and rows or #set
	end

	table.sort(set)
	local data = {}

	if job.mouse then
		local rx = job.mouse[1] - x
		local ry = job.mouse[2] - y
	end

-- now we have the sorted threadId's, build the actual representations
-- and retain the mapping from row to thread as well as to draw
-- expanded mouse-over options.
	for i,v in ipairs(set) do
		table.insert(data,
			string.lpad(
				tostring(v), max) .. ": " .. dbg.data.threads[set[i]].state
		)
	end

	data.linecount = #data
	data.bytecount = bc
	job.data = data

	return cat9.view_fmt_job(job, data, x, y, cols, rows)
end

local thwnd =
	cat9.import_job({
		short = "Debug:threads",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

thwnd.show_line_number = false
thwnd:set_view(view_threads, slice_threads, {}, "threads")
thwnd.write_override = write_threads

return thwnd
end
