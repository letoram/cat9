return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local queue_glob

local function resolve_path(path)
	local old = root:chdir()
	root:chdir(path)
	path = root:chdir()
	root:chdir(old)
	return path
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

local function filter_job(job, set)
	local res = {bytecount = 2}
	local up = {directory = true, name = ".."}
	table.insert(res, up)
	res[up.name] = up

	for _,v in ipairs(set) do
		if v.name == ".." or (#v.name == 1 and v.name == ".") then
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
	return line.name, #line.name, 1, line.name
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
				if not i then -- resolve full
					local ret = {bytecount = 0, linecount = 1}
					for _,v in ipairs(job.data.files_filtered) do
						if v.full then
							table.insert(ret, v.full)
							ret.bytecount = ret.bytecount + #v.full
							ret.linecount = ret.linecount + 1
						end
					end
					return ret
				end

	-- only copy items that resolve to an actual path
				if job.data.files_filtered[i] and
					job.data.files_filtered[i].full then
					local res = job.data.files_filtered[i].full
					return res, #res, 1
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

-- since view is called on each dirty, we want to cache any possibly
-- expensive operation, while handling selected items getting reordered
	if not job.last_view or #job.last_view ~= #job.data.files_filtered then
		job.last_view = {bytecount = 0, linecount = 0}
		job.selections = {}

		for _,v in ipairs(job.data.files_filtered) do
			local name, bc, lc, label = print_file(job, v)
			table.insert(job.last_view, label)
			job.last_view.bytecount = job.last_view.bytecount + #name
			job.last_view.linecount = job.last_view.linecount + 1
			job.selections[#job.last_view] = job.last_selection[name] ~= nil or false
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
		job.last_view = nil
		queue_glob(job, "./" .. job.cursor_item.name)
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
		dir = path,
		check_status = function() return true; end,
		attr_lookup = get_attr,
		last_selection = {}
	}
	cat9.import_job(job)

-- since this can be called when new files appear the actual names of selected
-- lines need to be saved and re-marked on discovery
	job["repeat"] =
	function()
		job.last_view = nil
		job.last_selection = {}

		for i,v in ipairs(job.selections) do
			if v and job.data.files_filtered[i] then
				job.last_selection[job.data.files_filtered[i].name] = true
			end
		end

		job.selections = {}
		job.data.files = {}
		job.handlers.mouse_button = item_click

		queue_glob(job, "")
	end

	job["repeat"]()
end

queue_glob =
function(src, path)
-- kill any outstanding glob request
	if src.ioh then
		src.ioh:close()
		src.ioh = nil
	end

	if string.sub(path, 1, 1) ~= "/" then
		path = resolve_path(src.dir .. "/" .. path)
	end

-- and any listening monitor process
	if src.monitor_pid then
		root:psignal(src.monitor_pid, "kill")
		src.monitor_pid = nil
	end

-- reset data store
	src.data.files = {}
	src.short = path
	src.dir = path

-- special case out hidden files as a separate list
	if string.sub(path, -2) == ".*" then
		path = string.sub(path, 1, -3)
	end

-- asynch a new background job with the spawned ls
	src.ioh =
	cat9.add_fglob_job( out, path .. "/*",
	function(line)
		if not line then
			queue_monitor(src)
			src.data.files_filtered = nil
			src.last_view = nil
			src:set_view(view_files, slice_files, {}, "list")
			cat9.flag_dirty(src)
		else
			local entry = {
				name = string.sub(line, #path + (path == "/" and 1 or 2)),
				full = line
			}
			local status, kind, ext = root:fstatus(line, true)
			if status then
				entry[kind] = true
				entry.meta = ext
			end
			table.insert(src.data.files, entry)
		end
	end
	)
end

function suggest.list(args, raw)
	local argv, prefix, flt, offset =
		cat9.file_completion(args[2], cat9.config.glob.dir_argv)

	if #raw == 4 then
		return
	end

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
