--
-- later we need ways of matching this to an external source oracle (e.g. vim)
-- but also treesitter coloring and navigation controls for jump to line-file,
-- breakpoint set, ...
--
return
function(cat9, cfg, job, source)
	local function click(job, btn, ofs, yofs, mods)
		print("click", btn, ofs, yofs)
	end

	local function attr_lookup(job, set, i, pos, highlight)
		local attr = cfg.debug.source_line

-- use background color to mark breakpoint (active, passive, hit, ...)
		if job.cursor_line and i == job.cursor_line then
			attr = cat9.table_copy_shallow(attr)
			attr.border_down = true
		end

		return attr
	end

	local data = {linecount = 0, bytecount = 0}
	local wnd =
		cat9.import_job({
			short = "Debug:source",
			parent = job,
			data = data
		})

-- need to consider number of actually visible lines and set offset
-- such that the actual line is within view
	wnd.move_to =
	function(wnd, line)
		local rows = wnd.collapsed_rows
		if wnd.expanded and wnd.lasthint then
			rows = job.lasthint.max_rows
		end

		wnd.row_offset = math.floor(line - 0.5 * rows)
		if wnd.row_offset < 0 then
			wnd.row_offset = 0
		end

		wnd.cursor_line = line
		cat9.flag_dirty(wnd)
	end

-- this is where treesitter highlighting would go by simply generating
-- formatting attributes for each line in data and returning those when
-- dirty
	wnd.source =
	function(wnd, source, line)
		local data = string.split(source, "\n")
		data.linecount = #data
		local bc = 0
		for i,v in ipairs(data) do
			bc = bc + #v
		end
		data.bytecount = bc
		wnd.data = data
		cat9.flag_dirty(wnd)
	end

	wnd:source(source, 1)
	wnd.attr_lookup = attr_lookup
	wnd.expanded = false
	wnd.row_offset_relative = false

return wnd
end
