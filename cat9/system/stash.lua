--
-- add:
--    compressor picking, archive destination
--    directory expansion
--    string / todo items
--    serialization
--
return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- we need to build a temporary directory where we expand the files
-- if they come from bchunk and symlink if they come from files and
-- then run through compressor / archival tool

local stashcfg = builtin_cfg.stash
local commands = {}
local slice_key = "map"

-- consolidated all printable strings for future localization
local errors = {
	verify_nostash = "stash verify: no active stash",
	verify_toomany = "stash verify: too many arguments",
	verify_pending = "stash verify: verification still pending",
	verify_empty   = "stash verify: no files in current stash",
	verify_resolve = "stash verify: unresolved items in stash, run stash resolve",
	verify_chkexec = "checksum execution failed",
	verify_chkout  = "no checksum output",
	verify_chkdata = "bad checksum data",

	add_duplicate  = "stash add : rejecting duplicate entry",
	add_collision  = "stash add : rejecting map collision",

	remove_nopath  = "stash remove : >path< missing",
	remove_toomany = "stash remove : too many arguments",
	remove_empty   = "stash remove : empty stash",
	remove_nomatch = "stash remove > %s < no match",

	unlink_yes     = "stash unlink : expecting 'yes' argument to confirm unlinking",

	map_toomany    = "stash map: too many arguments",

	archive_nostash= "stash archive: no active stash",
	archive_empty  = "stash archive: no files in current stash",
	archive_resolve= "stash archive: unresolved items in stash, run stash resolve",
	archive_badtmp = "stash archive: couldn't create temp file: %s",
	archive_ext    = "stash archive: %s failed",

	resolve_open   = "stash resolve: couldn't open %s",
	resolve_create = "stash resolve: couldn't create %s",

	sugg_nostash    = "no active stash",
	sugg_unknown    = "stash: unknown command >%s<",
	sugg_map_source = "stash map: no matching source item",
	sugg_map_toomany= "stash map: too many argments",
}

local commands =
{
	"add",
	"archive",
	"unlink",
	"map",
	"verify",
-- "compress",
-- "expand",
	"remove",
	"prefix",
	hint = {
		"Create a stash and add a file to it, will append if a stash already exists",
		"Step through the stash and build an archive for it",
		"Unlink/Delete all the files and directories referenced in the stash",
		"Specify a name for an item in the stash",
		"Sweep the stash and checksum each file entry",
--		"Resolve directories to individual files",
		"Remove one or a range of items from the stash",
		"Add or remove a number of characters to the beginning of a range of items in the stash",
	}
}

builtins.hint["stash"] = "Define a set of objects to manipulate"

local active_job = cat9.stash_active_job

cat9.state.export["stash"] =
function()
-- sweep active-job, linearize to source, map, source, map, ...
	return {}
end

cat9.state.import["stash"] =
function()
-- pop two, add_file -> update map
	return {}
end

local function all_by_type(type)
	local set = {}
	if not active_job or not active_job.set then
		return set
	end

	for _,v in ipairs(active_job.set) do
		if v.kind == type then
			table.insert(set, v)
		end
	end

	return set
end

local function monitor_inqueue(id, blob, lref)
	local map = {
		map = lref or stashcfg.fifo_prefix .. tostring(id),
		kind = "fifo",
		nbio = blob,
		source = lref or "fifo:" .. id .. "",
		message = ""
	}

	if not lref then
		map.unresolved = true
		map.message = stashcfg.unresolved
	end

-- on OSes where we can resolve the origin of the descriptor backing
-- a blob, it'll be provided in lref
	table.insert(active_job.data,
		map.message .. map.source .. stashcfg.right_arrow .. map.map)
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #active_job.data[#active_job.data]
	cat9.flag_dirty()
end

local function unregister()
	cat9.resources.bin = active_job.old_ioh
	active_job = nil
	cat9.stash_active_job = nil
end

local function expand_set(key)
	local res = {linecount = 0, bytecount = 0}
	for i,v in ipairs(active_job.set) do
		table.insert(res, v[key])
		res.linecount = res.linecount + 1
		res.bytecount = res.bytecount + #v[key]
	end
	return res, res.linecount, res.bytecount
end

local function stash_slice(job, lines, set)
	local data = set or job.data

	return
	cat9.resolve_lines(
		job, {}, lines,
			function(i)
				if not i then
					return expand_set(slice_key)
				elseif job.set[i] then
					return job.set[i][slice_key], #job.set[i][slice_key], 1
				else
					return nil, 0, 0
				end
			end
		)
end

local function write_at(job, x, y, str, set, i, pos, highlight, width)
-- figure out if the cursor is on the row src part, map part or neither
	local fattr = stashcfg.file
	local mattr = stashcfg.message
	local fmt_sep = {fc = tui.colors.label, bc = tui.colors.text}
	local sattr = fattr

	local mouse
	if job.mouse and job.mouse.on_row == i then
		mouse = true
		job.cursor_item = active_job.set[i]
		job.cursor_item_index = i
	end

	local item = active_job.set[i]

-- src=slen ras=ral map=dul
	local ras  = stashcfg.right_arrow
	local src  = item.source
	local map  = item.map
	local ral  = root:utf8_len(ras)
	local srl  = root:utf8_len(src)
	local mal  = root:utf8_len(map)
	local mgl  = root:utf8_len(item.message or "")

	if mouse then
		sattr = table.copy_recursive(fattr)
		sattr.border_down = true
	end

-- if we fit there is an easier path
	if ral + mgl + srl + mal < width then
		if mouse and job.mouse[1] <= mgl + srl + 1 then
			job.mouse.on_col = 2
			root:write_to(x, y, item.message, mattr)
			root:write(src, sattr)
		else
			root:write_to(x, y, item.message, mattr)
			root:write(src, fattr)
		end

		root:write(ras, fmt_sep)

		if mouse and job.mouse[1] >= mgl + srl + ral + 2 then
			job.mouse.on_col = 3
			root:write(map, sattr)
		else
			root:write(map, fattr)
		end
		return
	end

-- so we don't fit, priority:
	local ent = cat9.compact_path(src)
	local ull = root:utf8_len(ent)
	local lco = ull

--  1. short_path + right_arrow + map_name
	if mgl + ull + ral + mal <= width then
		if mouse and job.mouse[1] <= mgl + ull + 1 then
			job.mouse.on_col = 2
			root:write_to(x, y, item.message, mattr)
			root:write(ent, sattr)
		else
			root:write_to(x, y, item.message, mattr)
			root:write(ent, fattr)
		end

		root:write(ras, fmt_sep)

		if mouse and job.mouse[1] >= mgl + ull + ral + 2 then
			job.mouse.on_col = 3
			root:write(map, sattr)
		else
			root:write(map, fattr)
		end

--  (missing) 2. shared_prefix (if any) + right_arrow + map_name
--            3. shortened_source_shared + right_arrow + map_name
	elseif mgl + ral + mal < width then
--  4. right_arrow + map_name
		root:write_to(x, y, item.message, mattr)
		root:write(ras, fmt_sep)
		if mouse then
			job.mouse.on_col = 3
			root:write(map, sattr)
		else
			root:write(map, fattr)
		end
	else
--  5. right_arrow + shorten_map_name
		root:write_to(x, y, item.message, mattr)
		root:write(ras, fmt_sep)
		if mouse then
			job.mouse.on_col = 3
			root:write(map, sattr)
		else
			root:write(map, fattr)
		end
	end
end

local function button(job, ind, x, y, mods, active)
	if not active_job or not active_job.cursor_item then
		return
	end

-- since this is destructive, just set the readline to the right value
	if job.mouse.on_col then
		if job.mouse.on_col == 2 then
			cat9.readline:set("stash remove #stash("..tostring(active_job.cursor_item_index)..") ")
			return
		end
	end

	cat9.readline:set("stash map #stash(" .. tostring(active_job.cursor_item_index) ..") " )
end

local function ensure_stash_job()
	if active_job then
		return
	end

	local job =
	{
		set = {},
		alias = "stash",
		check_status =
		function()
			return true -- feedback if job
		end,
		write_override = write_at,
		raw = "",
		view_name = "stash",
		short = "Stash",
		slice = stash_slice,
		old_ioh = cat9.resources.bin
	}

	cat9.import_job(job)

	table.insert(job.hooks.on_destroy, unregister)
	job.handlers.mouse_button = button
	job.handlers.mouse_motion = motion
	active_job = job
	cat9.stash_active_job = job
	cat9.resources.bin = monitor_inqueue

-- we want to add a factory that exposes the stash to the saveset
end

local function add_file(v)
	local ok, kind = root:fstatus(v)
	if not ok then
		return false, kind
	end

	local map =
	{
		source = v,
		map = v,
		message = ""
	}

	map.kind = kind

	if string.sub(v, 1, 2) == "./" then
		v = root:chdir() .. string.sub(v, 2)
		map.map = v
		map.source = v
	end

-- O(n) ignore duplicates
	for i=1,#active_job.set do
		if v == active_job.set[i].source then
			return false, errors.add_duplicate
		elseif v == active_job.set[i].map then
			return false, errors.add_collision
		end
	end

	table.insert(active_job.data, v .. stashcfg.right_arrow .. v)
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #v
end

function commands.remove(args)
	if #args ~= 1 then
		return false, args == 0 and errors.remove_nopath or errors.remove_toomany
	end

	if not active_job then
		return false, errors.remove_empty
	end

	for i=1,#active_job.set do
		if active_job.set[i].source == args[1] then
			table.remove(active_job.set, i)
			table.remove(active_job.data, i)
			active_job.data.linecount = active_job.data.linecount - 1
			cat9.flag_dirty(active_job)
			return
		end
	end

	return false, string.format(errors.remove_nomatch, args[1])
end

function commands.unlink(args)
	if #args ~= 1 or args[1] ~= "yes" then
		return false, errors.unlink_yes
	end

-- this does not recurse into directories, need an explicit 'expand' to glob- commit
	local rv = true

	for i=#active_job.set,1,-1 do
		if active_job.set[i].kind == "file" then
			local ok, msg = root:funlink(active_job.set[i].source)
			if not ok then
				active_job.set[i].message = msg
			else
				table.remove(active_job.set, i)
				local count = table.remove(active_job.data, i)

				active_job.data.linecount = active_job.data.linecount - 1
				active_job.data.bytecount = active_job.data.bytecount - #count
			end
		end
	end

	cat9.flag_dirty(active_job)
	return rv
end

function commands.map(arg)
	if #arg ~= 2 then
		return false, errors.map_toomany
	end

	for i=1,#active_job.set do
		local li = active_job.set[i]
		if li.source == arg[1] then
			li.map = arg[2]
			cat9.flag_dirty(active_job)
			return
		end
	end

end

function commands.add(arg)
	ensure_stash_job()

	for _, v in ipairs(arg) do
		local ok, msg = add_file(v)
		if ok == false then
			return false, msg
		end
	end
end

function commands.verify(args)
	if not active_job then
		return false, errors.verify_nostash
	end

	if #args > 0 then
		return false, errors.verify_toomany
	end

	if active_job.verify_set then
		return false, errors.verify_pending
	end

	local set = all_by_type("file")
	if #set == 0 then
		return false, errors.verify_empty
	end

	for i=1,#set do
		if set[i].unresolved then
			return false, errors.verify_resolve
		end
	end

	local queue = {}

-- copy the command, swap in our current file path and add to queue
	for i=1,#set do
		local cmd = cat9.table_copy_shallow(stashcfg.checksum)
		set[i].message = stashcfg.checksum_pending

		for j=1,#cmd do
			if cmd[j] == "$path" then
				cmd[j] = set[i].source
			end
		end

-- let the parse- action be part of the config file, but provide
-- a default matching --tag otherwise
		cmd.handler = function(job, arg, code)
			if code ~= 0 then
				set[i].error = errors.verify_chkexec
				return
			end

			if not job.data[1] then
				set[i].error = errors.verify_chkout
				return
			end

			local out = string.split(job.data[1], " = ")
			if #out ~= 2 then
				set[i].error = errors.verify_chkdata
				return
			end

			if set[i].checksum then
				if set[i].checksum == out[2] then
					set[i].message = stashcfg.checksum_ok
				else
					set[i].message = stashcfg.checksum_fail
				end
			else
				set[i].message = stashcfg.checksum_ok
			end

			set[i].checksum = out[2]
			set[i].checksum_algorithm = string.split_first(out[1], " ")
		end

		table.insert(queue, cmd)
	end

	cat9.background_chain(queue, {lf_strip = true}, active_job,
	function(job)
		if job ~= active_job then -- stash was removed / rebuilt while processing
			return
		end

		cat9.flag_dirty(active_job)
		active_job.verify_set = nil
	end
	)

	active_job.verify_set = set
end

local function get_dirtbl(path)
	local res = {}
	local dirs = string.split(path, "/")

	if dirs[1] == "" then -- ignore leading /
		table.remove(dirs, 1)
	end

	if #dirs > 1 then
		for j=1,#dirs-1 do
			local str = ""
			for k=1,j do
				local suff = k ~= j and "/" or ""
				str = str .. dirs[k] .. suff
			end
			table.insert(res, str)
		end
	else
		return dirs
	end

	return res
end

local function ensure_tree(visited, dst, path, base)
	local tbl = get_dirtbl(path)
-- this will give us /a/b/c/d into
-- /a/b/c
-- /a/b
-- /a
--
-- add to unlink list in reverse order and mkdir in forward one
	for _, v in ipairs(tbl) do
		local path = base .. "/" .. v
		if not visited[path] then
			root:fmkdir(path)
			visited[path] = true
			table.insert(dst, 1, path)
		end
	end
end

function commands.archive(args)
	if not active_job then
		return false, errors.archive_nostash
	end

	local ajs = active_job.set
	if #ajs == 0 then
		return false, errors.archive_empty
	end

	for i,v in ipairs(ajs) do
		if v.unresolved then
			return false, errors.archive_resolve
		end
	end

-- until we get shmif- like support and can have another archiver that
-- isn't stdio crippled, need to make do with building a link-folder
-- and use the 'h' form.
	local tmpdir, tmpfile, tmpfilename, msg

	tmpdir, msg = root:tempdir(stashcfg.scratch_prefix)
	if not tmpdir then
		return false, msg
	end

-- don't create a tmpfile unless needed
	tmpfile, tmpfilename = root:tempfile(stashcfg.archive_prefix)
	if not tmpfile then
		root:funlink(tmpdir)
		return false, string.format(errors.archive_badtmp, tmpfilename)
	end

	local unlink_set = {}

-- build the virtual tree, any subpaths not used need to be mkdir:ed
	local dirmap = { tmpdir }
	local paths = {}

	for i=1,#ajs do
-- we need to track the subdirectories so we can replicate mkdir -p
-- but also keep an unlink order so that after we have wiped all the
-- links the directories can go 'empty'
		if string.find(ajs[i].map, "/") then
			ensure_tree(paths, dirmap, ajs[i].map, tmpdir)
		end

		local cmd =
		{
			"/usr/bin/env",
			"/usr/bin/env", "ln", "-s",
			ajs[i].source,
			tmpdir .. "/" .. ajs[i].map
		}
		root:popen(cmd, "")
	end

	local jobcmd = cat9.table_copy_shallow(stashcfg.archive.tar)
	for i=1,#jobcmd do
		if jobcmd[i] == "$file" then
			jobcmd[i] = tmpfilename
		elseif jobcmd[i] == "$dir" then
			jobcmd[i] = tmpdir
		end
	end

	local _, out, _, pid = root:popen(jobcmd, "r")
	cat9.add_background_job(out, pid, {lf_strip = true},
	function(job, code)
		-- cleanup after the compression job finishes, tempfile will be unlinked on :close()
		for i=1,#unlink_set do
			root:funlink(unlink_set[i])
		end

		for i=#dirmap,1,-1 do
			root:funlink(dirmap[i])
		end

		if code ~= 0 then
			cat9.add_message(string.format(errors.archive_ext, table.concat(jobcmd, " ")))
			return
		end

		tmpfile:set_position(0)
		local newjob = {
			inp = tmpfile,
			data = {
				tmpfilename,
				linecount = 1,
				bytecount = 10,
				name = "archive",
				short = "Archive",
				full = string.format("Archive(%s)", tmpfilename)
			}
		}
		cat9.import_job(newjob)

		active_job.archiving = nil
	end)
	active_job.archiving = tmpfile
end

function commands.resolve(args)
	for i,v in ipairs(active_job.set) do

-- there might be queued / processing already, but setup jobs for the others
		if v.unresolved and not v.pending then
			local fin = v.nbio
			if not fin then
				fin = root:fopen(v.source, "r")
				v.nbio = fin
			end
			if not fin then
				return false, string.format(errors.resolve_open, v.source)
			end

-- create the data sink end
			local fout = root:fopen(v.map, "w")
			if not fout then
				return false, string.format(errors.resolve_create, v.map)
			end

-- finally background copy job and process the progress as part of pending
-- and update the set item on bgcopy
			v.pending = root:bgcopy(fin, fout, "p")
			if v.pending then
				v.pending:data_handler(
					function()
						local line, alive = v.pending:read()
						local last

-- flush out progress
						while line and #line > 0 do
							last = line
							line, alive = v.pending:read()
						end

						local props = string.split(last, ":") -- status:current:total
						local bs = tonumber(props[1])
						local cur = tonumber(props[2])
						local tot = tonumber(props[3])
						if bs < 0 then -- failed
							v.nbio = nil
							v.source = "broken: " .. v.source
							cat9.flag_dirty(active_job)

						elseif bs == 0 then -- complete
							v.source = v.map
							v.nbio = nil
							v.message = ""
							cat9.flag_dirty(active_job)
							v.unresolved = false

						else
							v.message = string.format("[%.2f]", 100.0 * (cur + 1) / (tot + 1))
							cat9.flag_dirty(active_job)
						end
					end
				)
			else
				root:funlink(v.map)
				fout:close()
			end

		end
	end
end

builtins["stash"] =
function(cmd, ...)
	if not cmd then
		ensure_stash_job()
		return
	elseif not commands[cmd] then
		return false, "stash : unknown command " .. tostring(cmd)
	end

	local set = {...}
	local base = {}
	slice_key = "source"
	local ok, msg = cat9.expand_arg(base, set)
	slice_key = "map"
	if not ok then
		return false, msg
	end

	return commands[cmd](base)
end

local cmdsug = {}

cmdsug.verify =
function(args, raw)
end

cmdsug.remove =
function(args, raw)
end

cmdsug.unlink =
function(args, raw)
end

cmdsug.archive =
function(args, raw)
end

cmdsug.add =
function(args, raw)
-- ignore jobs as sources for now, with the headache of getting #0(1 .. 100) etc.
	local carg = args[#args]
	if type(carg) ~= "string" then
		return
	end

-- seems to be a path, send out the regular asynch-helper into dynamic oracle
	local ch = string.sub(carg, 1, 1)
	if ch and (ch == "." or ch == "/") then
		local argv, prefix, flt, offset =
			cat9.file_completion(carg, cat9.config.glob.file_argv)

		cat9.filedir_oracle(argv,
			function(set)
				if flt then
					set = cat9.prefix_filter(set, flt, offset)
				end
				cat9.readline:suggest(set, "word", prefix)
			end
		)
	end
end

cmdsug.map =
function(args, raw)
	if #raw == 3 or #args == 0 then
		return
	end

	if not active_job then
		cat9.add_message(errors.map_nostash)
		return false, 7
	end

-- pick from existing stash items
	if #args == 1 then
		local set = {title = "source item"}
		for i=1,#active_job.set do
			local src = active_job.set[i].source
			if #args[1] == 0 or string.sub(src, 1, #args[1]) == args[1] then
				table.insert(set, src)
			end
		end
		cat9.readline:suggest(set, "word")
		return
	end

-- completion should probably just be from known map paths
	if #args == 2 then
		local found = false
		for i=1,#active_job.set do
			if active_job.set[i].source == args[1] then
				found = true
				break
			end
		end

		if not found then
			cat9.add_message(errors.sugg_map_source)
			return false, #args[1] + 8
		end

		local set = {title = "mapped path/name"}
		local paths = {}

		for i=1,#active_job.set do
			local map = active_job.set[i].map
			local prefix = string.split(map, "/")
			table.remove(prefix, #prefix)
			paths[table.concat(prefix, "/")] = true
		end

		for k,v in pairs(paths) do
			if #args[2] == 0 or string.sub(k, 1, #args[2]) == args[2] then
				table.insert(set, k)
			end
		end

		cat9.readline:suggest(set, "word")

	else
		cat9.add_message(errors.sugg_map_toomany)
		return false, #args[1] + #args[2] + 7
	end
end

suggest["stash"] =
function(args, raw)
	if #raw == 5 then
		return
	end

--
-- make sure we don't have job references or pargs anymore, this can get
-- expensive if you reference a large job as part of stash something #bla
-- before getting to #bla(1,10), should have some option to expand_arg
-- there to cap suggestion slicing.
--
	local outargs = {}

-- all commands reference (so far, prefix might not, for instance) the source
-- part but slicing the job returns map part by default so change the key for
-- resolving here
	slice_key = "source"
	local ok, msg = cat9.expand_arg(outargs, args)
	if not ok then
		cat9.add_message("stash: " .. msg)
		return false, msg
	end
	slice_key = "map"

	table.remove(outargs, 1) -- don't need 'stash'
	local rem = string.sub(raw, 7)
	local cmd = table.remove(outargs, 1)

	if cmd and cmdsug[cmd] then
		return cmdsug[cmd](outargs, rem)
	elseif #outargs >= 1 then
		cat9.add_message(string.format(errors.sugg_unknown, outargs[1]))
	else
		cat9.readline:suggest(cat9.prefix_filter(commands, rem, 0), "word")
	end
end

end
