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
-- for breakpoints we want a special view for hooks:
--
-- clock, input, input_raw, input_end, preframe, postframe,
-- adopt, autores, autofont, displaystate, displayreset,
-- frameserver, mesh, calctarget, lwa, image, audio, main,
-- shutdown, nbio_read, nbio_write, nbio_data, handover,
-- trace
--
-- toggle_hook(name)
--  then tracking window for the states
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
	local th
	th = {
		id = id,
		state = "unknown",
		dbg = dbg,
		synch_frames = synch_frame,
		step = function(th)
			dbg.job.inp:write("stepnext\n")
			th.stack = {}
			th.state = "running"
		end,
		stepin = function(th)
			dbg.job.inp:write("stepcall\n")
			th.stack = {}
			th.state = "running"
		end,
		stepout = function(th)
			dbg.job.inp:write("stepend\n")
			th.stack = {}
			th.state = "running"
		end,
		freerun = function(th, mode, granularity)
		end,
		stepi = function(th)
			dbg.job.inp:write("stepinstruction\n")
			th.stack = {}
			th.state = "running"
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
	dbg.data.threads[id] = th
	return th
end

local Debugger = {}
function Debugger:get_suggestions(prefix, closure)
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
	self.job.inp:write("source " .. ref .. "\n")
	self.source_closure = closure
-- source references are just files
end

function Debugger:read_memory(base, length, closure)
end

function Debugger:watch_memory(base, length, closure)
end

function Debugger:eval(expression, context, closure)
	if self.job and self.job.inp then
		self.job.inp:write("eval " .. expression .. "\n")
	end
end

function Debugger:update_signal(signo, state, closure)
end

function Debugger:continue(id)
	if id ~= 1 then
		return
	end

	local th = ensure_thread(self, 1)
	th.state = "running"
	th.stack = {}

	self.job.inp:write("continue\n")
end

function Debugger:pause(id)
	if id ~= 1 then
		return
	end

	lash.root:psignal(self.job.pid, "user1");
	self.job.inp:write("dumpkeys\n");
	self.job.inp:write("backtrace\n");
end

function Debugger:restart()
	lash.root:psignal(self.job.pid, "user1");
	self.job.inp:write("reload\n");
end

function Debugger:set_log(login, logout)

end

local function get_frame_locals(frame, cb)
-- each local:
--  ref = someref
--  :modify(val, val)
--  :fetch(var, cb)
--  variables = {}
end

function process_key(debug)
-- BEGINKV is special as its contents will depend on if we ran dumpstate or
-- dumpkeys, this is because how arcan-net does it based on exit status
	if debug.key.name == "BACKTRACE" then
		for i,v in ipairs(debug.key) do
			local frame = {
				id = i,
				line = 0,
				line_end = 0,
				column = 0,
				pc = 0,
				thread = 0,
				name = "",
				locals = get_frame_locals,
				source = "nop",
				path = "/tmp",
			}
			local shmif = string.unpack_shmif_argstr(v)
			if shmif and shmif.type == "stacktrace" then
				frame.path = shmif.source
				frame.block_start = tonumber(shmif.start)
				frame.block_end = tonumber(shmif["end"])
				frame.line = tonumber(shmif.current)
				frame.line_end = current
				frame.name = shmif.name
				table.insert(debug.data.threads[1].stack, frame)
			end
		end

	elseif debug.key.name == "SOURCE" then
		debug.key.path = table.remove(debug.key, 1)
		debug.key.sourceReference = 0
		if debug.source_closure then
			debug.source_closure(table.concat(debug.key, "\n"))
			debug.source_closure = nil
		end
	end

	invalidate_threads(debug)
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
		breakpoints = {},
		sources = {}
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
	{
	block_wnd = true,
	closure =
	function(job)
		debug.job = job
		job.raw = "Arcan:Debug"
		job.short = "Arcan:Debug"
		job.block_buffer = true
		debug.stderr = job.err_buffer

--
-- uses #TAG and #ENDTAG to group data,
-- \# to escape initial # and \\n to escape linefeed
--
-- #TAG / #ENDTAG can be nested, buffer those
--
		table.insert(
			debug.job.hooks.on_data,
			function(line, _, _)
				line = string.sub(line, 1, -2) -- trailing linefeed

-- special cases: WAITING, FINISHED
				if line == "#WAITING" then
					local th = ensure_thread(debug, 1)
					th.state = "stopped"
					invalidate_threads(debug)
				elseif string.sub(line, 1, 4) == "#END" then
					if debug.key and string.sub(line, 5) == debug.key.name then
						process_key(debug)
						debug.key = nil
					else
						table.insert(debug.key, line)
					end

-- new key?
				elseif string.sub(line, 1, 6) == "#BEGIN" then
					if not debug.key then
						debug.key = {
							name = string.sub(line, 7)
						}
					else
						table.insert(debug.key, line)
					end

-- just buffer? if so, drop escaped \# (and unescape \n)
				elseif debug.key then
					if string.sub(line, 1, 1) == "\\" and string.sub(line, 2, 2) == "#" then
						table.insert(debug.key, string.sub(line, 2))
					else
						local line = string.gsub(line, "\\n", "\n")
						table.insert(debug.key, line)
					end

				else
					print("unexpected", line)
				end
			end
		)

		local th = ensure_thread(debug, 1)
		th.state = "stopped"
	end
	}
)

return debug
end
