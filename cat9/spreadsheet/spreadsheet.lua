--
-- draw
--
-- keyboard navigation
-- command navigation
-- mouse navigation
-- set / edit sell
--
-- expression via parser
-- basic functions (string, number)
-- export to dot
--
return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local parse_expr, types, type_strtbl =
	loadfile(string.format("%s/cat9/spreadsheet/parser.lua", lash.scriptdir))()()

lash.types = types
local expr_funcs =
	loadfile(string.format("%s/cat9/spreadsheet/functions.lua", lash.scriptdir))()

local history = {}

local expand_addr
local parse_expression

-- each function:
--  handler = function(...)
--  args = {types.TYPE}
local functions = {}

local errors =
{
	missing_csv = "new csv >file or job< : missing source argument",
	open_fail = "new csv >file< : couldn't open file",
	missing_row = "cell specifier lacks row reference (e.g. A1)",
	bad_addr = "cell address specifier has invalid values",
	insert_job = "insert >job< : job missing or not a spreadsheet",
	replace_job = "replace >job< : job missing or not a spreadsheet",
	set_job = "set >job< : job missing or not a spreadsheet",
	set_args = "set >...< : expected set [addr] \"value\" or \"=expression\" or \"=!command"
}

builtins.hint["new"] = "Create a new spreadsheet job with rows * cols cells"
builtins.hint["set"] = "Provide a value or expression for a specific cell"

local function new_cell(job, val)
	local tmpl = {
		label = "",
		update = -- accessor to add into history buffer
		function(cell, val)
			cell.label = tostring(val)
			cell.value = val
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
			if cx > cols then
				break
			end
		end

		yi = yi + 1
	end

	if builtin_cfg.column_border then
		local col = job.col_ofs + 1
		local lx = cw

		while lx < cols do
			if lx > cols then
				break
			end

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

-- copy all cells
	if not lines or #lines == 0 then
	end

--	for i,v in ipairs(lines) do
--		print("lines", i, v)
--	end

	return res

-- we want 'lines' to specify format, but default to csv or resolved values
-- as well as having subset options, e.g. specific columns
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

	new_row.cells = #new_row
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
		local nc = v.cells
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

	local cell, row, col = xy_to_cell(job, ofs, yofs - 1)
	job.cell_cursor[1] = col
	job.cell_cursor[2] = row

	if not cell then
		if cat9.readline then
			cat9.readline:set(
				string.format(
					"#%d set %s%d val \"\"",
					job.id,
					col_to_az(col-1), row
				)
			)
		end
	else
		if job.last_click[1] == row and job.last_click[2] == col then
			if cat9.readline then
				cat9.readline:set(
					string.format(
						"#%d set %s val %s",
						job.id,
						to_cell_address(col-1, row),
						cell.label
					)
				)
			end
		else
			cat9.add_message(
			string.format("%s%d = %s", col_to_az(col-1), row, cell.label)
			)
		end

		cat9.flag_dirty(job)
	end

	job.last_click = {row, col, cat9.time}
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

function builtins.plot(...)
-- gnuplot and graphviz into svg into afsrv_decode into embed.
--
-- set terminal svg dynamic enhanced background rgb 'white'
-- set datafile separator ","
-- plot "/dev/stdin" using col:1 with lines
-- \eof to separate passes?
--
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
		spreadsheet = true
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

	cb(cv, row)
end

parse_expression =
function(job, cell)
	local ret, res = pcall(
		parse_expr,
		cell.expression,
		function(name, name_type)
			local rv, rt = nil, types.STRING

			local ok, msg = expand_addr(
				name,
				function(col, row)
					if job.cells[row] and job.cells[row][col] then
						rv = job.cells[row][col].label
					end
				end
			)

			if name_type and name_type == types.NUMBER then
				return tonumber(rv)
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

local function flood_set(job, row, col, args)
	local row = job.cells[row]

	for i=1,col do
		if not row[i] then
			row[i] = new_cell(job)
			row.cells = row.cells + 1
		end
	end

	local domain = table.remove(args, 1)

	if domain ~= "val" then
-- format, name, ...
		return
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

function builtins.remove(...)
-- [row | col]
end

function builtins.configure(...)
-- [row to header, substitute a-z]
end

local function run_insert(replace, ...)
	local base = {...}
	local dst

	if type(base[1]) == "table" then
		dst = table.remove(base, 1)
	else
		dst = cat9.selectedjob
	end

-- ensure #job or set #job ...
	if not dst or not dst.spreadsheet then
		return false, errors.insert_job
	end

	local set = {}

-- now it's safe to expand #args
	local ok, msg = cat9.expand_arg(set, base)
	if not ok then
		return false, msg
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

						if not replace then
							ensure_insert_row(dst, row_ofs, col_ofs, set)
						else
							ensure_insert_row(dst, row_ofs, col_ofs, set)
						end
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

function builtins.insert(...)
	run_insert(false, ...)
end

function builtins.replace(...)
	run_insert(true, ...)
end

function builtins.set(...)
	local base = {...}
	local dst

	if type(base[1]) == "table" then
		dst = table.remove(base, 1)
	else
		dst = cat9.selectedjob
	end

-- ensure #job or set #job ...
	if not dst or not dst.spreadsheet then
		return false, errors.set_job
	end

	local args = {}

-- get rid of tables and references
	local ok, msg = cat9.expand_arg(args, base)
	if not ok then
		return false, msg
	end

-- if address is provided (#args > 2) use that. If not, use selection set or
-- finally, cursor.
--
-- for address though the question is if we should have syntax for a1c1 form
-- or just stick to 'baby' mode.
	local addr

	if #args >= 3 then
		addr = table.remove(args, 1)

-- priority should be 'selected set -> active cursor'
	elseif #args == 2 then
		addr = to_cell_address(dst.cell_cursor[1], dst.cell_cursor[2])

	else
		return false, errors.set_args
	end

	local ok, msg =
		expand_addr(addr,
			function(col, row)
				if not dst.cells[row] then
					dst.cells[row] = {cells = 0}
				end

				flood_set(dst, row, col, args)
			end
		)

	if not ok then
		return false, msg
	end
end

end
