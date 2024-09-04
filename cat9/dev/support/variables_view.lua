return
function(cat9, cfg, job, th, frameid, opts)

local function var_click(job, btn, ofs, yofs, mods)
-- shift-click to set watch?
	if not cat9.readline or not job.data[yofs] then
		return false
	end

	local var = job.data.vars[yofs]
	if var.namedVariables and var.namedVariables > 0 then
		if not var.variables then
			var:fetch(
				function(inv)
					var.expanded = true
					job:invalidated()
				end
			)
		else
			var.expanded = not var.expanded
			job:invalidated()
		end

		return true
	end

-- with modifier click a variable tracker should be spawned or appended to
-- (which should also support sampling various memory addresses)

-- this does not work recursively, we need to bind to parent so b->bb would say b.bb. etc.
	cat9.readline:set(
		string.format(
			"#%d debug #%d thread %d %d var %s",
			job.id, job.id, job.thread.id, frameid, job.data[yofs])
	)
	return true
end

local function recurse_append(data, max, v)
	table.insert(data.vars, v)

	if v.expanded and v.variables then
		table.insert(data, string.lpad(v.name, max) .. ":")

		for _,iv in ipairs(v.variables) do
			recurse_append(data, max + 4, iv)
		end
	else
		table.insert(data, string.lpad(v.name, max) .. " = " ..
			(v.variables and " ... " or v.value))
	end
end

local wnd =
cat9.import_job({
	short = "Debug:" .. (opts.globals and "globals" or "variables"),
	parent = job,
	thread = th,
	data = {bytecount = 0, linecount = 0}
})

wnd.invalidated =
function()

-- locals might be pending, defer update until that happens
	th:locals(frameid,
		function(locals)
			wnd.data = {linecount = 0, bytecount = 0, vars = {}}
			local key = opts.globals and "globals" or "locals"

			if locals[key] then
				local max = 0

-- align left part for first layer
				for i,v in ipairs(locals[key].variables) do
					if #v.name > max then
						max = #v.name
					end
				end

				for i,v in ipairs(locals[key].variables) do
					if not v.error then
						recurse_append(wnd.data, max, v)
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
