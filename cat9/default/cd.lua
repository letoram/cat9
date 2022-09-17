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

function builtins.cd(step, opt)
	if type(step) == "table" then
		if step.dir then
			cat9.switch_env(step)
		else
			cat9.add_message("job #" .. tostring(step.id) .. " doesn't have a working directory")
		end

-- allow cd #0 (4)
		if type(opt) == "table" and opt.parg then
			if #opt == 1 and tonumber(opt[1]) then
				local subdir = step:slice(opt)
				if subdir and subdir[1] then
					cat9.chdir(string.gsub(subdir[1], "\n", ""))
				end
			end
		end

		last_dir = root:chdir()
		return
	end

	if not step or step == "~" then
		cat9.chdir(root:getenv("HOME"))
		last_dir = root:chdir()
		return
	end

	if type(step) ~= "string" then
		return
	end

	if type(opt) == "string" then
		if step == "f" then
			step = opt
		elseif step == "f-" then
			hist[opt] = nil
			return
		elseif step == "f+" then
			if opt == "." then
				opt = root:chdir()
			end
			hist[opt] = hist_cutoff + 1
			return
		end
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

		if #args > 4 then
			cat9.add_message("cd favorite - too many arguments")
			return
		else
			cat9.add_message("cd - too many arguments")
			return
		end

	elseif #args < 1 then
		return
	end

-- special case, job references
	if string.sub(raw, 4, 4) == "#" then
		local set = {}
		for _,v in ipairs(lash.jobs) do
			if v.dir and v.id then
				table.insert(set, "#" .. tostring(v.id))
			end
		end
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
			cat9.readline:suggest(set, "substitute", "cd \"" .. prefix, "/\"")
		end
	)
end
end
