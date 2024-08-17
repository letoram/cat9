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
		short = "Debug:arguments",
		parent = job,
		thread = th,
		data = {bytecount = 0, linecount = 0}
	})

	th:locals(frameid,
	function(locals)
		if locals.locals then
			local max = 0
			for i,v in ipairs(locals.arguments.variables) do
				if #v.name > max then
					max = #v.name
				end
			end

			for i,v in ipairs(locals.arguments.variables) do
				table.insert(wnd.data, string.lpad(v.name, max) .. " = " .. v.value)
			end

			wnd.data.linecount = #wnd.data
		end
	end
	)

wnd.show_line_numbers = false
wnd.handlers.mouse_button = var_click
return wnd
end
