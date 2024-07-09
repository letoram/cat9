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
	no_active = "debug: no active job",
	readmem = "debug: couldn't read memory at %s+%d",
	no_target = "debug launch >target< missing"
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

local function render_breakpoints(job, dbg)
	local data = {
		bytecount = 0,
		linecount = 0
	}

	for i,v in pairs(dbg.data.breakpoints) do
		local linefmt = ""
		if v.line[1] then
			linefmt = tostring(v.line[1])
			if v.line[2] ~= v.line[1] then
				linefmt = linefmt .. "-" .. tostring(v.line[2])
			end
		end

-- this view ignores column
		local str =
		string.format(
			"%s: %s%s%s @ %s+%s",
			tostring(v.id) or "[]",
			v.source,
			#linefmt > 0 and ":" or "",
			linefmt,
			v.instruction[1],
			tostring(v.instruction[2])
		)
		table.insert(data, str)
		data.bytecount = data.bytecount + #str
	end

	data.linecount = #data
	job.windows.breakpoints.data = data
	cat9.flag_dirty(job)
end

local function render_threads(job, dbg)
	local set = {}
	local bc = 0
	local max = 0

-- convert debugger data model to window view one
	for k,v in pairs(dbg.data.threads) do
		table.insert(set, k)
		local kl = #tostring(k)
		max = kl > max and kl or max
		bc = bc + kl
	end

	table.sort(set)
	local data = {}

	for i,v in ipairs(set) do
		table.insert(data,
			string.lpad(
				tostring(v), max) .. ": " .. dbg.data.threads[set[i]].state
		)
	end

	data.linecount = #data
	data.bytecount = bc
	job.windows.threads.data = data
	cat9.flag_dirty(job)
end

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
		data = {bytecount = 0, linecount = 0}
	})
	job.windows.threads.show_line_number = false
	job.debugger.on_update.threads =
		function(dbg)
			render_threads(job, dbg)
		end

	job.windows.breakpoints =
	cat9.import_job({
		short = "Debug:breakpoints",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})
	job.windows.breakpoints.show_line_number = false
	job.debugger.on_update.breakpoints =
	function(dbg)
		render_breakpoints(job, dbg)
	end

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

function cmds.memory(...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end
	local job = activejob
	local len = 65536

	job.debugger:read_memory(base[1], len,
		function(data)
			if not data then
				job.debugger.output:add_line(job.debugger,
					string.format(errors.readmem, base[1], len))
				return
			end
-- this is where we hook the memory into a new hex view job
			print("got", data.unreadable, #data.data)
		end
	)
end

function cmds.launch(...)
	local set = {...}
	local outargs = {}
	local ok, msg = cat9.expand_arg(outargs, set)

	if not ok then
		return false, msg
	end

	if not outargs[1] then
		return false, errors.no_target
	end

	local job = {
		short = string.format("Debug:launch(%s)", outargs[1]),
		debugger = debugger(cat9, parse_dap, builtin_cfg.debug, outargs)
	}

	job.data = job.debugger.output
	cat9.import_job(job)
	spawn_views(job)
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

			pid = tonumber(outargs[1])
		end
	end

	if not pid then
		return false, errors.bad_pid
	end

	local job = {
		short = "Debug:attach",
		debugger = debugger(cat9, parse_dap, builtin_cfg.debug, pid)
	}

-- this lets us swap out job.data between the different buffers, i.e. stderr,
-- telemetry, ... or have one in between that just gives us meta- information
-- of the debugger state itself, as well as spawning separate views for the
-- many data domains.
	job.data = job.debugger.output
	cat9.import_job(job)
	activejob = job
	table.insert(job.hooks.on_destroy,
		function()
			job.debugger:terminate(false)
		end
	)

-- this is if we want to perform a lot of tasks when large state transitions
-- happen, like hitting a breakpoint. Invalidation of the views happen through
-- update hooks added in spawn_views
	job.debugger:set_state_hook(
		function()
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
function(args)
	local base = {}
	local ok, msg = cat9.expand_arg(base, args)
	if not ok then
		return false, msg
	end

	if not activejob then
		return false, errors.no_active
	end

-- other options here is to assume debug #jobid command and when there is no
-- overlay command, fall back to eval

	activejob.debugger:eval(table.concat(base, " "), function()
		cat9.flag_dirty(activejob)
	end)
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
		table.insert(set, "memory")
		table.insert(set.hint, "View memory at a specific address or reference")
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

-- get list of known targets, otherwise create a new based on treating first
-- as normal executable completion and the rest as --args style forwarding
		if args[2] == "launch" then
		end

-- check if we reference an existing debugger session, then append_dbg_commands
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
