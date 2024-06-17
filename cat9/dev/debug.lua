--
-- need a hook for the global window destroy / shutdown so we can send the
-- detach / shutdown command and not leave dangling gdb -i
--
local parse_dap =
	loadfile(string.format("%s/cat9/dev/support/parse_dap.lua", lash.scriptdir))()

local debugger =
	loadfile(string.format("%s/cat9/dev/support/debug_dap.lua", lash.scriptdir))()

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local activejob
local errors = {
	bad_pid = "debug attach >pid< : couldn't find or bind to pid",
	attach_block = "debug: kernel blocks ptrace(pid), attach will fail",
}

-- Probe for means that would block ptrace(pid), for linux that is ptrace_scope
-- this should latch into an 'explain' option with more detailed information
-- about what can be done.
--
-- Another option would be to permit builtin [name] [uid] to pick a prefix
-- runner in order to doas / sudo to run commands.
--
local attach_block = false
local ro = root:fopen("/proc/sys/kernel/yama/ptrace_scope", "r")
if ro then
	ro:lf_strip(true)
	local state, _ = ro:read()
	state = tonumber(state)
	if state ~= nil then
		if state ~= 0 then
			attach_block = true
		end
	end

	ro:close()
else
-- for openBSD this would be kern.global_ptrace
end

local cmds = {}

local function spawn_views(job)
	job.windows = {}

	job.windows.stderr =
	cat9.import_job({
		short = "Debug:stderr",
		parent = job,
		data = job.debugger.stderr
	})

	job.windows.stdout =
	cat9.import_job({
		short = "Debug:stdout",
		parent = job,
		data = job.debugger.stdout
	})

	job.windows.threads =
	cat9.import_job({
		short = "Debug:threads",
		parent = job,
		data = job.debugger.threads,
	})
	job.windows.threads.show_line_number = false

	job.windows.errors =
	cat9.import_job({
		short = "Debug:errors",
		parent = job,
		data = job.debugger.errors
	})
end

function cmds.backtrace(...)
	local set = {...}
	if not activejob then
		return
	end
	activejob.debugger:backtrace()
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
		debugger = debugger(cat9, parse_dap, builtin_cfg.debug, pid)
	}

-- this lets us swap out job.data between the different buffers, i.e.
-- stderr, telemetry, ... or have one in between that just gives us meta-
-- information of the debugger state itself
	job.data = job.debugger.output
	cat9.import_job(job)
	activejob = job
	table.insert(job.hooks.on_destroy,
		function()
			job.debugger:terminate(false)
		end
	)

	job.debugger:set_state_hook(
		function()
			cat9.flag_dirty(job)
		end
	)

	spawn_views(job)
end

function builtins.debug(cmd, ...)
	if cmds[cmd] then
		return cmds[cmd](...)
	end
end

builtins["_default"] =
function(argtbl)
-- this weill be called when there is no matching builtin.something applied,
-- then we can append our own current prefix and have that match into injeecting a prompt
-- for the last command. What needs some thought is that when we have more builtins in the
-- set, particularly for scm, build, test, deploy that we capture the intention of the
-- user and that there is no amvbiguity between which part of the set owns which keyword.
--
-- if there is an activejob set and we are here, forward as eval into the debug adapter,
-- asynch get suggestions and work from there
end

function suggest.debug(args, raw)
	if #raw == 5 then
		return
	end

	local set = {}

-- these are a bit special in the sense that we can either go debug #job (where the
-- ID is any job with a debugger or parent.debugger OR go from the activejob and then
-- set active based on last one we inserted things into.
	local function append_dbg_commands()
		table.insert(set, "backtrace")
		table.insert(set.hint, "Toggle a backtrace view on/off")
	end

	if #args == 2 then
		set =
			{
				"attach",
				"launch",
				hint = {
					"Attach a new debugger to a job or process-identifer",
					"Create a new debugging session and have it launch a target",
				}
			}
		if activejob then
			append_dbg_commands()
		end
	else
		if args[2] == "attach" and attach_block then
			cat9.add_message(errors.attach_block)
		end

-- check if we reference an existing debugger session, then append_dbg_commands
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
