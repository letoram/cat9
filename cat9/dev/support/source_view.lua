return
function(cat9, cfg, job)

local wnd =
	cat9.import_job({
		short = "Debug:source",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

-- cfg option to spawn external viewers through handover
-- expose controls to set file and path
-- check if any breakpoints match the current view
-- treesitter plugin for highlighting

return wnd
end
