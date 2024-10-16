-- should probably track updates with a timestamp

return
function(cat9, cfg, job, th, frameid, opts)

local wnd =
cat9.import_job({
	short = "Debug: watchset",
	parent = job,
	thread = th,
	raw = "",
	data = {bytecount = 0, linecount = 0},
	registers = {},
	variables = {},
	globals = {},
	threads = {}
})

local function dec_pending(pending, wnd)
	if pending > 1 then
		return pending - 1
	end

	local data = {bytecount = 0, linecount = 0}
	local columns = {}

	for k,v in ipairs(wnd.threads) do
		local frame = v:frame(0)

		if not frame or not frame.path or not frame.line then
			table.insert(data, string.format("%d: no source info", v.id))
			if v.in_spread then
				table.insert(columns, tostring(v.id))
			end
		else
			if v.in_spread then
				table.insert(columns, string.format("%s:%d", frame.path, frame.line))
			end
			table.insert(data, string.format("%d: %s:%d", v.id, frame.path, frame.line))
		end
	end

	for k,v in ipairs(wnd.globals) do
		table.insert(data, string.format("%s: %s", v.name, v.value))
		if v.in_spread then
			table.insert(data, '"' .. string.gsub(v.value, '"', "\\\"") .. '"')
		end
	end
	for k,v in ipairs(wnd.variables) do
		table.insert(data, string.format("%s: %s", v.name, v.value))
		if v.in_spread then
			table.insert(data, '"' .. string.gsub(v.value, '"', "\\\"") .. '"')
		end
	end
	for k,v in ipairs(wnd.registers) do
		table.insert(data, string.format("%s: %s", v.name, v.value))
		if v.in_spread then
			table.insert(columns, '"' .. string.gsub(v.value, '"', "\\\"") .. '"')
		end
	end
	wnd.data = data
	data.linecount = #data
	cat9.flag_dirty(wnd)
	local dbg = wnd.parent.debugger

-- synch to attached spreadsheet, but only if the clock has changed
	if wnd.spreadsheet and dbg.clock ~= wnd.spreadsheet.clock then
		wnd.selected_bar = {}
		wnd.spreadsheet.clock = dbg.clock
		local line =
		string.format(
		"#%d insert #%d %d %s",
			wnd.spreadsheet.wnd.id,
			wnd.spreadsheet.wnd.id,
			wnd.spreadsheet.next_row,
			table.concat(columns, " "))

		cat9.parse_string(cat9.readline, line)
		wnd.spreadsheet.next_row = wnd.spreadsheet.next_row + 1
	else
		wnd.selected_bar = {
			{"Spreadsheet"},
			m1 = {
				string.format(
					"#%d debug #%d thread %d watches spreadsheet",
					wnd.id, wnd.id, th.id
				)
			}
		}
	end

	return pending - 1
end

local function get_member_path(v, scope, closure)
	local path = cat9.table_copy_shallow(v.members)

	local found = false
	v.thread:locals(
		v.frame,
		function(vars)
			if not vars[scope] or not vars[scope].variables then
				closure(false)
				return
			end

			for _,w in ipairs(vars[scope].variables) do
-- here we need to remove one from path and repeat the call
-- instead of triggering the closure immediately
				if w.name == v.name then
					v.value = w.value
					closure(true)
					break
				end
			end
		end
	)
end

local function synch_vals(wnd)
	local pending = 0

	for k,v in ipairs(wnd.registers) do
		get_member_path(v, "registers",
			function()
				pending = dec_pending(pending, wnd)
			end
		)
	end

-- variables and globals are more tricky as we need to walk the
-- tree and find the path if the #members count is > 0
	for k,v in ipairs(wnd.variables) do
		pending = pending + 1
		get_member_path(v, "locals",
			function()
				pending = dec_pending(pending, wnd)
			end
		)
	end

	for k,v in ipairs(wnd.globals) do
		pending = pending + 1
		get_member_path(v, "globals",
			function()
				pending = dec_pending(pending, wnd)
			end
		)
	end

	for k,v in ipairs(wnd.threads) do
		pending = pending + 1
		pending = dec_pending(pending, wnd)
	end
end

wnd.invalidated =
function()
	synch_vals(wnd)
end

wnd.watch = true

wnd.add_watch =
function(wnd, domain, name, thread, frame, ...)
	local members = {...}
	local dt =
		{
			thread = thread or th,
			frame = frame or frameid,
			name = name,
			val = 0,
			members = members
		}

	local dd

	if domain == "register" then
		dd = wnd.registers

	elseif domain == "global" then
		dd = wnd.globals

-- threads will already have location synched when we trigger so no reason to
-- separately query them, just add the thread here. Treat as toggle.
	elseif domain == "thread" then
		for i,v in ipairs(wnd.threads) do
			if v == thread then
				table.remove(wnd.threads, i)
				return
			end
		end
		table.insert(wnd.threads, thread)
		return
	else --if domain == "variables" then
		dd = wnd.variables
	end

	for i,v in ipairs(dd) do
		if v.name == name then
			table.remove(dd, i)
			return
		end
	end

	table.insert(dd, dt)
end

wnd.selected_bar = {
}

wnd:invalidated()
wnd.show_line_numbers = false
return wnd

end
