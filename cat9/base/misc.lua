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

function cat9.system_path(ns)
	local base = lash.scriptdir .. "/cat9/config"
	if cat9.env["XDG_STATE_HOME"] then
		base = cat9.env["XDG_STATE_HOME"]
	end

	return base
end

function cat9.chdir(step)
	cat9.prevdir = root:chdir()
	root:chdir(step)
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

cat9.MESSAGE_WARNING = 0
cat9.MESSAGE_HELP = 1

-- helper for creating temp files, ideally this should come from the tui-lua
-- bindings, but that feature is missing so have a fallback safe first
function cat9.mktemp(prefix)
	if not prefix then
		prefix = "/tmp"
	end

	local tpath, tmp
	if root.mktemp then
		tpath, tmp = root:mktemp(prefix .. "/.tmp.cat9state.XXXXXX")
	else
		tpath = prefix .. "/.tmp." .. tostring(cat9.time) .. tostring(os.time())
		tmp = root:fopen(tpath, "w")
	end

	return tpath, tmp
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
			local tpath, file = cat9.mktemp()
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
function cat9.add_message(msg, use)
	if type(msg) ~= "string" then
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

function cat9.add_job_suggestions(set, allow_hidden, filter)
	if cat9.selectedjob then
		table.insert(set, "#csel")
	end
	if cat9.latestjob then
		table.insert(set, "#last")
	end
	for _,v in ipairs(lash.jobs) do
		if
			(filter and filter(v)) and
			(not v.hidden or allow_hidden) then
			table.insert(set, "#" .. tostring(v.id))
			if v.alias then
				table.insert(set, "#" .. v.alias)
			end
		end
	end
end

function cat9.template_to_str(template, helpers, ...)
	local res = {}
	for _,v in ipairs(template) do
		if type(v) == "table" then
			table.insert(res, v)
		elseif type(v) == "string" then
			if string.sub(v, 1, 1) == "$" then
				local hlp = helpers[string.sub(v, 2)]
				if hlp then
					local exp = hlp(...)
					if not exp then
						cat9.add_message("broken template helper:" .. v)
					else
						table.insert(res, exp)
					end
				else
					cat9.add_message("unsupported helper: " .. string.sub(v, 2))
				end
			else
				table.insert(res, v)
			end
		elseif type(v) == "function" then
			table.insert(res, v(cat9))
		else
			cat9.add_message("bad member in prompt")
		end
	end
	return res
end

function cat9.table_copy_shallow(intbl)
	local outtbl = {}
	for k,v in pairs(intbl) do
		outtbl[k] = v
	end
	return outtbl
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
			return force_prompt
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

end
