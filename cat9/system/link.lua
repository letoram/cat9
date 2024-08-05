--
-- builtin around 'ln' just to never have to waste time with understanding if
-- it's src -> dst, dst -> src, repeat with softlink when hardlink constraints
-- are not possible ..
--
return
function(cat9, root, builtins, suggest, views, builtin_cfg)

builtins.hint.link = "Create links between filesystem objects"

function builtins.link(src, dst)
	if not src or not dst then
	elseif type(src) ~= "string" then
		cat9.add_message("link >old< should be a file or directory name")
		return
	elseif type(dst) ~= "string" then
		cat9.add_message("link old >new< should be a file or directory name")
		return
	end

	local ok, stat = root:fstatus(src)
	if not ok then
		cat9.add_message("link > " .. src .. " < does not exist")
		return
	end

	ok, stat = root:fstatus(dst)
	if ok then
		cat9.add_message("the intended link name already exists")
		return
	end

	local _, _, _, pid = root:popen({"/usr/bin/env", "/usr/bin/env", "ln", "-s", src, dst})
	if not pid then
		cat9.add_message("link old new - failed to exec")
	end
end

local function pick_file(inset, arg, filter)
	local argv, prefix, flt, offset =
				cat9.file_completion(arg, cat9.config.glob.file_argv)

	cat9.filedir_oracle(argv,
		function(set)
			if #arg == 1 then
				table.insert(set, 1, "..")
				table.insert(set, 1, ".")
			end
			if flt then
				set = cat9.prefix_filter(set, flt, offset)
			end
			set.title = inset.title
			cat9.readline:suggest(set, "word", prefix)
		end
	)
end

function suggest.link(args, raw)
	local set = {}

	if #args > 1 then
		if #args == 2 then
			set.title = "source (existing)"
			pick_file(set, args[2], cat9.config.glob.file_argv)

		elseif #args == 3 then
			if type(args[2]) == "table" then
	-- need to check if this is a parg and if we can slice a single from it
				return
			end

			local ok, kind = root:fstatus(args[2])
			if not ok then
				return false, #args[1] + 2
			end

			set.title = string.format("link %s (%s) to (new)", args[2], kind)
			pick_file(set, args[3], cat9.config.glob.file_argv)

		elseif #args == 4 then
			local ok, kind = root:fstatus(args[2])
			if not ok then
				return false, #args[1] + 2
			end

			local isdir = kind == "directory"
			local ok, kind = root:fstatus(args[3])
			if ok then
				return false, #args[1] + #args[2] + 3
			end

			local set = {}
			set.title = string.format(
				"link (%s) (%s) to new: %s", args[2], kind, args[3])
			cat9.readline:suggest(set, "word")
		end
	end
end

end
