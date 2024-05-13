--
-- missing:
--
--  colorize
--  edit / define mapping
--  expand directories (shallow / recursive)
--  checksum / verify
--  compress

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- we need to build a temporary directory where we expand the files
-- if they come from bchunk and symlink if they come from files and
-- then run through compressor / archival tool

local commands = {}
local active_job
builtins.hint["stash"] = "Define a set of objects to manipulate"

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
		map = lref or "fifo." .. tostring(id),
		kind = "fifo",
		nbio = blob,
		source = lref or "(fifo:" .. id .. ")"
	}

-- on OSes where we can resolve the origin of the descriptor backing
-- a blob, it'll be provided in lref
	table.insert(active_job.data, map.source)
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #active_job.data[#active_job.data]
	cat9.flag_dirty()
end

local function unregister()
	cat9.resources.bin = active_job.old_ioh
	active_job = nil
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
					return expand_set("map")
				elseif job.set[i] then
					return job.set[i].map, #job.set[i].map, 1
				else
					return nil, 0, 0
				end
			end
		)
end

local function write_at(job, x, y, str, set, i, pos, highlight, width)
	if root:utf8_len(set[i]) < width then
		root:write_to(x, y, str)
		return
	end

-- so we don't fit, priority:
	local src = active_job.set[i].source
	local map = active_job.set[i].map

	local ras = builtin_cfg.stash.right_arrow
	local ent = cat9.compact_path(src)
	local ral = root:utf8_len(ras)
	local ull = root:utf8_len(ent)
	local dul = root:utf8_len(map)

--  1. short_path + right_arrow + map_name
	if ull + ral + dul <= width then
		str = ent .. ras .. map
--  (missing) 2. shared_prefix (if any) + right_arrow + map_name
--            3. shortened_source_shared + right_arrow + map_name
	elseif ral + dul < width then
--  4. right_arrow + map_name
		str = ras .. map
	else
--  5. right_arrow + shorten_map_name
		str = ras .. cat9.compact_path(map)
	end

	root:write_to(x, y, str)
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

--	job.attr_lookup = get_attr
	table.insert(job.hooks.on_destroy, unregister)
	job.handlers.mouse_button = button
	job.handlers.mouse_motion = motion
	active_job = job
	cat9.resources.bin = monitor_inqueue

-- we want to add a factory that exposes the stash to the saveset
end

local function add_file(v)
	local ok, kind = root:fstatus(v)

	local map =
	{
		source = v,
		map = v,
	}

	if not ok then
		map.error = kind
		map.kind = "bad"
	else
		map.kind = kind
	end

	if string.sub(v, 1, 2) == "./" then
		v = root:chdir() .. string.sub(v, 2)
		map.map = v
		map.source = v
	end

-- O(n) ignore duplicates
	for i=1,#active_job.set do
		if v == active_job.set[i].source then
			return false, "stash add : rejecting duplicate entry"
		elseif v == active_job.set[i].map then
			return false, "stash add : rejecting map collision"
		end
	end

	table.insert(active_job.data, v .. builtin_cfg.stash.right_arrow .. v)
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #v
end

function commands.unlink(args)
	if #args ~= 1 or args[1] ~= "yes" then
		return false, "stash unlink : expecting 'yes' argument to confirm unlinking"
	end

-- this does not recurse into directories, need an explicit 'expand' to glob- commit
	local rv = true

	for i=#active_job.set,1,-1 do
		if active_job.set[i].kind == "file" then
			local ok, msg = root:funlink(active_job.set[i].source)
			if not ok then
				active_job.set[i].error = msg
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
		return false, "stash map: too many arguments"
	end

	for i=1,#active_job.set do
		if active_job.set[i].source == arg[1] then
			active_job.set[i].map = arg[2]
			cat9.flag_dirty(active_job)
			break
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
		return false, "stash verify: no active stash"
	end

	if #args > 0 then
		return false, "stash verify: too many arguments"
	end

	if active_job.verify_set then
		return false, "stash verify: verification still pending"
	end

	local set = all_by_type("file")
	if #set == 0 then
		return false, "stash verify: no files in current stash"
	end

	local queue = {}

-- copy the command, swap in our current file path and add to queue
	for i=1,#set do
		local cmd = cat9.table_copy_shallow(builtin_cfg.stash.checksum)
		set[i].error = nil

		for i=1,#cmd do
			if cmd[i] == "$path" then
				cmd[i] = set[i]
			end
		end

-- let the parse- action be part of the config file, but provide
-- a default matching --tag otherwise
		cmd.handler = function(job, arg, code)
			if code ~= 0 then
				set[i].error = "checksum execution failed"
				return
			end

			if not job.data[1] then
				set[i].error = "no checksum output"
				return
			end

			local out = string.split(job.data[1], " = ")
			if #out ~= 2 then
				set[i].error = "unknown checksum output"
				return
			end

			if set[i].checksum and set[i].checksum ~= out[2] then
				set[i].error = "changed"
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

function commands.compress(fn)
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
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	return commands[cmd](base)
end

local commands =
{
	"add",
	"archive",
	"unlink",
	"map",
	"verify",
	"expand",
	"remove",
	"prefix",
	hint = {
		"Create a stash and add a file to it, will append if a stash already exists",
		"Step through the stash and build an archive for it",
		"Unlink/Delete all the files and directories referenced in the stash",
		"Specify a name for an item in the stash",
		"Sweep the stash and checksum each file entry",
		"Resolve directories to individual files",
		"Remove one or a range of items from the stash",
		"Add or remove a number of characters to the beginning of a range of items in the stash",
	}
}

local function get_attr(job, set, i, pos, highlight)
	return builtin_cfg.stash.file
end

local function button(job, ind, x, y, mods, active)
end

local function motion(job, x, y)
end

local cmdsug = {}
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
		cat9.add_message("stash: no active stash")
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
			cat9.add_message("stash map: no matching source item")
			return false, #args[1] + 7
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
		cat9.add_message("stash map: too many argments")
		return false, #args[1] + #args[2] + 7
	end
end

suggest["stash"] =
function(args, raw)
	if #raw == 5 then
		return
	end

	table.remove(args, 1) -- don't need 'stash'
	local rem = string.sub(raw, 7)
	local cmd = table.remove(args, 1)

	if cmd and cmdsug[cmd] then
		return cmdsug[cmd](args, rem)
	elseif #args > 1 then
		cat9.add_message("stash: unknown command >" .. args[1] .. "<")
	else
		cat9.readline:suggest(cat9.prefix_filter(commands, rem, 0), "word")
	end
end

end
