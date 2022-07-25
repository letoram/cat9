return
function(cat9, root, builtins, suggest)

function builtins.input(job, action)
	if type(job) ~= "table" then
		cat9.add_message("input: expected job argument")
		return
	end

-- no readline + selected job that is capable of input means interactive
-- input will be routed to the job
	if not job.inp then
		return
	end

	if cat9.readline then
		cat9.hide_readline(root)
	end

	if cat9.selectedjob then
		cat9.selectedjob.selected = false
	end

	cat9.selectedjob = job
	job.selected = true

-- don't re-enable readline
	return true
end

function suggest.input(args, raw)
	if #args > 3 then
		cat9.add_message("input #jobid >action<: too many arguments")
		return
	end

	if #args == 2 then
		local set = {}
		for _,v in ipairs(lash.jobs) do
			if v.dir and v.id then
				table.insert(set, "#" .. tostring(v.id))
			end
		end
		cat9.readline:suggest(cat9.prefix_filter(set, args[2]), "word")
		return
	end
end
end
