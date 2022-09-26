-- defines the subset of window event handlers that implement the
-- reactive user-input logic for keypresses, mouse actions as well
-- as more abstract paste/binary drop.
return

function(cat9, root, config)
local handlers = cat9.handlers

local mstate = {}
function handlers.mouse_motion(self, rel, x, y, mods)
	if rel then
		return
	end

	local job = cat9.xy_to_job(x, y)
	local cols, rows = root:dimensions()

-- deselect current unless the same
	if cat9.selectedjob then
		if job and cat9.selectedjob == job then
			if job.mouse then
				if job.mouse[1] ~= x or job.mouse[2] ~= y then
					cat9.flag_dirty()
				end
			end
			job.mouse = {x, y}
			return
		end

		cat9.selectedjob.mouse = nil
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

-- select new, we keep the mouse coordinates in global space and
-- let whatever job renderer that can leverage the information work
	job.selected = true
	cat9.selectedjob = job
	job.mouse = {x, y}
	cat9.flag_dirty()
end

local function alias_expand()
	if not cat9.readline then
		return
	end

-- easy case, direct alias match
	local str = cat9.readline:get()
	if cat9.aliases[str] then
		cat9.readline:set(cat9.aliases[str])
		return
	end

-- otherwise scan existing to whitespace and try with last (this should
-- use cursor logical position but the readline widget doesn't expose)
	local pos = 1
	for i=#str,1,-1 do
		if string.sub(str, i, i) == " " then
			pos = i+1
			break
		end
	end

	if pos == 1 or pos >= #str then
		return
	end

-- try the substring for alias
	local sub = string.sub(str, pos)
	if cat9.aliases[sub] then
		cat9.readline:set(string.sub(str, 1, pos-1) .. cat9.aliases[sub])
		return
	end

-- lastly try to expand string table into arguments and swap out the string
-- though we don't currently support groups the entire way through (a | b )
-- this would break from that since the linking semantics fail.
-- Should be just to iterate over strset, figure out the linker and
-- reinject that character though.
--
-- The expand_item_cap here is just some kind of arbitrary boundary safeguard,
-- expanding the wrong range into a huge command-line.
	local set, _, _ = cat9.tokenize_resolve(str)
	local expand_item_cap = 4096
	if set then
		local strset, err = cat9.expand_string_table(set[1], expand_item_cap, true)
-- expand string table will only give us resolved symbols, sliced out jobs
-- but possibly expanded strings are not escaped, so add that to those where
-- needed.
		if strset then
			cat9.readline:set(table.concat(strset, " "))
		else
			cat9.add_message(err)
		end
	end
end

-- custom keybinds go here (or forward routing to selected window)
function handlers.key(self, sub, keysym, code, mods)
	if bit.band(mods, tui.modifiers.CTRL) > 0 then
		if keysym == tui.keys.ESCAPE then
-- to disable readline there should be >= 1 valid jobs, and then
-- we move selection with CTRL+ARROW|CTRL+HJLK
			if cat9.readline then
				cat9.hide_readline(root)
			else
				cat9.block_readline(root, false)
				cat9.setup_readline(root)
			end
			return

		elseif keysym == tui.keys.SPACE then
			alias_expand()

		elseif cat9.bindings[keysym] then
			cat9.parse_string(false, cat9.bindings[keysym])
			cat9.flag_dirty()

		elseif keysym == tui.keys.R then
			if cat9.readline then
				cat9.suggest_history()
				return
			end
		end
	end

	if (cat9.selectedjob and cat9.selectedjob.write) then
		cat9.selectedjob:write(keysym)
	end
end

function handlers.state_in(self, blob)
	blob:lf_strip(true)
	local buf = {}
	local alive = true

-- just buffer everything first.
	while (alive) do
		_, alive = blob:read(buf)
	end
	blob:close()

	local magic = table.remove(buf, 1)
	if not magic or magic ~= "cat9_state_v1" then
		cat9.add_message("state-load: missing header/magic id")
		return
	end

-- then split/parse
	while #buf > 0 do
		local header = table.remove(buf, 1)
		header = string.split(header, " ")
		if #header ~= 2 or tonumber(header[2]) == nil then
			break
		end

-- trivial line format:
-- group n_keys\n
-- key\nval\n
-- key\nval\n
-- ...
		local group = header[1]
		local count = tonumber(header[2])
		local added = 0

-- fill out with k[y]
		local out = {}
		while count > 0 do
			local key = table.remove(buf, 1)
			local val = table.remove(buf, 1)
			if not key or not val then
				cat9.add_message("state-load: missing key/values in group " .. group)
				break
			end

			count = count - 1
			out[key:gsub("^%s*", "")] = val:gsub("^%s*", "")
			added = added + 1
		end

-- and forward to the right module
		if cat9.state.import[group] then
			if added > 0 then
				cat9.state.import[group](out)
			end
		else
			cat9.state.orphan[group] = out
		end
	end
end

local function out_append_table(name, out, set)
	table.insert(out, "") -- reserve header space
	local ci = #out

	local count = 0
	for k,v in pairs(set) do
		if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
			v = tostring(v)
			if not string.find(v, "\n") then
				count = count + 1
				table.insert(out, string.format("\t%s\n", k))
				table.insert(out, string.format("\t%s\n", v))
			end
		end
	end

	out[ci] = string.format("%s %d\n", name, count)
end

-- generate a t[group]={k=v} table of all registered state providers
function handlers.state_out(self, blob, internal)
-- run through all state handlers and retrieve their states
	local out = {"cat9_state_v1\n"}

	for k,v in pairs(cat9.state.export) do
		local i = 1

-- the exporter can either provide 1:1 or 1:* on import.
		local set = v()
		if type(set[1]) == "table" then
			for _, v in ipairs(set) do
				out_append_table(k, out, v)
			end
		else
			out_append_table(k, out, set)
		end
	end

	blob:write(out)

	if not internal then
		blob:flush(-1)
		blob:close()
	end
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

	if active then
		mstate[index] = active
		return
	end

-- ghost release
	if not mstate[index] then
		return
	end

-- completed click? (trigger on falling edge)
	mstate[index] = nil
	local cols, _ = root:dimensions()

	local try =
	function(...)
		local str = string.format(...)
		if cat9.bindings[str] then
			cat9.parse_string(nil, cat9.bindings[str])
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
-- in order to have better click-action handlers

-- Then check if we should act special on the data region of a job,
-- first try a specific column (1 is line-number/meta, 2 is data).
	local in_data = cat9.xy_to_data(x, y)
	if not in_data then
		return
	end

	if job.mouse and job.mouse.on_col then
		if try("m%d_data_col%d_click", index, job.mouse.on_col) then
			return
		end
	end

-- if that doesn't yield anything, a generic 'on data' one
	if try("m%d_data_click", index) or try("m%d_click", index) then
	end
end

function cat9.reset()
	root:revert()
	root:set_flags(config.mouse_mode)
	cat9.setup_readline(root)
	cat9.flag_dirty()
end

-- use for monotonic scrolling (drag+select on expanded?) and dynamic prompt
local clock = 10
function handlers.tick()
	cat9.time = cat9.time + 1
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
-- the :write is likely an nbio- table, but can be swapped out if interleaving/
-- queuing mechanisms are needed
	if cat9.selectedjob and cat9.selectedjob.inp then
		cat9.selectedjob:write(ch)
		return true
	end
end

end
