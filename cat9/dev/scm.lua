--
-- support functions and wrapper / integration for several SCMs within
-- the same source tree.
--
-- The different SCMs share the same primary output job or prompt-control.
--
return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local in_monitor
local config = cat9.config
local update_prompt

local function write_row_or_column(dst, x, y, cols, row, column, attr)
	if not column then
		_, x, y = dst:write_to(x, y, row, attr)
		return x, y
	end

	for i,v in ipairs(column) do
		_, x, y = dst:write_to(x, y, v.label, v.label_attr or attr)
		_, x, y = dst:write_to(x, y, v.data, v.data_attr or attr)
		x = x + 1

		if x >= cols then
			break
		end
	end

	return x, y
end

local function write_monitor(job, x, y, row, set, ind, _, selected, cols)
	local mouse = job.mouse
	local tags = set.tags or {}
	local tag = tags[ind]

-- show most significant characters
	if #row > cols then
		row = "..." .. string.sub(row, #row - cols * 0.5)
	end

-- expand action verbs when on a row with items
	if mouse and mouse.on_row and mouse.on_row == ind and tag then
		mouse.click_handler = nil
		local attr = tag.attr

		if tag.action_words then
			x, y = write_row_or_column(job.root, x, y, cols, row, tag.columns, attr)

-- prioritize action_words on overflow
			local count = 0
			for i,v in ipairs(tag.action_words) do
				count = count + #v[1] + 1
			end

			if x + count > cols then
				x = cols - count
				if x < 0 then
					x = 0
				end
			end

			for i,v in ipairs(tag.action_words) do
				local attr = v[2]
				_, x, y = job.root:write_to(x, y, " ")

				if mouse[1] >= x and mouse[1] <= x + #v[1] then
					attr = cat9.table_copy_shallow(attr)
					mouse.click_handler = v[3]
					attr.border_down = true
				end

				_, x, y = job.root:write_to(x, y, v[1], attr)
			end
		else
			write_row_or_column(job.root, x, y, cols, row, tag.columns, tag and tag.attr)
		end

		return
	end

	local attr = builtin_cfg.scm.data
	write_row_or_column(job.root, x, y, cols, row, tag and tag.columns, attr)
end

local function click_monitor(job, btn, ofs, yofs, mods)
	local fn = job.data.tags and job.data.tags[yofs]

-- only use lclick
	if btn ~= 1 then
		return false
	end

-- figure out the action word at which offset
	if job.mouse and job.mouse.click_handler then
		job.mouse.click_handler()
		return true

	elseif fn and fn.click then
		fn.click()
		return true
	end
	return yofs > 0 and btn == 1
end

local function build_data(path)
	in_monitor.data = {linecount = 0, bytecount = 0}
	local promptstr = ""

	for i,v in ipairs(in_monitor.scm_handlers) do
		v(path)
	end
end

local function refresh_monitor()
	local job = in_monitor
	job.data = {linecount = 0, bytecount = 0}
	job.pending = 0
	job.short = string.format("dev:scm monitor(%s)", root:chdir())

	local got_scm = false
	for i,v in ipairs(job.scm_handlers) do
		got_scm = v(job.dir) or got_scm
	end

	if not got_scm then
		if job.add_line then
			job:add_line("No source control active", {})
		end

		if job.prompt then
			job.prompt = "dev.scm:none"
		end
	end

	cat9.flag_dirty(job)
end

local function drop_prompt()
	if not in_monitor or not in_monitor.prompt then
		return
	end

	local tgt_i
	for i=1,#config.prompt_focus do
		if config.prompt_focus[i] == update_prompt then
			tgt_i = i
			break
		end
	end

	if tgt_i then
		table.remove(config.prompt_focus, tgt_i-1) -- drop $begin
		table.remove(config.prompt_focus, tgt_i-1) -- drop update_prompt
		table.remove(config.prompt_focus, tgt_i-1) -- drop $end
	end

-- if we own the monitor, just clear it and the handles
	if not in_monitor.imported then
		cat9.dir_monitor[in_monitor] = nil
		in_monitor = nil
	else -- otherwise just remove the prompt tracking
		in_monitor.prompt = nil
	end
end

update_prompt =
function()
	if in_monitor then
		return in_monitor.prompt
	else
		return "dev:scm()"
	end
end

local function attach_prompt()
	local insert_ind

	for i,v in ipairs(config.prompt_focus) do
		if v == '$dynamic' then
			insert_ind = i
			break
		end
	end
	if not insert_ind then
		cat9.add_message("dev:scm prompt - config.prompt_focus lacks $dynamic slot")
	else
		table.insert(config.prompt_focus, insert_ind, "$begin")
		table.insert(config.prompt_focus, insert_ind+1, update_prompt)
		table.insert(config.prompt_focus, insert_ind+2, "$end")
		return true
	end
end

local support_fossil =
	loadfile(string.format("%s/cat9/dev/support/fossil.lua", lash.scriptdir))()

local function cmd_monitor(arg)
-- 'prompt' form
	local prompt = (arg and arg == "prompt") or nil

-- toggle prompt form on / off
	if in_monitor and in_monitor.prompt then
		if prompt then
			drop_prompt()
			return
		end
	end

-- necessary tracking: where we are
	local cdir = root:chdir()
	local job = {
		short = string.format("dev:scm monitor(%s)", cdir),
		raw = "dev:scm monitor",
		dir = cdir,
		scroll_lock = true,
		check_status = function() return true; end,
		prompt = prompt
	}

-- find where in the prompt we can attach
	if prompt then
		if not attach_prompt() then
			return
		end

-- already got a monitor session, mark prompt as available
		if in_monitor then
			in_monitor.prompt = prompt
			return
		end

-- or import the job as a 'proper' one
	else
		if in_monitor then
			if in_monitor.imported then -- unless it already is
				return
			end
			job = in_monitor
		end

		cat9.import_job(job)
		job.imported = true
		job.show_line_number = false
		job["repeat"] = refresh_monitor

		table.insert(
			job.hooks.on_destroy,
			function()
				job.imported = false

				if not job.prompt then -- only release if we don't also have a prompt monitor
					in_monitor = nil
					cat9.dir_monitor[job] = nil
				end
			end
		)
	end

	job.write_override = write_monitor
	job.handlers.mouse_button = click_monitor

-- attach to directory changes and use it to trigger rescan
	cat9.dir_monitor[job] =
		function(new, old)
			job.dir = new
			refresh_monitor()
		end

	in_monitor = job

	job.scm_handlers = {
		support_fossil(cat9, root, builtin_cfg, write_monitor, click_monitor, build_data, job)
	}

	refresh_monitor()
end

local cmds =
{
	monitor = cmd_monitor
}

builtins.hint.scm = "Create a job tracking source-control state"

function suggest.scm(args, raw)
	if #args == 2 then
	end
end

function builtins.scm(cmd, ...)
	if cmd and cmds[cmd] then
		return cmds[cmd](...)
	end
end

end
