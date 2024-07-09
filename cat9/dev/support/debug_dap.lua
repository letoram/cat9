return
function(cat9, parser, args, target)
local Debugger = {}
local errors = {
	breakpoint_id = "change or remove on breakpoint without valid id",
	breakpoint_missing = "unknown breakpoint %d"
}

local function ensure_thread(dbg, id)
	if dbg.data.threads[id] then
		return
	end
	dbg.data.threads[id] = {id = id, state = "unknown"}
end

local function get_breakpoint_by_id(dbg, id)
	for k,v in ipairs(dbg.data.breakpoints) do
		if v.id and v.id == id then
			return v
		end
	end
end

local function run_update(dbg, event)
	if dbg.on_update[event] then
		dbg.on_update[event](dbg)
	end
end

local function send_request(dbg, req, args, handler)
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

local function handle_breakpoint_event(dbg, msg)
	local b = msg.body
	local bpts = dbg.data.breakpoints
	local bpt

	dbg.output:add_line(dbg, "breakpoint reached")

	b.id = b.id and tonumber(b.id) or nil
	if b.reason == "changed" then
		if not b.id then
			dbg.errors:add_line(dbg, errors.breakpoint_id)
			return
		end

		bpt = get_breakpoint_by_id(dbg, bpts.id)
		if not bpt then
			dbg.errors:add_line(dbg, string.format(errors.breakpoint_missing, b.id))
			return
		end

	elseif b.reason == "new" then
		bpt = {}
		table.insert(bpts, bpt)

	elseif b.reason == "removed" then
		for i=1,#bpts do
			if bpts[i].id and bpts[i].id == b.id then
				table.remove(bpts, i)
				return
			end
		end

		run_update(dbg, "breakpoints")
		return
	end

	b = b.breakpoint
	bpt.id = b.id
	bpt.verified = b.verified or b.reason
	if b.source then
		bpt.source = b.source.name
		bpt.path = b.source.path
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
		for k,v in pairs(dbg.data.threads) do
			v.state = "stopped"
		end
	elseif b.threadId then
		ensure_thread(dbg, b.threadId)
		dbg.data.threads[b.threadId].state = "stopped"
	end

	if dbg.state_hook then
		dbg:state_hook("stopped")
	end

	run_update(dbg, "threads")
end

local function handle_thread_event(dbg, msg)
	local b = msg.body

	if not dbg.data.threads[b.threadId] then
		dbg.data.threads[b.threadId] = { id = b.threadId }
	end

	local thread = dbg.data.threads[b.threadId]

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
		send_request(dbg, "attach", {pid = target}, function()
			send_request(dbg, "startDebugging", {request = "attach"}, function(dbg, msg)
			end)
		end)
	elseif type(target) == "table" then
		local launchopt = {
			stopAtBeginningOfMainSubprogram = true,
			program = table.remove(target, 1)
		}
		launchopt.args = target
		launchopt.env = cat9.env
		launchopt.cwd = lash.root:chdir()

		send_request(dbg, "launch", launchopt,
			function()
				send_request(dbg, "startDebugging", {request = "launch"}, function(dbg, msg) end)
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

function Debugger:disassemble(closure)
	if not self.data.capabilities.supportsDisassembleRequest then
		closure("Adapter does not support disassembly")
-- fallback or complement here would be to actually read_memory out the
-- text and forward into capstone et al. could even be useful to compare
-- disassembly engines ..
	else
		closure("")
	end
end

function Debugger:set_breakpoint(source, line, offset)
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

function Debugger:eval(expression, closure)
	send_request(self, "evaluate", {expression = expression},
		function(job, msg)
			self.output:add_line(self, msg.message)
		end
	)

-- evaluate
-- arguments:
--  expression
--  frameId?
--  context? : watch, repl, hover, clipboard, variables
--  format?
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
	send_request(self, {threadId = id or 1},
		function(job, msg)
		end
	)
end

function Debugger:pause(id)
-- there is a pause all as well to use if [id] is not specified
	send_request(self, "pause", {threadId = 1},
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

function Debugger:locals(id)
end

function Debugger:registers(id)
end

function Debugger:thread_state(id, state)
-- change state for one or many threads
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
		["breakpoint"] = handle_breakpoint_event
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
