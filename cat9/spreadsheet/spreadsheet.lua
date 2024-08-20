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

local function view_spread(job, x, y, cols, rows, probe)
	if probe then
		return rows
	end

	local cy = y
	local cw = 0
	local yi = 1 + job.row_ofs

-- draw the base rowset,
-- if we hit the currently selected one, pick other draw
-- parameters.
	local bg1 = builtin_cfg.col_1
	local bg2 = builtin_cfg.col_2
	local cw  = builtin_cfg.min_col_width
	local nc  = math.floor((cols-1) / cw)

-- draw outer border main header and column header first
	for x=0, nc * cw, cw do
	end

	for ly=y+1,y+rows-2,1 do
		local row = job.cells[yi + ly-y]

-- if not row then pad
		for x=0,nc * cw,cw do
			job.root:write_to(x, ly,
				string.lpad(" ", cw), (x+ly) % 2 == 1 and bg1 or bg2)
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
		row_ind = args.cell_cursor[1] + 1
	end

	local col_ind = 1

	local new_row = {}
	for i,v in ipairs(args) do
		table.insert(new_row, new_cell(v))
	end

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

function builtins.new(...)
	local set = {...}
	local base = {}

	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	local rows = 80
	local cols = 25

	if not tonumber(set[1]) then
		if set[1] ~= nil then
			return false, errors.bad_rows
		end
	else
		rows = tonumber(set[1])
	end

	if not tonumber(set[2]) then
		if set[2] ~= nil then
			return false, errors.bad_cols
		end
	else
		cols = tonumber(set[2])
	end

	local job = {
		raw = "spreadsheet",
		short = "spreadsheet",
		cells = {},
		row_ofs = 0,
		col_ofs = 0,
		cell_cursor = {1, 1},
		show_line_number = false
	}

	for i=1,rows do
		local row = {}

		for j=1,cols do
			table.insert(row, new_cell())
		end

		table.insert(job.cells, row)
	end

-- set custom view that draws the rows and cells
	cat9.import_job(job)

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
