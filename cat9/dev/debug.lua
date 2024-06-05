return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local activejob

local Parser = {}
Parser.transition = {}

function Parser.transition.done(self)
	local rest = self.input:sub(self.i)
	self:reset()
	self.input = rest
	return Parser.transition.header_field
end

function Parser.transition.error(self)
	return Parser.transition.error
end

function Parser.transition.header_field(self)
	local i = self.i

	local crlf = self.input:find("\r\n", i)
	if i == crlf then
		self.i = i + 2
		return Parser.transition.content
	end

	local column = self.input:find(": ", i)
	if not column then
		if crlf then
			self.error = 'Expected ": ", found end of line'
			self.i = crlf
			return Parser.transition.error
		else
			return nil, true
		end
	end

	local key = self.input:sub(i, column-1)
	if #key == 0 then
		self.error = "Empty header key"
		return Parser.transition.error
	end

	local value = self.input:sub(column+2, crlf-1)
	self.headers[key] = value
	self.i = crlf + 2

	return Parser.transition.header_field
end

function Parser.transition.content(self)
	local len = tonumber(self.headers["Content-Length"])
	if not len then
		self.error = "Missing or invalid Content-Length header"
		return Parser.transition.error
	end

	local i = self.i
	if #self.input - i + 1 < len then
		return nil, true
	end

	local msg = self.input:sub(i, i+len-1)
	local ok, err = pcall(function()
		local t, _ = cat9.json.decode(msg)
		self.protomsg = t
	end)

	if not ok then
		self.error = err
		return Parser.transition.error
	end

	self.i = i + len
	return Parser.transition.done
end

function Parser:reset()
	self.next_state = Parser.transition.header_field
	self.input = ""
	self.i = 1
	self.headers = {}

	self.error = nil
	self.protomsg = nil
end

function Parser:feed(msg)
	self.input = self.input .. msg
end

function Parser:next()
	if self.next_state == Parser.transition.done then
		self.next_state = self:next_state()
	end

	while self.next_state ~= Parser.transition.done do
		local next, yield = self:next_state()

		if next == Parser.transition.error then
			return false
		end

		if yield then
			-- not enough input, yield
			-- free already consumed stream
			self.input = self.input:sub(self.i)
			self.i = 1
			return nil
		end
		self.next_state = next
	end

	return self.protomsg, self.headers
end

local function newDapParser()
	local parser = setmetatable({}, { __index = Parser })
	parser:reset()
	return parser
end

local function startDapJob()
	local inf, outf, errf, pid = root:popen({"gdb", "gdb", "-i", "dap"}, "rw")
	-- TODO Handle popen failure
	local job = cat9.import_job({
		raw = "dap",
		pid = pid,
		inp = inf,
		out = outf,
		err = errf,
		hidden = true,
		unbuffered = true,
		dap_seq = 1,
		parser = newDapParser(),
		event_handlers = {},
		request_handlers = {},
		response_handlers = {},
	})

	table.insert(job.hooks.on_data, function(line, _, _)
		job.parser:feed(line)

		for protomsg in Parser.next, job.parser do
			if not protomsg then
				error(job.parser.error or "Unknown DAP parser error")
			end

			if protomsg.type == "event" then
				local handler = job.event_handlers[protomsg.event]
				if handler then
					handler(job, protomsg)
				else
					print("Unhandled event:", protomsg.event)
				end
			elseif protomsg.type == "request" then
				local handler = job.request_handlers[protomsg.command]
				if handler then
					handler(job, protomsg)
				else
					print("Unhandled request:", protomsg.command)
				end
			elseif protomsg.type == "response" then
				local seq = tonumber(protomsg.request_seq)
				local handler = job.response_handlers[seq]
				if handler then
					handler(job, protomsg)
					job.response_handlers[seq] = nil
				else
					print(string.format("Unhandled response(%d): %s", protomsg.request_seq, protomsg.command))
				end
			end
		end
	end)

	function job:setDapEventHandler(event, fn)
		self.event_handlers[event] = fn
	end

	function job:setDapRequestHandler(request, fn)
		self.request_handlers[request] = fn
	end

	function job:sendDapRequest(request, args, response_handler)
		local seq = self.dap_seq
		local request = {
			type = "request",
			command = request,
			arguments = args,
			seq = seq,
		}
		local jsonMsg = cat9.json.encode(request)
		local msg = string.format("Content-Length: %d\r\n\r\n%s", #jsonMsg, jsonMsg)

		self.dap_seq = seq + 1
		self.inp:write(msg)

		if response_handler then
			self.response_handlers[seq] = response_handler
		end
	end

	job.subjobs = {}

	job.subjobs.output = cat9.import_job({
		short = "dev:debug attach output",
		raw = string.format("dev:debug attach %d", pid),
	})

	job.subjobs.threads = cat9.import_job({
		short = "dev:debug attach threads",
		raw = string.format("dev:debug attach %d", pid),
		threads = {},
		update_thread_state = function(job, thread, state)
			local line = string.format("thread #%d: %s", thread.id, state)
			if thread.wndline then
				local prev_bytes = #job.data[thread.wndline]
				job.data[thread.wndline] = line
				job.data.bytecount = job.data.bytecount - prev_bytes + #line
			else
				job:add_line(line)
				thread.wndline = job.data.linecount
			end
			cat9.flag_dirty()
		end,
	})

	function job.subjobs.threads.handlers.mouse_button(subjob, ind, x, y, mods, active)
		if not activejob or y < 1 then
			return
		end

		local thread
		for _, t in ipairs(subjob.threads) do
			if t.wndline == ind then
				thread = t
				break
			end
		end

		if thread.state == "running" then
			job:sendDapRequest("pause", { threadId = thread.id })
		elseif thread.state == "stopped" then
			job:sendDapRequest("continue", { threadId = thread.id }, function(job, msg)
				if msg.success then
					subjob:update_thread_state(thread, "running")
					thread.state = "running"
				end
			end)
		end
	end

	job:setDapEventHandler("output", function(job, msg)
		local line
		if msg.body.category then
			line = string.format("%s: %s", msg.body.category, msg.body.output)
		else
			line = msg.body.output
		end
		job.subjobs.output:add_line(line)
	end)

	job:setDapEventHandler("thread", function(job, msg)
		local b = msg.body
		local subjob = job.subjobs.threads

		if not subjob.threads[b.threadId] then
			subjob.threads[b.threadId] = { id = b.threadId }
		end
		local thread = subjob.threads[b.threadId]

		if b.reason == "started" then
			thread.state = "running"
		elseif b.reason == "exited" then
			thread.state = "exited"
		else
			print("Unknown thread event reason: ", b.reason)
		end

		subjob:update_thread_state(thread, thread.state)
	end)

	job:setDapEventHandler("module", function(job, msg)
		local b = msg.body
		print(string.format('module "%s" %s', b.module.name, b.reason))
	end)

	job:setDapEventHandler("stopped", function(job, msg)
		local subjob = job.subjobs.threads
		local b = msg.body

		local thread = subjob.threads[b.threadId]
		if thread then
			thread.state = "stopped"
			local state = string.format("%s(%s)", thread.state, b.reason)
			subjob:update_thread_state(thread, state)
		end
	end)

	job:sendDapRequest("initialise", {
		adapterID = "gdb",
	}, function(job, msg)
		job.dap_capabilities = msg.body or {}
	end)

	return job
end

local cmds = {}

function cmds.continue()
	activejob:sendDapRequest("continue", {threadId = 1}, function(job, msg)
		local subjob = job.subjobs.threads
		local thread = subjob.threads[1]
		if thread then
			subjob:update_thread_state(thread, "running")
			thread.state = "running"
		end
	end)
end

function cmds.pause()
	activejob:sendDapRequest("pause", {threadId = 1}, function(job, msg)
		local subjob = job.subjobs.threads
		local thread = subjob.threads[1]
		if thread then
			subjob:update_thread_state(thread, "pausing")
		end
	end)
end

function cmds.disassemble()
	assert(activejob.dap_capabilities.supportsDisassembleRequest, "Debug adapter doesn't support disassemble request")
	-- activejob:sendDapRequest("disassemble", )
end

function cmds.attach(process)
	local pid

	if type(process) == "string" then
		pid = tonumber(process)
	elseif type(process) == "table" then
		pid = process.pid
	end

	if not pid then
		cat9:add_message("debug attach >process< - invalid pid, job reference or job without associated process")
		return
	end

	local job = startDapJob()
	activejob = job

	job:sendDapRequest("attach", {
		pid = tonumber(pid),
	}, function(job, msg)
		if msg.success then
			print("Succesful attach!")
		else
			print("Attach failed:", msg.message)
		end
	end)
end

function builtins.debug(cmd, ...)
	if cmds[cmd] then
		return cmds[cmd](...)
	end
end

end
