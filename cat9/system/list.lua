return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local function resolve_path(path)
	local old = root:chdir()
	root:chdir(path)
	path = root:chdir()
	root:chdir(old)
	return path
end

local function parse_ls(data)
	local res = {}

-- F (classify), remove = /, b = C escape normal
	for _,v in ipairs(data) do
		local ent = {}
		if string.sub(v, -1) == "/" and string.sub(v, -2) ~= "\\/" then
			ent.directory = true
			v = string.sub(v, 1, -2)
		elseif string.sub(v, -1) == "=" and string.sub(v, -2) ~= "\\=" then
			ent.socket = true
			v = string.sub(v, 1, -2)
		elseif string.sub(v, -1) == "*" and string.sub(v, -2) ~= "\\*" then
			ent.executable = true
			v = string.sub(v, 1, -2)
		elseif string.sub(v, -1) == "@" and string.sub(v, -2) ~= "\\@" then
			ent.link = true
			v = string.sub(v, 1, -2)
		end

		ent.name = string.gsub(v, "\\ ", " ")
		table.insert(res, ent)
	end

-- for the -l version things are much more involved:
--  split on spaces up until the filename, then look for C escapes
--       aaaaaaaaaa user group     sz 'text date' file/dir -> link

	data.files = res
end

local function queue_monitor(src, trigger)
	if src.monitor_pid then
		root:psignal(src.monitor_pid, "kill")
		src.monitor_pid = nil
	end

-- Watch is expected to match a binary and arguments to watch a path for
-- changes to trigger on, might be a point to add event triggers here
-- that could be hooked with trigger as well. The consequence for that
-- is that the job structure would again gain more inputs/outputs in the
-- form of dynamic triggers.
	if type(builtin_cfg.list.watch) ~= "table" then
		return
	end

	local set = table.copy_recursive(builtin_cfg.list.watch)

	for i=1,#set do
		if set[i] == "$path" then
			set[i] = src.dir
		end
	end

	local _, out, _, pid = root:popen(set, "r")
	if not pid then
		return
	end

-- don't really care which trigger, repeat regardless
	src.monitor_pid = pid
	cat9.add_background_job(out, pid, {lf_strip = true},
	function(job, code)
		if src.monitor_pid == pid then
			src.monitor_pid = nil

			if code == 0 then
				src["repeat"]()
			end
		end
	end)
end

local function queue_ls(src, path)
-- kill any outstanding ls request as it might be dated
	if src.ls_pending then
		root:psignal(src.ls_pending, "kill")
		srfc.ls_pending = nil
	end

	if string.sub(path, 1, 1) ~= "/" then
		path = resolve_path(src.dir .. "/" .. path)
	end

	local _, out, _, pid = root:popen({"/usr/bin/env", "/usr/bin/env", "ls", "-1aFb", path}, "r")
	if not pid then
		cat9.add_message("builtin:list - couldn't spawn ls")
		return
	end

-- and any listening monitor process
	if src.monitor_pid then
		root:psignal(src.monitor_pid, "kill")
		src.monitor_pid = nil
	end

-- asynch a new background job with the spawned ls
	cat9.add_background_job( out, pid, {lf_strip = true},
		function(job, code)
			if code == 0 then
				parse_ls(job.data)
				src.data = job.data
				src.raw = path
				src.short = path
				src.dir = path
				src.data.files_filtered = nil
				src.last_view = nil
				cat9.flag_dirty()
				queue_monitor(src)

-- recovery here would be to strip away path until we get something that exist
			else
				cat9.add_message("list failed: " .. table.concat(job.data, ""))
			end
			src.ls_pending = nil
		end
	)
end

local function filter_job(job, set)
	local res = {bytecount = 2}
	local up = {directory = true, name = ".."}
	table.insert(res, up)
	res[up.name] = up

-- ignore hidden?
	for _,v in ipairs(set) do
		if v.name == ".." or v.name == "." then
		elseif not builtin_cfg.hidden and
			string.sub(v.name, 1, 1) == "." then
		else
			table.insert(res, v)
			res.bytecount = res.bytecount + #v.name
			res[v.name] = v
		end
	end

	res.linecount = #res
	return res
end

-- Slicer here needs to be able to present different detailed views of the
-- current set of files with different coloring and details options. Use the
-- normal helper to extract the desired range (lines).
local function print_file(job, line)
	return line.name, #line.name, 1
end

local function slice_files(job, lines)
	if not job.data.files_filtered then
		job.data.files_filtered = filter_job(job, job.data.files)
	end

	local res = {}
	return
		cat9.resolve_lines(
			job, res, lines,
			function(i)
				if not i then
					local ret = {}
					for _,v in ipairs(job.data) do
						table.insert(ret, v .. "\n")
					end
					return ret
				end

				if job.data.files_filtered[i] then
					return print_file(job, job.data.files_filtered[i])
				else
					return nil, 0, 0
				end
			end
		)
end

local function get_attr(job, set, i, pos, highlight)
	local res = builtin_cfg.list.file

	if not job.data.files_filtered or not job.data.files_filtered[set[i]] then
		return res
	end

	if highlight then
		res = cat9.config.styles.data_highlight

-- socket, directory, executable, might send to open for probe as well?
	elseif job.data.files_filtered[set[i]].directory then
		res = builtin_cfg.list.directory

	elseif job.data.files_filtered[set[i]].socket then
		res = builtin_cfg.list.socket

	elseif job.data.files_filtered[set[i]].executable then
		res = builtin_cfg.list.executable

	elseif job.data.files_filtered[set[i]].link then
		res = builtin_cfg.list.link
	end

	if job.mouse and job.mouse.on_row == i then
		res = table.copy_recursive(res)
		res.border_down = true
		job.cursor_item = job.data.files_filtered[set[i]]
	end

	return res
end

local function view_files(job, x, y, cols, rows, probe)
	if not job.data.files_filtered then
		job.data.files_filtered = filter_job(job, job.data.files)
	end

	if not job.last_view or #job.last_view ~= #job.data.files_filtered then
		job.last_view = {bytecount = 0, linecount = 0}
		job.selections = {}
		for _,v in ipairs(job.data.files_filtered) do
			local name, bc, lc = print_file(job, v)
			table.insert(job.last_view, name)
			job.last_view.bytecount = job.last_view.bytecount + 1
			job.last_view.linecount = job.last_view.linecount + 1
			if job.last_selection and job.last_selection[name] then
				job.selections[#job.last_view] = true
			end
		end
	end

	local set = job.last_view

	if probe then
		return #set > rows and rows or #set
	end

	job.cursor_item = nil
	return cat9.view_fmt_job(job, set, x, y, cols, rows)
end

-- the cursor selection is already set so click is assumed to hit
local function item_click(job, btn, ofs, yofs, mods)
	local line_no_click = job.mouse and job.mouse.on_col == 1

	if not job.cursor_item or (line_no_click and job.cursor_item.name ~= "..") then
		return
	end

-- on directory: special case for navigation where left click will take precedence
	if mods == 0 and btn == 1 and job.cursor_item.directory then
		queue_ls(job, "./" .. job.cursor_item.name)
		return true
	end

-- different type actions, context popup etc. would go here
	local mstr = cat9.modifier_string(mods) .. "m" .. tostring(btn)

	if builtin_cfg.list[mstr] then
		cat9.parse_string(nil, builtin_cfg.list[mstr])
		return true
	end

-- drag is not covered by this still (e.g. drag from one job to another)
	return true
end

function builtins.list(path)
-- apply it by chdir-ir first
	if not path then
		path = "./"
	end

	local ok, kind = root:fstatus(path)

	if not ok or kind ~= "directory" then
		cat9.add_message("list: path is not a directory")
		return
	end

	local job = {
		short = path,
		raw = path,
		check_status = function() return true; end,
		attr_lookup = get_attr,
	}
	cat9.import_job(job)

-- since this can be called when new files appear the actual names of selected
-- lines need to be saved and re-marked on discovery
	job["repeat"] =
	function()
		job.last_view = nil
		job.last_selection = {}
		for i,v in ipairs(job.selections) do
			job.last_selection[job.data[i]] = true
		end
		job.selections = {}
		job.data.files = {}
		job.handlers.mouse_button = item_click
		job:set_view(view_files, slice_files, {}, "list")
		if not job.dir then
			job.dir = path
		end
		queue_ls(job, job.dir)
	end

	job["repeat"]()
end

function suggest.list(args, raw)
	local argv, prefix, flt, offset =
		cat9.file_completion(args[2], cat9.config.glob.dir_argv)

	cat9.filedir_oracle(argv,
		function(set)
			if #raw == 3 then
				table.insert(set, 1, "..")
				table.insert(set, 1, ".")
			end
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			cat9.readline:suggest(set, "substitute", "list \"" .. prefix, "/\"")
		end
	)
end
end
