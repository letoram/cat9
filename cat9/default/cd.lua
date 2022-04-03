return
function(cat9, root, builtins, suggest)

function builtins.cd(step)
	if type(step) == "table" then
		if step.dir then
			step = step.dir
		else
			cat9.add_message("job #" .. tostring(step.id) .. " doesn't have a working directory")
			return
		end
	end

	root:chdir(step)
	cat9.scanner_path = nil
	cat9.update_lastdir()
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
		cat9.readline:suggest(set, "word")
		return
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
	local path, prefix, flt, offset = cat9.file_completion(args[2])
	if cat9.scanner.active and cat9.scanner.active ~= path then
		cat9.stop_scanner()
	end

	if not cat9.scanner.active then
		if not cat9.scanner_path or (cat9.scanner_path and cat9.scanner_path ~= path) then
			cat9.scanner_path = path
			cat9.set_scanner(
				{"/usr/bin/find", "find", path, "-maxdepth", "1", "-type", "d"},
				function(res)
					if res then
						cat9.scanner.last = res
						local set = cat9.prefix_filter(res, flt, offset)
						if #raw == 3 then
							table.insert(set, 1, "..")
							table.insert(set, 1, ".")
						end
						cat9.readline:suggest(set, "substitute", "cd " .. prefix, "/")
					end
				end
			)
		end
	end

	if cat9.scanner.last then
		local set = cat9.prefix_filter(cat9.scanner.last, flt, offset)
		if #raw == 3 then
			table.insert(set, 1, "..")
			table.insert(set, 1, ".")
		end
		cat9.readline:suggest(set, "substitute", "cd " .. prefix, "/")
	end
end

end
