return
function(cat9, root, builtins, suggest, views)
views.hint.fold = "Define or toggle foldable subregions"

function views.fold(job, suggest, args)
	table.remove(args, 1) -- remove 'fold'

-- check for 'remove' command first

-- check for valid start line
-- check for valid end line

-- check if it is already covered by a fold region
	if not suggest then
		job.folds[1] = {start = 5, stop = 10, active = true,
			children = {
			}
		}

-- exact match or do we define a subregion?
-- check so that it doesn't overflow parent
		return
	end

	local set = {hints = {}}

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
