local parse_dap =
	loadfile(string.format("%s/cat9/dev/support/parse_dap.lua", lash.scriptdir))()

local debugger =
	loadfile(string.format("%s/cat9/dev/support/debug_dap.lua", lash.scriptdir))()

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local activejob
local errors = {
	bad_pid = "debug attach >pid< : couldn't find or bind to pid"
}

local cmds = {}

local function spawn_views(job)
	cat9.import_job({
		short = "Debug:stderr",
		parent = job,
		data = job.debugger.stderr
	})

	cat9.import_job({
		short = "Debug:stdout",
		parent = job,
		data = job.debugger.stdout
	})

	cat9.import_job({
		short = "Debug:threads",
		parent = job,
		data = job.debugger.threads
	})

	cat9.import_job({
		short = "Debug:errors",
		parent = job,
		data = job.debugger.errors
	})
end

function cmds.attach(...)
	local set = {...}
	local process = set[1]
	local pid

	if type(process) == "string" then
		pid = tonumber(process)

-- table arguments can be (1,2,3) or #1, the former has the parg attribute set
	elseif type(process) == "table" then
		if not process.parg then
			pid = process.pid

-- resolve into text-pid
		else
			local outargs = {}
			table.remove(set, 1)
			local ok, msg = cat9.expand_arg(outargs, set)
			if not ok then
				return false, msg
			end

			pid = tonumber(set[1])
		end
	end

	if not pid then
		return false, errors.bad_pid
	end

	local job = {
		short = "Debug:attach",
		debugger = debugger(cat9, parse_dap, {"gdb", "gdb", "-i", "dap"}, pid)
	}

-- this lets us swap out job.data between the different buffers, i.e.
-- stderr, telemetry, ... or have one in between that just gives us meta-
-- information of the debugger state itself
	job.data = job.debugger.output
	cat9.import_job(job)
	activejob = job
	table.insert(job.hooks.on_destroy,
		function()
			job.debugger:terminate()
		end
	)

	job.debugger:set_state_hook(
		function()
			print("state changed")
		end
	)

	spawn_views(job)
end

function builtins.debug(cmd, ...)
	if cmds[cmd] then
		return cmds[cmd](...)
	end
end

function suggest.debug(args, raw)
end
end
