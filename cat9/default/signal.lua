local sigmsg = "[default:kill,hup,user1,user2,stop,quit,continue]"
local oksig = {
	kill = true,
	hup = true,
	user1 = true,
	user2 = true,
	stop  = true,
	quit = true,
	continue = true
}

return function(cat9, root, builtins, suggest)

function builtins.signal(job, sig)
	if not sig then
		return cat9.add_message(string.format(
			"signal (#jobid or pid) >signal< missing: %s", sigmsg))
	end

	if type(sig) == "string" then
		if not oksig[sig] then
			return cat9.add_message(string.format(
				"signal (#jobid or pid) >signal< unknown signal (%s) %s", sig, sigmsg))
		end
	elseif type(sig) == "number" then
	else
		return cat9.add_message(string.format(
			"signal (#jobid or pid) >signal< unexpected type (string or number)"))
	end

	local pid
	if type(job) == "table" then
		if not job.pid then
			return cat9.add_message(string.format(
				"signal #jobid - job is not tied to a process"))
		end
		pid = job.pid
	elseif type(job) == "number" then
		pid = job
	else
		pid = tonumber(job)
		if not pid then
			return cat9.add_message(
				"signal (#jobid or pid) - unexpected type (" .. type(job) .. ")")
		end
	end

	root:psignal(pid, sig)
end

end
