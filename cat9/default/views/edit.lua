-- just restore the default state, could possibly add vt100 processing here as well
return
function(cat9, root, builtins, suggest, views)
views.hint.edit = "Controls for interactive editing"

function views.edit(job, suggest, args)
	table.remove(args, 1) -- remove 'edit'

	if not suggest then
		local opts = {}
		for i,v in ipairs(args) do
			if v == "revert" then
				opts.revert = true
			end
		end

		cat9.make_editable(job, opts)
		return
	end

	local set = {hints = {}}
	if #args <= 1 and job.edit and job.edit.restore.history then
		table.insert(set, "revert")
		table.insert(set.hints, "Undo the last editing session")
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
