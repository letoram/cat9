--
-- Higher level parsing
--
--  take a stream of tokens from the lexer and use to build a command table
--  this is a fair place to add other forms of expansion, e.g. why[1..5].jpg or
--  why*.jpg.
--
--  exports: .parse_string(rl, line)
--
return
function(cat9, root)

local ptable, ttable
local function build_ptable(t)
	ptable = {}
	ptable[t.OP_POUND  ] = {{t.NUMBER, t.STRING}, cat9.lookup_job} -- #sym -> [job]
	ptable[t.OP_RELADDR] = {t.STRING, cat9.lookup_res}
	ptable[t.SYMBOL    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.STRING    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.NUMBER    ] = {function(s, v) table.insert(v, tostring(s[1][2])); end}
	ptable[t.OP_NOT    ] = {
	function(s, v)
		if #v > 0 and type(v[#v]) == "string" then
			v[#v] = v[#v] .. "!"
		else
			table.insert(v, "!");
		end
	end
	}
	ptable[t.OP_MUL    ] = {function(s, v) table.insert(v, "*"); end}

-- ( ... ) <- context properties (env, ...)
	ptable[t.OP_LPAR   ] = {
		function(s, v)
			if v.in_lpar then
				return "nesting ( prohibited"
			else
				v.in_lpar = #v
			end
		end
	}
	ptable[t.OP_RPAR  ] = {
		function(s, v)
			if not v.in_lpar then
				return "missing opening ("
			end
			local stop = #v
			local pargs =
			{
				types = t,
				parg = true
			}

-- slice out the arguments within (
			local start = v.in_lpar+1
			local ntc = (stop + 1) - start

			while ntc > 0 do
				local rem = table.remove(v, start)
				table.insert(pargs, rem)
				ntc = ntc - 1
			end
			table.insert(v, pargs)

			v.in_lpar = nil
		end
	}

	ttable = {}
	for k,v in pairs(t) do
		ttable[v] = k
	end
end

local function tokens_to_commands(tokens, types, suggest)
	local res = {}
	local cmd = nil
	local state = nil

	local fail = function(msg)
-- just parsing debugging
		if config.debug then
			local lst = ""
				for _,v in ipairs(tokens) do
					if v[1] == types.OPERATOR then
						lst = lst .. ttable[v[2]] .. " "
					else
						lst = lst .. ttable[v[1]] .. " "
					end
				end
				print(lst)
		end

		if not suggest then
			lastmsg = msg
		end
		return _, msg
	end

-- deferred building the product table as the type mapping isn't
-- known in beforehand the first time.
	if not ptable then
		build_ptable(types)
	end

-- just walk the sequence of the ptable until it reaches a consumer
	local ind = 1
	local seq = {}
	local ent = nil

	for _,v in ipairs(tokens) do
		local ttype = v[1] == types.OPERATOR and v[2] or v[1]
		if not ent then
			ent = ptable[ttype]
			if not ent then
				return fail("token not supported")
			end
			table.insert(seq, v)
			ind = 1
		else
			local tgt = ent[ind]
-- multiple possible token types
			if type(tgt) == "table" then
				local found = false
				for _,v in ipairs(tgt) do
					if v == ttype then
						found = true
						break
					end
				end

				if not found then
					return fail("unexpected token in expression")
				end
				table.insert(seq, v)
	-- direct match, queue
			elseif tgt == ttype then
				table.insert(seq, v)
			else
				return fail("unexpected token in expression")
			end

			ind = ind + 1
		end

-- when the sequence progress to the execution function that
-- consumes the queue then reset the state tracking
		if type(ent[ind]) == "function" then
			local msg = ent[ind](seq, res)
			if msg then
				return fail(msg)
			end
			seq = {}
			ent = nil
		end
	end

-- if there is a scanner running from completion, stop it
	if not suggest then
		cat9.stop_scanner()
	end

	return res
end

local last_count = 0
local function suggest_for_context(prefix, tok, types)
-- empty? just add builtins
	if #tok == 0 then
		cat9.readline:suggest(builtin_completion)
		return
	end

-- still in suggesting the initial command, use prefix to filter builtin
-- a better support script for this would be handy, i.e. prefix tree and
-- a cache on prefix string itself.
	if #tok == 1 and tok[1][1] == types.STRING then
		local set = cat9.prefix_filter(builtin_completion, prefix)
		if #set > 1 or (#set == 1 and #prefix < #set[1]) then
			cat9.readline:suggest(set)
			return
		end
	end

-- clear suggestion by default first
	cat9.readline:suggest({})
	local res, err = tokens_to_commands(tok, types, true)
	if not res then
		return
	end

-- these can be delivered asynchronously, entirely based on the command
-- also need to prefix filter the first part of the token ..
	if res[1] and cat9.suggest[res[1]] then
		cat9.suggest[res[1]](res, prefix)
	else
-- generic fallback? smosh whatever we find walking ., filter by taking
-- the prefix and step back to whitespace
	end
end

function cat9.readline_verify(self, prefix, msg, suggest)
	if suggest then
		local tokens, msg, ofs, types = lash.tokenize_command(prefix, true)
		suggest_for_context(prefix, tokens, types)
	end

	laststr = msg
	local tokens, msg, ofs, types = lash.tokenize_command(msg, true)
	if msg then
		return ofs
	end
end

-- nop right now, the value later is to allow certain symbols to expand with
-- data from job or other variable references, glob patterns being a typical
-- one. Returns 'false' if there is an error with the expansion
--
-- do that by just adding the 'on-complete' function into dst
function cat9.expand_arg(dst, str)
	return str
end

function cat9.parse_string(rl, line)
	if rl then
		cat9.readline = nil
	end

	if not line or #line == 0 then
		return
	end

	laststr = ""
	local tokens, msg, ofs, types = lash.tokenize_command(line, true)
	if msg then
		lastmsg = msg
		return
	end
	lastmsg = nil

-- build job, special case !! as prefix for 'verbatim string'
	local commands
	if string.sub(line, 1, 2) == "!!" then
		commands = {"!!"}
		commands[2] = string.sub(line, 3)
	else
		commands = tokens_to_commands(tokens, types)
		if not commands or #commands == 0 then
			return
		end
	end

-- this prevents the builtins from being part of a pipeline which might
-- not be desired - like cat something | process something | open @in vnew
	if cat9.builtins[commands[1]] then
		return cat9.builtins[commands[1]](unpack(commands, 2))
	end

-- validation, all entries in commands should be strings now - otherwise the
-- data needs to be extracted as argument (with certain constraints on length,
-- ...)
	for _,v in ipairs(commands) do
		if type(v) ~= "string" then
			lastmsg = "parsing error in commands, non-string in argument list"
			return
		end
	end

-- throw in that awkward and uncivilised unixy 'application name' in argv
	local lst = string.split(commands[1], "/")
	table.insert(commands, 2, lst[#lst])

	local job = cat9.setup_shell_job(commands, "re")
	if job then
		job.raw = line
	end
end

end
