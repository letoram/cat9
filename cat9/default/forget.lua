return
function(cat9, root, builtins, suggest)

function builtins.forget(...)
	local forget =
	function(job, sig)
		local found

		for i,v in ipairs(lash.jobs) do
			if (type(job) == "number" and v.id == job) or v == job then
				job = v
				found = true
				break
			end
		end

		if not found then
			return
		end

-- kill the thing, can't remove it yet but mark it as hidden - main
-- loop will discovered the signalled process and then clean/remove
-- that way
		if job.pid then
			root:psignal(job.pid, sig)
			job.hidden = true
		else
			cat9.remove_job(job)
		end
	end

	local set = {...}
	local signal = "hup"
	local lastid
	local in_range = false

	for _, v in ipairs(set) do
		if type(v) == "table" then
			if in_range then
				in_range = false
				if lastid then
					local start = lastid+1
					for i=lastid,v.id do
						forget(i, signal)
					end
				end
			end
			lastid = v.id
			forget(v, signal)
		elseif type(v) == "string" then
			if v == ".." then
				in_range = true
			elseif v == "all" then
				while #lash.jobs > 0 do
					local job = lash.jobs[1]
					forget(job, signal)
				end
			else
				signal = v
			end
		end
	end
end

end
