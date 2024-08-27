local tokenize = lash.tokenize_command
local _, _, _, types = tokenize("", false, {})

-- simple functions for the time being, FCALL(FCALL(),,1) option is to
-- allow expressions as arguments as well, in that case run a new eval_token
-- on the subset and have it treat OP_SEP as terminal
--
local eval_tokens

local precendence = {
	[types.OP_MUL] = 8,
	[types.OP_DIV] = 8,
	[types.OP_MOD] = 8,

	[types.OP_ADD] = 2,
	[types.OP_SUB] = 2,
}

local type_str = {}
type_str[types.STRING] = "string"
type_str[types.NUMBER] = "number"
type_str[types.NIL] = "null"
type_str[types.VARTYPE] = "dynamic"
type_str[types.BOOLEAN] = "boolean"
type_str[types.OPERATOR] = "operator"
type_str[types.VARARG] = "variadic"
type_str[types.IMAGE] = "image"
type_str[types.AUDIO] = "audio"
type_str[types.VIDEO] = "video"
type_str[types.SYMBOL] = "symbol"
type_str[types.FCALL] = "function-call"
type_str[types.CELL] = "cell"
type_str[types.FACTORY] = "cell-factory"

local valid_ops = {
	[types.OP_ADD] = true,
	[types.OP_SUB] = true,
	[types.OP_MUL] = true,
	[types.OP_DIV] = true,
	[types.OP_LPAR] = true,
	[types.OP_RPAR] = true,
	[types.OP_MOD] = true
}

local function dump_tokens(printer, list)
	local find = function(val)
		for k,v in pairs(types) do
			if v == val then
				return k
			end
		end
	end

	for _,v in ipairs(list) do
		if v[1] == types.OPERATOR then
			printer("operator", find(v[2]))
		else
			printer(find(v[1]), v[2])
		end
	end
end

-- resolve a symbol as part of argument transfer, this means that if a referenced
-- cell exports multiple types, a compatible one will be picked to try and match
-- the function that is being called.
--
-- Format of typetbl is
--  [return type, arg1, arg2, .. argN] where types come from lexer defined types
--  remove consumed type (typetbl[2]) unless types.VARARG
--
--  return nil + error-token on failure to resolve
--  return result, result type on success
--
local function fcall_arg_symbol(fctx, symbol, stype, ofs, sub)

-- resolve symbol against desired type from function signature, resulting
-- symtype can possibly be types.ERROR if the referenced cell is broken
	local sym, symtype = fctx.lookup_symbol(symbol, stype, sub)
	if sym then
		return sym, symtype
	end

	if symtype then
		return nil, {types.ERROR, "(" .. symbol .. ") " .. symtype, ofs}
	end

-- even if symbol lookup fails, it could basically be a F() call
	local nfun, ntype = fctx.lookup_function(symbol, types.FCALL, sub)
	if not nfun then
		return nil, {types.ERROR, "symbol lookup failed " .. symbol, ofs}
	end

-- then the requirement is that the function takes no arguments or variable length
	if #ntype > 1 and ntype[3] ~= types.VARARG then
		return nil, {
			types.ERROR,
			string.format(
				"function %s used as symbol (no argument transfer) requires arguments",
				symbol
			),
			ofs
		}
	end

-- actual return type validation will then be done later
	return nfun, ntype[1]
end

local function is_primitive_type(tt, allow_null)
	return
		tt == types.NUMBER or
		tt == types.STRING or
		tt == types.SYMBOL or
		tt == types.BOOLEAN or
		(allow_null and tt == types.NIL)
end

local function get_argtype(tbl, index)
	local stype = tbl[index]
	if not stype then
		stype = types.NIL
	end

-- VARARG uses the PREVIOUS type repeated until end of function call
-- tbl has return at index 1, so first valid vararg indicator is at index 3
	if stype == types.VARARG then
		if index == 2 then
			return types.NIL, index
		else
			stype = tbl[index-1]
		end
	else
		index = index + 1
	end

	return stype, index
end

local function check_argtype(arg, tbl, index, exttype)
	local stype
	stype, index = get_argtype(tbl, index)

-- function calls as arguments has an extended type from the symbol lookup,
-- but the token itself is used to convey that the data should be executed
-- before
	if arg == types.FCALL then
		arg = exttype
	end

	return (stype == types.VARTYPE or arg == stype), stype, index, arg
end

local function parse_fcall(fctx, fn, tokens, depth)
-- the function itself performs error reporting and argument verification
	local fptr, typetbl, nargs = fctx.lookup_function(fn[2])

	if not fptr then
		return {types.ERROR, "no function named " .. fn[2], fn[3]}
	elseif not typetbl or not type(typetbl) == "table" then
		return {types.ERROR,
			string.format(
				"func(%s => %s, %s) call did not return a type table",
				fn[2], type(fptr), type(typetbl)
			)
		}
	elseif not nargs then
		return {types.ERROR,
			string.format("func(%s) did not return an arg count", fn[2])}
	elseif not typetbl[1] then
		return {types.ERROR, "function signature has no return type", fn[3]}
	end

-- wrap function call with type so it follows the token format but does
-- not have to be forced as the return format of the lookup_function itself
	local rfun =
	function(...)
		local args = {...}
		return {typetbl[1], fptr(...), fn[3]}
	end

-- error state, should at least have a RPAR on the stack
	local ok = false

-- args is populated with the parsed / resolved symbols, function calls
-- and literals, while 'larg' is the currently pending argument. it is
-- added to args on ) or ,
	local args = {}
	local lastarg = nil
	local in_sep = false
	local arg_index = 2
	local nfun_return

	while #tokens > 0 do
		local tt = table.remove(tokens, 1)
		local toktype = tt[1]
		local tokdata = tt[2]
		local tokpos  = tt[3]
		local tokalt  = tt[5]

-- recursive resolve function
		if toktype == types.FCALL then
			local res
			res, nfun_return = parse_fcall(fctx, {types.FCALL, tokdata, tokpos}, tokens, depth + 1)

-- propagate error from nested function parsing
			if res[1] == types.ERROR then
				return res

-- the function returns both the function token and an extended 'type' (return
-- result of executing the function)
			else
				lastarg = res
			end

-- symbol resolution is dynamic and type might mutate as other cells change
		elseif toktype == types.SYMBOL then
-- don't allow [sym sym], require separator
			if lastarg ~= nil then
				return {types.ERROR, "expected , or ) got " .. tokdata, tokpos, #args}
			end

-- resolve symbol against typetbl, remember the result but don't advance the
-- argument index, that is done on the operator
			local stype
			stype, _ = get_argtype(typetbl, arg_index)
			local sym, symtype = fcall_arg_symbol(fctx, tokdata, stype, tokpos, tokalt)
			if not sym then
				return symtype
			end

			lastarg = {symtype, sym, tokpos}
			nfun_return = nil
			in_sep = false

-- simple literal types don't take much work
		elseif is_primitive_type(toktype, true) then
			if lastarg ~= nil then
				return {types.ERROR, "expected , or ) got " .. type_str[toktype], tokpos, #args}
			end

-- validation happens in , or )
			lastarg = {toktype, tokdata, tokpos}
			in_sep = false

-- some operators should trigger recursive expression evaluation, others
-- should step arguments or terminate function call scope
		elseif toktype == types.OPERATOR then

-- separator, add previous token to argument list or insert a 'nil' argument
			if tokdata == types.OP_SEP or tokdata == types.OP_RPAR then
				if not lastarg then -- ,, -> , nil,
					lastarg = {types.NIL, nil, tokpos}
				end

-- but before adding the argument, verify its type against signature
				local status, cmptype, arg_type
				status, cmptype, arg_index, arg_type =
					check_argtype(lastarg[1], typetbl, arg_index, nfun_return)

				if not status and (nargs > 0 or lastarg[1] ~= types.NIL) then
					return {
						types.ERROR,
						string.format("type mismatch, got:%s,%s expected:%s at argument %d",
							type_str[arg_type], tostring(lastarg[1]), type_str[cmptype], arg_index-1
						),
						tokpos,
						#args,
						fn[2]
					}
				end

				if lastarg then
					table.insert(args, lastarg)
				end

				lastarg = nil
				in_sep = true

-- ) terminates argument processing
				if tokdata == types.OP_RPAR then
					break
				end

-- in this case we get a subexpression where a non-fcall context is treated as terminal
-- the result of eval_tokens is different from a normal token:
-- [action] [kind] [value]
--
-- where action can be a function that executes the expression itself, in that case we
-- can add it as a fcall and assume return type as number (arithmetic expression rather
-- than chaining functions)
			else
				if lastarg then
					table.insert(tokens, 1, lastarg)
				end

				local act, kind, val = eval_tokens(fctx, tokens, true)
				if type(act) == "function" then
					act, kind, val = act()
					lastarg = {kind, val, tokpos}
				elseif act == types.STATIC then
					lastarg = {kind, val, tokpos}
				else
					return {
						types.ERROR,
						"subexpression error, expected dynamic or numeric result",
						tokpos
					}
				end
			end

-- unexpected token
		else
			local str = type_str[toktype] and type_str[toktype] or tostring(toktype)
			return {types.ERROR, "unexpected type: " .. str, tokpos, #args, fn[2]}
		end
	end

-- the function call is 'done', compare the number of arguments against the
-- expected number of 'minimum' arguments
	if #args < nargs then
		return {types.ERROR, string.format(
			"%s: missing arguments, got %d, expected %d", fn[2], #args, nargs), tokpos, #args, fn[2]}
	end

-- this substitutes the symbol name tied to F( with invocating the function
-- using the argument list that we built above, the actual invocation is
-- defered until the entire expression has been parsed
	fn[2] =
	function()
		local argtbl = {}

		for i=1,#args do
			if args[i][1] == types.FCALL then
				argtbl[i] = (args[i][2]())[2]
			else
				argtbl[i] = args[i][2]
			end
		end

		return rfun(unpack(argtbl))
	end

	return fn, typetbl[1]
end

local function apply_op(cell, tok, out, stack)
-- first balance stacks based on ()
	if tok[2] == types.OP_LPAR then
		table.insert(stack, tok)
		return true

	elseif tok[2] == types.OP_RPAR then
		local ok = false

		while #stack > 0 and stack[#stack][2] ~= types.OP_LPAR do
			table.insert(out, table.remove(stack))
		end

-- unbalanced ) ? that's an error unless we are nested
		if #stack == 0 then
			return false
		else
			table.remove(stack)
		end
		return true
	end

	if #stack == 0 or stack[#stack][2] == types.OP_LPAR then
		table.insert(stack, tok)
		return true
	end

-- while lower or equal precedence to stack, pop from stack to out
	local token_precedence = precedence[tok[2]]
	while #stack > 0 do
		local top = stack[#stack]
		local top_precedence = precedence[top[2]]

		if token_precedence > top_precedence then
			table.insert(stack, tok)
			return true
		end
		table.insert(out, table.remove(stack))
	end

-- then add
	table.insert(stack, tok)
	return true
end

-- ensure that the specified token can provide the desired type
local function resolve_ensure(fctx, tok, dtype)
	if tok[1] == types.SYMBOL then
		return fctx.lookup_symbol(tok[2], dtype, tok[5])
	end

	if dtype == types.NUMBER then
		if tok[1] == types.NUMBER then
			return tok[2]
		elseif tok[1] == types.STRING then
			return tonumber(tok[2])
		end

	elseif dtype == types.STRING then
		if tok[1] == types.NUMBER then
			return tostring(tok[2])
		elseif tok[1] == types.STRING then
			return tok[2]
		end
	end
end

-- this is the place to add strings management as operators rather
-- than builtin functions if that is ever desired
local function exec_op(fctx, op, a, b)
	local an = resolve_ensure(fctx, a, types.NUMBER)
	local bn = resolve_ensure(fctx, b, types.NUMBER)

	if not an or not bn then
		return
	end

	if op == types.OP_ADD then
		return {types.NUMBER, an + bn, a[3]}

	elseif op == types.OP_SUB then
		return {types.NUMBER, an - bn, a[3]}

	elseif op == types.OP_MUL then
		return {types.NUMBER, an * bn, a[3]}

	elseif op == types.OP_MOD then
		return {types.NUMBER, an % bn, a[3]}

	elseif op == types.OP_DIV then
		return {types.NUMBER, an / bn, a[3]}

	else
		return nil
	end
end

eval_tokens =
function(fctx, tokens, nested)
	local out = {}
	local ops = {}

-- just shunting-yard and recurse into fcalls, which can recurse into eval_tokens
-- on subexpression as argument, nested+(unbalanced or SEP) or EXPREND act as
-- terminal
	local i = 1
	while #tokens > 0 do
		local tok = table.remove(tokens, 1)
		local toktype = tok[1]

-- terminal ends expression processing
		if toktype == types.EXPREND then
			break

-- So fcalls gets parsed separately and are treated as just adding a function
-- on out, that will produce a return value of some operator compatible result
-- as well as making sure to consume the related tokens. This is also recursive
-- so that a function with F((1+2), 3) will yield (1+2) as a subexpression.
		elseif toktype == types.FCALL then
			local fcr = parse_fcall(fctx, tok, tokens, 1)

			if fcr[1] == types.ERROR then
				fctx.error(fcr[2], fcr[3], fctx.msg, fcr[4], fcr[5], fcr[6])
				return fcr
			end
			table.insert(out, fcr)

-- just forward normal tokens, except for null (=false argument)
		elseif is_primitive_type(toktype, false) then
			table.insert(out, tok)

-- apply op takes precedence and ordering, actual evaluation is in exec_op
		elseif toktype == types.OPERATOR then

-- nested subexpression where separator or unbalanced right parenthesis end
-- then re-add the token back to the front of the queue so the caller can
-- act
			if nested and tok[2] == types.OP_SEP then
				table.insert(tokens, 1, tok)
				break
			end

			if not apply_op(cell, tok, out, ops) then
				if nested and tok[2] == types.OP_RPAR then
					table.insert(tokens, 1, tok)
					break
				end

				fctx.error("unbalanced ()", tok[3], fctx.msg)
				return
			end
		end
	end

-- flush operator stack into postfix expression
	while #ops > 0 do
		table.insert(out, table.remove(ops))
	end

-- optimization option here, if the entire expression lacks operators or
-- symbols we can simply merge that into static, this adds up in more complex
-- worksheets or when there are nested expressions as function arguments

-- open question if we should first check if ops and operand count match in
-- order to provide an error without triggering any function as those can
-- have larger consequences
	return
	function()
		local stack = {}
		local yield = fctx.yield

		for _, v in ipairs(out) do
			local toktype = v[1]
			if toktype == types.OPERATOR then
				local o2 = table.remove(stack)
				local o1 = table.remove(stack)

				if not o1 or not o2 then
					fctx.error("argument/operator mismatch", v[3], fctx.msg)
					return types.ERROR, "argument/operator mismatch", v[3]
				end

				local res = exec_op(fctx, v[2], o1, o2)
				if not res then
					fctx.error("type or operator mismatch", v[3], fctx.msg)
					return types.ERROR, "type or operator mismatch", v[3]
				end

				table.insert(stack, res)

-- not yielding after each operator, as they should be sufficiently cheap,
-- perhaps have a # cap and reduce it if these are references to other cells
-- that need to be resolved
			elseif toktype == types.FCALL then
				local res = v[2]()
				if res then
					table.insert(stack, res)
				end
				yield()

			elseif is_primitive_type(toktype, false) then
				table.insert(stack, v)
			end
		end

-- not all expressions will return a result, function calls that return nil
-- won't leave anything of use on the stack
		if stack[1] then
			return types.STATIC, stack[1][1], stack[1][2]
		end
	end
end

-- [msg] the string to parse
--
-- [lookup_sym(name, *type*)] function that resolves a specific symbol address
--            => data, type   if type is not provided, return data, type
--                            otherwise return data that matches type
--
-- [lookup_fcall](name, type:nil, args) function invocation, if a known desired return
--       => function(args), {types}, argc types is 1..n of token types that are permitted.
--                                        the first result is the function return (or .NIL)
--                                        and 'argc' is the minimum number of arguments
--
-- [on_error](error_message, character_position, input_message)
--
local function parse_expression(msg, lookup_sym, lookup_fcall, on_error, token_out)
	if not msg then
		print(debug.traceback())
		return ""
	end
	local tokens, err, err_ofs = tokenize(msg)

-- missing show this as an overlay and highlight the offending offset in the input box
	if err then
		on_error(err, err_ofs, msg)
		return

	elseif #tokens == 0 then
		return
	end

-- keep a copy of the tokens as well as other features might want to re-use
	if token_out then
		for _,v in ipairs(tokens) do
			table.insert(token_out, v)
		end
	end

--
-- open question, how should we re-symbolise expression in order for reference
-- to remain on row/cell deletion/insertion and cover aliases?
--
-- 1. have token to string formatter and replace initial msg with (alias) expansion?
-- 2. mark the cell as invalid and tell the user?
--

-- rule: single symbol: number (treat as set numeric constant)
--                      string (treat as set string constant)
	local fctx = {
		lookup_function = lookup_fcall,
		lookup_symbol = lookup_sym,
		error = on_error,
		msg = msg,

-- add later when we move to coroutines
		yield = function()
		end
	}

-- resolve any single-token alias,
--
-- should we allow alias expansion within expression (a=12) (a + a) => (12) + (12)?
-- it is problematic as the expansion error reporting need to make sense in the
-- expanded form so some rewriting of [3] field so position and source is known
--
	local tt = tokens[1][1]
	if #tokens == 1 and tt == types.SYMBOL then
		local arg = tokens[1][2]
		local ofs = tokens[1][3]

-- swap in symbol, return function with dynamic or static type?
		local data, dtype = lookup_sym(arg, types.VARTYPE, tokens[1][5])

		if data and dtype then
			tokens[1] = {arg, dtype, data}
			return
				function()
					return
						types.STATIC,
						dtype,
						data
				end
		else
			fctx.error("missing alias/function: " .. arg, ofs, msg)
			return
		end
	end

-- special case, single literal
	if #tokens == 1 then
		local tok = tokens[1][1]
		local arg = tokens[1][2]
		return
		function()
			return
				types.STATIC,
				tok,
				tostring(arg)
		end
	end

-- rule: symbol, op_ass, [expr] (store expr as alias) - we could go with returning
-- the tokenised string and merge that way, but it would make alias expansion subexpr
-- error handling worse
	if #tokens >= 2 and
		tokens[1][1] == types.SYMBOL and
		tokens[2][1] == types.OPERATOR and tokens[2][2] == types.OP_ASS then
		return function()
			return
				types.FN_ALIAS,
				tokens[1][2],
				string.sub(msg, tokens[2][3]+1)
		end
	end

-- add terminal token
	table.insert(tokens, {types.EXPREND, nil, #msg})

	return eval_tokens(fctx, tokens)
end

return
function()
	return parse_expression, types, type_str, tokenize
end
