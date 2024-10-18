return
function(cat9, root, builtins, suggest)
local errors =
{
	missing_job = "trigger >job< missing",
	invalid_job = "trigger >job< can not be assigned a trigger",
	bad_action = "trigger job >action< missing or bad type",
	bad_argument = "trigger job ... with non-string types",
	missing_delay = "trigger job delay >n< missing",
	bad_delay = "trigger job delay >n< isn't a valid number",
	missing_command = "trigger job [delay n] >command< missing",
	cmd_arg_overflow = "trigger job [delay n] command >...< too many arguments"
}

builtins.hint["trigger"] = "Add or Remove job event triggers"
function builtins.trigger(job, action, ...)
	if not job then
		return false, errors.missing_job
	end

	if type(job) ~= "table" or job.hidden then
		return false, errors.invalid_job
	end

	if not action or type(action) ~= "string" or (action ~= "ok" and action ~= "fail") then
		return false, errors.bad_action
	end

-- make sure that no tables snuck in there
	local opts = {...}
	for i,v in ipairs(opts) do
		if type(v) ~= "string" then
			return false, errors.bad_argument
		end
	end

	local errprefix = "[ delay n ]"
	local delay = 0

-- optional > delay <
	if opts[1] and opts[1] == "delay" then
		table.remove(opts, 1)
		if not opts[1] then
			return false, errors.missing_delay
		end
		delay = tonumber(table.remove(opts, 1))
		if not delay then
			return false, errors.bad_delay
		end
		errprefix = " delay " .. tostring(delay) .. " "
		delay = delay * 25 -- 25Hz, resolution in seconds
	end

	if not opts[1] then
		return false, errors.missing_command
	end

-- safeguard against unescaped command
	local cmd = table.remove(opts, 1)

	if opts[1] and cmd ~= "alert" and cmd ~= "run" then
		return false, errors.cmd_arg_overflow
	end

	if action == "ok" then
		action = "on_finish"
	else
		action = "on_fail"
	end

-- ignore the trigger on a running job
-- (someone manually repeat:ed while there was a delay timer attached that also repeated)
	local runfn =
	function()
-- make sure that we can handle #csel and actions that indirectly work assuming the job
-- being 'selected', might need to mask 'on_select' events if those are added.
		local osel = cat9.selectedjob
		cat9.selectedjob = job
		cat9.parse_string(nil, opts[1])
		cat9.selectedjob = osel
	end

-- instead of triggering runfn() when the action occurs, queue a timer that counts down
-- a delay that then fires / removes the timer.
	if delay and delay > 0 then
		local base = delay
		local old = runfn
		runfn =
		function()
			table.insert(cat9.timers,
				function()
					delay = delay - 1
					if delay <= 0 then
						delay = base
						old()
					else
						return true
					end
				end
			)
		end
	end

	if cmd == "flush" then
		job.hooks[action] = {}

	elseif cmd == "alert" then
		table.insert(job.hooks[action],
		function()
			local wnd = cat9.a11y or root
			if action == "on_finish" then
				root:alert(opts[1] and opts[1] or job.raw)
			else
				root:failure(opts[1] and opts[1] or job.raw)
			end
		end)
	elseif cmd == "run" then
		job.block_clear = true
		table.insert(job.hooks[action], runfn)
	end
end

function suggest.trigger(args, raw)
	local set = {}

	if #args == 2 then
		cat9.add_job_suggestions(set, false)
		cat9.readline:suggest(cat9.prefix_filter(set, args[2]), "word")
	elseif #args == 3 then
		cat9.readline:suggest(cat9.prefix_filter({"ok", "fail"}, args[3]), "word")

	elseif #args == 4 then
		cat9.readline:suggest(cat9.prefix_filter({"flush", "delay", "alert", "run"}, args[4]), "word")
-- should recursively resolve the rest of the 4th argument through the
-- same parser / suggest as we do elsewhere
	end
end

end
