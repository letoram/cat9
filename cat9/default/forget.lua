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
				table.remove(lash.jobs, i)
				break
			end
		end
-- kill the thing, can't remove it yet but mark it as hidden
		if found and job.pid then
			root:psignal(job.pid, sig)
			job.hidden = true
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
					local item = table.remove(lash.jobs, 1)
					if item.pid then
						root:psignal(item.pid, signal)
						item.hidden = true
					end
				end
			else
				signal = v
			end
		end
	end
end

end
