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

function cat9.add_job_suggestions(set, allow_hidden)
	if cat9.selectedjob then
		table.insert(set, "#csel")
	end

	for _,v in ipairs(lash.jobs) do
		if not v.hidden or allow_hidden then
			table.insert(set, "#" .. tostring(v.id))
		end
	end
end

function cat9.template_to_str(template, helpers)
	local res = {}
	for _,v in ipairs(template) do
		if type(v) == "table" then
			table.insert(res, v)
		elseif type(v) == "string" then
			if string.sub(v, 1, 1) == "$" then
				local hlp = helpers[string.sub(v, 2)]
				if hlp then
					table.insert(res, hlp())
				else
					cat9.add_message("unsupported helper: " .. string.sub(v, 2))
				end
			else
				table.insert(res, v)
			end
		elseif type(v) == "function" then
			table.insert(res, v())
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
		cat9.job_stash = nil
	end

	if not job then
		return
	end

	cat9.job_stash =
	{
		dir = root:chdir(),
		env = cat9.table_copy_shallow(cat9.env),
		get_prompt = cat9.get_prompt
	}

	if force_prompt then
		cat9.get_prompt =
		function()
			return force_prompt
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
	cat9.readline = nil
end

function cat9.setup_readline(root)
	local rl = root:readline(
		function(self, line)
			cat9.readline = nil

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

			local block_reset = cat9.parse_string(self, line)

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

			if not block_reset then
				cat9.reset()
			end
		end, config.readline)

	cat9.readline = rl
	rl:set(cat9.laststr)
	rl:set_prompt(cat9.get_prompt())
	rl:set_history(lash.history)
	rl:suggest(config.autosuggest)
end

end
