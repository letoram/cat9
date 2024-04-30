--
-- missing:
--  edit / define mapping
--  expand filepath
--  expand directory (shallow / recursive)
--  checksum / verify
--  compress
--

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- we need to build a temporary directory where we expand the files
-- if they come from bchunk and symlink if they come from files and
-- then run through compressor / archival tool

local commands = {}
local active_job
builtins.hint["stash"] = "Define a set of objects to manipulate"

local function monitor_inqueue(id, blob, lref)
	local map = {
		map = id,
		kind = "fifo",
		nbio = blob
	}

-- on OSes where we can resolve the origin of the descriptor backing
-- a blob, it'll be provided in lref
	table.insert(active_job.data, lref or "(fifo:" .. id .. ")")
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #active_job.data[#active_job.data]
	cat9.flag_dirty()
end

local function unregister()
	cat9.resources.bin = active_job.old_ioh
	active_job = nil
end

local function add_stash_job()
	local job =
	{
		set = {},
		check_status =
		function()
			return true -- feedback if job
		end,
		raw = "",
		view_name = "stash",
		short = "Stash",
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

-- O(n) ignore duplicates
	for i=1,#active_job.set do
		if v == active_job.set[i].source then
			return
		end
	end

	table.insert(active_job.data, v .. builtin_cfg.stash.right_arrow .. v)
	table.insert(active_job.set, map)

	active_job.data.linecount = active_job.data.linecount + 1
	active_job.data.bytecount = active_job.data.bytecount + #v
end

function commands.unlink(arg)
	if type(arg) == "table" then
		if not arg.parg then
			return false
		end
	elseif type(arg) ~= "string" or arg ~= "yes" then
		cat9.add_message("unlink: please add 'yes' to confirm deleting all files referenced by the stash")
		return false
	end

-- this does not recurse into directories, need an explicit 'expand' to glob- commit
	local rv = true

	for i=#active_job.set,1,-1 do
		if active_job.set[i].kind == "file" then
			local ok, msg = root:funlink(active_job.set[i].source)
			if not ok then
				cat9.add_message(string.format("unlink (%s) failed: %s, stopping.", active_job.set[i], msg))
				rv = false
				break
			end

			table.remove(active_job.set, i)
			local count = table.remove(active_job.data, i)

			active_job.data.linecount = active_job.data.linecount - 1
			active_job.data.bytecount = active_job.data.bytecount - #count
		end
	end

	cat9.flag_dirty(active_job)
	return rv
end

function commands.add(...)
	local set = {...}

	if not active_job then
		add_stash_job()
	end

-- handle job (args) to slice out and add to set, this requires that
-- the source (typically list) slices out into absolute and useful path
	local parg
	if type(set[1]) == "table" and
		type(set[2]) == "table" and set[2].parg then
		local job = table.remove(set, 1)
		local parg = table.remove(set, 1)
		local res = job:slice(parg)

		if res then
			for i, v in ipairs(res) do
				if type(v) == "string" then
					add_file(v)
				end
			end
		end
	end

	for i,v in ipairs(set) do
		if type(v) == "table" then
		elseif type(v) == "string" then
			add_file(v)
		end
	end
end

function commands.compress(fn)
end

builtins["stash"] =
function(cmd, ...)
	if not cmd then
		if not active_job then
			add_stash_job()
		end
		return
	elseif not commands[cmd] then
		cat9.add_message("system:stash - unknown command : " .. tostring(cmd))
		return
	end

	commands[cmd](...)
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

local function slice()
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
