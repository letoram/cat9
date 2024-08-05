-- this should possibly be split out into a base/osdev part to get the
-- actual valid list of signals rather than a hardcoded set

local sigmsg = "[default:kill,hup,user1,user2,stop,quit,continue]"
local signame = {"kill", "hup", "user1", "user2", "stop", "quit", "continue"}
local oksig = {
	kill = true,
	hup = true,
	user1 = true,
	user2 = true,
	stop  = true,
	quit = true,
	continue = true
}

local errors =
{
	missing_signal = "signal >sig< missing",
	bad_signal = "signal >sig< unknown signal name",
	bad_pid = "signal sig >job< bad process id",
	bad_job = "signal sig >job< bad job identifier",
	too_many_arguments = "signal sig job >...< too many arguments"
}

return function(cat9, root, builtins, suggest)
builtins.hint["signal"] = "Send a signal to a job or pid"

function builtins.signal(sig, job)
	if not sig then
		return false, errors.missing_signal
	end

	if not oksig[sig] then
		return false, errors.bad_signal
	end

	if type(job) == "string" then
		job = tonumber(job)
		if not job then
			return false, errors.bad_pid
		end
	elseif type(job) == "table" and not job.parg and job.pid then
		job = job.pid
	else
		return false, errors.bad_job
	end

	root:psignal(job, sig)
end

function suggest.signal(args, raw)
	local set = {hint = {}, title = "Process ID"}

	if #raw == 6 then
		return
	end

	if #args == 2 then
		cat9.readline:suggest(cat9.prefix_filter(signame, args[2]), "word")
		return
	end

	if #args > 3 then
		return false, errors.too_many_arguments
	end

	cat9.list_processes(
	function(procs)
		for i=1,#procs do
			if string.sub(procs[i].name, 1, 1) ~= "[" then
				table.insert(set, tostring(procs[i].pid))
				table.insert(set.hint, procs[i].name)
			end
		end
		local set = cat9.prefix_filter(set, args[3])

		cat9.readline:suggest(cat9.prefix_filter(set, args[3]), "word")
	end,
	true
	)

	cat9.add_job_suggestions(set, false,
		function(job)
			return job.pid ~= nil
		end
	)

	cat9.readline:suggest(set, "word")
end

end
