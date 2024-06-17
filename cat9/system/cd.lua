return
function(cat9, root, builtins, suggest)

-- this history should possibly also be job- contextual, i.e. when
-- we actively switch env, attach hist to that as well. this makes
-- the state store more complex so something for later.
local last_dir = root:chdir()
local hist = {}
local hist_cutoff = 2

local function linearize(hist)
	local res = {}
	for k,v in pairs(hist) do
		if v > hist_cutoff then
			table.insert(res, k)
		end
	end
	return res
end

local errors =
{
	job_nowd = "cd job #%d has no working directory",
	cdf_badarg = "cd f[-+] >arg< is not a string",
	missing = "cd >dir< missing"
}

-- hijack process launching and check the working directory whenever
-- this happens, this will catch other calls as well - so filter out
-- the common (/usr/bin etc.) that does not match the last manual
-- directory
local opopen = root.popen
function root.popen(self, ...)
	local dir = root:chdir()
	if dir == last_dir and not cat9.scanner.active then
		hist[dir] = hist[dir] and hist[dir] + 1 or 1
	end

	return opopen(self, ...)
end

cat9.state.export["dir_history"] =
function()
	return hist
end

cat9.state.import["dir_history"] =
function(tbl)
	hist = {}
	for k,v in pairs(tbl) do
		hist[k] = tonumber(v)
	end
end

builtins.hint["cd"] = "Change Directory"

function builtins.cd(...)
	local args = {...}

	if type(args[1]) == "table" and not args[2] then
		if args[1].dir then
			cat9.switch_env(args[1])
		else
			return false, string.format(errors.job_nwd, args[1].id)
		end
		return
	end

	local base = {}

-- special case cd f, cd f+, cd- which uses history
	if type(args[1]) == "string" then
		local step = args[1]
		local opt = args[2]

		if step == "f" or step == "f-" or step == "f+" then
			if type(opt) ~= "string" then
				return false, errors.cdf_badarg
			end

			if step == "f" then
				step = opt
				cat9.chdir(step)
				last_dir = root:chdir()

			elseif step == "f-" then
				hist[opt] = nil

			elseif step == "f+" then
				if opt == "." then
					opt = root:chdir()
				end
				hist[opt] = hist_cutoff + 1
			end

			return
		end
	end

-- now we can allow cd #0(1,2,3) or cd /path or cd ~ or cd $..
	local ok, msg = cat9.expand_arg(base, args)
	if not ok then
		cat9.add_message("cd: " .. msg)
		return
	end

	local step = table.concat(base, " ")

	if #args == 0 or #args[1] == "" then
		return false, errors.missing
	end

	if step == "~" then
		cat9.chdir(root:getenv("HOME"))
		last_dir = root:chdir()
		return
	end

	if step == "-" then
		cat9.chdir(cat9.prevdir)
	else
		cat9.chdir(step)
	end

	last_dir = root:chdir()
end

-- cd [job or str]
-- cd f
-- cd f-
-- cd #job (line) [ basically used for ls ]
function suggest.cd(args, raw)
	if #args > 2 then
		if type(args[2]) == "string" then
			if args[2] == "f" or args[2] == "f-" then
				cat9.readline:suggest(cat9.prefix_filter(linearize(hist), args[3]), "word")
				return
			elseif args[2] == "f+" then
				return
			end
		end

	elseif #args < 1 then
		return
	end

-- special case, job references
	if string.sub(raw, 4, 4) == "#" then
		local set = {}

		cat9.add_job_suggestions(set, false, function(job)
			return job.dir ~= nil, job.dir
		end)

		cat9.readline:suggest(cat9.prefix_filter(set, string.sub(raw, 4)), "word")
		return
	end

	local argv, prefix, flt, offset =
		cat9.file_completion(args[2], cat9.config.glob.dir_argv)

	cat9.filedir_oracle(argv,
		function(set)
			if #raw == 3 then
				table.insert(set, 1, "..")
				table.insert(set, 1, ".")
			end
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			cat9.readline:suggest(set, "substitute", "cd " .. prefix, "/")
		end
	)
end
end
