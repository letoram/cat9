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

	local forget_filter =
	function(sig, eval)
		local set = {}
		for _,v in ipairs(lash.jobs) do
			if not v.hidden and eval(v) then
				table.insert(set, v)
			end
		end
		for _,v in ipairs(set) do
			forget(v, sig)
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
	-- this one is dangerous as it just murders everything, maybe the highlight
	-- suggestion should indicate it in alert (or the prompt) by setting prompt
	-- to some alert state
			elseif v == "all-hard" then
				forget_filter(signal, function() return true end)
			elseif v == "all-passive" then
				forget_filter(signal,
						function(a)
							if a.pid then
								return false
							elseif a.check_status then
								return not a.check_status()
							else
								return true
							end
						end
				)
			elseif v == "all-bad" then
				forget_filter(signal,
					function(a)
						return a.exit ~= nil and a.exit ~= 0;
					end
				)
			else
				signal = v
			end
		end
	end
end

function suggest.forget(args, raw)
	local set = {}
	local cmd = args[#args]

	for _,v in ipairs(lash.jobs) do
		if not v.pid and not v.hidden then
			table.insert(set, "#" .. tostring(v.id))
		end
	end

	if #args == 2 then
		table.insert(set, "all-passive")
		table.insert(set, "all-bad")
		table.insert(set, "all-hard")
	end

-- this is messier than other job- targetting suggestions due to the
-- whole 'previous argument might be a range and would then resolve to table
-- but if we are just starting on a new argument it will be zero-length str
	local lastarg = args[#args]
	if #args > 2 and type(lastarg) == "string" and #lastarg == 0 then
		lastarg = args[#args - 1]
	end

	if #args > 2 and type(lastarg) == "table" then
		table.insert(set, "..")
	end

-- and to understand #num without getting the to-table conversion the raw
-- string needs to be processed and extract out the actual value or #1 will
-- mask #11
	local pref = string.match(raw, "[^%s]+$")
	if pref then
		set = cat9.prefix_filter(set, pref)
	end
	cat9.readline:suggest(set, "word")
end
end
