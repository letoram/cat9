--
-- need a hook for the global window destroy / shutdown so we can send the
-- detach / shutdown command and not leave dangling gdb -i
--
local parse_dap =
	loadfile(string.format("%s/cat9/dev/support/parse_dap.lua", lash.scriptdir))()

local debugger =
	loadfile(string.format("%s/cat9/dev/support/debug_dap.lua", lash.scriptdir))()

--
-- split out the rendering and interaction code for each window
--
local view_factories = {"thread", "breakpoint", "source"}
for i=1,#view_factories do
	view_factories[view_factories[i]] = loadfile(
		string.format("%s/cat9/dev/support/%s_view.lua",
		lash.scriptdir, view_factories[i]
	))()
end

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local activejob
local errors = {
	bad_pid = "debug attach >pid< : couldn't find or bind to pid",
	attach_block = "debug: kernel blocks ptrace(pid), attach will fail",
	no_active = "debug: no active job",
	readmem = "debug: couldn't read memory at %s+%d",
	no_target = "debug launch >target< missing",
	no_job = "no active debug job"
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
local views = {}

local function attach_window(key, fact)
	return
	function(job)
		if job.windows[key] then
			return
		end

		if type(fact) == "string" then
			job.windows[key] =
				cat9.import_job({
					short = fact,
					parent = job,
					data = job.debugger[key]
				})
		else
			job.windows[key] = fact(cat9, builtin_cfg, job)
		end

		table.insert(job.windows[key].hooks.on_destroy,
		function()
			job.windows[key] = nil
		end)
	end
end

views.stderr = attach_window("stderr", "Debug:stderr")
views.stdout = attach_window("stdout", "Debug:stdout")
views.errors = attach_window("errors", "Debug:errors")
views.threads = attach_window("threads", view_factories.thread)
views.breakpoints = attach_window("breakpoints", view_factories.breakpoint)
views.source = attach_window("source", view_factories.source)
-- views.disassembly = attach_window("disassembly", view_factories.disassembly)
-- views.registers = attach_window("registers", view_factories.registers)

local function spawn_views(job, set)
	activejob = job

	if not set then
		set = {"stderr", "stdout", "threads", "errors", "breakpoints"}
	end

	for i,v in ipairs(set) do
		if views[v] then
			views[v](job)
		end
	end
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
	local len = 10

	if not job then
		return false, errors.no_job
	end

-- gdb will fail for the entire request if we try to read beyond a mapping,
-- the option is to figure out page alignment from base address and request
-- one page at a time until we've covered length.
	job.debugger:read_memory(base[1], len,
		function(data)
			if not data then
				job.debugger.output:add_line(job.debugger,
					string.format(errors.readmem, base[1], len))
				return
			end

			local new = {
				short = string.format("memory @ %s + %d", base[1], #data.data),
				data = {
					data.data,
					bytecount = #data.data,
					linecount = 1
				},
			}

			new["repeat"] =
			function(self)
				job.debugger:read_memory(
					base[1], len,
					function(data)
						if not data then
							return
						end

						new.data = {
							data.data,
							bytecount = #data.data,
							linecount = 1
						}
						cat9.flag_dirty(new)
					end
				)
			end

-- set repeat as a new request
			cat9.import_job(new)
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
		debugger = debugger(cat9, parse_dap, builtin_cfg.debug, outargs),
		windows = {}
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
		debugger = debugger(cat9, parse_dap, builtin_cfg.debug, pid),
		windows = {}
	}

-- this lets us swap out job.data between the different buffers, i.e. stderr,
-- telemetry, ... or have one in between that just gives us meta- information
-- of the debugger state itself, as well as spawning separate views for the
-- many data domains.
	job.data = job.debugger.output
	cat9.import_job(job)
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
	activejob.debugger:eval(
		table.concat(base, " "), "repl",
		function()
			cat9.flag_dirty(activejob)
		end
	)
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
