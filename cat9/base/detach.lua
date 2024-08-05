--
-- todo:
--  handle bchunk state for drag and drop
--

return
function(cat9, job)

local detach_handlers = {}
function detach_handlers.mouse_motion(self, rel, x, y, mods)
	job.mouse = {x, y}
	cat9.flag_dirty(job)
end

local function run_as_selected(job, closure)
	local csel = cat9.selectedjob
	cat9.selectedjob = job
	closure()
	cat9.selectedjob = csel
end

local function try_click(...)
	local str = string.format(...)
	if cat9.bindings[str] then
		cat9.parse_string(nil, cat9.bindings[str])
		return true
	end
end

function detach_handlers.mouse_button(self, index, x, y, mods, active)
	if job.handlers.mouse_button and not active then
		run_as_selected(job,
				function()
					local id, job = cat9.xy_to_hdr(self, x, y)
					if job and id > 0 then
						local mind = "m" .. tostring(index)
						local cfgrp = cat9.config[job.last_key][mind]
						if cfgrp and cfgrp[id] then
							cat9.parse_string(nil, cfgrp[id])
							return
						end
					end

					if (job.handlers.mouse_button(job, index, x, y, mods, active)) then
						return
					end

					if job.mouse and job.mouse.on_col then
						if try_click("m%d_data_col%d_click", index, job.mouse.on_col) then
							return
						end
						local _ = try_click("m%d_data_click", index) or try_click("m%d_click", index)
					end
				end
		)
	end
end

function detach_handlers.key(self, sub, keysym, code, mods)
	if job.key_input then
		run_as_selected(job,
			function() job:key_input(sub, keysym, code, mods) end
		)
	elseif job.write then
		run_as_selected(job,
			function() job:write(keysym) end
		)
	end
	cat9.flag_dirty(job)
end

function detach_handlers.tick(self)
end

function detach_handlers.exec_state(self, state)
	if job.root ~= self then
		return
	end

-- should destroy window return the job or chain the destruction
	if state == "shutdown" then
		for i,v in ipairs(job.hooks.on_destroy) do
			if v == job.detach_destroy then
				table.remove(job.hooks.on_destroy, i)
				break
			end
		end

		job.hidden = false
		job.detach_handlers = nil

		if job.detach_keep then
			job.detach_destroy = nil
			job.root = lash.root
		else
			cat9.remove_job(job)
		end
		cat9.flag_dirty(job)
	end
end

function detach_handlers.utf8(self, ch)
	if job.write then
		return job:write(ch)
	end
end

function detach_handlers.redraw(self)
	self:erase()
	local cols, rows = self:dimensions()
	run_as_selected(job, function()
		job.expanded = true
		job.selected = true
		job.region = {0, 0, cols, rows}
		job:view(0, 1, cols, rows - 1, false)
		cat9.draw_job_header(job, 0, 0, cols, 1)
	end)
end

function detach_handlers.state_in(self, blob)
-- this should ignore cat9.config.allow_state
end

function detach_handlers.state_out(self, blob)
end

function detach_handlers.bchunk_out(self, blob, id)
-- chain, we can't do much
end

function detach_handlers.bchunk_in(self, blob, id, lref)
-- chain, we can't do much
end

function detach_handlers.paste(self, str)
--forward as write into job
end

function detach_handlers.visibility()
end

function detach_handlers.recolor(self)
	detach_handlers.redraw(self)
end

function detach_handlers.resized(self)
	detach_handlers.redraw(self)
end

	return detach_handlers
end
