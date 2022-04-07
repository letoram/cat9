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

	function cat9.remove_match(tbl, ent)
	for i, v in ipairs(tbl) do
		if v == ent then
			table.remove(tbl, i)
			return
		end
	end
end

function cat9.chdir(step)
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

-- expected to return nil (block_reset) to fit in with expectations of builtins
function cat9.add_message(msg)
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

function cat9.setup_readline(root)
	local rl = root:readline(
		function(self, line)
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
	rl:set(cat9.laststr);
	rl:set_prompt(cat9.get_prompt())
	rl:set_history(lash.history)
	rl:suggest(config.autosuggest)
end

end

