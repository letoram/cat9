--
-- missing:
--  edit / define mapping
--  expand filepath
--  expand directory (shallow / recursive)
--  checksum / verify
--  compress
--

return
function(cat9, root, builtins, suggest)

-- we need to build a temporary directory where we expand the files
-- if they come from bchunk and symlink if they come from files and
-- then run through compressor / archival tool

local commands = {}
local active_job
builtins.hint["stash"] = "Define a set of objects to manipulate"

local function monitor_inqueue(id, blob)
	local map = {
		map = id,
		kind = "fifo",
		nbio = blob
	}

-- On some OSes, we could try and map the descriptor back to some local backing
-- file even though there might not be one, but the nbio abstraction doesn't
-- expose a fd, so that'd take monitoring proc/fds and notice the change when
-- we receive it. Better would be to let NBIO try and expose if there is a
-- valid and (at the time) accurate reverse-mapping. The main point is knowing
-- if the resource is local and can be treated as a file or a socket/fifo.
	table.insert(active_job.data, "(fifo:" .. id .. ")")
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

function commands.add(...)
	local set = {...}

	if not active_job then
		add_stash_job()
	end

	for i,v in ipairs(set) do
		local ok, kind = root:fstatus(v)
		local map =
		{
			map = v
		}

		if not ok then
			map.error = kind
			map.kind = "bad"
		else
			map.kind = kind
		end

		table.insert(active_job.data, v)
		table.insert(active_job.set, {map = v})

		active_job.data.linecount = active_job.data.linecount + 1
		active_job.data.bytecount = active_job.data.bytecount + #v
	end
end

function commands.compress(fn)
end

builtins["stash"] =
function(cmd, ...)
	if not cmd or not commands[cmd] then
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
	hint = {
		"Create a stash and add a file to it, will append if a stash already exists",
		"Step through the stash and build an archive for it",
		"Unlink and remove all the files and directories referenced in the stash",
		"Specify a name for an item in the stash",
		"Sweep the stash and checksum each file entry",
		"Resolve directories to individual files",
		"Remove one or a range of items from the stash",
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

suggest["stash"] =
function(args, raw)
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
