-- Arcan- specific debugger to cover both the needs of stepping
-- arcan/arcan_lwa via the --monitor command, and through arcan-net to
-- attach to a running controller and debugging an appl.
--
-- The only 'special' thing versus DAP, other than a lot of the
-- functions matching raw memory doesn't make sense, is that we
-- have the .lua snapshot format to create a view for.
--
-- Since everything is single threaded, the thread interface makes
-- more sense to be used for when we can attach to an appl-controller
-- and step/interface with that. Then we map that as thread 2 .. n
--
return
function(cat9, args, target)

local synch_frame =
-- Arcan- specific debugger to cover both the needs of stepping
function(thread)
	if thread.state ~= "stopped" then
		return
	end

	thread.stack = {}
end

local function invalidate_threads(dbg)
	for k,thread in pairs(dbg.data.threads) do
		for i=#thread.handlers.invalidated,1,-1 do
			thread.handlers.invalidated[i](thread)
		end
	end
end

local function ensure_thread(dbg, id)
	if dbg.data.threads[id] then
		return dbg.data.threads[id]
	end
	dbg.data.threads[id] = {
		id = id,
		state = "unknown",
		dbg = dbg,
		synch_frames = synch_frame,
		step = function(th)
		end,
		stepin = function(th)
		end,
		stepout = function(th)
		end,
		freerun = function(th, mode, granularity)
		end,
		stepi = function(th)
		end,
		locals = function(th, fid, cb)
			local frame = th:frame(fid)
			if not frame then
				cb({error = string.format(errors.no_frame, fid)})
			end
			frame:locals(cb)
		end,
		frame = function(th, fid)
			for i=1,#th.stack do
				if th.stack[i].id == fid then
					return th.stack[i]
				end
			end
		end,
		stack = {},
		handlers = {
			invalidated = {}
		}
	}
	return dbg.data.threads[id]
end

local Debugger = {}
function Debugger:get_suggestions(prefix, closure)
end

function Debugger:input_line(line)
end

function Debugger:break_at(source, line)
end

function Debugger:break_on(func)
end

function Debugger:break_addr(addr)
end

function Debugger:disassemble(addr, ofs, count, closure)
end

function Debugger:source(ref, closure)
end

function Debugger:read_memory(base, length, closure)
end

function Debugger:watch_memory(base, length, closure)
end

function Debugger:eval(expression, context, closure)
end

function Debugger:update_signal(signo, state, closure)
end

function Debugger:continue(id)
	if id ~= 1 then
		return
	end

	print("set running")
	local th = ensure_thread(self, 1)
	th.state = "running"
	self.job.inp:write("continue\n")
	invalidate_threads(self)
end

function Debugger:pause(id)
	if id ~= 1 then
		return
	end

	print("request stop")
	lash.root:psignal(self.job.pid, "user1");
	self.job.inp:write("dumpkeys\n");
	self.job.inp:write("backtrace\n");
end

function Debugger:restart()

	print("request restart")
	lash.root:psignal(self.job.pid, "user1");
	self.job.inp:write("reload\n");
end

function Debugger:set_log(login, logout)

end

function Debugger:terminate(hard)
end

local debug = setmetatable(
{
	data = {
		threads = {},
		files = {},
		functions = {},
		modules = {},
		capabilities = {},
		breakpoints = {}
	},

	job = job,
}, {__index = Debugger})

local applname = "pipeworld"

cat9.shmif_handover(
	args.arcan_default_mode, -- creation
	"rwe", -- streams wanted
	"/usr/bin/arcan_lwa", -- binary
	{}, -- environment
	{
		string.format("arcan(debug:%s)", applname), -- actual name
		"-O", -- monitor through stdout
		"LOGFD:1",
		"-C", -- accept commands through stdin
		"/home/void/.arcan/appl/pipeworld" -- appl to run
	},
	function(job)
		debug.job = job
		job.raw = "Arcan:Debug"
		job.short = "Arcan:Debug"
		debug.stderr = job.err_buffer

		table.insert(
			debug.job.hooks.on_data,
			function(line, _, _)
				if line == "#WAITING\n" then
					local th = ensure_thread(debug, 1)
					th.state = "stopped"
					invalidate_threads(debug)
					print("set stopped")
				else
					print("line", line)
				end
			end
		)

		local th = ensure_thread(debug, 1)
		th.state = "stopped"
		print("set stopped")
	end
)

return debug
end
