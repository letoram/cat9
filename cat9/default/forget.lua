return
function(cat9, root, builtins, suggest)

-- permitted worst case
-- 1 2 3 .. 5 1 7 ..
local function forget_lines(job, set)
	local in_range

-- verify before building set,
-- guarantees set only has '..' and valid numbers (tonumber(n) >= 1)
	for i,v in ipairs(set) do
		if type(v) ~= "string" then
			cat9.add_message("forget job-lines: unexpected argument at " .. tostring(i))
			return
		end

		if v ~= ".." and v ~= "-" then
			local num = tonumber(v)
			if not num then
				cat9.add_message("forget job-lines: invalid argument: " .. v)
			end

			if num <= 0 then
				cat9.add_message("forget job-lines: linenumber overflow (<= 0)")
				return
			end
		end
	end

-- sort and add numbers into map,
--
-- this is done to handle overlaps (ranges) as well as duplicates
-- need to sweep this from low to high as well to not leave holes
-- and update counters (which other parts expect to match).
	local map = {}
	local hi = 0
	local lo = 9999999999

	local add =
	function(num)
		if num > job.data.linecount then
			return
		end
		if hi < num then
			hi = num
		end
		if lo > num then
			lo = num
		end
		map[num] = true
	end

	local in_range
	for i=1,#set do
		local v = set[i]

		if v == ".." or v == "-" then
			in_range = tonumber(i > 1 and set[i-1] or 1)
		elseif in_range then
			local lim = tonumber(v)
			local step = in_range > lim and -1 or 1
			for j=in_range,lim,step do
				add(j)
			end
			in_range = nil
		else
			local num = tonumber(v)
			add(tonumber(v))
		end
	end

-- no-op
	if hi < lo then
		return
	end

-- ended with ., so cut everything above the in_range
	local data = job.data
	local bc = data.bytecount
	local lc = data.linecount

	local drop =
	function(i)
		bc = bc - #job.data[i]
		data[i] = nil
		lc = lc - 1
	end

	if in_range then
		for i=lc,in_range do
			drop(i)
		end
	end

	for i=hi,lo,-1 do
		if map[i] then
			drop(i)
		end
	end

	data.linecount = lc
	data.bytecount = bc

	cat9.flag_dirty()
end

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
			job:hide()
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

	if set[1] and set[1] == "lines" then
		table.remove(set, 1)
		local job = table.remove(set, 1)
		if not job or type(job) ~= "table" then
			cat9.add_message("forget job-lines: missing job argument")
			return
		end

		return forget_lines(job, set)
	end

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
			if v == ".." or v == "-" then
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

	if #args == 2 then
		cat9.add_job_suggestions(set, false)
		table.insert(set, "all-passive")
		table.insert(set, "all-bad")
		table.insert(set, "all-hard")
		table.insert(set, "lines")
	end

	if #args == 3 and args[2] == "lines" then
		cat9.add_job_suggestions(set, false)
	elseif #args > 3 and args[2] == "lines" then
-- add_message for line-number bounds?
		cat9.readline:suggest({})
		return
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
