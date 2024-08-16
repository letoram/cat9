return
function(cat9, cfg, job, th, frame)

local function var_click(job, btn, ofs, yofs, mods)
-- shift-click to set watch?
	if cat9.readline and job.data[yofs] then
		cat9.readline:set(
			string.format(
				"#%d debug #%d thread %d %d var %s",
				job.id, job.id, job.thread.id, frame.id, job.data[yofs])
		)
		return true
	end
end

local wnd =
	cat9.import_job({
		short = "Debug:variables",
		parent = job,
		thread = th,
		data = {bytecount = 0, linecount = 0}
	})

	local locals = frame:locals()

	if locals.locals then
		local max = 0

		for i,v in ipairs(locals.locals.variables) do
			if #v.name > max then
				max = #v.name
			end
		end

		for i,v in ipairs(locals.locals.variables) do
			if not v.error then
				table.insert(wnd.data, string.lpad(v.name, max) .. " = " .. v.value)
			end
		end

		wnd.data.linecount = #wnd.data
	end

wnd.show_line_numbers = false
wnd.handlers.mouse_button = var_click
return wnd
end
