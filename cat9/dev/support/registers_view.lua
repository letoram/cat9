return
function(cat9, cfg, job, th, frame)

-- improvements todo:
--
--  * make reg clickable for set reg value
--  * make value clickable for toggle representation to force hex or binary (need bigInt)
--  * hover for readMemory if it's natively hex-provided
--  * arg for setting the visible registry group
--

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
	job.root:cursor_to(x, y)

	for _,v in ipairs(ents) do
		local regv = string.split(v, "=")
		job.root:write(regv[1] .. "=", cfg.debug.register)
		job.root:write((regv[2] or "") .. " ", cfg.debug.register_value)
	end
end

-- with write-override we perform the same as pack_for_group and apply
-- the color values for name versus value

local function view_regs(job, x, y, cols, rows, probe)
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
		local locals = frame:locals()
		if not locals.registers then
			return
		end

-- prepare data for slice to work
		for _, v in ipairs(locals.registers.variables) do
			table.insert(wnd.data,
				string.format("%s = %s", v.name, v.value))
		end

		wnd.data.linecount = #wnd.data
		wnd.data.raw = locals.registers.variables
	end

	wnd:invalidated()
	wnd.expanded = false
	wnd.show_line_number = false
	wnd.write_override = write_regs
	wnd:set_view(view_regs, nil, {}, "registers")

return wnd
end
