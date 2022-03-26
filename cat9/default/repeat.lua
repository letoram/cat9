return
function(cat9, root, builtins, suggest)

builtins["repeat"] =
function(job, cmd)
	if type(job) ~= "table" then
		cat9.add_message("repeat >#jobid< [flush] missing job reference")
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

	if cmd and type(cmd) == "string" then
		if cmd == "flush" then
			job:reset()
		end
	end

	job["repeat"](job)
end

suggest["repeat"] =
function(args, raw)
	local set = {}

	if #args > 2 or #args == 2 and string.sub(raw, -1) == " "  then
		cat9.readline:suggest({"flush"}, "word")
		return
	end

	for _,v in ipairs(lash.jobs) do
		if not v.pid and not v.hidden then
			table.insert(set, "#" .. tostring(v.id))
		end
	end

	cat9.readline:suggest(set, "word")
end

end
