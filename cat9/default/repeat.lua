return
function(cat9, root, builtins, suggest)
builtins.hint["repeat"] = "Repeat existing job execution"
builtins["repeat"] =
function(job, ...)
	if type(job) ~= "table" then
		cat9.add_message("repeat >#jobid< [flush | edit] [input] missing job reference")
		return
	end

	if job.pid then
		cat9.add_message("job still running, terminate first (signal #jobid kill)")
		return
	end

	if not job["repeat"] then
		cat9.add_message("job not repeatable")
		return
	end

	local cmds = {...}

	local opts = {
		flush = false,
		diff = false,
		edit = false,
		input = false
	}

	for _,v in ipairs(cmds) do
		opts[v] = true
	end

	local function run()
		if opts.diff then
			if not job.history then
				job.history = {}
			end
			table.insert(job.history, job.data)
			job.data =
			{
				bytecount = 0,
				linecount = 0
			}
		end
		if opts.flush then
			job:reset()
		end
		job["repeat"](job, opts.input)
	end

-- for edit we hook into job creation, substitute in our new argv then call reset
	if opts.edit then
		cat9.switch_env(job, {"(#" .. job.id .. " : " .. job.dir .. " ) "})
		local old_setup = cat9.setup_shell_job

-- this can come asynch due to arguments not resolving immediately, so let
-- setup_shell_job chaining do the old release
		cat9.setup_shell_job =
		function(args, mode, env, line)
			cat9.setup_shell_job = old_setup
			job.args = args
			job.mode = mode
			job.raw = line
			run()
		end

		cat9.on_cancel =
		function()
			cat9.switch_env()
			cat9.setup_shell_job = old_setup
		end

		cat9.on_line =
		function()
			cat9.switch_env()
		end
	else
		run()
	end
end

suggest["repeat"] =
function(args, raw)
	local set = {}

	if #args > 2 then
		cat9.readline:suggest(
			cat9.prefix_filter({"flush", "edit", "input"}, args[#args]), "word")
		return
	end

	cat9.add_job_suggestions(set, false, function(job)
		return not job.pid
	end)

	cat9.readline:suggest(set, "word")
end
end
