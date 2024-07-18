--
-- later we need ways of matching this to an external source oracle (e.g. vim)
-- but also treesitter coloring and navigation controls for jump to line-file,
-- breakpoint set, ...
--
return
function(cat9, cfg, job, source)
	local function attr_lookup(job, set, i, pos, highlight)
		local attr = cfg.debug.source_line

		if job.cursor_line and i == job.cursor_line then
			attr = cat9.table_copy_shallow(attr)
			attr.border_down = true
		end

		return attr
	end

	local data = string.split(source, "\n")
	data.linecount = #data
	local bc = 0
	for i,v in ipairs(data) do
		bc = bc + #v
	end
	data.bytecount = bc

	local wnd =
		cat9.import_job({
			short = "Debug:source",
			parent = job,
			data = data
		})

	wnd.move_to =
	function(wnd, line)
		wnd.cursor_line = line
	end

	wnd.attr_lookup = attr_lookup

return wnd
end
