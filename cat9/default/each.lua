return
function(cat9, root, builtins, suggest, views, builtin_cfg)
	builtins.hint["each"] = "Repeat a command for each item in a referenced job"

local errors = {}
errors.no_job = "each .. >job< (parg) parg without job"
errors.unknown_parg = "each (>arg<) unknown argument, expected 'merge'"
errors.missing_action = "missing action separator: !!"
errors.missing_command = "missing command argument"
errors.recursive = "each .. !! each recursion is not permitted"

local in_each_parse = false
builtins.each =
function(...)
	local args = {...}
	local i = 1
	local lastjob
	local set = {}

	if in_each_parse then
		return false, errors.recursive
	end

	local mode = "split"

	if type(args[1]) == "table" and args[1].parg then
		if args[1][1] == "merge" then
			mode = "merge"
		elseif args[1][1] == "sequential" then
			mode = "sequential"
		else
			return errors.unknown_parg
		end
	end

	local gotsep = false

	while args[i] do
		if type(args[i]) == "string" then
			if args[i] ~= "!!" then
				table.insert(set, args[i])
			else
				gotsep = true
				i = i + 1
				break
			end
		else
-- should add mode for 'silent' jobs in the set
			if args[i].parg then
				if not lastjob then
					if i > 1 then
						return false, errors.no_job
					end
				else
					local exp =
						cat9.expand_string_table({lastjob, args[i]}, true)
					for i=1,#exp do
						table.insert(set, exp[i])
					end
					lastjob = nil
				end
			else
				if lastjob then
					for _,v in ipairs(lastjob:slice()) do
						table.insert(set, v)
					end
					lastjob = nil
				else
					lastjob = args[i]
				end
			end
		end

		i = i + 1
	end

	if lastjob then
		for _,v in ipairs(lastjob:slice()) do
			table.insert(set, v)
		end
	end

	if not gotsep then
		return false, errors.missing_action
	end

	if not args[i] then
		return false, errors.missing_command
	end

	local _, action = string.split_first(cat9.parsestr, "!!")

-- The actual task depends on processing mode. For sequential and merge we need
-- to hook on_finish, on_fail and on_data as all indicate changes in completion
-- state.

-- Merge also needs a container job where we link all the others, and mark them
-- as hidden.
	local merge_job

	if mode == "merge" then
		cat9.parse_string(nil, "contain new")
		merge_job = cat9.latestjob
	end

	local run_item
	local pending = 0
	run_item = function(ic)
-- make sure we only fire once.
		if ic then
			if not ic.armed then
				return
			end
			ic.armed = false
			pending = pending - 1
-- any collection / processing goes here
		end

-- one repeat command can potentially manifest in multiple jobs, since we hook
-- into all we need to track how many that are left so we know when to start
-- the next item in the sequence.
		if pending > 0 and mode == "sequential" then
			return
		end

		local ni = table.remove(set, 1)
		if not ni then
			cat9.hook_import_job()
			return
		end

		if mode == "sequential" or mode == "merge" then
-- capture the creation of any new job from the command, this is more
-- annoying than one might think since a command can spawn jobs asynch
-- that trigger other jobs etc. and we need to hook / batch all of them.
			local job_hook
			job_hook =
			function(job)
				if not job then
					cat9.hook_import_job()
					return
				end

				if merge_job then
					cat9.parse_string(nil,
						string.format("#%d contain #%d add #%d", merge_job.id, merge_job.id, job.id)
					)
				end
				pending = pending + 1

				local opt = {armed = true, job = job, pid = job.pid}
				local chook

				local ic =
				function()
					print("event callback")
					run_item(opt)
				end

				table.insert(job.hooks.on_destroy, ic)
				table.insert(job.hooks.on_fail, ic)
				table.insert(job.hooks.on_finish, ic)
				table.insert(job.hooks.on_closure,
					function(enter)
						if enter then
							chook = cat9.import_hook
							cat9.hook_import_job(job_hook)
						else
							cat9.import_hook = chook == ic and nil or chook
						end
					end
				)
			end
			cat9.hook_import_job(job_hook)
		end

-- We ignore the parsing / tokenization after !! so that we can copy
-- it and swap out $arg with the current item and just throw this into
-- parse_string. Make sure to prevent each from being part of the arg.
		in_each_parse = true
		local torun = string.gsub(
			action, "$arg", "\"" .. string.gsub(ni, "\"", "\\\"") .. "\"")

-- special-case /some/item and give that priority for things to work from slicing
-- the stash, otherwise use the cwd for the job
		local dir = root:chdir()
		if string.sub(ni, 1, 1) == "/" or string.sub(ni, 1, 2) == "./" then
			dir = string.match(ni, "(.*)/")
		end

		torun = string.gsub(
			torun, "$dir", "\"" .. string.gsub(dir, "\"", "\\\"") .. "\"")

		cat9.parse_string(nil, torun)
		in_each_parse = false
		run_item()
	end

	run_item()
end

suggest["each"] =
function(args, raw)
-- if raw has reached !! then we need to go back into suggest with the
-- first part chopped out
	local si = 0
	local pos = 1

	for i=1,#args do
		if args[i] == "!!" then
			if i == 1 then
				return false, #raw
			end
			si = i
			break
		end
	end

	if si == 0 then
		local set = {hint = {}}
		if #raw > 6 then
			table.insert(set, "!!")
			table.insert(set.hint, "Separate job list from command template")
		end
		cat9.add_job_suggestions(set, false)
		set.title = "Source job",
		cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
		return
	end

	local a, b = string.split_first(raw, "!!")
	local cmd = args[si + 1]
	if not cmd then
	else
		local reduce = {}
		for i=si+1,#args do
			table.insert(reduce, args[i])
		end
		cat9.add_message("expand: $arg and/or $dir")
		if suggest[cmd] then
			return suggest[cmd](reduce, b)
		end
	end
end

end
