return function(cat9, root, builtins, suggest)

local function shc_helper(mode, ...)
	local args = {...}
	local argv = {"/bin/sh", "sh", "-c"}
	local str  = ""
	local env = root:getenv()

	for k,v in pairs(cat9) do
		env[k] = v
	end

-- check processing directive
	lastarg = args[1]

	argv[4] = table.concat(args, " ")
	local job = cat9.setup_shell_job(argv, mode, env)
	if job then
		job.short = "subshell"
		job.raw = argv[4]
	end
	return job
end

-- alias for handover into vt100
builtins["!"] =
function(...)
	cat9.term_handover("join-r", ...)
end

builtins["!!"] =
function(...)
	shc_helper("rwe", ...)
end

builtins["p!"] =
function(...)
--
-- note: we can't just run pty line-buffered like normal, there is timing
-- behaviour and hold/wait like scenarios that will bite immediately, e.g. ssh
-- asking for prompt.
--
-- This is also where we should have an attachable vt100 parser in multiple
-- stages, from just 'cursor + motion' to full on terminal. This helper
-- should probably be part of proper (lash.tty_setup(wnd) -> function(data))
--
-- the terminal option would probably be best solved with running through an
-- afsrv_terminal that unpacks inputs from stdin, runs into its state machine
-- and ttpacks the results back.
--
	local job = shc_helper("pty", ...)
	if job then
		job.isatty = true
		job.unbuffered = true
	end
end

builtins["v!"] =
function(...)
	cat9.term_handover("join-d", ...)
end

local function binarg_select(args, raw, sz, pref)
-- if there are any pre-parser arguments, strip those first so they don't
-- confuse the completion
	if type(args[2]) == "table" and args[2].parg then
		sz = args[2].offset + 1
		table.remove(args, 1)
	end

-- run a path-scan for the first time, might want to reset in the event of
-- an environment change or a timer - but any install/build like command
-- might invalidate, just a bit too expensive to run for every time
	if #args == 1 then
		cat9.readline:suggest(cat9.pathexec_oracle(), "insert", pref)

	elseif #args == 2 then
		cat9.readline:suggest(
			cat9.prefix_filter(
				cat9.pathexec_oracle(), string.sub(raw, sz), 0), "substitute",
				string.sub(raw, 1, sz-1))
		return
	end

	local carg = args[#args]
	if #carg == 0 then
		return
	end

-- use / or . as indicator for generic file argument completion (assuming
-- by default was annoying) another possibility here is to piggyback on
-- other shell completion tools (bash_completion et al.) but it'd require
-- interactive+parsing tricks.
	local ch = string.sub(carg, 1, 1)
	if ch ~= "." and ch ~= "/" then
		return
	end

	local argv, prefix, flt, offset =
		cat9.file_completion(carg, cat9.config.glob.file_argv)

	local cookie = "term " .. tostring(cat9.idcounter)
	cat9.filedir_oracle(argv, prefix, flt, offset, cookie,
		function(set)
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			cat9.readline:suggest(set, "word", prefix)
		end
	)
end


suggest["!"] =
function(args, raw)
	return binarg_select(args, raw, 2)
end

local function wrap(a, b)
	return binarg_select(a, b, 3)
end

suggest["!!"] = wrap
suggest["v!"] = wrap
suggest["p!"] = wrap
end
