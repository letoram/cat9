return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local parse_dap =
	loadfile(string.format("%s/cat9/dev/support/parse_dap.lua", lash.scriptdir))()

local debugger =
	loadfile(string.format("%s/cat9/dev/support/debug_dap.lua", lash.scriptdir))()

local activejob
local errors = {
	bad_pid = "debug attach >pid< : couldn't find or bind to pid"
}

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
		parser = parse_dap(cat9),
		event_handlers = {},
		request_handlers = {},
		response_handlers = {},
	})

	table.insert(job.hooks.on_data, function(line, _, _)
		job.parser:feed(line)

		for protomsg, headers in job.parser:next() do
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

			pid = tonumber(set[1])
		end
	end

	if not pid then
		return false, errors.bad_pid
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

function suggest.debug(args, raw)
end
end
