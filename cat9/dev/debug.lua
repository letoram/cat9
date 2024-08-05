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
local view_factories =
{
	"thread",
	"breakpoint",
	"source",
	"disassembly",
	"registers",
	"variables",
	"arguments",
	"files",
	"maps"
}

for i=1,#view_factories do
	view_factories[view_factories[i]] = loadfile(
		string.format("%s/cat9/dev/support/%s_view.lua",
		lash.scriptdir, view_factories[i]
	))()
end

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local os_support =
	loadfile(string.format("%s/cat9/dev/support/debug_os.lua", lash.scriptdir))()(cat9, root)

local attach_block = os_support:can_attach()

local activejob
local errors = {
	bad_pid = "debug attach >pid< : couldn't find or bind to pid",
	attach_block = "debug: kernel blocks ptrace(pid), attach will fail",
	no_active = "debug: no active job",
	readmem = "debug: couldn't read memory at %s+%d",
	no_target = "debug launch >target< missing",
	no_job = "no active debug job",
	bad_ref = "debug >ref< ... is not a tied to a debugger",
	no_cmd = "debug: no valid command specified",
	bad_thread = "debug thread >id< ... invalid thread id",
	bad_thread_cmd = "debug thread (id) >cmd< unknown command: %s",
	bad_frame = "debug thread i cmd >frame< .. unknown or missing stack frame",
	no_source = "debug source >fn< .. missing source reference",
	no_pid = "debug >job< .. no process id assigned to job",
	no_break = "debug break job >target< ... no breakpoint target"
}

local cmds = {}
local views = {}

-- wrapper for tracking singleton or grouped windows (sources)
local function attach_window(key, fact, ...)
	return
	function(job, opts, ...)
		local group = opts.group or "windows"
		local wnd

		if job[group][key] then
			return job[group][key]
		end

		if type(fact) == "string" then
			wnd =
				cat9.import_job({
					short = fact,
					parent = job,
					data = job.debugger[key],
					check_status = cat9.always_active
				})
		else
			wnd = fact(cat9, builtin_cfg, job, ...)
		end
		job[group][key] = wnd

-- if the contents should be rebuilt on a hook like a stack frame
-- becoming invalid or updated
		local track
		if opts.invalidated then
			track = function()
				if wnd.invalidated then
					wnd:invalidated()
				end
			end
		end

		table.insert(
			wnd.hooks.on_destroy,
			function()
				job[group][key] = nil
				if opts.invalidated then
					local ih = opts.invalidated

					for i=1,#ih do
						if ih[i] == track then
								table.remove(ih, i)
								break
						end
					end
				end
			end
		)

		return wnd
	end
end

views.stderr = attach_window("stderr", "Debug:stderr")
views.stdout = attach_window("stdout", "Debug:stdout")
views.errors = attach_window("errors", "Debug:errors")
views.threads = attach_window("threads", view_factories.thread)
views.breakpoints = attach_window("breakpoints", view_factories.breakpoint)
views.source = attach_window("source", view_factories.source)
views.disassembly = attach_window("disassembly", view_factories.disassembly)
views.registers = attach_window("registers", view_factories.registers)
views.variables = attach_window("variables", view_factories.variables)
views.arguments = attach_window("arguments", view_factories.arguments)
views.files = attach_window("files", view_factories.files)
views.maps = attach_window("maps", view_factories.maps)

local function spawn_views(job, set)
	cat9.list_processes(function() end, true)

	activejob = job
	for i,v in ipairs(builtin_cfg.debug.options) do
		job.debugger:eval(
			v,
			"repl",
			function()
			end
		)
	end

	if not set then
		set = {"stderr", "stdout", "threads", "errors", "breakpoints"}
	end

	for i,v in ipairs(set) do
		if views[v] then
			views[v](job, {})
		end
	end
end

function cmds.files(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	if not job or not job.debugger.pid then
		return false, errors.no_pid
	end

	views.files(job, {}, os_support, job.debugger.pid)
end

function cmds.maps(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	if not job or not job.debugger.pid then
		return false, errors.no_pid
	end

	views.maps(job, {}, os_support, job.debugger.pid)
end

function cmds.thread(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	local thid
	local fid = 0
	local th

-- thread [n | n:f] stop | continue
	if tonumber(base[1]) ~= nil then

		local set = string.split(base[1], ":")
		if tonumber(set[2]) then
			fid = tonumber(set[2])
		end

		thid = tonumber(table.remove(base, 1))
		th = job.debugger.data.threads[thid]
	end

-- apply to all threads unless this is set
	if base[1] == "stop" then
		job.debugger:continue(thid)
		return
	elseif base[1] == "continue" then
		job.debugger:pause(thid)
		return
	elseif th and base[1] == "next" then
		th:step()
		return
	elseif th and base[1] == "in" then
		th:stepin()
		return
	elseif th and base[1] == "out" then
		th:stepout()
		return
	end

-- thread [n]
	thid = thid or 1
	th = job.debugger.data.threads[thid]

	if not th then
		return false, errors.bad_thread
	end

	local frame
	local domains =
	{
		registers =
		function()
			local wnd = views.registers(job,
				{invalidated = frame}, th, frame)
		end,
		disassemble =
		function()
			views.disassembly(job, {}, th, frame)
		end,
		variables =
		function()
			views.variables(job, {}, th, frame)
		end,
		arguments =
		function()
			views.arguments(job, {}, th, frame)
		end,
		var =
		function()
		end
	}

	local fid = 0
	if tonumber(base[2]) then
		fid = tonumber(base[2])
	end

	if not domains[base[1]] then
		return false, string.format(errors.bad_thread_cmd, base[1])
	end

	for i=1,#th.stack do
		if th.stack[i].id == fid then
			frame = th.stack[i]
			break
		end
	end

	if not frame then
		return false, errors.bad_frame
	end

	domains[base[1]]()

	return true
end

cmds["break"] = function(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

-- ensure we reference a job with a debugger in its hierarchy
	if not job then
		return false, errors.no_job
	end

	if job.debugger then
	elseif job.parent and job.parent.debugger then
		job = job.parent
	else
		return false, errors.bad_ref
	end

	if not base[1] then
		return false, errors.no_break
	end

-- a trailing conditional expression would be nice ...

-- instruction, function, source:line
	if string.sub(base[1], 1, 2) == "0x" then
		job.debugger:break_addr(base[1])

	elseif string.find(base[1], ":") then
		local set = string.split(base[1], ":")
		job.debugger:break_at(set[1], set[2])

-- assume function
	else
		job.debugger:break_on(set[1])
	end
end

function cmds.source(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end

	if not job then
		return false, errors.no_job
	end

	if not base[1] then
		return false, errors.no_source
	end

	local ref = string.split(base[1], ":")

	job.debugger:source(ref[1],
		function(source)
			if not source or #source == 0 then
				job.debugger.output:add_line(job.debugger, "empty source for " .. ref[1])
				return
			end

-- do we bind to track a specific thread and/or frame?
			local thid = tonumber(base[2])
			local swnd = views.source(job, {}, source, ref[1])
			swnd.source_ref = ref[1]

			local line = tonumber(ref[2])
			if line then
				swnd:move_to(line)
			end

			if not thid then
				return
			end

			local th = job.debugger.data.threads[thid]
			if not th then
				return
			end
			swnd.thid = thid

			local synch_markers =
			function()
				local marks = {}
				for i,v in ipairs(job.debugger.data.breakpoints) do
					if v.path == swnd.source_ref then
						marks[v.line[1]] = builtin_cfg.debug.breakpoint_line
					end
				end
				swnd.marks = marks
				cat9.flag_dirty(swnd)
			end

			local track =
			function(th)
				if th.stack[1].path ~= ref[1] then
					job.debugger:source(th.stack[1].path,
						function(source)
							th.stack[1]:source(source, th.stack[1].line)
							wnd.source_ref = th.stack[1].path
						end
					)
				else
					swnd:move_to(th.stack[1].line)
				end
				synch_markers()
			end

			synch_markers()
			table.insert(th.handlers.invalidated, track)

-- detach tracking if we terminate
			table.insert(swnd.hooks.on_destroy,
				function()
					for i=1,#th.handlers.invalidated do
						if th.handlers[i] == track then
							table.remove(th.handlers.invalidated, i)
							break
						end
					end
					return
				end
			)
-- source closure
		end
	)
end

function cmds.memory(job, ...)
	local set = {...}
	local base = {}
	local ok, msg = cat9.expand_arg(base, set)
	if not ok then
		return false, msg
	end
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
		windows = {},
		check_status = cat9.always_active
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
		windows = {},
		check_status = cat9.always_active
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

function builtins.debug(...)
	local set = {...}
	local job = activejob

	if type(set[1]) == "table" then
		job = table.remove(set, 1)

		if job.debugger then
		elseif job.parent and job.parent.debugger then
			job = job.parent
		else
			return false, errors.bad_ref
		end
	end

	local cmd = table.remove(set, 1)

	if not cmds or not cmds[cmd] then
		return false, errors.no_cmd
	end

	if cmd == "attach" or cmd == "launch" then
		return cmds[cmd](unpack(set))
	else
		return cmds[cmd](job, unpack(set))
	end
end

builtins["_default"] =
function(args)
	local job = active_job

	if type(args[1]) == "table" then
		if args[1].debugger then
			job = table.remove(args, 1)
		elseif args[1].parent and args[1].parent.debugger then
			job = (table.remove(args, 1)).parent
		end
	end

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
