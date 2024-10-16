return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local parse_expr, types, type_strtbl =
	loadfile(string.format("%s/cat9/spreadsheet/parser.lua", lash.scriptdir))()()

lash.types = types
local expr_funcs =
	loadfile(string.format("%s/cat9/spreadsheet/functions.lua", lash.scriptdir))()

local plot_templates =
	loadfile(string.format("%s/cat9/spreadsheet/plot.lua", lash.scriptdir))()

local history = {}

local expand_addr
local parse_expression

local functions = {}

local errors =
{
	missing_csv = "new csv >file or job< : missing source argument",
	open_fail = "new csv >file< : couldn't open file",
	missing_row = "cell specifier lacks row reference (e.g. A1)",
	bad_addr = "cell address specifier has invalid values",
	insert_job = "insert >job< : job is not a spreadsheet",
	replace_job = "replace >job< : job is not a spreadsheet",
	set_job = "set >job< : job missing or not a spreadsheet",
	plot_job = "plot >job< : job missing or not a spreadsheet",
	malformed_range = "range specifier cell1:cell2 invalid",
	set_args = "set >...< : expected set [addr] \"value\" or \"=expression\" or \"=!command"
}

builtins.hint["new"] = "Create a new spreadsheet job with rows * cols cells"
builtins.hint["set"] = "Provide a value or expression for a specific cell"

local function new_cell(job, val)
	local tmpl = {
		label = "",
		listeners = {},

-- value history tracking would go here to make this a 3D grid
		update =
		function(cell, val)
			cell.label = tostring(val)
			cell.value = val

-- any dependent expressions need to be recalculated
			if #cell.listeners > 0 then
				local oldli = cell.listeners
				cell.listeners = {}
				for k,v in ipairs(oldli) do
					parse_expression(job, v)
				end
			end
		end
	}

	if val == nil then
		return tmpl
	end

	tmpl.raw = val
	if type(val) == "number" then
		val = tostring(val)
	end

	tmpl.label = val
	tmpl.value = val

	return tmpl
end

local az = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local azc = #az
local function col_to_az(x)
	local ci = x % azc
	local cq = math.floor(x / azc)
	local ch = string.sub(az, ci+1, ci+1)

	if cq >= 1 then
		return col_to_az(cq - 1) .. ch
	end

	return ch
end

local function border_column(job, x, y, y2)
	for cy=y,y2 do
		local ch, attr = job.root:get(x, cy)
		attr.border_right = true
		job.root:write_to(x, cy, attr)
	end
end

local function border_row(job, x, y, x2)
	for cx=x,x2 do
		local ch, attr = job.root:get(cx, y)
		attr.border_down = true
		job.root:write_to(cx, y, attr)
	end
end

local function view_for_cell(cell, ccw)
	local res = ""
	cat9.each_ch(cell.label,
	function(ch, pos)
		res = res .. ch
		ccw = ccw - 1
		return ccw <= 0
	end)
	return res
end

local function view_spread(job, x, y, cols, rows, probe)
	if probe then
		return rows
	end

	local cy = y
	local yi = 1 + job.row_ofs
	job.max_rows = rows
	job.max_cols = cols

	local rowfmt = builtin_cfg.col_1
	local colfmt = builtin_cfg.col_2
	local cw  = builtin_cfg.min_col_width
	local col = job.col_ofs + 1
	local endcol = col

-- draw column headers
	local lx = cw
	while lx < cols do
		if lx > cols then
			break
-- recall the ending column so we can draw the cursor even if there
-- is nothing on the row
		else
			endcol = col
		end

		local ccw = job.column_sizes[col] or cw
		local fmt = job.cell_cursor[1] == x and builtin_cfg.cursor or colfmt

		local label = col_to_az(col-1)
		col = col + 1
		local lpad = string.rep(" ", math.floor(0.5 * ccw - #label))
		local rpad = string.rep(" ", ccw - #lpad - #label)

		job.root:write_to(
			lx + x, y,
			string.format("%s%s%s", lpad, label, rpad),
			fmt
		)

		lx = lx + ccw
	end

-- draw row header
	for ly=y+1,y+rows-1,1 do
		local yofs = yi + ly - y - 1
		local cpad = math.floor(#tostring(yi) - cw * 0.5)
		local fmt = (job.selected_row and job.selected_row == yofs)
			and builtin_cfg.cursor or rowfmt

		job.root:write_to(
			x, ly,
			string.format("%" .. tostring(cw) .. "s", tostring(yofs)),
			fmt
		)
	end

-- draw the cell window
	local selected_x, selected_y, selected_width

	for ly=y+1,y+rows-1,1 do
		local row = job.cells[yi]
		local cx = cw
		local cap = row and #row or endcol

		for cc=job.col_ofs+1,endcol do
			local fmt = builtin_cfg.cell
			local selected = job.cell_cursor[1] == cc and job.cell_cursor[2] == yi
			local ccw = job.column_sizes[cc] or cw

			if selected then
				fmt = builtin_cfg.cursor
				selected_x = x + cx
				selected_y = ly
				selected_width = ccw
			end

			if row and row[cc] then
				job.root:write_to(x + cx, ly, view_for_cell(row[cc], ccw), fmt)
			end

			cx = cx + (job.column_sizes[cc] or cw)

			if cx > x + cols then
				break
			end
		end

		yi = yi + 1
	end

	if builtin_cfg.column_border then
		local col = job.col_ofs + 1
		local lx = cw + x

		while lx < x + cols do
			local ccw = job.column_sizes[col] or cw
			col = col + 1
			lx = lx + ccw
			border_column(job, lx - 1, y + 1, y + rows - 1)
		end
	end

	if builtin_cfg.row_border then
		for ly=y+1,y+rows-1,1 do
			border_row(job, x + 1, ly, cols)
		end
	end

-- draw cursor into selected region
	if selected_x then
		for x=selected_x,selected_x + selected_width-1 do
			local _, attr = job.root:get(x, y)
			attr.fc = builtin_cfg.cursor.fc
			attr.bc = builtin_cfg.cursor.bc
			attr.border_left = x==selected_x
			attr.border_top = true
			attr.border_down = true
			attr.border_right = x == selected_x + selected_width - 1
			job.root:write_to(x, selected_y, attr)
		end
	end

	return rows
end

local function flood_set(job, row, col, args)
	if not job.cells[row] then
		for i=1,row do
			if not job.cells[i] then
				job.cells[i] = {}
			end
		end
	end
	local row = job.cells[row]

	for i=1,col do
		if not row[i] then
			row[i] = new_cell(job)
		end
	end

	local domain = "val"

-- format, name, ...
	if args[1] == "val" then
		table.remove(args, 1)
	end

	local cmd = table.concat(args, " ")
	local prefix = string.sub(cmd, 1, 1)

	if prefix == "=" then
		row[col].expression = string.sub(cmd, 2)
		parse_expression(job, row[col])
-- expression
	elseif prefix == "!" then
		cmd = string.sub(cmd, 2)

		row[col].handler =
		function()
			local _, out, _, pid = root:popen("/bin/sh -c \"" .. cmd .. "\"", "r", {})
			cat9.add_background_job(out, pid, {lf_strip = true},
				function(job, code)
					if code == 0 then
						row[col]:update(table.concat(job.data, ""), row[col].label)
					else
						row[col]:update("#ERROR", row[col].label)
					end
					cat9.flag_dirty(job)
				end
			)
		end
		row[col].handler()
	else
		row[col]:update(cmd, cmd)
	end

	cat9.flag_dirty(job)
end

local function ensure_insert_row(job, row, col, cols)
	for i=1,row do
		if not job.cells[i] then
			job.cells[i] = {}
		end
	end

	local drow = {}

	for i=1,col do
		drow[i] = new_cell(job, "")
	end

	for i=1, #cols do
		drow[i+ col - 1] = new_cell(job, cols[i])
	end

	table.insert(job.cells, row, drow)
end

local function ensure_replace_row(job, row, col, cols)
	for i=1,row do
		if not job.cells[i] then
			job.cells[i] = {}
		end
	end

-- prefill to the boundary
	for i=1,col do
		if not job.cells[row][i] then
			job.cells[row][i] = new_cell(job, "")
		end
	end

-- and create
	for i=1,#cols do
		job.cells[row][i+col-1] = new_cell(job, cols[i])
	end
end

local function slice_spread(job, lines)
	local res = {
		bytecount = 0,
		linecount = 0
	}

	local format = "csv" -- raw would preserve = in expressions
	local elemsep = ","
	local rowsep = "\n"
	local compact = false

	if lines then
		local cells = {}
		local maxrow = 1

		for i,v in ipairs(lines) do
			if v == "compact" then
				compact = true
			else
				expand_addr(v,
					function(col, row)
-- extract the value
						local val = job.cells[row] and job.cells[row][col]
						if not val then
							if compact then
								return
							end
							val = ""
						else
							if not val.value or #val.value == 0 then
								if compact then
									return
								end
								val = ""
							else
								val = val.value
							end
						end

-- allocate (with holes) into cells (we will walk and emit later)
						if maxrow > row then
							maxrow = row
						end

						if not cells[row] then
							cells[row] = {}
							cells[row].cells = col
						elseif cells[row].cells < col then
							cells[row].cells = col
						end
						cells[row][col] = val
					end
				)
			end

-- cells is populated, time to build into dataset
		end

		for i=1,maxrow do
			if cells[i] then
				table.insert(res, "")
			end
		end

		return res
	end

	for i=1,#job.cells do
		local row = job.cells[i]
		local set = {}
		for i=1,#row do
			if row[i].value then
				table.insert(set, tostring(row[i].value))
			elseif not compact then
				table.insert(set, "")
			end
		end
		if #set > 0 or not compact then
			table.insert(res, table.concat(set, elemsep))
			res.bytecount = res.bytecount + #res[#res]
		end
	end

	res.linecount = #res
	return res
end

local function append_row(job, at_cursor, ...)
	local args = {...}
	if type(args[1]) == "table" then
		args = args[1]
	end

	local row_ind = #job.cells + 1

	if at_cursor then
		row_ind = args.cell_cursor[2] + 1
	end

	local new_row = {}
	for i,v in ipairs(args) do
		table.insert(new_row, new_cell(job, v))
	end

	table.insert(job.cells, row_ind, new_row)
	cat9.flag_dirty(job)
end

-- opts should control separator
local function import_csv(job, io, opts)
	opts = opts or {sep = ',', escape = "\""}
	io:lf_strip(true)

-- this should really use coroutines and yield often enough
	io:data_handler(
		function()
			local line, alive = io:read()
			while line do
				local tbl = {}

				local in_escape, in_mask
				local entry = {}

				if not opts.escape then
					tbl = string.split(line, opts.sep)
				else
					cat9.each_ch(line,
						function(ch)
							if ch == "," and not in_escape then
								table.insert(tbl, table.concat(entry, ""))
								entry = {}
							elseif opts.escape and ch == "\\" then
								in_mask = true
							elseif opts.escape and ch == opts.escape and not in_mask then
								in_escape = not in_escape
							else
								table.insert(entry, ch)
								in_mask = false
							end
						end
					)
				end

				append_row(job, opts.at_cursor, tbl)
				line, alive = io:read()
			end
			if not alive then
				io:close()
			end
		end
	)
end

local function get_window_col_width(job, col)
	local cols, rows = job.root:dimensions()
	local cw = builtin_cfg.min_col_width

	for row=1,rows do
		if job.cells[row] and job.cells[row][col] then
			local refw = job.root:utf8_len(job.cells[row][col].label)
			if refw > cw then
				cw = refw
			end
		end
	end

	if cw ~= builtin_cfg.min_col_width then
		return cw + 1
	end

	return cw
end

local function xy_to_cell(job, x, y)
	local col = job.col_ofs + 1
	local row = job.row_ofs + y
	local cx = builtin_cfg.min_col_width

	if cx <= x then
		while cx <= x do
			cx = cx + (job.column_sizes[col] or builtin_cfg.min_col_width)
			if cx <= x then
				col = col + 1
			end
		end
	end

	if col == 0 then
		col = 1
	end

	local cell
	if job.cells[row] then
		cell = job.cells[row][col]
	end

	return cell, row, col
end

local function to_cell_address(col, row)
	local pref = col_to_az(col)
	return pref .. tostring(row)
end

local function refresh_spread(job)
	for _, v in pairs(job.cells) do
		local nc = #v
		local i = 1

-- this is a fair place to track history of values
		while nc > 0 do
			if v[i] then

-- the ugly part here is asynchronous handling of updated cells with expression
-- dependencies which would need to be marked deferred if there is a handler,
-- and register on set/reference as part of symbol lookup.
				if v[i].handler then
					v[i].handler()

				elseif v[i].expression then
					parse_expression(job, v[i])
				end
				i = i + 1
				nc = nc - 1
			end
		end
	end
end

local function query_value(job, label, value, closure)
	local oprompt = cat9.get_prompt
	local got_readline = cat9.readline

-- this should really spawn a new readline if the job is detached, and
-- anchor / clip it closer to the cell itself
	cat9.set_readline(
		lash.root:readline(
			function(self, line)
				cat9.get_prompt = oprompt
				cat9.block_readline(lash.root, false, false)
				cat9.reset()
				job.in_query = false
				if not got_readline then
					cat9.hide_readline(lash.root)
				end
				closure(line)
			end
		, {

-- this is where we can latch in our expression specific helper that
-- provides type and completion hints for the related function space
-- just like done in pipeworld.
--
-- basically suggest would:
--  local tokens = {}
--  parse(
-- 	string_up_to_caret,
--  cell_lookup,
--  func_lookup,
--  error_handler: fail = ofs, fail_ind = nargs, fail_fun = sfun
--  tokens
--  )
--
-- and after parse:
-- local lt = tokens[#tokens]
-- local ind = fail_fun or (lt and (lt[1] == types.FCALL or lt[1] == types.SYMBOL) and lt[2])
--
-- func_table[ind] -> convert function definition to arguments for suggest
--
-- if there's no error, then just suggest from the list of known functions
--
			cancellable = true,
			forward_meta = false,
			forward_paste = false,
			forward_mouse = true
		}), "spread:set"
	)

	job.in_query = true
	cat9.block_readline(lash.root, true, true)
	cat9.readline:set(value)

	cat9.get_prompt = function()
		return {string.format("(XY = %s) ", label)}
	end
end

local function key_write(job, u8)
	query_value(job, "", u8,
		function(val)
			flood_set(job, job.cell_cursor[2], job.cell_cursor[1], {"val", val})
		end
	)
end

local function fit_cursor(job)
	local yi = 1 + job.row_ofs
	local ci = 1 + job.col_ofs
	local row = job.cell_cursor[2]
	local col = job.cell_cursor[1]

	if row <= yi or row > yi + job.max_rows - 2 then
		job.row_ofs = math.clamp(0, row - job.max_rows + 1)
	end

-- cols is more involved as we need to match the different column widths
	local cx = 1
	local ci = 1
	local cofs = 0
	local cw = builtin_cfg.min_col_width

	while ci ~= col do
		cx = cx +	(job.column_sizes[ci] or cw)
		ci = ci + 1

		if cx + (job.column_sizes[ci] or cw) >= job.max_cols then
			cofs = cofs + 1
		end
	end

	job.col_ofs = cofs
end

local function key_input(job, sub, sym, code, mods)
	local row = job.cell_cursor[2]
	local col = job.cell_cursor[1]
-- with modifier present we search for the first cell with non-empty contents
	if sym == tui.keys.UP then

		if row > 1 then
			row = row - 1
			if bit.band(mods, tui.modifiers.SHIFT) > 0 then
				while row > 1 do
					local no_value =
						not job.cells[row] or not job.cells[row][col] or
						not job.cells[row][col].value or #job.cells[row][col].value == 0
					if not no_value then
						break
					end
					row = row - 1
				end
			end
		end

		job.cell_cursor[2] = row
		fit_cursor(job)

	elseif sym == tui.keys.DOWN then
		job.cell_cursor[2] = row + 1
		fit_cursor(job)

	elseif sym == tui.keys.LEFT then
		if job.cell_cursor[1] > 1 then
			job.cell_cursor[1] = job.cell_cursor[1] - 1
		end
		fit_cursor(job)

	elseif sym == tui.keys.RIGHT then
		job.cell_cursor[1] = job.cell_cursor[1] + 1
		fit_cursor(job)

	elseif sym == tui.keys.BACKSPACE then
		flood_set(job, job.cell_cursor[2], job.cell_cursor[1], {"val", ""})

	elseif sym == tui.keys.ENTER or sym == tui.keys.RETURN then
		query_value(job, "",
			function(val)
				flood_set(job, job.cell_cursor[2], job.cell_cursor[1], {"val", val})
			end
		)
	end
	cat9.flag_dirty(job)
end

local function item_click(job, btn, ofs, yofs, mods)
	if yofs == 0 then
		return
	end

-- wheel translates to dy, mods+wheel translates to dx
	if btn == 4 then
		if mods > 0 and job.col_ofs > 0 then
			job.col_ofs = job.col_ofs - 1
		elseif job.row_ofs > 0 then
			job.row_ofs = job.row_ofs - 1
		end
		cat9.flag_dirty(job)
		return
	end

	if btn == 5 then
		if mods > 0 then
			job.col_ofs = job.col_ofs + 1
		else
			job.row_ofs = job.row_ofs + 1
		end
		cat9.flag_dirty(job)
		return
	end

-- switch the cursor unless it is on a column or row header.
	if ofs <= builtin_cfg.min_col_width - 1 then
		if yofs > 0 then
--			job.cells[job.row_ofs + yofs].selected =
--				not job.cells[job.row_ofs + yofs].selected
		end
		cat9.flag_dirty(job)
		return true
	end

-- toggle row width to fit
	if yofs == 1 then
		local cell, row, col = xy_to_cell(job, ofs, yofs - 1)
		if col > 0 then
			if not job.column_sizes[col] or
				job.column_sizes[col] == builtin_cfg.min_col_width then
				job.column_sizes[col] = get_window_col_width(job, col)
			else
				job.column_sizes[col] = builtin_cfg.min_col_width
			end
		end
		cat9.flag_dirty(job)
		return true
	end

-- if we are querying for a value, just append the cell to the expression
	local cell, row, col = xy_to_cell(job, ofs, yofs - 1)

	if job.in_query then
-- it would help to determine if we are in a function argument context
-- and add argument separator instead, drag range should also be handled
		cat9.readline:set(
			cat9.readline:get() .. col_to_az(col - 1) .. tostring(row)
		)
		return true
	end

-- otherwise move the cursor
	job.cell_cursor[1] = col
	job.cell_cursor[2] = row

-- new insertion?
	if not cell then
		if cat9.readline then
			query_value(job, "", "",
				function(val)
					flood_set(job, row, col, {"val", val})
				end
			)
		end
-- existing cell
	else
		if job.last_click[1] == row and job.last_click[2] == col then
			if cat9.readline then
				query_value(job, cell.value, cell.value,
					function(val)
						flood_set(job, row, col, {"val", val})
					end
				)
			end
		else
			cat9.add_message(
			string.format("%s%d%s = %s",
				col_to_az(col-1),
				row,
				cell.expression and string.format("(%s)", cell.expression) or "",
				cell.error or cell.label
			)
			)
		end
	end

	job.last_click = {row, col, cat9.time}
	cat9.flag_dirty(job)
	return true
end

-- overload so we can handle drag ourselves for region selection
local function item_motion(job, rel, x, y, mods)
	if rel then
		return
	end

	if x == job.last_mx and y == job.last_my then
		return true
	end

	job.last_mx = x
	job.last_my = y

-- make sure we'll be drawn with underline
	cat9.flag_dirty(job)
end

function builtins.new(...)
	local set = {...}
	local base = {}

	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	local job = {
		raw = "spreadsheet",
		short = "spreadsheet",
		cells = {},
		column_sizes = {},
		row_ofs = 0,
		col_ofs = 0,
		last_mx = 0,
		last_my = 0,
		cell_cursor = {1, 1},
		last_click = {0, 0, 0},
		show_line_number = false,
		spreadsheet = true,
		write = key_write,
		key_input = key_input
	}

	if set[1] and set[1] == "csv" then
		if not set[2] then
			return false, errors.missing_csv
		end

-- if set[2] is a table + slice reference, handle that
		local io, msg = root:fopen(set[2], "r")
		if not io then
			return false, errors.open_fail
		else
			import_csv(job, io)
		end
	end

	cat9.import_job(job)
	job["repeat"] = refresh_spread
	job["reset"] = function()
	end

	job:set_view(view_spread, slice_spread, nil, "Spreadsheet")
	job.handlers.mouse_button = item_click
	job.handlers.mouse_motion = item_motion
end

expand_addr =
function(addr, cb)
-- missing: handle ranges A1:B2 -> A1, A2, B1:B2 ..
--	local set = string.split(addr, ":")

	local addr_to_col_row =
	function(addr)
		local col, row = string.match(addr, "(%a+)(%d+)")
		row = tonumber(row)
		if not row then
			return false, errors.missing_row
		end

		local cv = 0
		local aval = string.byte("A") - 1
		col = string.upper(col)

		for ind=1,#col do
			cv = cv + (string.byte(col, ind) - aval) * math.pow(#az, ind - 1)
		end

		return cv, row
	end

	if string.find(addr, ":") then
		local set = string.split(addr, ":")
		if #set ~= 2 then
			return false, errors.malformed_range
		end

		local start_col, start_row = addr_to_col_row(set[1])
		local stop_col, stop_row = addr_to_col_row(set[2])

		if not start_col then
			return false, start_row
		end

		if not stop_col then
			return false, stop_col
		end

-- swap, might be better to actually enumerate high to low instead
		if stop_col < start_col then
			local tmp = start_col
			start_col = stop_col
			stop_col = tmp
		end

		if stop_row < start_row then
			local tmp = start_row
			start_row = stop_row
			stop_row = tmp
		end

-- same logic as in parser.lua (synch any fixes manually) but yield instead
-- of manipulating the token stack
		local di = 1
		for i=start_row,stop_row do
			for j=start_col,stop_col do
				cb(j, i)
			end
		end
	else
		local col, row = addr_to_col_row(addr)
		if not col then
			return col, row
		end
		cb(col, row)
	end
end

parse_expression =
function(job, cell)
	local ret, res = pcall(
		parse_expr,
		cell.expression,
		function(name, dtype)
			local rv, rt = false, types.STRING
			local ok, msg = expand_addr(
				name,
				function(col, row)

-- a possible space-time trade-off here is to track this bidirectionally
-- so that when our expression is updated, we first remove ourselves from
-- all the cells we previously listened to
					if job.cells[row] and job.cells[row][col] then
						table.insert(job.cells[row][col].listeners, cell)
						rv = job.cells[row][col].value
					end
				end
			)

			if dtype and dtype == types.NUMBER then
				return tonumber(rv), dtype
			end

			return rv, rt
		end,
		function(name) -- function lookup
			local fn = expr_funcs[name]
			if not fn then
				return false
			end
			return fn.handler, fn.args, fn.argc
		end,
		function(val)
			cell.error = val
			cell.label = "#ERROR"
		end
	)

	if not ret then
		return
	end

	if type(res) ~= "function" then
		cell.label = "#ERROR"
		return false
	end

	local act, kind, val = res()
	if kind == types.NUMBER or kind == types.STRING then
		cell:update(val, tostring(val))
-- unhandled return type, this could support synthesis of objects that
-- we then export through bchunkhandler or handover into open
	end
end

function builtins.remove(...)
	local dst, set = cat9.expand_arg_dst("remove", ...)
	if not dst then
		return false, set
	end

	local noshift
	if dst[1] == "noshift" then
		noshift = true
		table.remove(dst, 1)
	end

-- for row it's just a table.remove
end

function builtins.configure(...)
-- [row to header, substitute a-z, swap presentation]
end

local function run_insert(replace, ...)
	local dst, set = cat9.expand_arg_dst(replace and "replace" or "insert", ...)
	if not dst then
		return false, set
	end

-- ensure #job or set #job ...
	if not dst.spreadsheet then
		return false, errors.insert_job
	end

-- get address
	if not set[1] then
		return false, errors.missing_row
	end

	local col_ofs = 1
	local row_ofs = 1

	if set[1] == "cursor" then
		col_ofs = dst.cell_cursor[1]
		row_ofs = dst.cell_cursor[2]

-- allow colrow or just row
	elseif string.byte(set[1], 1) >= string.byte('A') then
		expand_addr(table.remove(set, 1), function(col, row)
			col_ofs = col
			row_ofs = row
		end)
	else
		row_ofs = tonumber(table.remove(set, 1))
	end

	if not row_ofs or row_ofs <= 0 then
		return false, errors.bad_addr
	end

-- optional separate [ptn], split [ptn]
	local col_ptn
	local row_ptn

	while #set > 0 do
		if set[1] == "separate" then
			table.remove(set, 1)
			if not set[1] then
				return false, errors.missing_separate
			end
			col_ptn = table.remove(set, 1)
		elseif set[1] == "split" then
			table.remove(set, 1)
			if not set[1] then
				return false, errors.missing_split
			end
			row_ptn = table.remove(set, 1)

-- out of options, run the actual thing
		else
			local fun = replace and ensure_replace_row or ensure_insert_row

-- with ! prefix we shell out and then post-process the results
			if set[1] == "!" then
				col_ptn = col_ptn or "%s+"
				row_ptn = row_ptn or "\n"
				table.remove(set, 1)
				local cmd = string.gsub(table.concat(set, " "), "\"", "\\\"")
				local _, out, _, pid = root:popen("/bin/sh -c \"" .. cmd .. "\"", "r", {})
				cat9.add_background_job(out, pid, {lf_strip = false},
					function(job, code)
						local set = {"#ERROR"}
						if code == 0 then
							local base = table.concat(job.data, "")
							for _,v in ipairs(string.split(base, row_ptn)) do
								local set = string.split(v, col_ptn)
								fun(dst, row_ofs, col_ofs, set)
								row_ofs = row_ofs + 1
							end
						else
							fun(dst, row_ofs, col_ofs, set)
						end

						cat9.flag_dirty(dst)
					end
				)
				break
-- otherwise treat the expanded command-line as a single string and
-- then apply the col/row split operations
			else
				if not replace then
					ensure_insert_row(dst, row_ofs, col_ofs, set)
				else
					ensure_replace_row(dst, row_ofs, col_ofs, set)
				end

				cat9.flag_dirty(dst)
				break
			end
			break
		end
	end
end

function builtins.plot(...)
-- resolve range as copy slice would
-- copy slice into set, stream set with template into dot or gplot
-- for dot we want to first resolve all statics,
-- then pick expressions based on listeners
-- popen the target application, take out and map as in into
-- afsrv_decode with protocol=image and file on stdin
	local dst, args = cat9.expand_arg_dst("set", ...)
	if not dst then
		return false, args
	end

	if not dst.spreadsheet then
		return false, errors.set_job
	end

	local set = slice_spread(dst, {"csv", "compact"})

-- if the first row isn't a number, assume it is the title and
-- add that as the plot paramters

-- generate the plotting config file and write to a tmpfile
	local file, tpath = root:tempfile("/tmp/plotXXXXXX")
	file:write(plot_templates.gnuplot.points({xmin = -5, xmax = 5, ymin = -5, ymax = 5}))
	file:flush()
	local fin, fout, _, pid = root:popen("gnuplot -c " .. tpath, "rw", {}, "gnuplot", {})

	cat9.new_window(root, "handover",
		function(par, wnd)
			if not wnd then
				cat9.add_message("window request rejected")
-- kill gnuplot pid
				file:close()
				return
			end

-- Connect gnuplot to our temp config, then write into it.
-- this is not yet streamable as _decode doesn't handle streaming svg
-- and we have no way to route bchunk or other events to afsrv_decode
-- (yet)
			fin:write(table.concat(set, "\n"))
			fin:write("\ne\n")
			fin:close()

			local stdin, _, _, pid =
				par:phandover(cat9.config.plumber, "w",
				{"afsrv_decode"}, {ARCAN_ARG = "proto=image:fdin=0"})

-- setup a copy thread that will map from gnuplot to afsrv_decode
				root:bgcopy(fout, stdin, "")
		end, "split-l"
	)
end

function builtins.insert(...)
	run_insert(false, ...)
end

function builtins.replace(...)
	run_insert(true, ...)
end

function builtins.set(...)
	local dst, args = cat9.expand_arg_dst("set", ...)
	if not dst then
		return false, args
	end

-- ensure #job or set #job ...
	if not dst.spreadsheet then
		return false, errors.set_job
	end

-- if address is provided (#args > 2) use that. If not, use selection set or
-- finally, cursor.
--
-- for address though the question is if we should have syntax for a1c1 form
-- or just stick to 'baby' mode.
	local addr

	if #args >= 2 then
		addr = table.remove(args, 1)

-- priority should be 'selected set -> active cursor'
	elseif #args == 1 then
		flood_set(dst, dst.cell_cursor[2], dst.cell_cursor[1], args)
	else
		return false, errors.set_args
	end

	local ok, msg =
		expand_addr(addr,
			function(col, row)
				if not dst.cells[row] then
					dst.cells[row] = {}
				end

				flood_set(dst, row, col, args)
			end
		)

	if not ok then
		return false, msg
	end
end

end
