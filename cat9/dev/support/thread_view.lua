return
function(cat9, cfg, job)

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

local function write_threads(job, x, y, row, set, ind, _, selected)
	local th = set.threads[ind]
	local mouse = job.mouse

	if not th then
		return
	end

	local mx = -1
	if mouse and mouse.on_row and mouse.on_row == ind then
		mx = mouse[1]
	end

	job.root:cursor_to(x, y)
	local cx, cy = x, y
	for i=1,#th do
		local attr = cfg.debug.thread

		if th.click[i] and
			mx >= cx and mx < cx + job.root:utf8_len(th[i]) then
			attr = cfg.debug.thread_selected
		end

		job.root:write(tostring(th[i]), attr)
		cx, cy = job.root:cursor_pos()
	end
end

local function thread_click(job, btn, ofs, yofs, mods)
	local th = job.data.threads[yofs]
	if not th then
		return
	end

	local step = 0
	for i=1,#th do
		step = step + #th[i]
		if ofs <= step then
			if th.click[i] then
				th.click[i]()
				break
			end
		end
	end

	cat9.flag_dirty(job)
	return true
end

local function view_threads(job, x, y, cols, rows, probe)
	local dbg = job.parent.debugger

	local set = {}
	local lc = 1
	local bc = 0
	local max = 0

-- convert debugger data model to window view one
	for k,v in pairs(dbg.data.threads) do
		table.insert(set, k)
		local kl = #tostring(k)
		max = kl > max and kl or max
		bc = bc + kl

		if v.expanded then

-- this should expand with the number of lines in the stack frame, which
-- depends on if variables are exposed or not
			for i=1,#v.stack do
				lc = lc + 1 + 1
			end
		else
			lc = lc + 1
		end
	end

	if probe then
		return lc > rows and rows or lc
	end

-- the per-line setup should really be cached instead as it will be consistent
	table.sort(set)
	local data = {
		threads =
		{
			click = {}
		},
	}
	local active_row
	local active_col

-- sorted set, then build placeholder with lines in data, and the
-- actual relevant components and click handlers in .threads
	for i,v in ipairs(set) do
		local th = dbg.data.threads[set[i]]
		local newth = {string.lpad(tostring(v), max) .. ":", " ", th.state, " ", click = {}}
		table.insert(data, "")
		table.insert(data.threads, newth)

		if th.state == "stopped" then
			table.insert(newth, "Step(")
			table.insert(newth, "next")
			newth.click[#newth] = function()
				th:step()
			end
			table.insert(newth, " ")

			table.insert(newth, "in")
			newth.click[#newth] = function()
				th:stepin()
			end
			table.insert(newth, " ")

			table.insert(newth, "out")
			newth.click[#newth] = function()
				th:stepout()
			end
			table.insert(newth, ")")
		end

		newth.click[1] =
		function()
			th.expanded = not th.expanded
			cat9.flag_dirty(job)
		end

		newth.click[3] =
		function()
			if th.state == "stopped" then
				dbg:continue(th.id)
			else
				dbg:pause(th.id)
			end
		end

		local gen_debug_call =
		function(frame, arg)
			return
			function()
				local str = string.format(
						"#%d debug #%d thread %d %s %d",
						job.parent.id, job.parent.id, th.id, arg, frame
				)
				cat9.parse_string(cat9.readline, str)
			end
		end

-- just add placeholder lines in data just for view_fmt to forward
-- correctly, then use the write override to actually populate
		if th.expanded and th.stack then
			for i=1,#th.stack do
				local frame = th.stack[i]
				local fref = nil
				if frame.path and #frame.path > 0 then
					fref = frame.path
					if frame.line then
						fref = string.format("(%s:%d)", fref, frame.line)
					else
						fref = "(" .. frame.path .. ")"
					end
				end

				local newfm = {
					string.lpad(tostring(frame.id) .. ":", max + 4),
					frame.name .. " ",
					fref,
					click = {}
				}

-- expose source name is available, with click handler to view source
				table.insert(data.threads, newfm)
				table.insert(data, "")

				newfm.click[1] =
				function()
					frame.expanded = not frame.expanded
					cat9.flag_dirty(job)
				end

				newfm.click[3] =
				function()
					local str = frame.ref ~= nil and tostring(frame.ref) or frame.path
					local str = string.format(
						"#%d debug #%d source %s%s %d",
						job.parent.id, job.parent.id,
						str,
						(frame.line and ":" .. tostring(frame.line)) or "",
						th.id
					)
					cat9.parse_string(cat9.readline, str)
				end

				if frame.expanded then
					local locals = frame:locals()
					if locals.pending then
						table.insert(data.threads,{
							string.lpad("(pending)", max + 8), click = {}})
						table.insert(data, "")
					else
						local set = {string.lpad("", max + 8), click = {}}

-- these should probably just be shown as
-- arg1="", arg2="", arg3="" on a separate line with on-click setting the
-- prompt to edit the argument with debug set id var value
						if locals.arguments then
							table.insert(set, "Arguments ")
							set.click[#set] = gen_debug_call(frame.id, "arguments")
						end

						if locals.registers then
							table.insert(set, "Registers ")
							set.click[#set] = gen_debug_call(frame.id, "registers")
						end

						if locals.locals then
							table.insert(set, "Variables ")
							set.click[#set] = gen_debug_call(frame.id, "variables")
						end

						table.insert(set, "Disassemble ")
						set.click[#set] = gen_debug_call(frame.id, "disassemble")

						table.insert(data, "")
						table.insert(data.threads, set)
					end
				end

			end
		end
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
thwnd.handlers.mouse_button = thread_click

return thwnd
end
