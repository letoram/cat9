return function(cat9, root, builtins, suggest)

local function shc_helper(mode, ...)
	local args = {...}
	local argv = {"/bin/sh", "sh", "-c"}
	local str  = ""

-- check processing directive
	lastarg = args[1]

	argv[4] = table.concat(args, " ")
	local job = cat9.setup_shell_job(argv, mode)
	if job then
		job.short = "subshell"
		job.raw = argv[4]
	end
	return job
end

-- alias for handover into vt100
builtins["!"] =
function(...)
-- check first argument here for (arcan) (x11) (wayland) and setup
-- the other proper handover
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

end
