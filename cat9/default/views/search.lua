--
-- similar to 'filter' but instead of creating a new dataset it
-- scrolls and searches based on an interactive pattern instead
--
return
function(cat9, root, builtins, suggest, views)

local function scroll(job, start, dir)
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
		if type(res) == "table" then
			res = res[1]
		end

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

local function set_interactive(job)
	local oprompt = cat9.get_prompt

	if cat9.readline then
		root:revert()
	end

-- This repeats basically what parse_string does, without the execution or
-- suggestion set. Instead, the suggestion is treated as the full command
-- applied as the new filter.
	local last_set
	local verify =
	function(self, prefix, msg, suggest)
		local set, err, ofs = cat9.tokenize_resolve(msg)

		if err or ofs or not set then
			if err then
				cat9.add_message(err)
			end
			last_set = nil
			return ofs
		end

		job.row_offset = 1
		job.highlight_filter = build_chain(job, set)
		cat9.parse_string(string.format(
			"#%d view #%d scroll +1",
			job.id, job.id
			)
		)
	end

-- just re-use the verification result
	local rlover =
	function(self, line)
		cat9.get_prompt = oprompt
		cat9.block_readline(root, false, false)
		cat9.reset()
	end

-- hijack readline
	cat9.set_readline(
		root:readline(rlover,
			{
				cancellable = true,
				forward_meta = false,
				forward_paste = false,
				forward_mouse = false,
-- same as the normal parse /verify
				verify = verify
			}), "view:search"
	)

	cat9.block_readline(root, true, true)

	cat9.readline:suggest({})
	cat9.get_prompt =
	function()
		return {"(search)"}
	end
	cat9:flag_dirty()
end

views.hint.search = "Define a pattern to use for stepping"
function views.search(job, suggest, args)
	if not suggest then
		if not args[2] then
			cat9.add_message("view(match): empty pattern/string, setting interactive")
			set_interactive(job)
			return
		end

		table.remove(args, 1)
		job.highlight_filter = build_chain(job, args)
		return
	end

	cat9.add_message(
		"search [substring | operator (match, find, not) substring] | a or b or c ... ",
		cat9.MESSAGE_HELP
	)
end
end
