return
function(cat9, cfg, job, th, frameid)

local function reg_click(job, btn, ofs, yofs, mods)
	if yofs == 0 then
		return
	end

-- now we know if it's register (add tracking), value (toggle rep, add watch)
	local row = job.xy_map[yofs]
	if not row or not row[ofs] then
		return
	end

-- click on register
	if row[ofs][1] then
		if btn == 1 then
-- toggle between dec, hex and binary
		elseif btn == 3 then
		elseif btn == 2 then
			local str = string.format(
				"#%d debug #%d thread %d %s watches register %s",
				job.parent.id, job.parent.id, th.id, frameid, row[ofs][2])
			cat9.parse_string(cat9.readline, str)
		end

		return true
	end

	return true
end

local function get_group(job, group, cols)
	local set = job.data.raw

-- filter out the set of registers to show
	if not group or not cfg.debug.reggroups[group] then
		return set
	end

	new = {}

	for i,v in ipairs(set) do
		for _, ptn in ipairs(cfg.debug.reggroups[group]) do
			if string.match(v.name, ptn) then
				table.insert(new, v)
			end
		end
	end

	return new
end

local function pack_for_group(job, group, vars, cols)
	local set = get_group(job, group)

	local res = {}

-- walk through the set and flood fill reg = value based on cols
	local str = ""
	local gotent = false

	for i,v in ipairs(set) do

-- test next value for overflow
		local nent = str .. v.name .. " = " .. v.value

-- and if so, defer it to the next round or, if can never fit, force add
		if #nent >= cols - 1 then
			if not gotent then
				table.insert(res, nent)
				str = ""
			else
				gotent = false
				table.insert(res, str)
				str = v.name .. " = " .. v.value .. "\t"
			end
-- or append and mark for next value
		else
			str = nent .. "\t"
			gotent = true
		end
	end

-- append any straggler
	if #str > 0 then
		table.insert(res, str)
	end

	res.bytecount = 0
	res.linecount = #res
	return res
end

local function write_regs(job, x, y, row, set, ind, _, selected)
	local ents = string.split(row, "\t")
	local rx = x - job.region[1]
	local ry = y - job.region[2]
	local regfmt
	local valfmt

	job.root:cursor_to(x, y)

	for _,v in ipairs(ents) do
		local regv = string.split(v, "=")
		if #regv[1] == 0 then
			break
		end
		regv[2] = regv[2] or ""

-- track so we can resolve clicks
		local cx = rx
		if not job.xy_map[ry] then
			job.xy_map[ry] = {}
		end

		for i=1,#regv[1] do
			job.xy_map[ry][rx] = {true, regv[1]}
			rx = rx + 1
		end

-- visual feedback for mouse over reg or value
		regfmt = cfg.debug.register
		if job.mouse and job.mouse.on_row == ind then
			if job.mouse[1] >= cx and job.mouse[1] <= rx then
				regfmt = table.copy_recursive(regfmt)
				regfmt.border_down = true
			end
		end

		cx = rx

		for i=1,#regv[2] do
			job.xy_map[ry][rx] = {false, regv[2]}
			rx = rx + 1
		end

		valfmt = cfg.debug.register_value
		if job.mouse and job.mouse.on_row == ind then
			if job.mouse[1] >= cx and job.mouse[1] <= rx then
				valfmt = table.copy_recursive(valfmt)
				valfmt.border_down = true
			end
		end

		job.root:write(regv[1] .. "=", regfmt)
		job.root:write(regv[2] .. " ", valfmt)

		rx = rx + 2
	end
end

-- with write-override we perform the same as pack_for_group and apply
-- the color values for name versus value

local function view_regs(job, x, y, cols, rows, probe)
	job.xy_map = {}

	local set = pack_for_group(job, nil, job.data.raw, cols)
	if probe then
		return set.linecount
	end

	return cat9.view_fmt_job(job, set, x, y, cols, rows, probe)
end

local function slice_threads(job, lines)
	local res = {}

-- return a more informed view of each thread so that we can use it
-- to copy out all resolved information about an execution thread
	return cat9.resolve_lines(
		job, res, lines,
		function(i)
			return job.data[i]
		end
	)
end

local wnd =
	cat9.import_job({
		short = "Debug:registers",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

	wnd.invalidated =
	function()
		th:locals(frameid,
			function(locals)
				if not locals.registers then
					return
				end

-- prepare data for slice to work
			wnd.data = {bytecount = 0}
			for _, v in ipairs(locals.registers.variables) do
				table.insert(wnd.data,
					string.format("%s = %s", v.name, v.value))
				end

				wnd.data.linecount = #wnd.data
				wnd.data.raw = locals.registers.variables
				cat9.flag_dirty(wnd)
		end)
	end

	wnd.handlers.mouse_button = reg_click
	wnd:invalidated()
	wnd.expanded = false
	wnd.show_line_number = false
	wnd.write_override = write_regs
	wnd.row_offset_relative = false
	wnd:set_view(view_regs, nil, {}, "registers")

return wnd
end
