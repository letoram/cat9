return
function(cat9, cfg, job, th, frameid, opts)

local function write_vars(job, x, y, row, set, ind, _, selected)
	local fattr = cfg.debug.variable
	if job.mouse then
		if job.mouse.on_row == ind then
			fattr = table.copy_recursive(fattr)
			fattr.border_down = true
		end
	end

	job.root:write_to(x, y, set[ind], fattr)
end

local function var_click(job, btn, ofs, yofs, mods)
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

	elseif btn == 2 then
		local cv = job.data.vars[yofs]

-- need to handle nested structs so reverse-build a path up to the scope,
-- but the outmost one is the variable scope itself
		local namepath = {cv.name}
		cv = cv.parent
		while cv.parent do
			table.insert(namepath, 1, cv.name)
			cv = cv.parent
		end

		cat9.readline:set(
			string.format(
				"#%d debug #%d thread %d %d watches %s %s",
				job.id, job.id, job.thread.id, frameid,
				opts.scope or "locals", table.concat(namepath, " ")
			)
		)
		return true
	end

-- with modifier click a variable tracker should be spawned or appended to
-- (which should also support sampling various memory addresses)

-- this does not work recursively, we need to bind to parent so b->bb would say b.bb. etc.
	local oprompt = cat9.get_prompt
	cat9.set_readline(
		lash.root:readline(
			function(self, line)
				cat9.get_prompt = oprompt
				if line and #line > 0 then
					job.data.vars[yofs]:modify(line)
				end
				cat9.block_readline(lash.root, false, false)
				cat9.reset()
			end,
			{
				cancellable = true,
				forward_meta = false,
				forward_paste = true,
				forward_mouse = false
			}), "dbg:var"
	)
	cat9.block_readline(lash.root, true, true)
	cat9.get_prompt = function()
		return {"(set " .. job.data.vars[yofs].name .. ") "}
	end

	cat9.readline:set(job.data.vars[yofs].value)
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
			(v.namedVariables and " ... " or v.value))
	end
end

local wnd =
cat9.import_job({
	short = "Debug:" .. (opts.scope and opts.scope or "variables"),
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
			local key = opts.scope and opts.scope or "locals"

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
wnd.write_override = write_vars

return wnd

end
