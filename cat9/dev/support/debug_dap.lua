return
function(cat9, parser, args, target)
local Debugger = {}

local function send_request(dbg, req, args, handler)
	local seq = dbg.dap_seq
	dbg.dap_seq = dbg.dap_seq + 1
	dbg.response[seq] = handler

	local request = {
		type = "request",
		command = req,
		arguments = args,
		seq = seq,
	}
	local jsonMsg = cat9.json.encode(request)
	local msg = string.format("Content-Length: %d\r\n\r\n%s", #jsonMsg, jsonMsg)
	dbg.job.inf:write(msg)
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

	destination:add_line(line)
end

local function handle_stopped_event(dbg, msg)
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
		dbg.errors:add_line("Unknown thread event reason: ", b.reason)
	end

-- think we need some stronger hooks for when threads stop from
-- reaching a breakpoint or is triggered by a signal
-- update_thread_state(thread, thread.state)
end

local function handle_module_event(dbg, msg)
	local b = msg.body
	table.insert(dbg.data.modules, {name = b.module.name, reason = b.reason})
end

local function handle_stop_event(dbg, msg)
	local b = msg.body

	local thread = dbg.threads[b.threadId]
	if not thread then
		return
	end

	thread.state = "stopped"
	local state = string.format("%s(%s)", thread.state, b.reason)

	dbg.job.stdout:add_line("stopped")
--	subjob:update_thread_state(thread, state)
end

local function on_active(dbg, msg)
	if msg.success then
		dbg.stdout:add_line("Adapter Active")
		debug.active = true
	else
		dbg.stdout:add_line("Couldn't set debugger to target")
	end
end

local function on_initialized(dbg, msg)
	dbg.data.capabilities = msg.body or {}
	if type(target) == "number" then
		send_request(dbg, "attach", {pid = target}, on_active)
	else
		stdout:add_line("Missing: handle argument transfer for program launch")
	end
end

local msghandlers =
{
event =
function(dbg, msg)
	if dbg.event[msg.event] then
		dbg.event[msg.event](dbg, msg)
	else
		dbg.errors:add_line("Unhandled event:" .. msg.event)
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
		dbg.errors:add_line("No response handler for " .. (seq and seq or "bad_seqence"))
	end
end
}

function Debugger:get_suggestions(prefix, closure)
-- since we can get many when / if the prefix changes maybe the cancellation
-- request should be returned as a function() that the UI can call
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
			self.errors:add_line(errstr)
			break
		end

		if msghandlers[protomsg.type] then
			msghandlers[protomsg.type](self, protomsg)
		else
			self.errors:add_line("Unknown message type: " .. protomsg.type)
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
end

function Debugger:watch_memory(base, length, closure)
end

function Debugger:eval(expression, closure)
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
	activejob:sendDapRequest("continue", {threadId = 1}, function(job, msg)
		local subjob = job.subjobs.threads
		local thread = subjob.threads[1]
		if thread then
			subjob:update_thread_state(thread, "running")
			thread.state = "running"
		end
	end)
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

function Debugger:terminate()
-- kill job so we don't leave dangling DAPs around
end

function Debugger:backtrace(id)
end

function Debugger:locals(id)
end

function Debugger:registers(id)
end

function Debugger:thread_state(id, state)
-- change state for one or many threads
end

function Debugger:threads()
	local set = {}
	return set
end

local function add_tbl_line(tbl, line)
	table.insert(tbl, line)
	tbl.linecount = tbl.linecount + 1
	tbl.bytecount = tbl.bytecount + #line
end

local inf, outf, errf, pid = lash.root:popen(args, "rw")
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
	},
	request = {},
	response = {},
	output = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	stderr = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	stdout = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	errors = {bytecount = 0, linecount = 0, add_line = add_tbl_line},
	data = {
		threads = {},
		files = {},
		functions = {},
		modules = {},
		capabilities = {}
	},
	job = job,
--	log = lash.root:fopen("/tmp/log", "w"), (uncomment to see data before parse)
	parser = parser(cat9),
	dap_seq = 1
}, {__index = Debugger})

table.insert(
	debug.job.hooks.on_data,
	function(line, _, _)
		debug:input_line(line)
	end
)

send_request(debug, "initialize", {adapterID = "gdb"}, on_initialized)

return debug
end
