-- Arcan- specific debugger to cover both the needs of stepping arcan/arcan_lwa
-- via the --monitor command, and through arcan-net to attach to a running
-- controller and debugging an appl.
--
-- The only 'special' thing versus DAP, other than a lot of the
-- functions matching raw memory doesn't make sense, is that we
-- have the .lua snapshot format to create a view for.
--
-- Since everything is single threaded, the thread interface makes more sense
-- to be used for when we can attach to an appl-controller and step/interface
-- with that. Then we map that as thread 2 .. n.
--
-- Todo:
--   [ ] - expand table
--   [ ] - support varargs
--   [ ] - modify local
--   [ ] - breakpoint support
--   [ ] - completion helper for arcan launch
--   [ ] - add local attach support
--   [ ] - view for showing snapshots and snapshot deltas
--   [ ] - copy table to spreadsheet
--   [ ] - move reads/writes to thread specific inp/outp
--   [ ] - port interface to arcan-net directory
--   [ ] - port interface to afsrv_terminal:lua
--   [ ] - arcan_db key to trigger debugger
--
return
function(cat9, args, target)

local errors = {
	no_frame = "missing requested frame %d",
}

local synch_frame =
-- Arcan- specific debugger to cover both the needs of stepping
function(thread)
	if thread.state ~= "stopped" then
		return
	end

	thread.stack = {}
end

local function invalidate_threads(dbg)
	for k,thread in ipairs(dbg.data.threads) do
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
		vmstack = {
			locals =
			function(_, cb)
				cb({locals = { variables = th.vmstack }})
			end
		},
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
				cb({error = string.format(errors.no_frame, fid or -1)})
			else
				frame:locals(cb)
			end
		end,
		frame = function(th, fid)
			if fid == -1 then
				return th.vmstack
			end

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
	cb({locals = { variables = frame.locals_tbl }})
end

local function gen_local(debug, frame, shmif, parent)
	local tbl =
	{
		ref = tonumber(shmif.index),
		type = shmif.vartype and tonumber(shmif.vartype) or "nil",
		value = shmif.value,
		parent = parent,
		name = shmif.name or "(missing)",
		modify =
		function(var, val)
			print("set", frame.id, shmif.index, val)
		end,
		fetch =
		function(var, cb)
			if var.type ~= "table" then
				cb(var.value or "nil")
			end

-- walk parents and build forward- list of indices
			table.insert(debug.queue, {"TABLEVALUE", cb})
			local base = string.format("table %d ", frame.id)
			local tree = {tostring(var.ref)}
			local cv = var.parent
			while cv do
				table.insert(tree, 1, tostring(cv.ref))
				cv = cv.parent
			end

-- need to check if the table reference is local, stack, vararg, global
			dbg.job.inp:write(string.format(
				"table l %d %s\n", frame.id, table.concat(tree, " ")))
		end
	}

	if shmif.vartype == "table" then
		tbl.namedVariables = tonumber(shmif.length) + tonumber(shmif.keys)
	elseif not tbl.value then
		tbl.value = "nil"
	end

	return tbl
end

function process_key(debug)
-- priority if the key matches a queued one
	if debug.queue[1] and debug.queue[1][1] == debug.key.name then
		local ent = table.remove(debug.queue, 1)
		ent(debug.key)
		return
	end

-- BEGINKV is special as its contents will depend on if we ran dumpstate or
-- dumpkeys, this is because how arcan-net does it based on exit status
	if debug.key.name == "BACKTRACE" then
		local stack = debug.data.threads[1].stack
		stack.entrypoint = "(unknown)"

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
				locals_tbl = {},
				source = "nop",
				path = "/tmp",
			}
			local shmif = string.unpack_shmif_argstr(v)
			if not shmif then
				debug.errors:add_line("Broken backtrace: " .. v)
				return
			end

-- some frames of anonymous inner functions we should resolve the outer name
-- afterwards as a fixup and propagate onwards
			if shmif.type == "stacktrace" then
				frame.path = shmif.source
				frame.source = frame.path
				frame.block_start = tonumber(shmif.start)
				frame.block_end = tonumber(shmif["end"])
				frame.line = tonumber(shmif.current)
				frame.line_end = current
				frame.name = shmif.name
				frame.id = tonumber(shmif.frame) or i
				table.insert(stack, frame)

			elseif shmif.type == "entrypoint" then
				stack.entrypoint = shmif.kind

			elseif shmif.type == "local" then
				table.insert(stack[#stack].locals_tbl, gen_local(debug, stack[#stack], shmif))
			end
		end

-- fixup stack in reverse, propagate name into (null) named ones
		local lastname = stack.entrypoint
		for i=#stack,1,-1 do
			if stack[i].name == "(null)" then
				stack[i].name = lastname
			end
			lastname = stack[i].name
		end

-- stack is just a special frame-id (with a possible stack marker for each frame
	elseif debug.key.name == "STACK" then
		for i=#debug.data.threads[1].vmstack, 1, -1 do
			table.remove(debug.data.threads[1].vmstack, i)
		end

		for i,v in ipairs(debug.key) do
			local shmif = string.unpack_shmif_argstr(v)
			if not shmif then
				debug.errors:add_line("Broken VM stack: " .. v)
				return
			end
			table.insert(debug.data.threads[1].vmstack, gen_local(debug, {id = -1}, shmif))
		end

		elseif debug.key.name == "ERROR" then
		for _,v in ipairs(debug.key) do
			local source, line, msg = string.match(v, "%[string%s(.+)%]%:(%d+):(.+)")
			if not source or not line or not msg then
				debug.errors:add_line(debug, "couldn't parse error message, raw:")
				debug.errors:add_line(debug, v)
			else
-- can get string.sub 2,-2 from source for the full filename
				debug.errors:add_line(debug, msg)
			end
		end

	elseif debug.key.name == "SOURCE" then
		debug.key.path = table.remove(debug.key, 1)
		debug.key.sourceReference = 0
		if debug.source_closure then
			debug.source_closure(table.concat(debug.key, "\n"))
			debug.source_closure = nil
		end
	else
		print("unhandled key", debug.key.name)
	end
end

function Debugger:terminate(hard)
end

local function add_tbl_line(tbl, dbg, line)
-- presenting the number as a timeline gives weird interactions with the default
-- crop view, track the counter as linear between the buffers but don't add it to
-- the explicit data for now
	line = string.trim(line)
	if #line == 0 then
		return
	end

	table.insert(tbl, line)
	tbl.linecount = tbl.linecount + 1
	tbl.bytecount = tbl.bytecount + #line
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
	queue = {},
	stdout = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	output = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	errors = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	features = {
		launch = true,
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
		"-C", "-", -- accept commands through stdin
		"/home/void/.arcan/appl/test" -- appl to run
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
				local th = ensure_thread(debug, 1)
				line = string.sub(line, 1, -2) -- trailing linefeed

-- special cases: WAITING, FINISHED
				if line == "#WAITING" then
					if th.state ~= "stopped" then
						th.state = "stopped"
					end
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

-- print output from the debugee?
				elseif th.state ~= "stopped" then
					local shmif = string.unpack_shmif_argstr(line)
					if shmif and shmif.type and shmif.value then
						debug.stdout:add_line(debug,
							string.format("%s: %s", shmif.type, shmif.value))
					else
						print("unexpected", line)
					end
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
