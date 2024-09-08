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
	globals = {}
})

local function dec_pending(pending, wnd)
	if pending == 1 then
		local data = {bytecount = 0, linecount = 0}
		local columns = {}

		for k,v in ipairs(wnd.globals) do
			table.insert(data, string.format("%s: %s", v.name, v.value))
			if v.in_spread then
				table.insert(columns, '"' .. string.gsub(v.value, '"', "\\\"") .. '"')
			end
		end
		for k,v in ipairs(wnd.variables) do
			table.insert(data, string.format("%s: %s", v.name, v.value))
			if v.in_spread then
				table.insert(columns, '"' .. string.gsub(v.value, '"', "\\\"") .. '"')
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

		if wnd.spreadsheet then
			local line =
			string.format(
			"#%d insert #%d %d %s",
				wnd.spreadsheet.wnd.id,
				wnd.spreadsheet.wnd.id,
				wnd.spreadsheet.next_row,
				table.concat(columns, " "))

			cat9.parse_string(cat9.readline,  line)

			wnd.spreadsheet.next_row = wnd.spreadsheet.next_row + 1
		end
-- synch to spreadsheet is the next option
	end
	return pending - 1
end

local function synch_vals(wnd)
	local pending = 0

-- since these can all be on different threads etc. simply sweep each, count
-- pending and flag dirty when done (or if there is a spreadsheet attach, send
-- the update values as we go).
	for k,v in ipairs(wnd.registers) do
		pending = pending + 1
		local th = v.thread:locals(v.frame,
			function(vars)
				if vars.registers then
					for _,w in ipairs(vars.registers.variables) do
						if w.name == v.name then
							v.value = w.value
							break
						end
					end
				end
				pending = dec_pending(pending, wnd)
			end
		)
	end

	for k,v in ipairs(wnd.variables) do
			pending = pending + 1
			local th = v.thread:locals(v.frame,
			function(vars)
				if vars.variables then
					for _,w in ipairs(vars.locals.variables) do
						if w.name == v.name then
							v.value = w.value
							break
						end
					end
				end
				pending = dec_pending(pending, wnd)
			end
		)
	end

	for k,v in ipairs(wnd.globals) do
		pending = pending + 1
		local th = v.thread:locals(v.frame,
			function(vars)
				if vars.variables then
					for _,w in ipairs(vars.globals.variables) do
						if w.name == v.name then
							v.value = w.value
							break
						end
					end
				end
				pending = dec_pending(pending, wnd)
			end
		)
	end
end

wnd.invalidated =
function()
	synch_vals(wnd)
end

wnd.watch = true

wnd.add_watch =
function(wnd, domain, name, thread, frame)
	local dt = {thread = thread or th, frame = frame or frameid, name = name, val = 0}
	local dd

	if domain == "register" then
		dd = wnd.registers
	elseif domain == "global" then
		dd = wnd.globals
	else --if domain == "variables" then
		dd = wnd.variables
	end

	table.insert(dd, dt)
end

wnd:invalidated()
wnd.show_line_numbers = false
return wnd

end
