return
function(cat9, root, builtins, suggest)

function builtins.cd(step)
	if type(step) == "table" then
		if step.dir then
			cat9.switch_env(step)
		else
			cat9.add_message("job #" .. tostring(step.id) .. " doesn't have a working directory")
		end
		return
	end

	if not step then
		cat9.chdir(root:getenv("HOME"))
		return
	end

	if type(step) ~= "string" then
		return
	end

	if step == "-" then
		cat9.chdir(cat9.prevdir)
	else
		cat9.chdir(step)
	end
end

function suggest.cd(args, raw)
	if #args > 2 then
		cat9.add_message("cd - too many arguments")
		return

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

	local cookie = "cd" .. tostring(cat9.idcounter)
	cat9.filedir_oracle(argv, prefix, flt, offset, cookie,
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
