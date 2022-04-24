return
function(cat9, root, builtins, suggest)

function builtins.trigger(job, action, cmd, oflow)
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

	if not cmd or type(cmd) ~= "string" then
		cat9.add_message("trigger job >action< - should be a valid cli input or 'flush'")
		return
	end

	if oflow then
		cat9.add_message("trigger job action >< - too many arguments (escape action with \"\")")
		return
	end

-- the actions are just shorter aliases
	if action == "ok" then
		action = "on_finish"
	else
		action = "on_fail"
	end

	if cmd == "flush" then
		job.hooks[action] = {}
	else
		table.insert(
		job.hooks[action],
			function()
				local osel = cat9.selectedjob
				cat9.selectedjob = job
				cat9.parse_string(nil, cmd)
				cat9.selectedjob = osel
			end
		)
	end
end

function suggest.trigger(args, raw)
	local set = {}
	if #args == 2 then
		for _,v in ipairs(lash.jobs) do
			if not v.hidden then
				table.insert(set, "#" .. tostring(v.id))
			end
		end
		cat9.readline:suggest(set, "word")
	elseif #args == 3 then
		cat9.readline:suggest(cat9.prefix_filter({"ok", "fail"}, args[3]), "word")

	elseif #args == 4 and #args[#args] == 0 then
		cat9.readline:suggest({"flush"}, "word")
-- should recursively resolve the rest of the 4th argument through the
-- same parser / suggest as we do elsewhere
	end
end

end
