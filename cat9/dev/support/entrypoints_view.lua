return
function(cat9, cfg, job, th, frameid)

local entrypoints =
{
	"clock", "input", "input_raw", "input_end", "preframe",
	"postframe", "adopt", "autores", "autofont", "handover", "shutdown",
	"display_state", "display_reset",
	"frameserver", "mesh", "calctarget", "lwa", "image", "audio",
	"main", "shutdown", "nbio_read", "nbio_write", "nbio_data",
	"handover", "trace"
}

local function ep_click(job, btn, ofs, yofs, mods)
	if yofs == 0 then
		return
	end

-- now we know if it's register (add tracking), value (toggle rep, add watch)
	local row = job.xy_map[yofs]
	if not row or not row[ofs] then
		return
	end

-- update active set for job and send the command if needed
	if btn == 1 then
		if job.active_eps[row[ofs]] then
			job.active_eps[row[ofs]] = nil
		else
			job.active_eps[row[ofs]] = true
		end
	end

	local active = {}
	for k, _ in pairs(job.active_eps) do
		table.insert(active, k)
	end
	local cmd = "entrypoint " .. table.concat(active, " ") .. "\n"
	job.parent.debugger.job.inp:write(cmd)
	print("send", cmd)

	cat9.flag_dirty(job)
	return true
end

local function pack_set(cols, set)
	local res = {}
	local str = ""
	local gotent = false

-- pack to fit cols without wrapping or cropping
	for i,v in ipairs(set) do
		if #v >= cols - 1 then
			if #str == 0 then
				return res
			end

			table.insert(res, str)
			str = ""
		else
			str = str .. "\t" .. v
		end
	end

	if #str > 0 then
		table.insert(res, str)
	end

	res.bytecount = 0
	res.linecount = #res
	return res
end

local function write_eps(job, x, y, row, set, ind, _, selected)
	local ents = string.split(row, "\t")
	job.root:cursor_to(x, y)
	local rx = x - job.region[1]
	local ry = y - job.region[2]

	for _,v in ipairs(ents) do
		local cx = rx
		local attr = job.active_eps[v] and cfg.debug.file_selected or cfg.debug.file

		if not job.xy_map[ry] then
			job.xy_map[ry] = {}
		end

	-- for clicking
		for i=1,#v do
			job.xy_map[ry][rx] = v
			rx = rx + 1
		end

	-- highlight on-over
		if job.mouse and job.mouse.on_row == ind then
			if job.mouse[1] >= cx and job.mouse[1] <= rx then
				attr = table.copy_recursive(attr)
				attr.border_down = true
			end
		end

		job.root:write(v, attr)
		job.root:write(" ", cfg.debug.file)

		rx = rx + 1
	end

end

local function view_eps(job, x, y, cols, rows, probe)
	job.xy_map = {}
	local set = pack_set(cols, entrypoints)
	if probe then
		return set.linecount
	end

	return cat9.view_fmt_job(job, set, x, y, cols, rows, probe)
end

local wnd =
	cat9.import_job({
		short = "Debug:entrypoints",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

	wnd.handlers.mouse_button = ep_click
	wnd.expanded = false
	wnd.show_line_number = false
	wnd.write_override = write_eps
	wnd:set_view(view_eps, nil, {}, "entrypoints")
	wnd.active_eps = {}

return wnd
end
