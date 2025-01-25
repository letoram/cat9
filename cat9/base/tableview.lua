return
function(cat9, root, builtins, suggest, views)

local function show_table(job, x, y, rows, cols, probe)
-- count is cached count for current table path, updates when we step in/out
	local state = job.view_state
	local lc = state.count - job.row_offset

	if probe then
		return #rows > lc and #rows or lc
	end

	return view_fmt_job(job, job.data, x, y, rows, cols)
end

local function build_set_for_table(state)
	state.data = {
		bytecount = 0
	}

	local tbl = state.cpath[#state.cpath][1]

-- flatten table, [apply filter]
	local i, v = lua_next(tbl, v)
	while i do
		table.insert(state.data, {i, v})
		if type(v) == "string" then
			state.bytecount = state.bytecount + #v
		else
			state.bytecount = state.bytecount + 8
		end
		i, v = lua_next(tbl, i)
	end

	state.linecount = #state.data
	return state
end

function cat9.set_table_view(job, tbl)
	state = {
		table = tbl,
		cpath = {
			{tbl, 0}
		},
		count = get_count(state)
	}
	state.data = build_set_for_table(state)

	job:set_view(show_table, slice_table, state, "table")
end

-- parse and run the .lua in its own environment
--  (this is for the actual source, we don't do that here)
--
-- with debug arcan we want a copy to view that deep resolves a table
--      using recursive calls into table
--
--  setfenv(func, {})
--  pcall(
-- this takes a setfenv,
-- return {
-- }
	local test = {

	}
end
