
-- provides helper functions for generating and filter readline completions
-- using external oracles (e.g. find -maxdepth 1 -type d):
--
--  set_scanner(path, closure):
--      runs 'path' in a new process (str or argtbl), collects lines (\n strip)
--      into an n-indexed table and calls [closure](table).
--
--      repeated calls cancels any ongoing scanner.
--
--  stop_scanner():
--      cancels any ongoing scanning job, safe to call even without a scanner
--      running.
--
--  file_completion(fn) -> path, prefix, flt, offset:
--      helper that deals with the parameters needed to feed readline:suggest
--      with a list of filenames, dealing with all relative/absolute edge cases.
--
--  prefix_filter(set, flt, offset) -> set:
--      take an n-indexed table in [set], apply the prefix [flt] and return
--      results with the first [offset] number of leading characters stripped.
--

return
function(cat9, root, config)
--
-- run [path (str | argtbl) and trigger closure with the dataset when completed.
-- should only be used for singleton short-lived, line-separated fast commands
-- used for tab completion
--
function cat9.set_scanner(path, cookie, closure)
	cat9.stop_scanner()
	cat9.scanner.active = path

	local _, out, _, pid = root:popen(path, "r")

	if not pid then
		if config.debug then
			print("failed to spawn scanner job:", path)
		end
		cat9.scanner.active = nil
		return
	end

-- the pid will be wait():ed / killed as part of job control
	cat9.scanner.pid = pid
	cat9.scanner.closure = closure
	cat9.scanner.pathcookie = cookie

-- mark as hidden so it doesn't clutter the UI or consume job IDs but can still
-- re-use event triggers an asynch processing
	local job =
	{
		out = out,
		pid = pid,
		hidden = true,
	}

	cat9.import_job(job)
	out:lf_strip(true)

-- append as closure so it'll be triggers just like any other job completion
	table.insert(job.closure,
	function(id, code)
		cat9.scanner.pid = nil
		if cat9.scanner.closure then
			cat9.scanner.closure(job.data)
		end
	end)

end

-- This can be called either when invalidating an ongoing scanner by setting a
-- new, or cancelling ongoing scanning due to the results not being interesting
-- anymore. It does not actually stop immediately, but rather kill the related
-- process (if still alive) so the normal job management will flush it out.
function cat9.stop_scanner()
	if not cat9.scanner.active then
		return
	end

	if cat9.scanner.pid then
		root:psignal(cat9.scanner.pid, "kill")
		cat9.scanner.pid = nil
	end

-- not to be confused with the job closure table
	if cat9.scanner.closure then
		cat9.scanner.closure()
	end

	cat9.scanner.cookie = nil
	cat9.scanner.closure = nil
	cat9.scanner.active = nil
end

-- the rules for generating / filtering a file/directory completion set is
-- rather nuanced and shareable so that is abstracted here.
--
-- returned 'path' is what we actually pass to find
-- prefix is what we actually need to add to the command for the value to be right
-- flt is what we need to strip from the returned results to show in the completion box
-- and offset is where to start in each result string to just present what's necessary
--
-- so a dance to get:
--
--    cd ../fo<tab>
--          lder1
--          lder2
--
-- instead of:
--   cd ../fo<tab>
--          ../folder1
--          ../folder2
--
-- and still comleting to:
--  cd ../folder1
--
-- for both / ../ ./ and implicit 'current directory'
--
function cat9.filedir_oracle(path, prefix, flt, offset, cookie, closure)
-- cancel anything ongoing unless it is for the same path from the same source
	if cat9.scanner.active and cat9.scanner.cookie ~= cookie then
		cat9.stop_scanner()
	end

-- if the path is new it is time to rescan
	if not cat9.scanner.active then
		if not cat9.scanner.cookie or cat9.scanner.cookie ~= cookie then
			cat9.set_scanner(path, cookie,
			function(res)
				if res then
					cat9.scanner.last = res
					closure(res)
				end
			end
		)
		end
	end

	if cat9.scanner.last then
		closure(cat9.scanner.last)
	end
end

function cat9.pathexec_oracle()
	if cat9.path_set then
		return cat9.path_set
	end

	local path = root:getenv()["PATH"]
	local argv = string.split(path, ":")
	table.insert(argv, 1, "/usr/bin/find")
	table.insert(argv, 2, "find")
	table.insert(argv, "-executable")
	local dupcheck = {}
	cat9.path_set = {}
	cat9.filedir_oracle(argv, prefix, flt, offset, cookie,
-- add with both implicit path in search order and explicit path
		function(set)
			for _,v in ipairs(set) do
				local pos = string.find(v, "/[^/]*$")
				if pos then
					str = string.sub(v, pos + 1)
					if str and v[#v] ~= "/" and not dupcheck[str] then
						dupcheck[str] = true
						table.insert(cat9.path_set, str)
					end
				end
			end
			for _,v in ipairs(set) do
				table.insert(cat9.path_set, v)
			end
		end
	)
	return cat9.path_set
end

local function swapin_path(argv, path)
	local res = {}
	for _, v in ipairs(argv) do
		if v == "$path" then
			table.insert(res, path)
		else
			table.insert(res, v)
		end
	end
	return res
end

-- calculate the suggestion- set parameters to account for absolute/relative/...
function cat9.file_completion(fn, argv)
	local path   -- actual path to search
	local prefix -- prefix to filter from last path when applying completion
	local flt    -- prefix to filter away from result-set
	local offset -- add item to suggestion starting at offset after prefix match

-- args are #1 (cd) or #2 (cd <path>)
	if not fn or #fn == 0 then
		path = swapin_path(argv, "./")
		prefix = ""
		flt = "./"
		offset = 3
		return path, prefix, flt, offset
	end

-- $env expansion not considered, neither is ~ at the moment
	local elements = string.split(fn, "/")
	local nelem = #elements

	path = table.concat(elements, "/", 1, nelem - 1)
	local ch = string.sub(fn, 1, 1)

-- explicit absolute
	if ch == '/' then
		offset = #path + 2
		if #elements == 2 then
			path = "/" .. path
		end
		prefix = path .. (#path > 1 and "/" or "")

		if nelem == 2 then
			flt = path .. elements[nelem]
		else
			flt = path .. "/" .. elements[nelem]
		end
		path = swapin_path(argv, path)
		return path, prefix, flt, offset
	end

-- explicit relative
	if string.sub(fn, 1, 2) == "./" then
		offset = #path + 2
		prefix = path .. "/"
		flt = path .. "/" .. elements[nelem]
		path = swapin_path(argv, path)
		return path, prefix, flt, offset
	end

	if string.sub(fn, 1, 3) == "../" then
		offset = #path + 2
		prefix = path .. "/"
		flt = path .. "/" .. elements[nelem]
		path = swapin_path(argv, path)
		return path, prefix, flt, offset
	end

	prefix = path
	path = "./" .. path
	if nelem == 1 then
		flt = path .. elements[nelem]
		offset = #path + 1
	else
		flt = path .. "/" .. elements[nelem]
		prefix = prefix .. "/"
		offset = #path + 2
	end

	path = swapin_path(argv, path)
	return path, prefix, flt, offset
end

function cat9.prefix_filter(intbl, prefix, offset)
	local res = {}

	for _,v in ipairs(intbl) do
		if string.sub(v, 1, #prefix) == prefix then
			local str = v
			if offset then
				str = string.sub(v, offset)
			end
			if #str > 0 then
				table.insert(res, str)
			end
		end
	end

-- special case, we already have what we suggest, set to empty so the readline
-- implementation can autocommit on linefeed
	if #res == 1 then
		local sub = offset and string.sub(prefix, offset) or prefix
		if sub and sub == res[1] then
			return {}
		end
	end

	table.sort(res)
	return res
end
end
