return
function(cat9, root, builtins, suggest, views, builtin_cfg)
	builtins.hint["each"] = "Repeat a command for each item in a referenced job"

builtins.each =
function(...)
	local args = {...}
	local i = 1
	local lastjob
	local set = {}

	local mode = "sequential"
	local silent = false

-- pargs we want:
--
--  sequential
--  	parallel
--      silent
--
--   would also want to group parallel by order
--
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
			if args[i].parg then
				if not lastjob then
					if i > 1 then
						return false, "() arg without job"
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
		return false, "missing action separator: !!"
	end

	if not args[i] then
		return false, "missing command argument"
	end

	local _, action = string.split_first(cat9.parsestr, "!!")

-- The actual task depends on processing mode.
-- For sequential we need to hook on_finish, on_fail and
-- on_data as all indicate that it is time for the next, if
-- we also weren't told to stop.

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

-- one repeat command can potentially manifest in multiple
-- jobs, since we hook into all we need to track how many
-- that are left so we know when to start the next item in
-- the sequence.
		if pending > 0 then
			return
		end

		local ni = table.remove(set, 1)
		if not ni then
-- if we have a monitor job, mark that we are complete and
-- present / merge the data from ic.job.data
			return
		end

		if mode == "sequential" then

-- capture the creation of any new job from the command, this is more
-- annoying than one might think since a command can spawn jobs asynch
-- that trigger other jobs etc. and we need to hook / batch all of them.
			local job_hook
			job_hook =
			function(job)
				if not job then
					cat9.hook_import_job(job_hook)
					return
				end

				local opt = {armed = true, job = job, pid = job.pid}
				local chook

				pending = pending + 1
				local ic = function() run_item(opt) end
				table.insert(job.hooks.on_destroy, ic)
				table.insert(job.hooks.on_fail, ic)
				table.insert(job.hooks.on_finish, ic)
				table.insert(job.hooks.on_closure,
					function(enter)
						if enter then
							chook = cat9.import_hook
							cat9.hook_import_job(job_hook)
						else
							cat9.import_hook = chook
						end
					end
				)
			end

			cat9.hook_import_job(job_hook)

-- we ignore the parsing / tokenization after !! so that we can copy
-- it and swap out $arg with the current item and just throw this into
-- parse_string
				local torun = string.gsub(
					action, "$arg", "\"" .. string.gsub(ni, "\"", "\\\"") .. "\"")
				cat9.parse_string(nil, torun)
			end
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
		local set = {}
		if #raw > 6 then
			table.insert(set, "!!")
		end
		cat9.add_job_suggestions(set, false)
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
		if suggest[cmd] then
			return suggest[cmd](reduce, b)
		end
	end
end

end
