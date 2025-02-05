return
function(cat9, cfg, job, th, frameid)

local function var_click(job, btn, ofs, yofs, mods)
-- shift-click to set watch?
	if cat9.readline then
		cat9.readline:set(
			string.format(
				"#%d debug #%d thread #%d %d var %s",
				job.id, job.id, job.thread.id, frameid, job.data[yofs])
		)
		return true
	end
end

-- useful:
--
--  architecture specific helpers for pretty-printing registers
--  and provide hover / suggestions for flags etc.
--
local wnd =
	cat9.import_job({
		short = "Debug:LuaVM stack",
		parent = job,
		thread = th,
		data = {bytecount = 0, linecount = 0}
	})

	if false then
		th:stackvars(
	function(vars)
		for i,v in ipairs(vars) do
			table.insert(wnd.data, tostring(v.level) .. ": " .. v.value)
		end
		wnd.data.linecount = #wnd.data
	end
	)
end

wnd.show_line_numbers = false
wnd.handlers.mouse_button = var_click
return wnd
end
