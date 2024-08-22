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

local errors =
{
	bad_rows = "new >rows< cols: expected number of rows",
	bad_cols = "new rows >cols<: expected number of columns"
}

builtins.hint["new"] = "Create a new spreadsheet job with rows * cols cells"

local function new_cell(val)
	local tmpl = {
		label = ""
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

	while cq >= 1 do
		return col_to_az(cq) .. ch
	end

	return ch
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

-- draw column headers
	local lx = cw
	while lx < cols do
		if lx > cols then
			break
		end

		local ccw = job.column_sizes[col] or cw
		local fmt = job.cell_cursor[1] == x and builtin_cfg.cursor or rowfmt

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
	for ly=y+1,y+rows-2,1 do
		local yofs = yi + ly - y - 1
		local cpad = math.floor(#tostring(yi) - cw * 0.5)
		local fmt = (job.cell_cursor[2] == ly - y) and builtin_cfg.cursor or rowfmt

		job.root:write_to(
			x, ly,
			string.format("%" .. tostring(cw) .. "s", tostring(yofs)),
			fmt
		)
	end

-- draw the cell window
	for ly=y+1,y+rows-2,1 do
		local row = job.cells[yi]
		yi = yi + 1
		local cx = cw

		if row then
			for cc=job.col_ofs+1,row.cells do
				job.root:write_to(x + cx, ly, row[cc].label)
				cx = cx + (job.column_sizes[cc] or cw)
				if cx > cols then
					break
				end
			end
		end
	end

	return rows
end

local function slice_spread(job, lines, set)
-- we want 'lines' to specify format, but default to csv or resolved values
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

	local col_ind = 1

	local new_row = {}
	for i,v in ipairs(args) do
		table.insert(new_row, new_cell(v))
	end

	new_row.cells = #new_row
	table.insert(job.cells, row_ind, new_row)
	cat9.flag_dirty(job)
end

-- opts should control separator
local function import_csv(job, io, opts)
	opts = opts or {sep = ','}
	io:lf_strip(true)

	io:data_handler(
		function()
			local line, alive = io:read()
			while line do
				local tbl = string.split(line, opts.sep)
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
			job.cells[job.row_ofs + yofs].selected =
				not job.cells[job.row_ofs + yofs].selected
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

	if not cell then
		if cat9.readline then
			cat9.readline:set(
				string.format(
					"#%d set %s %d ",
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
						"#%d set %s %d %s",
						job.id,
						col_to_az(col-1), row, cell.label
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
		cell_cursor = {2, 2},
		last_click = {0, 0, 0},
		show_line_number = false
	}

-- set custom view that draws the rows and cells
	cat9.import_job(job)
	job.handlers.mouse_button = item_click
	job.handlers.mouse_motion = item_motion

	job:set_view(view_spread, slice_spread, nil, "Spreadsheet")
	local path = string.format(
		"%s/cat9/spreadsheet/test.csv",
		lash.scriptdir
	)

	local io, msg = job.root:fopen(path, "r")
	if not io then
		print("failed", msg)
	else
		import_csv(job, io)
	end
end
end
