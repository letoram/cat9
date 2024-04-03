return
function(cat9, root, builtins, suggest)
builtins.hint["trigger"] = "Add or Remove job event triggers"
function builtins.trigger(job, action, ...)
	if not job then
		cat9.add_message("trigger >job< ... - job missing")
		return
	end

	if type(job) ~= "table" or job.hidden then
		cat9.add_message("trigger >job< ... - wrong type or state for job")
		return
	end

	if not action or type(action) ~= "string" or (action ~= "ok" and action ~= "fail") then
		cat9.add_message("trigger job >action< - should be one of 'ok', 'fail'")
		return
	end

-- make sure that no tables snuck in there
	local opts = {...}
	for i,v in ipairs(opts) do
		if type(v) ~= "string" then
			cat9.add_message("trigger job " .. action .. " [delay n] string - type error")
			return
		end
	end

	local errprefix = "[ delay n ]"
	local delay = 0

-- optional > delay <
	if opts[1] and opts[1] == "delay" then
		table.remove(opts, 1)
		if not opts[1] then
			cat9.add_message("trigger job " .. action .. " delay >n< - missing")
			return
		end
		delay = tonumber(table.remove(opts, 1))
		if not delay then
			cat9.add_message("trigger job " .. action .. " delay >n< - invalid time value")
			return
		end
		errprefix = " delay " .. tostring(delay) .. " "
		delay = delay * 25 -- 25Hz, resolution in seconds
	end

	if not opts[1] then
		cat9.add_message("trigger job " .. action .. errprefix .. "command - command missing")
		return
	end

-- safeguard against unescaped command
	local cmd = table.remove(opts, 1)
	if opts[1] and cmd ~= "alert" then
		cat9.add_message("trigger job " .. action .. errprefix .. cmd .. " > overflow at " .. opts[1])
		return
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
		if job.dead or job.pid then
			return
		end

-- make sure that we can handle #csel and actions that indirectly work assuming the job
-- being 'selected', might need to mask 'on_select' events if those are added.
		local osel = cat9.selectedjob
		cat9.selectedjob = job
		cat9.parse_string(nil, cmd)
		cat9.selectedjob = osel
	end

-- instead of triggering runfn() when the action occurs, queue a timer that counts down
-- a delay that then fires / removes the timer.
	if delay then
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
		table.insert(job.hooks[action], function()
			if action == "on_finish" then
				root:notification(opts[1] and opts[1] or job.raw)
			else
				root:failure(opts[1] and opts[1] or job.raw)
			end
		end)
	else
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
		cat9.readline:suggest(cat9.prefix_filter({"", "flush", "delay", "alert"}, args[4]), "word")
-- should recursively resolve the rest of the 4th argument through the
-- same parser / suggest as we do elsewhere
	end
end

end
