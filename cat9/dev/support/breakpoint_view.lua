return
function(cat9, cfg, job)

local function write_bpt(job, x, y, row, set, ind, _, selected)
	job.root:write_to(x, y, row)
end

local function view_bpt(job, x, y, cols, rows, probe)
	local data = {
		bytecount = 0,
		linecount = 0
	}
	local dbg = job.parent.debugger

	if probe then
		local lc = 0
		for i,v in pairs(dbg.data.breakpoints) do
			lc = lc + 1
		end
		return lc > rows and rows or lc
	end

	for i,v in pairs(dbg.data.breakpoints) do
		local linefmt = ""
		if v.line[1] then
			linefmt = tostring(v.line[1])
			if v.line[2] ~= v.line[1] then
				linefmt = linefmt .. "-" .. tostring(v.line[2])
			end
		end

-- this view ignores column
		local str =
		string.format(
			"%s: %s%s%s @ %s+%s",
			tostring(v.id) or "[]",
			v.source,
			#linefmt > 0 and ":" or "",
			linefmt,
			v.instruction[1],
			tostring(v.instruction[2])
		)
		table.insert(data, str)
		data.bytecount = data.bytecount + #str
	end

	data.linecount = #data

	return cat9.view_fmt_job(job, data, x, y, cols, rows, probe)
end

local wnd =
	cat9.import_job({
		short = "Debug:breakpoints",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

wnd.show_line_number = false
wnd:set_view(view_bpt, slice_bpt, {}, "threads")
wnd.write_override = write_bpt

return wnd
end
