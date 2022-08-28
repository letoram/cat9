--
-- create a reduced dataset based on pattern
--
return
function(cat9, root, builtins, suggest, views)

local function show_ptn(job, ...)
-- substitute in our reduced data
	local dset = job.data
	local filterfn = job.view_state.filter
	local state = job.view_state

-- apply pattern to new data, some kind of processing queue here
-- that limits the amount of lines processed and defer the rest to
-- renderloop downtime (or actually thread .. )
	if job.view_state.data_linecount < dset.linecount then
		for i=state.linecount+1,dset.linecount do
			local ok, res = filterfn(dset[i])
			if ok then
				table.insert(job.view_state, res)
				job.view_state.linecount = job.view_state.linecount + 1
			end
		end
		job.view_state.data_linecount = dset.linecount
	end

	job.data = job.view_state
	local rc = cat9.view_raw(job, ...)
	job.data = dset
	return rc
end

local function slice_ptn(job, lines, set)
	local data = set or job.data
	local res =
	{
		bytecount = 0,
		linecount = 0
	}

	return cat9.resolve_lines(
		job, res, lines,
		function(i)
			if not i then
				return job.view_state
			end
			local line = job.view_state[i]
			if line then
				return line, #line, 1
			else
				return nil, 0, 0
			end
		end
	)
end

local opmap = {}
opmap["or"] = true
opmap["not"] =
function(arg)
	return
	function(line)
		if not string.find(line, arg) then
			return true, line
		end
	end
end

-- apply pattern matching, but return full string
opmap["find"] =
function(arg)
	return
	function(line)
		local res = string.find(line, arg)
			return true, res
	end
end

-- only return the first capture
opmap["match"] =
function(arg)
	return
	function(line)
		local res = string.match(line, arg)
		if res then
			return true, res
		end
	end
end

-- the current chains are direct and synchronous, the obvious improvement
-- would be adding asynchronous processing that can yield and work with
-- an external filter process.
local function build_chain(job, args)
	local chain = {}
	local split = {}

	local in_op = false

-- "and" is implied for each chain
	for _,v in ipairs(args) do
		if in_op then
			table.insert(chain, in_op(v))
			in_op = false

-- add other matching group
		elseif v == "or" then
			table.insert(split, chain)
			chain = {}
			in_op = false

-- or a builtin generator
		elseif opmap[v] then
			in_op = opmap[v]

-- assume 'has'
		else
			table.insert(chain,
			function(line)
				local ok = string.find(line, v, 1, true)
				if ok then
					return true, line
				end
			end)
		end
	end

-- build iteration function that takes line and moves through chain
	local
	function walk_chain(chain)
		return function(line)
			for _, v in ipairs(chain) do
				local res
				res, line = v(line)
				if not res then
					return false
				end
			end
			return true, line
		end
	end

-- if we have or, we need another level that earlies out at the first
-- valid group of chains
	if #split > 0 then
		table.insert(split, chain)
		return
		function(line)
			for _,v in ipairs(split) do
				local ok, retl = (walk_chain(v))(line)
				if ok then
					return ok, retl
				end
			end
			return false
		end
	else
		return walk_chain(chain)
	end
end

function views.filter(job, suggest, args)
	if not suggest then
		if not args[2] then
			cat9.add_message("view(match): empty pattern/string")
			job:set_view(cat9.view_raw, nil, nil, "match")
			return
		end

		table.remove(args, 1)
		local state =
			{
				data_linecount = 0,
				linecount = 0,
				bytecount = 0,
				filter = build_chain(job, args)
			}
		local name = "filter(" .. table.concat(args, "") .. ")"
		job:set_view(show_ptn, slice_ptn, state, name)

		return
	end

	cat9.add_message(
		"filter [substring | operator (match, find, not) substring] | a or b or c ... ",
		cat9.MESSAGE_HELP
	)
end
end
