return
function(cat9, parser, args, target)
local Debugger = {}
local errors = {
	breakpoint_id = "change or remove on breakpoint without valid id",
	breakpoint_missing = "unknown breakpoint %d",
	set_breakpoint = "breakpoint request failed",
	set_variable, "set %s failed: %s",
	no_frame = "missing requested frame %d"
}

local send_request

local function invalidate_threads(dbg)
	for k,thread in pairs(dbg.data.threads) do
		for i=#thread.handlers.invalidated,1,-1 do
			thread.handlers.invalidated[i](thread)
		end
	end
end

local function send_set_variable(dbg, ref, var, val)
	send_request(
	dbg, "setVariable", {
			variablesReference = ref,
			name = var.name,
			value = val,
		},
		function(job, msg)
			if msg.success then
				var.value = val
				return
			end

			dbg.errors:add_line(dbg,
				string.format(errors.set_variable, name, msg.message))
		end
	)
end

local function get_frame_locals(frame, on_response)
	if frame.cached_locals then

		if frame.cached_locals.pending then
			table.insert(frame.cached_locals.pending, on_response)
		else
			on_response(frame.cached_locals)
		end
		return
	end

	frame.cached_locals = {pending = {count = 0}}

--
-- the scopes returned are just reference,
-- then we need to actually fetch them individually
--
	send_request(frame.thread.dbg, "scopes", {
		frameId = frame.id
		},
		function(job, msg)
			if not msg.body or not msg.body.scopes then
				return
			end

-- then request the actual variables, do it for all scopes even though
-- one might want to defer the ones marked as expensive so we don't
-- drift into Gb territory.
			for i,v in ipairs(msg.body.scopes) do

				local pending = frame.cached_locals.pending
				pending.count = pending.count + 1

				send_request(frame.thread.dbg, "variables", {
						variablesReference = v.variablesReference
					},
					function(job, msg)
						pending.count = pending.count - 1

						local ref = {
							reference = v.variablesReference,
						}
						if msg.success and msg.body.variables then
							ref.variables = msg.body.variables

							for _, var in ipairs(msg.body.variables) do
								var.modify =
								function(var, val)
									send_set_variable(
										frame.thread.dbg, v.variablesReference, var, val)
								end
							end
						else
							error = not msg.success and msg.message or nil
						end
						frame.cached_locals[string.lower(v.name)] = ref

-- last one requested, wake everyone
						if pending.count == 0 then
							frame.cached_locals.pending = nil
							for _,v in ipairs(pending) do
								v(frame.cached_locals)
							end
						end
					end
				)
			end
		end
	)
end

local function synch_frame(thread)
	if thread.state ~= "stopped" then
		return
	end

-- fair optimization here would be to request locals here for the frames
-- that have cached_locals requested (but with stepping that would quickly
-- become all of them)

	thread.stack = {}

-- first get the trace so we have IDs, then update the scopes for the topmost
	send_request(thread.dbg, "stackTrace", {threadId = thread.id},
		function(job, msg)
			local b = msg.body
			if not b or not b.stackFrames then
				return
			end

			for i,v in ipairs(b.stackFrames) do
				local frame = {
					id = v.id,
					line = v.line,
					column = v.column,
					pc = v.instructionPointerReference,
					thread = thread,
					name = v.name,
					locals = get_frame_locals
				}

				if v.source then
					frame.source = v.source.name
					frame.path = v.source.path
					frame.ref = v.source.sourceReference
				else
					frame.source = "unknown"
					frame.path = ""
				end

-- resolve the module as a reference
				for i,v in ipairs(thread.dbg.data.modules) do
					if v.name == b.moduleId then
						frame.module = v
						break
					end
				end

				table.insert(thread.stack, frame)
			end

			for i=#thread.handlers.invalidated,1,-1 do
				thread.handlers.invalidated[i](thread)
			end
		end
	)
end

local function stepreq(th, req)
	if th.state ~= "stopped" then
		return
	end

	th.state = "running"
	send_request(th.dbg, req, {threadId = th.id, singleThread = true},
		function()
		end
	)
end

local function ensure_thread(dbg, id)
	if dbg.data.threads[id] then
		return dbg.data.threads[id]
	end
	dbg.data.threads[id] =
		{
			id = id,
			state = "unknown",
			dbg = dbg,
			synch_frames = synch_frame,
			step = function(th)
				stepreq(th, "next")
			end,
			stepin = function(th)
				stepreq(th, "stepIn")
			end,
			stepout = function(th)
				stepreq(th, "stepOut")
			end,
			locals = function(th, fid, cb)
				local frame = th:frame(fid)
				if not frame then
					cb({error = string.format(errors.no_frame, fid)})
					return
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

local function get_breakpoint_by_addr(dbg, addr)
	for i,v in ipairs(dbg.data.breakpoints) do
		if v.instructionReference == addr then
			return v, i
		end
	end
end

local function get_breakpoint_by_source(dbg, source, line)
	for i,v in ipairs(dbg.data.breakpoints) do
		if v.path and v.path == source and v.line[1] == line then
			return v, i
		end
	end
end

local function get_breakpoint_by_id(dbg, id)
	for i,v in ipairs(dbg.data.breakpoints) do
		if v.id and v.id == id then
			return v, i
		end
	end
end

local function dap_bpt_to_bpt(bpt, b)
	bpt.id = b.id
	bpt.verified = b.verified or b.reason

	if b.source then
		bpt.source = b.source.name
		bpt.path = b.source.path
		bpt.ref = b.source.sourceReference
	else
		bpt.source = "unknown"
		bpt.path = ""
	end

	if b.line then
		bpt.line = {b.line, b.endLine or b.line}
	else
		bpt.line = {-1, -1}
	end

	if b.column then
		bpt.column = {b.column, b.endColumn or b.column}
	else
		bpt.column = {0, 0}
	end

	if b.instructionReference then
		bpt.instruction = {b.instructionReference, b.offset or 0}
	else
		bpt.instruction = {"0x??", "+?"}
	end
end

local function synch_breakpoints_handler(dbg, msg)
	if not msg.success then
		dbg.output:add_line(dbg, errors.set_breakpoint)
		return
	end
	for i,v in ipairs(msg.body.breakpoints) do
		local id, ind = get_breakpoint_by_id(dbg, v.id)
		local bpt = {}
		dap_bpt_to_bpt(bpt, v)

		if not id then
			table.insert(dbg.data.breakpoints, bpt)
		else
			dbg.data.breakpoints[ind] = bpt
		end
	end

	invalidate_threads(dbg)
end

local function run_update(dbg, event)
	if dbg.on_update[event] then
		dbg.on_update[event](dbg)
	end
end

send_request =
function(dbg, req, args, handler)
	local seq = dbg.dap_seq
	dbg.dap_seq = dbg.dap_seq + 1
	dbg.response[seq] = handler

	local kvc = 0
	for k,v in pairs(args) do
		kvc = kvc + 1
	end

	local request = {
		type = "request",
		command = req,
		arguments = kvc > 0 and args or nil,
		seq = seq,
	}
	local jsonMsg = cat9.json.encode(request)
	local msg = string.format("Content-Length: %d\r\n\r\n%s", #jsonMsg, jsonMsg)
	if dbg.log_out then
		dbg.log_out:write(msg)
	end
	dbg.job.inf:write(msg)
end

local function handle_continued_event(dbg, msg)
	local b = msg.body

	if b.allThreadsContinued then
		for k,v in pairs(dbg.data.threads) do
			v.state = "continued"
		end
	elseif b.threadId then
		ensure_thread(dbg, b.threadId)
		dbg.data.threads[b.threadId].state = "continued"
	else
		dbg.output:add_line(dbg, "'continued' on unknown thread: " .. tostring(b.threadId))
	end

	if dbg.on_update.threads then
		dbg.on_update.threads(dbg)
	end
end

local function handle_output_event(dbg, msg)
	local line
	local destination = dbg.stdout

	if msg.body.category then
		if type(dbg[msg.body.category]) == "table" then
			destination = dbg[msg.body.category]
			line = msg.body.output
		else
			line = string.format("%s: %s", msg.body.category, msg.body.output)
		end
	else
		line = msg.body.output
	end

	destination:add_line(dbg, line)
end

local function handle_process_event(dbg, msg)
	local b = msg.body
	dbg.remote = not b.isLocalProcess
	dbg.pid = b.systemProcessId
end

local function handle_breakpoint_event(dbg, msg)
	local b = msg.body
	local bpts = dbg.data.breakpoints
	local bpt

	if b.reason == "changed" then
		if not b.breakpoint.id then
			dbg.errors:add_line(dbg, errors.breakpoint_id)
			return
		end

		bpt = get_breakpoint_by_id(dbg, b.breakpoint.id)
		if not bpt then
			dbg.errors:add_line(dbg, string.format(errors.breakpoint_missing, b.breakpoint.id))
			return
		end

	elseif b.reason == "new" then
		bpt = {}
		table.insert(bpts, bpt)

	elseif b.reason == "removed" then
		for i=1,#bpts do
			if bpts[i].id and bpts[i].id == b.breakpoint.id then
				table.remove(bpts, i)
				break
			end
		end

		run_update(dbg, "breakpoints")
		return
	end

	dap_bpt_to_bpt(bpt, b.breakpoint)
	run_update(dbg, "breakpoints")
end

local function handle_stopped_event(dbg, msg)
-- reason:
--  step, breakpoint, exception, pause, entry, goto,
--  function breakpoint, data breakpoint, instruction breakpoint
-- description?
-- threadId?
-- preserveFocusHint?
-- text?
-- allThreadsStopped?
-- hitBreakpointIds?
	local b = msg.body

	if b.allThreadsStopped then
		for k,v in ipairs(dbg.data.threads) do
			v.state = "stopped"
			v:synch_frames()
		end
	elseif b.threadId then
		local th = ensure_thread(dbg, b.threadId)
		th.state = "stopped"
		th:synch_frames()
	end

	if dbg.state_hook then
		dbg:state_hook("stopped")
	end

	run_update(dbg, "threads")
end

local function handle_thread_event(dbg, msg)
	local b = msg.body
	local thread = ensure_thread(dbg, b.threadId)

	if b.reason == "started" then
		thread.state = "running"
	elseif b.reason == "exited" then
		thread.state = "exited"
	else
		dbg.errors:add_line(dbg, "Unknown thread event reason: ", b.reason)
	end

	run_update(dbg, "threads")
end

local function handle_module_event(dbg, msg)
	local b = msg.body
	table.insert(dbg.data.modules, {name = b.module.name, reason = b.reason})
end

local function handle_initialized_event(dbg, msg)
	dbg.data.capabilities = msg.body or {}
	if type(target) == "number" then
		send_request(dbg, "attach", {pid = target},
			function()
			end)
	elseif type(target) == "table" then
		local target = cat9.table_copy_shallow(target)
		local program = table.remove(target, 1)

		if args.dap_create then
			for i,v in ipairs(args.dap_create) do
				send_request(dbg, string.format(v, program))
			end
		end

		local launchopt = {
			stopAtBeginningOfMainSubprogram = true,
			program = program
		}
		launchopt.args = target
		launchopt.env = cat9.env
		launchopt.cwd = lash.root:chdir()

		send_request(dbg, "launch", launchopt,
			function()
--				send_request(dbg, "startDebugging", {request = "launch"}, function(dbg, msg) end)
			end
		)
	else
		dbg.output:add_line(dbg, "Unknown launch target type: " .. tostring(target))
	end
end

local function handle_stop_event(dbg, msg)
	local b = msg.body
	local thread = ensure_thread(dbg, b.threadId)
	thread.state = "stopped"
	thread.reason = b.reason
	run_update(dbg, "threads")
end

local msghandlers =
{
event =
function(dbg, msg)
	if dbg.event[msg.event] then
		dbg.event[msg.event](dbg, msg)
	else
		dbg.errors:add_line(dbg, "Unhandled event:" .. msg.event)
	end
end,
request =
function(dbg, msg)
-- what in DAP is actually sending requests to us?
end,
response =
function(dbg, msg)
	local seq = tonumber(msg.request_seq)

	if dbg.response[seq] then
		dbg.response[seq](dbg, msg)
		dbg.response[seq] = nil
	else
		dbg.errors:add_line(dbg, "No response handler for " .. (seq and seq or "bad_seqence"))
	end
end
}

function Debugger:get_suggestions(prefix, closure)
-- since we can get many when / if the prefix changes maybe the cancellation
-- request should be returned as a function() that the UI can call
end

function Debugger:set_state_hook(hook)
	self.state_hook = hook
end

-- public interface
function Debugger:input_line(line)
	local job = self.job

-- quick troubleshooting, uncomment the log = root:fopen part further down
	if self.log then
		self.log:write(line)
		self.log:flush()
	end

	self.parser:feed(line)
	for protomsg, headers in self.parser:next() do
		if not protomsg then
			local errstr = self.parser.error or "Unknown DAP parser error"
			if self.log then
				self.log:write(errstr)
			end
			self.errors:add_line(self, errstr)
			break
		end

		if msghandlers[protomsg.type] then
			msghandlers[protomsg.type](self, protomsg)
		else
			self.errors:add_line(self, "Unknown message type: " .. protomsg.type)
		end
	end
end

function Debugger:break_at(source, line)
	local bp = self.data.breakpoints
	local tog

	local set = {
		source = {path = source},
		breakpoints = {}
	}

-- check if its a toggle
	local id, ind = get_breakpoint_by_source(self, source, line)
	if id then
		table.remove(bp, ind)
	else
		table.insert(set.breakpoints, {line = line})
	end

	for i,v in ipairs(bp) do
		if v.path == source then
			table.insert(set.breakpoints, {line = v.line[1]})
		end
	end

	send_request(self, "setBreakpoints", set, synch_breakpoints_handler)
end

function Debugger:break_on(func)
-- toggle by calling on existing with no added arguments
	local tog
	for i=#self.breakpoints.func, 1, -1 do
		if self.breakpoints.addr[i].name == func then
			table.remove(self.breakpoints.func, i)
			tog = true
		end
	end

	if not func then
		self.breakpoints.addr = {}
	else
		if not tog and func then
			table.insert(self.breakpoints.func, {name = func})
		end
	end

	local set = {}
	for i,v in ipairs(self.breakpoints.func) do
		table.insert(set, {name = v.name})
	end

	send_request(self, "setFunctionBreakpoints", { breakpoints = set },
		function()
		end
	)
end

function Debugger:break_addr(addr)
end

function Debugger:disassemble(addr, ofs, count, closure)
	send_request(self, "disassemble", {
		memoryReference = addr,
		resolveSymbols = true,
		instructionOffset = ofs,
		instructionCount = count
	},
	function(job, msg)
		if not msg.success then
			closure()
			return
		end

		local set = {}
		for i,v in ipairs(msg.body.instructions) do
			local insn = {}
			insn.str = v.instruction
			insn.bytes = {}
			insn.addr = v.address

			for b=1,#v.instructionBytes,2 do
				table.insert(insn.bytes, tonumber(string.sub(v.instructionBytes, b, b+1), 16))
			end

			table.insert(set, insn)
		end

		closure(set)
	end
	)
end

function Debugger:source(ref, closure)
	local src = {}
	if tonumber(ref) then
		src.sourceReference = ref
	else
		src.path = ref
		src.sourceReference = 0
	end

	send_request(self, "source", {source = src, sourceReference = 0},
		function(job, msg)
			closure(msg.body and msg.body.content or nil)
		end
	)
end

function Debugger:read_memory(base, length, closure)
	send_request(self, "readMemory", {memoryReference = base, count= length},
		function(job, msg)
			local b = msg.body
			if b then
				if b.data then
					closure(
						{data = cat9.from_b64(b.data),
						unreadable = b.unreadableBytes or 0}
					)
			-- address, unreadableBytes? data?
				else
					closure({data = {}, unredable = length})
				end
			else
				closure()
			end
		end
	)
end

function Debugger:watch_memory(base, length, closure)
end

-- possible contexts:
--  watch
--  repl
--  hover
--  clipboard
--  variables
--
-- other options:
--  evaluate in frame (frameId)
--  format (?)
--
function Debugger:eval(expression, context, closure)
	send_request(self, "evaluate", {expression = expression, context = context},
		function(job, msg)
			local b = msg.body
			if not msg.success then
				self.errors:add_line(self, msg.message)
			elseif b and b.result then
				for _, line in ipairs(string.split(b.result, "\n")) do
					self.output:add_line(self, line)
				end
			end
		end
	)
end

function Debugger:update_signal(signo, state, closure)
-- maybe we need to run gdb/lldb special eval requests here,
-- didn't see anything to retrieve posix signal mask and the state
-- of blocked, print, nopass etc.
end

-- interesting / most difficult task is really
--
-- if (fork()) execve()
--
-- and be able to get that split out into another job so that we can have
-- multiples running and actually step through things
--
-- other would be building ftrace() and strace() like behaviours so that
-- we can use the same interface for tracing and pattern based trace triggers
-- like trace(write, data %some_pattern)
function Debugger:continue(id)
	local arg = {
		threadId = 1
	}

	if id then
		arg.threadId = id
		arg.singleThread = true
	end

	send_request(self, "continue", arg,
		function(job, msg)
			if msg.success and id then
				handle_continued_event(self,
					{
						body = {
							allThreadsContinued = msg.body.allThreadsContinued,
							threadId = id
						}
					}
				)
			end
		end
	)
end

function Debugger:pause(id)
	local arg = {
		threadId = 1
	}

	if id then
		arg.threadId = id
		arg.singleThread = true
	end

-- there is a pause all as well to use if [id] is not specified
	send_request(self, "pause",
		{
		--	threadId = 1
		},
		function(job, msg)
		end
	)
end

function Debugger:reset()
-- should restart / run the target again, perhaps not useful for attach
end

function Debugger:terminate(hard)
	local function close_job()
		if not self.job then
			return
		end

-- this is a bit dangerous as normally we just know from failure on outf
-- that the process is dead, here we don't have those guarantees so SIGCHLD
-- should really be caught and handled somewhere so we don't blindly kill
-- lash.root:psignal(self.job.pid, "hup")
		cat9.remove_job(self.job)
		self.job = nil
	end

-- 3s timer
	local lim = 25 * 3
	table.insert(cat9.timers,
	function()
		lim = lim - 1
		if lim == 0 then
			close_job()
		end
	end)

	send_request(self, hard and "terminate" or "disconnect", {},
		function(job, msg)
			close_job()
		end
	)
-- kill job so we don't leave dangling DAPs around
end

function Debugger:get_threads()
	send_request(self, "threads", {},
		function(job, msg)
			if not msg.success then
				self.output:add_line(self, "thread request failed: " .. msg.message)
			else
			end
		end
	)
	return set
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
	if not tbl.clock then
		tbl.clock = {}
		table.insert(tbl.clock, dbg.counter)
	end

	dbg.counter = dbg.counter + 1
	tbl.linecount = tbl.linecount + 1
	tbl.bytecount = tbl.bytecount + #line
end

local inf, outf, errf, pid =
	lash.root:popen(args.dap_default, "rw")
	-- TODO Handle popen failure

local job =
cat9.import_job({
	raw = "dap",
	pid = pid,
	inf = inf,
	out = outf,
	err = errf,
	block_buffer = true,
	hidden = true,
	unbuffered = true,
})

outf:lf_strip(false)

local debug = setmetatable(
{
	event = {
		["output"] = handle_output_event,
		["thread"] = handle_thread_event,
		["module"] = handle_module_event,
		["stopped"] = handle_stopped_event,
		["initialized"] = handle_initialized_event,
		["continued"] = handle_continued_event,
		["breakpoint"] = handle_breakpoint_event,
		["process"] = handle_process_event
	},
	request = {},
	response = {},
	counter = 1,
	output = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	stderr = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	stdout = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	errors = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	threads = {bytecount = 0, linecount = 0},

	data = {
		threads = {},
		files = {},
		functions = {},
		modules = {},
		capabilities = {},
		breakpoints = {},
	},

	on_update = {},
	job = job,
-- (uncomment to see data before parse)
	log = lash.root:fopen("/tmp/dbglog.in", "w"),
	log_out = lash.root:fopen("/tmp/dbglog.out", "w"),
	parser = parser(cat9),
	dap_seq = 1
}, {__index = Debugger})

table.insert(
	debug.job.hooks.on_data,
	function(line, _, _)
		debug:input_line(line)
	end
)

-- the actual trigger event is "initialized" not the reply to "initialize"
send_request(debug, "initialize", {adapterID = "gdb"}, function() end)

return debug
end
