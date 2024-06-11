return function(cat9, root, builtins, suggest)

local function shc_helper(mode, ...)
	local args = {...}
	local argv = string.split(cat9.config.sh_runner, " ")

	local str  = ""
	local env = cat9.table_copy_shallow(cat9.env)

-- check processing directive
	lastarg = args[1]
	local opts = {}

	if mode == "pty" then
		opts.close = false
	end

	argv[4] = table.concat(args, " ")
	local job = cat9.setup_shell_job(argv, mode, env, nil, opts)
	if job then
		job.short = string.sub(argv[4], 1, 10)
		job.raw = argv[4]
		if job.write and cat9.stdin then
			job:write(cat9.stdin)
		end
	end

	return job
end

local function spawn_arcan(...)
-- setup with a monitor channel so we can do things to it later
-- monitor-ctrl
end

-- alias for handover into vt100
builtins.hint["!"] = "Run command in a terminal in a new window"
builtins["!"] =
function(...)
	cat9.term_handover("join-r", ...)
end

builtins.hint["!!"] = "Run a raw command string in a terminal"
builtins["!!"] =
function(...)
	shc_helper("rwe", ...)
end

builtins.hint["a!"] = "Run an arcan-shmif compatible client"
builtins["a!"] =
function(...)
	local args = {...}
	local cmode = "join-r"
	local omode = ""
	omode, cmode = cat9.misc_resolve_mode(args, cmode)
	if not omode then
		return
	end

-- ensure that we actually inherit
	local env = cat9.table_copy_shallow(root:getenv())
	env["ARCAN_CONNPATH"] = nil

-- should probe to determine if we need:
--   a. arcan-lwa (arg indicates appl)
--   b. arcan-wayland
--   c. Xarcan
--   d. generic-shmif (try ldd and look for shmif)
	cat9.shmif_handover(cmode, omode, args[1], root:getenv(), args)
end

builtins.hint["l!"] = "Run a command in a new Lash shell"
builtins["l!"] =
function(...)
-- lash helper, just retain ARCAN_... args for now.
-- RESET would be best collaboratively so the right event gets sent. Again
-- the problem if the display server should forward or we should add a
-- separate channel for event injection.
	cat9.term_handover("join-r", ...)
end

builtins.hint["p!"] = "Run a legacy shell command as a lash job"
builtins["p!"] =
function(...)
--
-- note: we can't just run pty line-buffered like normal, there is timing
-- behaviour and hold/wait like scenarios that will bite immediately, e.g. ssh
-- asking for prompt.
--
-- we also static-default to wrap in vt100 mode.
--
	local job = shc_helper("pty", ...)
	if job then
		job.unbuffered = true
	end
end

builtins.hint["v!"] = "Run command in a terminal in a new vertical-child window"
builtins["v!"] =
function(...)
	cat9.term_handover("join-d", ...)
end

builtins.hint["s!"] = "Run command in a terminal in a new swallowed window"
builtins["s!"] =
function(...)
	cat9.term_handover("swallow", ...)
end

local function binarg_select(args, raw, sz, pref)
-- if there are any pre-parser arguments, strip those first so they don't
-- confuse the completion
	if type(args[2]) == "table" and args[2].parg then
		sz = args[2].offset + 1
		table.remove(args, 2)
	end

-- run a path-scan for the first time, might want to reset in the event of
-- an environment change or a timer - but any install/build like command
-- might invalidate, just a bit too expensive to run for every time
	if #args == 1 then
		cat9.readline:suggest(cat9.pathexec_oracle(), "insert", pref)
		return

	elseif #args == 2 then
		cat9.readline:suggest(
			cat9.prefix_filter(
				cat9.pathexec_oracle(), string.sub(raw, sz), 0), "substitute",
				string.sub(raw, 1, sz-1))
		return
	end

	local carg = args[#args]
	if #carg == 0 or type(carg) ~= "string" then
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

	cat9.filedir_oracle(argv,
		function(set)
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			cat9.readline:suggest(set, "word", prefix)
		end
	)
end

suggest["a!"] =
function(args, raw)
-- First we need to check applbase, then scan current directories for the
-- pattern name/name.lua with grep on function name. It is probably time to
-- accept the fact that we need a manifest file.
--
-- a12 should have its own here so that arcan-net isn't activated in
-- discovery mode unnecessarily.
--
-- Lastly we can check secondary / known dependencies, or better yet, let
-- arcan-wayland and xarcan themselves expose probe methods.
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
suggest["a!"] = wrap
suggest["s!"] = wrap
end
