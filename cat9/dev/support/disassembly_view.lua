return
function(cat9, cfg, job)

local wnd =
	cat9.import_job({
		short = "Debug:disassembly",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

return wnd
end
