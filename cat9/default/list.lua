--
-- basic bringup:
--
--  inotify refresh
--  input (move cursor, click)
--  type- coloring
--

return
function(cat9, root, builtins, suggest)

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
		end

		ent.name = v
		table.insert(res, ent)
	end

-- for the -l version things are much more involved:
--  split on spaces up until the filename, then look for C escapes
--       aaaaaaaaaa user group     sz 'text date' file/dir -> link

	data.files = res
end

local function queue_ls(src, args)
	local _, out, _, pid = root:popen({"/bin/ls", "cat9-ls", "-1aFb"}, "r")
	if not pid then
		cat9.add_message("builtin:list - couldn't spawn /bin/ls")
		return
	end

	if src.monitor_pid then
		root:psignal(src.monitor_pid, "kill")
		src.monitor_pid = nil
	end

-- when done we can add job.data or simply skip if the source token
	local job =
		cat9.add_background_job(
			out, pid, {lf_strip = true},
			function(job, code)
				if code == 0 then
					parse_ls(job.data)
					src.data = job.data
					src.data.files_filtered = nil
					src.last_view = nil
					cat9.flag_dirty()
				else
					cat9.add_message("list failed: " .. table.concat(job.data, ""))
				end
			end
		)
end

local function filter_job(job, set)
	local res = {bytecount = 0}

	for _,v in ipairs(set) do
		if string.sub(v.name, 1, 1) == "." and v.name ~= ".." then
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

	return
		cat9.resolve_lines(
			job, res, lines,
			function(i)
			if job.data.files_filtered[i] then
					return print_file(job, job.data.files_filtered[i])
				else
					return nil, 0, 0
				end
			end
		)
end

local function get_attr(job, set, i, pos, highlight)
	local res = {fc = tui.colors.ui, bc = tui.colors.ui}

	if not job.data.files_filtered[set[i]] then
		return res
	end

	if highlight then
		res = cat9.config.styles.data_highlight

-- socket, directory, executable, might send to open for probe as well?
	elseif job.data.files_filtered[set[i]].directory then
		res = {fc = tui.colors.alert, bc = tui.colors.alert}
	end

	if job.mouse and job.mouse.on_row == i then
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
		for _,v in ipairs(job.data.files_filtered) do
			local name, bc, lc = print_file(job, v)
			table.insert(job.last_view, name)
			job.last_view.bytecount = job.last_view.bytecount + 1
			job.last_view.linecount = job.last_view.linecount + 1
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
local function item_click(job, ind)
	if not job.cursor_item then
		return
	end

-- on directory: temporarily switch dir, queue a new ls
	if job.cursor_item.directory then
		local old = root:chdir()
		root:chdir(job.raw)
		root:chdir(job.cursor_item.name)
		local new = root:chdir()
		job.short = new
		job.raw = new
		job.last_view = nil
		queue_ls(job)
		root:chdir(old)

-- default click action otherwise should be open with modifier or button
-- controls to determine if open in new, embed, ...
	else

	end

-- drag is not covered by this still (e.g. drag from one job to another(
	return true
end

function builtins.list(path)
	local job = {
		short = root:chdir(),
		raw = root:chdir(),
		check_status = function() return true; end,
		attr_lookup = get_attr,
	}
	cat9.import_job(job)
	job.data.files = {}
	job.handlers.mouse_button = item_click
	job:set_view(view_files, slice_files, {}, "list")
	queue_ls(job)
end

function suggest.list(args, raw)

end
end
