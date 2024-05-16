--
-- misc convenience functions that do not for elsewhere:
--
--  exposes:
--   update_lastdir(): grab the current dir from rootwnd -> cat9.lastdir
--   add_message(msg): queue a message to be shown close to the readline
--   get_message(deq) -> str: return the most important message queued, clear if deq is set
--
--   run_lut(cmd, tgt, lut, set):
--    take a set of unordered options (n-indexed, like 'err', 'tog')
--    match to a lut of [key = fptr(set, i, job)] and invoke all entries with
--    a match.
--
return
function(cat9, root, config)
local lastmsg

function cat9.each_ch(str, cb, err)
	local u8_step = root.utf8_step
	local pos = 1
	while true do
		local nextch = u8_step(str, 1, pos)
		if nextch == -1 then
			if pos <= #str then
				err(str, pos)
			end
			return
		end
		cb(string.sub(str, pos, nextch-1), pos)
		if nextch - pos > 1 then
		end

		pos = nextch
	end
end

function cat9.remove_match(tbl, ent)
	for i, v in ipairs(tbl) do
		if v == ent then
			table.remove(tbl, i)
			return true
		end
	end
end

-- assumes no cycles
function table.copy_recursive(tbl)
	local res = {}
	for k,v in pairs(tbl) do
		if type(v) == "table" then
			res[k] = table.copy_recursive(v)
		else
			res[k] = v
		end
	end
	return res
end

function table.equal(tbl1, tbl2)
	if not tbl1 or not tbl2 then
		return false
	end
	if #tbl1 ~= #tbl2 then
		return false
	end
	for i,v in ipairs(tbl1) do
		if v ~= tbl2[i] then
			return false
		end
	end
	return true
end

if not string.split_first then
function string.split_first(instr, delim)
	if (not instr) then
		return;
	end
	local delim_pos, delim_stp = string.find(instr, delim, 1);
	if (delim_pos) then
		local first = string.sub(instr, 1, delim_pos - 1);
		local rest = string.sub(instr, delim_stp + 1);
		first = first and first or "";
		rest = rest and rest or "";
		return first, rest;
	else
		return "", instr;
	end
end
end

function cat9.compact_path(str, lastcap)
	local set = string.split(str, "/")
	local compact = {}

-- build to /a/b/c/filename
	for i=1,#set do
		if i < #set then
			local next = root.utf8_step(set[i], 1, 1)
			table.insert(compact, next == -1 and set[i] or string.sub(set[i], 1, next))
		else
			table.insert(compact, set[i])
		end
	end
	return table.concat(compact, "/")
end

function cat9.modifier_string(mod)
	local str = ""
	if bit.band(mod, tui.modifiers.SHIFT) > 0 then
		str = str .. "shift_"
	end
	if bit.band(mod, tui.modifiers.CTRL) > 0 then
		str = str .. "ctrl_"
	end
	if bit.band(mod, tui.modifiers.ALT) > 0 then
		str = str .. "alt_"
	end
	if bit.band(mod, tui.modifiers.META) > 0 then
		str = str .. "meta_"
	end
	return str
end

function cat9.system_path(ns)
	local base = lash.scriptdir .. "/cat9/config"
	if cat9.env["XDG_STATE_HOME"] then
		base = cat9.env["XDG_STATE_HOME"]
	end

	return base
end

function cat9.run_in_dir(root, dir, cb)
	local old = root:chdir()
	root:chdir(dir)
	cb()
	root:chdir(old)
end

function cat9.chdir(step)
	cat9.prevdir = root:chdir()
	root:chdir(step)

	if (step) then
		local new = root:chdir()
		if new ~= cat9.prevdir then
			for k, v in pairs(cat9.dir_monitor) do
				v(new, cat9.prevdir)
			end
		end
	end

	cat9.scanner_path = nil
	cat9.update_lastdir()
end

function cat9.update_lastdir()
	local wd = root:chdir()
	local dirs = string.split(wd, "/")
	local dir = "/"
	if #dirs then
		cat9.lastdir = dirs[#dirs]
	end
end

-- sweeps through args and replaces job references with temp files, return a
-- closure for unlinking them as well as a trigger for when all writes have
-- completed.
function cat9.build_tmpjob_files(args, dispatch, fail)
-- pre-alloc files so we don't run into fd cap
	local files = {}
	local names = {}

	local function
	closure()
		for _,v in ipairs(names) do
			root:funlink(v)
		end
		for _,v in ipairs(files) do
			v:close()
		end
	end

	for _,v in ipairs(args) do
		if type(v) == "table" and v.slice then
			local tpath, file = root:mktemp()
			if file then
				table.insert(files, file)
				table.insert(names, tpath)
			else
				cat9.add_message("build tmp-job: couldn't create temporary storage")
				return closure()
			end
		end
	end

-- nothing to do? just return
	if #files == 0 then
		return
	end

-- now actually queue the transfers, when the last report done, signal
	local pending = 0
	local failed = 0
	local ok = 0
	local writeh =
	function(oob, finish_ok)
		if finish_ok then
			ok = ok + 1
		else
			failed = failed + 1
		end

		if failed+ok == pending then
			if failed > 0 then
				fail()
			else
				dispatch()
			end
		end
	end

	for i,v in ipairs(args) do
		if type(v) == "table" and v.slice then
			pending = pending + 1
			files[pos]:write(v:slice(), writeh)
		end
	end

	return closure
end

-- expected to return nil (block_reset) to fit in with expectations of builtins
function cat9.add_message(msg)
	if not msg then
		lastmsg = ""
	elseif type(msg) ~= "string" then
		print("add_message(" .. type(msg) .. ")" .. debug.traceback())
	else
		lastmsg = msg
	end
end

function cat9.get_message(dequeue)
	local old = lastmsg
	if dequeue then
		lastmsg = nil
	end
	return old
end

function cat9.opt_number(set, ind, default)
	local num = set[ind] and tostring(set[ind])
	return num and num or default
end

function cat9.run_lut(cmd, tgt, lut, set)
	local i = 1
	while i and i <= #set do
		local opt = set[i]

		if type(opt) ~= "string" then
			lastmsg = string.format("%s >...< %d argument invalid", cmd, i)
			return
		end

-- ignore invalid
		if not lut[opt] then
			i = i + 1
		else
			i = lut[opt](set, i, tgt)
		end
	end
end

local maptype = {
	s = tostring,
	n = tonumber,
	b = function(v) return v == true; end
}

-- shallow and only simple types
function cat9.stableb64(tbl)
	local res = {}

	local typemap = {
		["string"] = "s",
		["boolean"] = "b",
		["number"] = "n"
	}

	for k,v in pairs(tbl) do
		local kt = typemap[type(k)]
		local vt = typemap[type(v)]

		if kt and vt then
			table.insert(res, cat9.to_b64(kt .. vt .. tostring(k)))
			table.insert(res, cat9.to_b64(tostring(v)))
		end
	end

	return table.concat(res, ":")
end

function cat9.b64stable(str)
	local sub = string.split(str, ":")
	local deq = table.remove
	local res = {}

	while #sub > 0 do
		local key = cat9.from_b64(deq(sub, 1))
		local val = cat9.from_b64(deq(sub, 1))

		if key then
			local kt = string.sub(key, 1, 1)
			local vt = string.sub(key, 2, 2)
			key = string.sub(key, 3)

			if key and val and maptype[kt] and maptype[vt] then
				res[maptype[kt](key)] = maptype[vt](val)
			end
		end
	end

	return res
end

-- taken from Ilya Kolbins unlicensed b64 enc/dec
local function extract(v, from, width)
	return bit.band(bit.rshift, bit.lshift(1, width) - 1)
end

-- build LUTs
local b64enc = {}
for b64, ch in pairs({[0]='A','B','C','D','E','F','G','H','I','J',
		'K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y',
		'Z','a','b','c','d','e','f','g','h','i','j','k','l','m','n',
		'o','p','q','r','s','t','u','v','w','x','y','z','0','1','2',
		'3','4','5','6','7','8','9','+','/','='})
do
	b64enc[b64] = ch:byte()
end

local b64dec = {}
for b64, ch in pairs(b64enc) do
	b64dec[ch] = b64
end

function cat9.to_b64(str)
	local char, concat = string.char, table.concat
	local encoder = b64enc

	local t, k, n = {}, 1, #str
	local lastn = n % 3

	for i = 1, n-lastn, 3 do
		local a, b, c = str:byte( i, i+2 )
		local v = a*0x10000 + b*0x100 + c
		local s
			s = char(
				encoder[extract(v,18,6)],
				encoder[extract(v,12,6)],
				encoder[extract(v,6,6)],
				encoder[extract(v,0,6)]
			)
		t[k] = s
		k = k + 1
	end

	if lastn == 2 then
		local a, b = str:byte( n-1, n )
		local v = a*0x10000 + b*0x100
		t[k] = char(
			encoder[extract(v,18,6)],
			encoder[extract(v,12,6)],
			encoder[extract(v,6,6)],
			encoder[64]
		)
	elseif lastn == 1 then
		local v = str:byte( n )*0x10000
		t[k] = char(
			encoder[extract(v,18,6)],
			encoder[extract(v,12,6)],
			encoder[64],
			encoder[64]
		)
	end

	return concat(t)
end

function cat9.from_b64(b64)
	local char, concat = string.char, table.concat
	local decoder = b64dec
	local pattern = '[^%w%+%/%=]'
	b64 = b64:gsub( pattern, '' )

	local t, k = {}, 1
	local n = #b64
	local padding = b64:sub(-2) == '==' and 2 or b64:sub(-1) == '=' and 1 or 0

	for i = 1, padding > 0 and n-4 or n, 4 do
		local a, b, c, d = b64:byte( i, i+3 )
		local s
		local v =
			decoder[a] * 0x40000 +
			decoder[b] * 0x1000  +
			decoder[c] * 0x40    +
			decoder[d]

		s = char(
			extract(v,16,8),
			extract(v, 8,8),
			extract(v,0,8)
		)
		t[k] = s
		k = k + 1
	end

	if padding == 1 then
		local a, b, c = b64:byte( n-3, n-1 )
		local v =
			decoder[a]*0x40000 +
			decoder[b]*0x1000  +
			decoder[c]*0x40

		t[k] = char(
			extract(v,16,8),
			extract(v,8,8)
		)

	elseif padding == 2 then
		local a, b = b64:byte( n-3, n-2 )
		local v =
			decoder[a]*0x40000 +
			decoder[b]*0x1000

		t[k] = char(extract(v,16,8))
	end

	return concat( t )
end

function cat9.reader_factory(io, tick, cb)
	local cd = tick
	local buf = {}

-- perform a read into a buffer, on timeout or eof submit the buffer
	table.insert(
		cat9.timers,
		function()
			local oc = #buf
			local _, ok = io:read(buf)
			if not ok then
				cb(buf, true)
				buf = {}
				return false
			end

			if #buf == oc and #buf > 0 then
				cd = cd - 1
				if cd <= 0 then
					cd = tick
				end
				local ob = buf
				buf = {}
				return cb(ob, false)
			end

			return true
		end
	)
end

function cat9.add_job_suggestions(set, allow_hidden, filter)
	local filter = filter or function() return true end
	if not set.hint then
		set.hint = {}
	end

	if cat9.selectedjob then
		local ok, hint = filter(cat9.selectedjob)
		if ok then
			table.insert(set, "#csel")
			table.insert(set.hint, hint or "")
		end
	end

	if cat9.latestjob then
		local ok, hint = filter(cat9.latestjob)
		if ok then
			table.insert(set, "#last")
			table.insert(set.hint, hint or "")
		end
	end

	for _,v in ipairs(lash.jobs) do
		local ok, hint = filter(v)
		if ok and (not v.hidden or allow_hidden) then
			table.insert(set, "#" .. tostring(v.id))
			table.insert(set.hint, hint or "")
			if v.alias then
				table.insert(set, "#" .. v.alias)
				table.insert(set.hint, hint or "")
			end
		end
	end
end

local function expand_helpers(helpers, v, ...)
	local a, b, c = string.find(v, "$([%w_]+)")
	if not c then
		return v
	end

	local res = ""
	if a > 1 then
		res = string.sub(v, 1, a-1)
	end

	if helpers[c] then
		local expanded = helpers[c](...)
		if expanded then
			if #expanded == 0 then
				return nil
			end
			res = res .. expanded
		end
	end

-- drop leading first whitespacing, forcing a double-escape to get padding
-- between expansion and possible unit indicator
	local suf = string.sub(v, b+1)
	if string.sub(suf, 1, 1) == " " then
		suf = string.sub(suf, 2)
	end

	res = res .. suf

	return expand_helpers(helpers, res)
end

-- part of prompt expansion:
--   wrap items in some user-defined block (prefix data suffix) or
--   omitt the block entirely if there is no actual data
local function apply_queue(dst, queue, template)
	if not queue or #queue == 0 then
		return
	end

	if template.prefix and type(template.prefix) == "table" then
		for _,v in ipairs(template.prefix) do
			table.insert(dst, v)
		end
	end

	for _,v in ipairs(queue) do
		table.insert(dst, v)
	end

	if template.suffix and type(template.suffix) == "table" then
		for _,v in ipairs(template.suffix) do
			table.insert(dst, v)
		end
	end
end

-- used for prompt expansion, should be improved a bit to better support
-- decorating groups (rather than forcing the prompt template to do it)
function cat9.template_to_str(template, helpers, ...)
	local res = {}
	local queue

	for _,v in ipairs(template) do

-- tables are treated as format tables and added verbatim
		if type(v) == "table" then
			table.insert(res, v)

-- strings have expansion based on $ but we can stack expansions
-- and ignore them if they expansions do not produce any results
		elseif type(v) == "string" then
			if v == "$begin" or v == "$end" then
				apply_queue(res, queue, template)
				if v == "$begin" then
					queue = {}
				else
					queue = nil
				end
			else
				table.insert(queue or res, expand_helpers(helpers, v, ...))
			end

-- functions are just executed and expected to return string or nil
-- and only a string with non-whitespace characters are considered
		elseif type(v) == "function" then
			local fret = v(cat9)
			if fret and string.find(fret, "%S") then
				table.insert(queue or res, fret)
			end
		else
			cat9.add_message("bad member in prompt")
		end
	end

-- implicit $end
	apply_queue(res, queue, template)
	return res
end

function cat9.table_copy_shallow(intbl)
	local outtbl = {}
	for k,v in pairs(intbl) do
		outtbl[k] = v
	end
	return outtbl
end

local function escape(line, expand)
	if not expand then
		return line
	end

	if string.find(line, " ") or string.find(line, "\"") then
		return '"' .. string.trim(string.gsub(line, "\"", "\\\"")) .. '"'
	end

	return line
end

-- this also takes parg on table with slicing into account
function cat9.expand_string_table(intbl, cap, expand)
-- treat as a FIFO
	local out = {}
	local count = 0

	while #intbl > 0 do
		local item = table.remove(intbl, 1)
		local as_string = escape(tostring(item), expand)

-- just a simple literal?
		if type(item) ~= "table" and as_string then
			table.insert(out, as_string)
			count = count + #as_string

-- a job that needs to be sliced out
		elseif type(item) == "table" and item.slice then
			local arg = nil

-- possibly constrained by a parg
			if type(intbl[1]) == "table" and intbl[1].parg then
				arg = table.remove(intbl, 1)
			end

-- that can fail
			local set = item:slice(arg)

-- abort on overflow
			if set then
-- merge
				for _,v in ipairs(set) do
					v = escape(tostring(v), expand)
					count = count + #v
					table.insert(out, v)
				end
			end
-- or an unhandled / unknown entry
		else
			return nil, "unexpected type in arguments"
		end
	end

	return out
end

function cat9.switch_env(job, force_prompt)
	if cat9.job_stash and not job then
		cat9.chdir(cat9.job_stash.dir)
		cat9.env = cat9.job_stash.env
		cat9.get_prompt = cat9.job_stash.get_prompt
		cat9.builtins = cat9.job_stash.builtins
		cat9.views = cat9.job_stash.views
		cat9.suggest = cat9.job_stash.suggest
		cat9.builtin_name = cat9.job_stash.builtin_name
		cat9.job_stash = nil
	end

	if not job then
		return
	end

	cat9.job_stash =
	{
		dir = root:chdir(),
		env = cat9.table_copy_shallow(cat9.env),
		get_prompt = cat9.get_prompt,
		views = job.views,
		builtins = job.builtins,
		builtin_name = job.builtin_name,
		suggest = job.suggest
	}

	if force_prompt then
		cat9.get_prompt =
		function()
			if type(force_prompt) == "string" then
				return {force_prompt}
			elseif type(force_prompt) == "table" then
				return force_prompt
			else
				return {""}
			end
		end
		if cat9.readline then
			cat9.readline:set(job.raw)
		end
	end

	cat9.chdir(job.dir)
	cat9.env = job.env
end

function cat9.hide_readline(root)
	if not cat9.readline then
		return
	end

	cat9.laststr = cat9.readline:get()
	root:revert()
	cat9.flag_dirty()
end

function cat9.set_readline(rl, src)
	cat9.readline = rl
	cat9.readline_src = src
end

function cat9.block_readline(root, on, hide)
	cat9.readline_block = on
	cat9.readline_block_hide = hide
end

function cat9.setup_readline(root)
	if cat9.readline_block then
		if not cat9.readline_block_hide then
			cat9.hide_readline(root)
		end
		return
	end

	local rl = root:readline(
		function(self, line)
			cat9.set_readline(nil, "readline_cb")

			if not line or #line == 0 then
				local on_cancel = cat9.on_cancel
				if on_cancel then
					cat9.on_cancel = nil
					on_cancel()
					cat9.reset()
					return
				end
			end
			cat9.on_cancel = nil

-- allow the line to be intercepted once, with optional block- out
			local on_line = cat9.on_line
			if on_line then
				cat9.on_line = nil
				if on_line() then
					cat9.reset()
					return
				end
			end

			cat9.parse_string(self, line)

-- ensure that we do not have duplicates, but keep the line as most recent
			if not lash.history[line] then
				lash.history[line] = true
			else
				for i=#lash.history,1,-1 do
					if lash.history[i] == line then
						table.remove(lash.history, i)
						break
					end
				end
			end

			table.insert(lash.history, 1, line)
			if not cat9.readline_block then
				cat9.reset()
			end
		end, config.readline)

	cat9.set_readline(rl, "setup_readline")
	rl:set(cat9.laststr)
	rl:set_prompt(cat9.get_prompt())
	rl:set_history(lash.history)
	rl:suggest(config.autosuggest)
end

-- use the same parg setup everywhere for extracting parameters on embed,
-- tab, ... like properties. this is used by term/shmif like handovers.
function cat9.misc_resolve_mode(arg, cmode)
	if type(arg[1]) ~= "table" then
		return "", cmode
	end
	local open_mode = ""

	local t = table.remove(arg, 1)
	if not t.parg then
		cat9.add_message("spurious #job argument in subshell command")
		return
	end

	for _,v in ipairs(t) do
		if v == "err" then
			open_mode = "e"
		elseif v == "embed" then
			cmode = "embed"
		elseif v == "v" then
			cmode = "join-d"
		elseif v == "tab" then
			cmode = "tab"
		end
	end

	return open_mode, cmode
end
end
