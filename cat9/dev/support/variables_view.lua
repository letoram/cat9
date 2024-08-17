return
function(cat9, cfg, job, th, frameid)

local function var_click(job, btn, ofs, yofs, mods)
-- shift-click to set watch?
	if cat9.readline and job.data[yofs] then
		cat9.readline:set(
			string.format(
				"#%d debug #%d thread %d %d var %s",
				job.id, job.id, job.thread.id, frameid, job.data[yofs])
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

wnd.invalidated =
function()

-- locals might be pending, defer update until that happens
	th:locals(frameid,
		function(locals)
			wnd.data = {linecount = 0, bytecount = 0}

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
			end

			wnd.data.linecount = #wnd.data
			cat9.flag_dirty(wnd)
		end
	)
end

wnd:invalidated()
wnd.show_line_numbers = false
wnd.handlers.mouse_button = var_click
return wnd

end
