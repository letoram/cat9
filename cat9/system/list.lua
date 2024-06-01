-- filter- view through fuzzy match or~
--
-- with long paths we need to compact the path for titlebar to not overflow
-- justify pad user/group
--

local KiB = 1024
local MiB = 1024 * 1024
local GiB = 1024 * 1024 * 1024
local TiB = 1024 * 1024 * 1024 * 1024

local group_score =
{
	["file"] = 5,
	["directory"] = 1,
	["fifo"] = 2,
	["socket"] = 3,
	["link"] = 4
}

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

local function sort_az_nat(a, b)
-- find first digit point
	local s_a, e_a = string.find(a, "%d+");
	local s_b, e_b = string.find(b, "%d+");

-- if they exist and are at the same position
	if (s_a ~= nil and s_b ~= nil and s_a == s_b) then

-- extract and compare the prefixes
		local p_a = string.sub(a, 1, s_a-1);
		local p_b = string.sub(b, 1, s_b-1);

-- and if those match, compare the values
		if (p_a == p_b) then
			return
				tonumber(string.sub(a, s_a, e_a)) <
				tonumber(string.sub(b, s_b, e_b));
		end
	end

-- otherwise normal a-Z
	return string.lower(a) < string.lower(b);
end

local function string_justify(source, len)
-- left-justify
	if #source < len then
		source = string.rep(" ", len - #source) .. source
	end
	return source
end

local function sort_group(a, b)
	local as = group_score[a.kind] or 10
	local bs = group_score[b.kind] or 10
	return as < bs
end

local function build_sort(job, method, inv, group)
	if method == "alphabetic" then
		if inv then
			return function(a, b)
				if group and a.kind ~= b.kind then
					return sort_group(a, b)
				end
				return not sort_az_nat(a.name, b.name)
			end
		else
			return function(a, b)
				if group and a.kind ~= b.kind then
					return sort_group(a, b)
				end

				return sort_az_nat(a.name, b.name)
			end
		end
	elseif method == "size" then
		if inv then
			return
			function(a, b)
				if not group or a.kind == b.kind then
					return a.meta.size < b.meta.size
				else
					return sort_group(a, b)
				end
			end
		else
			return
			function(a, b)
				if not group or a.kind == b.kind then
					return a.meta.size > b.meta.size
				else
					return sort_group(a, b)
				end
			end
		end
	elseif method == "date" then
		if inv then
			return
			function(a, b)
				if not group or a.kind == b.kind then
					return a.meta.mtime < b.meta.mtime
				else
					return sort_group(a, b)
				end
			end
		else
			return
			function(a, b)
				if not group or a.kind == b.kind then
					return a.meta.mtime > b.meta.mtime
				else
					return sort_group(a, b)
				end
			end
		end
	end
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
				src["repeat"](src, nil, builtin_cfg.list.track_changes)
			end
		end
	end)
end

local function filter_job(job, set)
	local res = {bytecount = 2}

	for _,v in ipairs(set) do
		if v.name == ".." or (#v.name == 1 and v.name == ".") then
		else
			table.insert(res, v)
			res.bytecount = res.bytecount + #v.name
			res[v.name] = v
		end
	end

-- insertion is a better bet here though
	if job.sort then
		pcall(function() table.sort(res, job.sort) end)
	end

	if job.dir ~= "/" then
		local up = {directory = true, name = ".."}
		table.insert(res, 1, up)
		res[up.name] = up
	end

	res.linecount = #res
	return res
end

-- Slicer here needs to be able to present different detailed views of the
-- current set of files with different coloring and details options. Use the
-- normal helper to extract the desired range (lines).
local function print_file(job, line)
	if job.compact or not line.meta then
		return line.name, #line.name, 1, line.name
	else
		local m = line.meta
		local ts = os.date(builtin_cfg.list.time_str, m[builtin_cfg.list.time_key])
		return line.name, #line.name, 1,
			string.format("%s %s %s %s %s %s",
				m.mode_string,
				m.user,
				m.group,
				ts,
				string_justify(tostring(m.size), job.max_size),
				line.name
			)
	end
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

local function get_attr(job, set, i, pos, highlight, str, width)
	local lcfg = builtin_cfg.list
	local fattr = lcfg.file

-- fallback, shouldn't happen
	if not job.data.files_filtered then
		return {{lcfg.file, str}}
	end

	local m = job.data.files_filtered[i]

	if highlight then
		fattr = cat9.config.styles.data_highlight

-- socket, directory, executable, might send to open for probe as well?
	elseif m.directory then
		fattr = lcfg.directory

	elseif m.socket then
		fattr = lcfg.socket

	elseif m.executable then
		fattr = lcfg.executable

	elseif m.link then
		fattr = lcfg.link
	end

-- highlight on mouse, but cursor_item can also be set by keyboard,
-- switch to the latest known as the dominant for any cursor-action
	if job.mouse then
		if job.mouse.on_row == i then
			job.cursor_item = m
			fattr = table.copy_recursive(fattr)
			fattr.border_down = true
		end

	elseif job.cursor_item == m then
		fattr = table.copy_recursive(fattr)
		fattr.border_down = true
	end

	local suffix
	if m.new and lcfg.new_suffix then
		suffix = {lcfg.suffix or fattr, lcfg.new_suffix}
	end

-- it is a bit weird that we first provide the verbose text list
-- and repeat the expansion here, but the first one is for alloc
-- when layouting, then here for actually rendering the view.
--
	if not job.compact and m.meta then
		local meta = m.meta
		local len = root:utf8_len(m.name)
		local set = {{fattr, m.name}, suffix}

		local size_str = string_justify(meta.size_string, job.max_size) .. " "
		local size_len = root:utf8_len(size_str)

		if (len + size_len <= width) then
			table.insert(set, 1, {lcfg.size, size_str})
			len = len + size_len
		end

		local date_str = os.date(lcfg.time_str, meta[lcfg.time_key]) .. " "
		local date_len = root:utf8_len(date_str)

		if (len + date_len <= width) then
			table.insert(set, 1, {lcfg.time, date_str})
			len = len + date_len
		end

		local group_str = string_justify(meta.group, job.max_group_length) .. " "
		local group_len = root:utf8_len(group_str)

		if len + group_len <= width then
			table.insert(set, 1, {lcfg.group, group_str})
			len = len + group_len
		end

		local user_str = string_justify(meta.user, job.max_user_length) .. " "
		local user_len = root:utf8_len(user_str)

		if len + user_len <= width then
			table.insert(set, 1, {lcfg.user, user_str})
			len = len + user_len
		end

		local mode_len = root:utf8_len(meta.mode_string) + 1
		if len + mode_len <= width then
			table.insert(set, 1, {lcfg.permission, meta.mode_string .. " "})
		end

		return set
	end

	return {{fattr, str}}
end

local function on_redraw(job, over, selected)
	if not job.data.files_filtered then
		job.data.files_filtered = filter_job(job, job.data.files)
	end

	if not job.mouse then
		job.cursor_item = job.data.files_filtered[job.view_base + job.cursor[2]]
	end

-- we are in control over the cursor, move it to the view_base+cursor
	if over and selected and (job.hidden or not cat9.readline) then
		job.root:cursor_to(0, job.region[2] + job.cursor[2] + 1)
	end
end

local function write_at(job, x, y, str, set, i, pos, highlight, width)
	local attr = get_attr(job, set, i, pos, highlight, str, width)
	local ok
	for _, v in ipairs(attr) do
		ok, x, y = job.root:write_to(x, y, v[2], v[1])
	end
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

--	job.cursor_item = nil
	return cat9.view_fmt_job(job, set, x, y, cols, rows)
end

-- the cursor selection is already set so click is assumed to hit
local function item_click(job, btn, ofs, yofs, mods)
	local line_no_click = job.mouse and job.mouse.on_col == 1

-- no special behaviour for job-bar
	if yofs == 0 then
		return
	end

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

local function list_text_input(job, ch)
	local start = job.view_base + job.cursor[2] + 1
	local found

	for i=start,job.data.files_filtered.linecount do
		local item = job.data.files_filtered[i]
		if string.sub(item.name, 1, #ch) == ch then
			found = i
			break
		end
	end

-- wrap around
	if not found then
		for i=1,start do
			local ent = job.data.files_filtered[i]
			if ent and string.sub(ent.name, 1, #ch) == ch then
				found = i
				break
			end
		end
		if not found then
				return
		end
	end

-- now we need to jump such that job.data.files_filtered[i] is in view
-- and then set the cursor to that position
	local nitems = found - start + 1
	local rh = job.region[4] - job.region[2]

	if job.cursor[2] + nitems > rh + job.cursor[2] then
		cat9.parse_string(cat9.readline, "view #" .. tostring(job.id) .. "scroll " .. found)
		cat9.redraw()

		return list_text_input(job, ch)
	else
		job.cursor[2] = job.cursor[2] + nitems
	end

	cat9.flag_dirty(job)

	return true
end

local function list_input(job, sub, keysym, code, mods)
	job.mouse = nil

	if keysym == builtin_cfg.list.bindings.up then
		if job.cursor[2] == 0 then
			cat9.parse_string(cat9.readline, "view #" .. tostring(job.id) .. "scroll -1")
		else
			job.cursor[2] = job.cursor[2] - 1
		end

-- jump up one directory
	elseif keysym == builtin_cfg.list.bindings.dir_up then
		queue_glob(job, "..")

		return true

	elseif keysym == builtin_cfg.list.bindings.down then
		local rh = job.region[4] - job.region[2]
		job.cursor[2] = job.cursor[2] + 1

-- should we scroll down?
		if job.cursor[2] >= rh-3 then

-- but only if we aren't at the end
			if job.view_base + job.cursor[2] + 1 < job.data.files_filtered.linecount then
				cat9.parse_string(cat9.readline, "view #" .. tostring(job.id) .. "scroll +1")
				job.cursor[2] = job.cursor[2] - 1

			else
				job.cursor[2] = rh-3
			end

-- otherwise clamp if list is larger than region, only happens on detached
		else
			if job.view_base + job.cursor[2] > job.data.files_filtered.linecount then
				job.cursor[2] = job.data.files_filtered.linecount - job.view_base
			end
		end

	elseif keysym == builtin_cfg.list.bindings.activate then
		item_click(job, 1, 0, 1, mods)

	elseif builtin_cfg.list.bindings[keysym] then
		cat9.parse_string(nil, builtin_cfg.list.bindings[keysym])
	end

	cat9.flag_dirty(job)
end

builtins.hint["list"] = "List the contents of a directory"

function builtins.list(path, opt, ...)

-- are we trying to run a new list or configure an existing one?
	if type(path) == "table" then
		local job = path
		if not job.list then
			cat9.add_message("list >path< does not refer to a list job")
			return
		end

		if type(opt) ~= "string" then
			cat9.add_message("list path >opt< unexpected type or missing")
			return
		end

		if opt == "toggle" then
			job.compact = not job.compact

		elseif opt == "short" then
			job.compact = true

		elseif opt == "sort" then
			local extra = {...}

			for _,v in ipairs(extra) do
				if v == "alphabetic" or v == "size" or v == "date" then
					if job.sort_kind == v then
						job.sort_inv = not job.sort_inv
					end
					job.sort_kind = v

				elseif v == "type" then
					job.sort_group = not job.sort_group
				end
			end

			job.sort = build_sort(job, job.sort_kind, job.sort_inv, job.sort_group)
			job.data.files_filtered = nil
			return
		end

		job["repeat"]()
		return
	end

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
		write_override = write_at,
		last_selection = {},
		compact = builtin_cfg.list.compact,
		list = true,
		redraw = on_redraw,
		dir_history = {},
		view_name = "list",
		sort_group = builtin_cfg.list.sort_group,
		sort_inv = false,
		sort_kind = builtin_cfg.list.sort,
		size_prefix = builtin_cfg.list.size_prefix,
		sort_group = true,
	}
	job.sort = build_sort(job, job.sort_kind, job.sort_inv, job.sort_group)
	cat9.import_job(job)

	job.key_input = list_input
	job.write = list_text_input

-- since this can be called when new files appear the actual names of selected
-- lines need to be saved and re-marked on discovery
	job["repeat"] =
	function(ctx, _, track)
		job.last_view = nil
		job.last_selection = {}

		for i,v in ipairs(job.selections) do
			if v and job.data.files_filtered[i] then
				job.last_selection[job.data.files_filtered[i].name] = true
			end
		end

		local oldfiles = job.data.files

		job.selections = {}
		job.data.files = {}
		job.handlers.mouse_button = item_click

		queue_glob(job, "", track and oldfiles or nil)
	end

	job["repeat"]()
end

queue_glob =
function(src, path, ref)
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

-- remember so that we can meta+ESCAPE back
	if src.dir ~= path then
		table.insert(src.dir_history, src.dir)
	end

-- reset data store
	src.data.files = {}
	src.short = path
	src.dir = path
	src.max_size = 0
	src.max_user_length = 0
	src.max_group_length = 0

-- special case out hidden files as a separate list
	local hidden = string.sub(path, -1) == "."

-- asynch a new background job with the spawned ls
	src.ioh =
	cat9.add_fglob_job( out, path,
	function(line)
		if not line then
			queue_monitor(src)
			src.data.files_filtered = nil
			src.last_view = nil
			src:set_view(view_files, slice_files, {}, "list")
			src.cursor = {0, 0}
			src.row_offset = -#src.data.files
			cat9.flag_dirty(src)
		else
-- filter unwanted / hidden
			if line == ".." or line == "." then
				return
			end

			local fh = string.sub(line, 1, 1) == "."
			if (fh and not hidden) or (not fh and hidden) then
				return
			end

			local entry = {
				name = line,
				full = path .. "/" .. line
			}

			local status, kind, ext = root:fstatus(entry.full, true)

			if status then
				entry[kind] = true
				entry.meta = ext
				entry.kind = kind

				if #ext.user > src.max_user_length then
					src.max_user_length = #ext.user
				end

				if #ext.group > src.max_group_length then
					src.max_group_length = #ext.group
				end

-- for human-readable presentation
				if ext.size < KiB then
					ext.prefix = "B"
					ext.size_prefix = ext.size

				elseif ext.size < MiB then
					ext.prefix = "K"
					ext.size_prefix = ext.size / KiB

				elseif ext.size < GiB then
					ext.prefix = "M"
					ext.size_prefix = ext.size / MiB

				elseif ext.size < TiB then
					ext.prefix = "G"
					ext.size_prefix = ext.size / GiB

				else
					ext.prefix = "T"
					ext.size_prefix = ext.size / TiB
				end

				if src.size_prefix then
					ext.size_string = string.format("%.1f%s", ext.size_prefix, ext.prefix)
				else
					ext.size_string = tostring(ext.size)
				end

				if #ext.size_string > src.max_size then
					src.max_size = #ext.size_string
				end
			end

	-- Anything missing in 'ref' is lost, new entries are marked as
	-- new and can be used to pick a different coloring attribute or
	-- other indicator. Unfortunately we can't trigger before the
	-- unlink happens and keeping the descriptors in the list 'held'
	-- isn't viable or we would have the makings of an undo.
			if ref then
				entry.new = true
				for i,v in ipairs(ref) do
					if v.name == entry.name then
						table.remove(ref, i)
						entry.new = false
						break
					end
				end
			end
			table.insert(src.data.files, entry)
		end
	end
	)
end

function suggest.list(args, raw)
	if #raw == 4 or #args > 2 then
		if not args[2] or not type(args[2]) == "table" or not args[2].list then
			return
		end

		if #args == 3 then
			local set = cat9.prefix_filter(
				{
					"full",
					"short",
					"toggle",
					"sort",
				hint =
				{
					"Set the list to verbose (permission, user, ...)",
					"Set the item list to compact (name-only)",
					"Toggle between verbose and compact",
					"Change sort criteria",
				}
			}, args[3])
			cat9.readline:suggest(set, "word")

		elseif #args == 4 then
			local set = cat9.prefix_filter(
				{
					"alphabetic",
					"size",
					"date",
					"type",
					"unordered",
				hint = {
					"Sort by alphabetic name, repeat to invert",
					"Sort by size, repeat to invert",
					"Sort by date, repeat to invert",
					"Group by type, within group last sort operation applies",
					"Present items as they arrived",
				}
			},
				args[4]
			)
			cat9.readline:suggest(set, "word")
		end

		return
	end

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
