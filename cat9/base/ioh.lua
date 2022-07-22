-- defines the subset of window event handlers that implement the
-- reactive user-input logic for keypresses, mouse actions as well
-- as more abstract paste/binary drop.
return

function(cat9, root, config)
local handlers = cat9.handlers

local mstate = {}
function handlers.mouse_motion(self, rel, x, y)
	if rel then
		return
	end

	local job = cat9.xy_to_job(x, y)
	local cols, rows = root:dimensions()

-- deselect current unless the same
	if cat9.selectedjob then
		if job and cat9.selectedjob == job then
			return
		end

		cat9.selectedjob.selected = nil
		cat9.selectedjob = nil
		cat9.flag_dirty()

		return
	end

-- early out common case
	if not job then
		cat9.selectedjob = nil
		return
	end

-- select new
	job.selected = true
	cat9.selectedjob = job
	job.mouse_x = x
	cat9.flag_dirty()
end

-- custom keybinds go here (or forward routing to selected window)
function handlers.key(self, sub, keysym, code, mods)

	if bit.band(mods, tui.modifiers.CTRL) then
		if keysym == tui.keys.ESCAPE then

-- to disable readline there should be >= 1 valid jobs, and then
-- we move selection with CTRL+ARROW|CTRL+HJLK
			if cat9.readline then
--				root:revert()
--				cat9.readline = nil
			end

-- uncertain how to display the help still, just popup at last
-- known cursor position? or as regular popup?
		elseif keysym == tui.keys.F1 then
--			print("toggle help")
		elseif keysym == tui.keys.R then
			cat9.suggest_history()
		end
	end
end

function handlers.state_in(self, blob)
end

function handlers.state_out(self, blob)
end

--
-- two options for this, one is a prefill copy [$blobin] >test.id
-- and move cursor in there and prepare prompt (possibly save last / current line)
--
function handlers.bchunk_out(self, blob, id)
	if type(cat9.resources.bout) == "function" then
		cat9.resources.bout(id, blob)
	else
		cat9.add_message("request for outbound binary blob")
		cat9.resources.bout = {id, blob}
	end
end

function handlers.bchunk_in(self, blob, id)
	if type(cat9.resources.bin) == "function" then
		cat9.resources.bin(id, blob)
	else
		cat9.add_message("got incoming binary blob")
		cat9.resources.bin = {id, blob}
	end
end

-- these are accessible to the copy command via $res
function handlers.paste(self, str)
	if config.clipboard_job then
		if not cat9.clipboard_job then
			cat9.clipboard_job = cat9.import_job({short = "clipboard", raw = "clipboard [paste]"})
		end
		local job = cat9.clipboard_job

-- have the paste behave as line-buffered input
		if #str > 0 then
			for _,v in ipairs(string.split(str, "\n")) do
				job.data.bytecount = job.data.bytecount + #str
				job.data.linecount = job.data.linecount + 1
				table.insert(job.data, v .. "\n")
			end
		end

		cat9.redraw()
		cat9.flag_dirty()
	else
		cat9.readline:suggest({str}, "insert")
	end
end

function handlers.mouse_button(self, index, x, y, mods, active)
-- motion will update current selection so no need to do the lookup twice
	if not cat9.selectedjob then
		return
	end

-- track for drag
	if not active and mstate[index] then
		mstate[index] = nil
		local cols, _ = root:dimensions()

		local try =
		function(...)
			local str = string.format(...)
			if config[str] then
				cat9.parse_string(nil, config[str])
				return true
			end
		end

-- first check if we are on the job bar, and the bar handler for the job
-- has a mouse action assigned to the group index at the cursor position
		local id, job = cat9.xy_to_hdr(x, y)
		if job and id > 0 then
			local mind = "m" .. tostring(index)
			local cfgrp = config[job.last_key][mind]

			if cfgrp and cfgrp[id] then
				cat9.parse_string(nil, cfgrp[id])
				return
			end
		end

-- here is a possible spot for forwarding to the active view on the job
-- in order to have better click-action handlers (e.g. open or select per line)

-- then check if we should act special on the data (e.g. scroll) or
-- fallback to a more generic mouse handler
		if (
			(cat9.xy_to_data(x, y) ~= nil and try("m%d_data_click", index)) or
			try("m%d_click", index)) then
			return
		end

	elseif active then
		mstate[index] = active
	end
end

function cat9.reset()
	root:revert()
	root:set_flags(config.mouse_mode)
	cat9.setup_readline(root)
end

-- use for monotonic scrolling (drag+select on expanded?) and dynamic prompt
local clock = 10
function handlers.tick()
	clock = clock - 1

	if clock == 0 then
		cat9.flag_dirty()
		clock = 10
	end

-- auto-clean jobs, ones that need periodic polling, ...
	if #cat9.timers > 0 then
		local torem = {}
		for i=#cat9.timers,1 do
			if not cat9.timers[i]() then
				table.remove(cat9.timers, i)
			end
		end
	end
end

function handlers.utf8(self, ch)
-- setup readline, cancel current selection activity and inject ch
end

end
