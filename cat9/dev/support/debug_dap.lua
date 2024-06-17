return
function(cat9, parser, args, target)
local Debugger = {}

local function render_threads(dbg)
	local set = {}
	local bc = 0
	local max = 0

	for k,v in pairs(dbg.data.threads) do
		table.insert(set, k)
		local kl = #tostring(k)
		max = kl > max and kl or max
		bc = bc + kl
	end

-- remove / rewrite as replacing the set would break other references
	table.sort(set)
	for i=#dbg.threads,1,-1 do
		table.remove(dbg.threads, i)
	end

	for i,v in ipairs(set) do
		table.insert(dbg.threads,
			string.lpad(
				tostring(v), max) .. ": " .. dbg.data.threads[set[i]].state
		)
	end
	dbg.threads.linecount = #set
	dbg.threads.bytecount = bc

	if dbg.state_hook then
		dbg.state_hook()
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
	elseif dbg.data.threads[b.threadId] then
		dbg.data.threads[b.threadId].state = "continued"
	else
		dbg.output:add_line(dbg, "'continued' on unknown thread: " .. tostring(b.threadId))
	end
	render_threads(dbg)
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

local function handle_stopped_event(dbg, msg)
	render_threads(dbg)
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

	render_threads(dbg)

-- think we need some stronger hooks for when threads stop from
-- reaching a breakpoint or is triggered by a signal as that takes
-- rebuilding all thread-local views
end

local function handle_module_event(dbg, msg)
	local b = msg.body
	table.insert(dbg.data.modules, {name = b.module.name, reason = b.reason})
end

local function handle_initialized_event(dbg, msg)
	dbg.data.capabilities = msg.body or {}
	if type(target) == "number" then
		local on_active =
		function(dbg, msg)
			if msg.success then
				dbg.output:add_line(dbg, "Target active: " .. tostring(target))
				debug.active = true
				dbg:get_threads()
			else
				dbg.output:add_line(dbg, "Couldn't set debugger to target")
			end
		end
		send_request(dbg, "attach", {pid = target}, function()
			send_request(dbg, "startDebugging", {}, function(dbg, msg)
			end)
		end)
	else
		dbg.output:add_line(dbg, "Missing: handle argument transfer for program launch")
	end
end

local function handle_stop_event(dbg, msg)
	local b = msg.body

	local thread = dbg.threads[b.threadId]
	if not thread then
		self:threads()
		return
	end

	thread.state = "stopped"
	local state = string.format("%s(%s)", thread.state, b.reason)

	render_threads(dbg)
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

function Debugger:backtrace(id)
	send_request(self, "stackTrace", {threadId = id},
		function(job, msg)
			self.output:add_line(self, "got msg" .. msg.body.output)
		end
	)
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
		["initialized"] = handle_initialized_event,
		["continued"] = handle_continued_event
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
		capabilities = {}
	},
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
