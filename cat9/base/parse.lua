--
-- Higher level parsing
--
--  take a stream of tokens from the lexer and use to build a command table
--
--  exposes:
--       parse_string(rl, line) - will both parse and trigger builtins/shell jobs
--
--       readline_verify(rl, prefix, msg, suggest) - run parse_string but
--       just for providing parsing state feedback on input error, or emit
--       completion suggestions.
--
--       ok, err = expand_arg(dst, args, escape) -- take the argument list
--       in [args] and resolve / expand into arguments inserted into ok. If
--       escape is set to an n-indexed table of [sym,val] tables, each
--       string will also be filtered through the indices in order, gsub:ing
--       sym into val, for instance: {{'\', '\\', {'"', '\"'}, {' ', '\ '}}
--       would turn: hi "there" \what into: hi\ \"there\"\ \\what
--

-- change the default lexer operator treatment so that /hi would becomes
-- TOK_STR(/hi) and not OP_DIV TOK_STR.
local lex_opts =
{
	operator_mask = {
		["+"] = true,
		["-"] = true,
		["/"] = true,
		["="] = true,
	}
}

return
function(cat9, root, config)

local function lookup_res(s, v)
	local base = s[2][2]
-- special: $=row
	if base == "=crow" or base == "=crow:" then
		local sj = cat9.selectedjob
		if sj then
			if not sj.mouse then
				table.insert(v, sj.cursor[2] + 1)
			elseif sj.mouse and sj.mouse.on_row then
				table.insert(v, sj.mouse.on_row)
			else
				return "cursor not on job row"
			end
		else
			return "no job selected"
		end
		return
	end

-- fallback use: $env
	local split_i = string.find(base, "/")
	local split = ""

	if split_i then
		split = string.sub(base, split_i)
		base = string.sub(base, 1, split_i-1)
	end

	local env = root:getenv(base)
	if not env then
		env = cat9.env[base]
	end

	if env then
		table.insert(v, env .. split)
	end
end

local function lookup_job(s, v)
	local job = cat9.id_to_job(s[2][2])
	if job then
		table.insert(v, job)
	else
		return "no job matching ID " .. s[2][2]
	end
end

local function flush_pargs(v)
-- slice out the arguments within (
	local stop = #v
	local start = v.in_lpar+1
	local ntc = (stop + 1) - start
	local set = {}

-- open question is what to do with tables ..
	while ntc > 0 do
		local rem = table.remove(v, start)
		if tonumber(rem) or type(rem) == "string" then
			table.insert(set, rem)
		end
		ntc = ntc - 1
	end

	return table.concat(set, "")
end

local ptable, ttable
local function build_ptable(t)
	ptable = {}
	ptable[t.OP_POUND  ] = {{t.NUMBER, t.STRING}, lookup_job} -- #sym -> [job]
	ptable[t.OP_RELADDR] = {t.STRING, lookup_res}
	ptable[t.SYMBOL    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.STRING    ] = {function(s, v) table.insert(v, s[1][2]); end}
	ptable[t.NUMBER    ] = {function(s, v) table.insert(v, tostring(s[1][2])); end}
	ptable[t.OP_SEP    ] = {function(s, v)
		if v.in_lpar then
			table.insert(v.lpar_stack, flush_pargs(v, true))
			v.in_lpar = #v
		else
			table.insert(v, ",")
		end
	end}
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
				v.lpar_stack = {}
			end
		end
	}
	ptable[t.OP_RPAR  ] = {
		function(s, v, tok)
			if not v.in_lpar then
				return "missing opening ("
			end
			local pargs =
			{
				types = t,
				parg = true,
				offset = tok[3]
			}
			table.insert(v.lpar_stack, flush_pargs(v))

			for _,v in ipairs(v.lpar_stack) do
				table.insert(pargs, v)
			end

			table.insert(v, pargs)
			v.in_lpar = nil
			v.lpar_stack = nil
		end
	}

	ttable = {}
	for k,v in pairs(t) do
		ttable[v] = k
	end
end

-- convenience helper to get 'args' similar to a full parse
function cat9.tokenize_resolve(str)
	local tokens, err, ofs, types =
		lash.tokenize_command(str, true, lex_opts.operator_mask)

	if err then
		return nil, err, ofs
	end

	local set = cat9.parse_resolve(tokens, types, true)
	if not set then
		return nil, nil, ofs
	end

	return set
end

function cat9.parse_resolve(tokens, types, suggest)
	local res = {}
	local groups = {res}
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
				print(lst, msg)
		end

-- adding the message on every parse run would be confusing,
-- especially as some 'in parg' etc. stepping yields more args
		if not suggest then
			cat9.add_message(msg)
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

-- Group operators (and &, pipe | or ||) sets a new res and adds
-- to the group table with the condition that should be fulfilled.
-- For now jus deal with pipe.
		if ttype == types.OP_PIPE then
			groups[#groups].stdin = true
			res = {}
			table.insert(groups, res)

		elseif not ent then
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
		if ent and type(ent[ind]) == "function" then
			local msg = ent[ind](seq, res, v)
			if msg then
				return fail(msg)

			else
-- make sure dangling last error/fail message is cleared
				cat9.add_message()
			end
			seq = {}
			ent = nil
		end
	end

-- if there is a scanner running from completion, stop it
	if not suggest then
		cat9.stop_scanner()
	end

	return groups
end

local last_count = 0
local function suggest_for_context(prefix, tok, types)
-- chunk up into groups based on OP_PIPE
-- (same can then be done for OP_AND, OP_OR, ...)
	local last_group = 1
	for i=1,#tok do
		if tok[i][1] == types.OPERATOR and tok[i][2] == types.OP_PIPE then
			last_group = i
		end
	end

-- but only completion-concern with the last one
	if last_group > 1 then
		local rtok = {}
		for i=last_group+1,#tok do
			table.insert(rtok, tok[i])
		end
		tok = rtok
	end

	if #tok == 0 then
		local ret, ofs =
			cat9.readline:suggest(cat9.prefix_filter(builtin_completion, ""))
		return ret, ofs
	end

-- still in suggesting the initial command, use prefix to filter builtin
-- a better support script for this would be handy, i.e. prefix tree and
-- a cache on prefix string itself.
	if #tok == 1 and tok[1][1] == types.STRING then
		local set = cat9.prefix_filter(builtin_completion, prefix)
		if #set > 1 or (#set == 1 and #prefix < #set[1]) then
			local ret, ofs = cat9.readline:suggest(set)
			return ret, ofs
		end
	end

-- clear suggestion by default first
	if cat9.readline then
		local ret, ofs = cat9.readline:suggest({})
		if ret == false then
			return ret, ofs
		end
	end

	local res, err = cat9.parse_resolve(tok, types, true)
	if not res then
		return
	end

-- we have already jumped to the last group based on cursor for
-- generating suggestion, so just pick that one already
	res = res[1]

-- if a job table is used silently remove it and set it as context
-- empty? just add builtins
	local closure = function() end
	if res[1] and type(res[1]) == "table" and res[1].job then
		cat9.switch_env(res[1])
		table.remove(res, 1)
		closure = function() cat9.switch_env(); end
	end

-- these can be delivered asynchronously, entirely based on the command
-- also need to prefix filter the first part of the token .. Force-inject
-- an empty argument if we have added a space but not yet started on the
-- first character.
	if res[1] and cat9.suggest[res[1]] then
		if #res[1] == #prefix then
			return
		end

		if string.sub(prefix, -1) == " " then
			res[#res+1] = ""
		end
		local err, ofs = cat9.suggest[res[1]](res, prefix)
		if err == false then
			closure()
			return err, ofs
		end
		return closure()
	end

-- generic fallback? smosh whatever we find walking ., filter by taking
-- the prefix and step back to whitespace
	local carg = res[#res]
	if type(carg) ~= "string" or #carg == 0 then
		return closure()
	end

	local argv, prefix, flt, offset =
		cat9.file_completion(carg, cat9.config.glob.file_argv)

	cat9.filedir_oracle(argv,
		function(set)
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			if cat9.readline then
				cat9.readline:suggest(set, "word", prefix)
			end
		end
	)

	return closure()
end

--
-- There is quite a few pitfalls in this, so worth taking note of if other
-- 'lets replace readline while the rest of the system do not expect it' -
-- anything in the refresh/redraw will index cat9.readline so that must be
-- removed immediately to not call into a bad widget state.
--
-- Then the prompt is updated on a tick timer, so if the resolve function
-- isn't hijacked, whatever prompt is set will be overwritten almost
-- immediately.
--
local function history_prompt()
	return {"(history)"}
end

function cat9.lock_readline(name, msg, prompt, verify)
	if cat9.readline then
		cat9.laststr = cat9.readline:get()
		root:revert()
		cat9.set_readline(nil, msg)
	end

-- triggering suggest twice would cause the history prompt to hijack forever
	if cat9.get_prompt ~= prompt then
		cat9.old_prompt = cat9.get_prompt
	end

	cat9.set_readline(
	root:readline(
		function(self, line)
			cat9.set_readline(nil, name)
			cat9.get_prompt = cat9.old_prompt
			cat9.old_prompt = nil
			if line then
				cat9.laststr = line
			end
			cat9.setup_readline(root)
		end,
		{
			cancellable = true,
			forward_meta = false,
			forward_paste = false,
			forward_mouse = false,
			verify = verify,
		}), msg)
	cat9.get_prompt = prompt
	cat9.flag_dirty()
end

function cat9.suggest_history()
	cat9.lock_readline("history_cb", "history", history_prompt,
		function(self, prefix, msg, suggest)
			self:suggest(cat9.prefix_filter(lash.history, msg, 0, "replace"))
		end
	)
	cat9.readline:suggest(true)
	cat9.readline:suggest(lash.history)
end

function cat9.readline_verify(self, prefix, msg, suggest)
	if string.sub(prefix, 1, 2) == "!!" then
		cat9.readline:suggest(true)
		return
	end

	if suggest then
		local tokens, msg, ofs, types = lash.tokenize_command(prefix, true, lex_opts)
		local ret, ofs = suggest_for_context(prefix, tokens, types)
		if ret == false then
			return ofs
		end
	end

	cat9.laststr = msg
	local tokens, msg, ofs, types = lash.tokenize_command(msg, true, lex_opts)
	if msg then
		return ofs
	end
end

function cat9.expand_arg(dst, args, escape)
	local escape_str =
	function(s)
		if not escape then
			return s
		end
		for i,v in ipairs(escape) do
			s = string.gsub(s, v[1], v[2])
		end
		return s
	end

	local job = nil
	local i = 1
	while i <= #args do
		local v = args[i]
		local vn = args[i+1]

		if type(v) == "string" then
			table.insert(dst, escape_str(args[i]))

-- #job reference,
		elseif type(v) == "table" then
			if v.parg then
				return false, "() without backing job"

			elseif not v.slice then
				return false, "job reference can't slice"

			else
-- check if we have #id(...) and not #id1 #id2, let the slicer work
				local arg = nil
				if type(vn) == "table" and vn.parg then
					arg = vn
					i = i + 1
				end

-- and inject-escape the results, could reduce this from 2n to n by
-- overriding resolver to return pre-escaped
				local ok, msg = v:slice(arg)
				if not ok then
					return false, msg
				end
				for _,v in ipairs(ok) do
					table.insert(dst, escape_str(v))
				end

			end
		end

		i = i + 1
	end

	return true
end

function cat9.default_fallthrough(commands, inp, line)
-- validation, all entries in commands should be strings now - otherwise the
-- data needs to be extracted as argument (with certain constraints on length,
-- ...)
	local dst = {}
	local ok, err = cat9.expand_arg(dst, commands)
	if not ok then
		cat9.add_message("couldn't expand command line: " .. err)
		return
	end

-- throw in that awkward and uncivilised unixy 'application name' in argv
	local lst = string.split(dst[1], "/")
	table.insert(dst, 2, lst[#lst])

	local job = cat9.setup_shell_job(dst,
		inp and "wre" or "re", cat9.env, line, {close = true})

	if job and job.write and inp then
		job:write(inp)
	end
end

function cat9.parse_string(rl, line)
	if not line or #line == 0 then
		return
	end

	cat9.parsestr = line
	cat9.laststr = ""
	cat9.flag_dirty()

-- build job, special case !! as prefix for 'verbatim string', this should
-- be moves to a part of the normal parser so that #id | !!something would
-- work.
	if string.sub(line, 1, 2) == "!!" then
		cat9.setup_shell_job(string.sub(line, 3), "re", cat9.env, line)
		return
	end

	local tokens, msg, ofs, types = lash.tokenize_command(line, true, lex_opts)
	if msg then
		cat9.add_message(msg)
		return
	end
-- dequeue
	cat9.get_message(true)

	local groups
	groups = cat9.parse_resolve(tokens, types)
	if not groups or #groups[1] == 0 then
		return
	end

-- with multiple processing groups we need to setup a job queue, ignore
-- that for now and just handle the case of #job | actual_command
	local inp = nil
	if #groups > 2 then
		cat9.add_message("in-shell processing groups incomplete, use !!")
		return
	elseif #groups == 2 then
		if type(groups[1][1]) == "table" then
			inp = groups[1][1]
			table.remove(groups, 1)
		else
			cat9.add_message("[job | ] cmd expected")
			return
		end
	end

-- could also be popt in order to control input routing, or if it is a
-- job, setup an explicit data forward / copy
	local revert = false
	local commands = groups[1]

	if type(commands[1]) == "table" then
		local tbl = table.remove(commands, 1)
		cat9.switch_env(tbl, nil, commands[1])

-- just switch context
		if #commands == 0 then
			return
		end

		revert = true
	end

-- this prevents the builtins from being part of a pipeline which might
-- not be desired - like cat something | process something | open @in vnew
	local res
	local cmd = commands[1]

	if string.sub(cmd, 1, 1) ~= "_" and cat9.builtins[cmd] then
		cat9.stdin = inp
		local ok, msg = cat9.builtins[cmd](unpack(commands, 2))
		if ok == false then
			cat9.add_message(msg)
		end
		cat9.stdin = nil
		return ok
	elseif cat9.builtins["_default"] then
		res = cat9.builtins["_default"](commands, inp, line)
	else
		res = cat9.default_fallthrough(commands, inp, line)
	end

	if revert then
		cat9.switch_env()
	end

	return res
end
end
