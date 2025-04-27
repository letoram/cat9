return
function(cat9, root, builtins, suggest, views)
views.hint.fold = "Define or toggle foldable subregions"

local function suggest_fold(folds, show_active, show_inactive, cb, err)

-- complication is that the lines can append to a current region
	if #folds == 0 then
		err("view #job fold action: No folds defined for job")
		return false
	end

	local set = {folds = {}}

	local function add_fold(v)
		if show_active and v.active then
			table.insert(set, tostring(v.start))
			table.insert(set.folds, v)

		elseif show_inactive and not v.active then
			table.insert(set, tostring(v.start))
			table.insert(set.folds, v)
		end
	end

	local function flatten(fold)
		add_fold(fold)
		for i,v in ipairs(fold.children) do
			flatten(v)
		end
	end

-- first level is a list of trees, so we need to process each root
	for i,v in ipairs(folds) do
		flatten(v)
	end

	cb(set)
end

local function suggest_lines(data, args, index, cb, err)
	if #args - index > 1 then
		err("view #job fold set start stop >...< : Too many arguments")
		return false
	end

	local start = tonumber(args[index])
	if not start then
		err("view #job fold set >start< stop : Not a number")
		return false
	end

	local stop = tonumber(args[index+1])
	if not stop then
		err("view #job fold set start >stop< : Not a number")
		return false
	end

	if start >= stop then
		err("view #job fold set start stop : Invalid range (stop <= start)")
		return false
	end

	return true
end

local function fold_suggest(job, args)
	local set

	if #job.folds > 0 then
		set = {
			"expand",
			"contract",
			"remove",
			"jump_to",
			"set",

			hint = {
				expand = "Expand a contracted fold",
				contract = "Contract an expanded fold",
				remove = "Remove a fold",
				jump_to = "Scroll view to fold [offset]",
				set = "Create a new fold"
			}
		}
	else
		set = {"set", hint = {set = "Create a new fold"}}
	end

	if not args[1] then
		cat9.readline:suggest(set, "", "word")
		return
	end

	if not args[2] then
		cat9.readline:suggest(cat9.prefix_filter(set, args[1]), "word")
		return
	end

	local sfun =
	function(set)
		cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
	end

	if args[1] == "expand" then
		return suggest_fold(job.folds, false, true, sfun, cat9.add_message)

	elseif args[1] == "contract" then
		return suggest_fold(job.folds, true, false, sfun, cat9.add_message)

	elseif args[1] == "remove" then
		return suggest_fold(job.folds, true, true, sfun, cat9.add_message)

	elseif args[1] == "set" then
		return suggest_lines(job.data, args, 2, sfun, cat9.add_message)
	else
		cat9.add_message("view #job fold >command<: invalid")
		return false
	end
end

function views.fold(job, suggest, args)
	table.remove(args, 1) -- remove 'fold'

	if suggest then
		return fold_suggest(job, args)
	end

-- re-use the suggestion validation
	local function toggle(set)
		for i,v in ipairs(set) do
			v.active = not v.active
		end
		cat9.flag_dirty(job)
	end

	local err
	local errf =
	function(msg)
		err = errf
	end

	if args[1] == "expand" then
		suggest_fold(job.folds, false, true, toggle, errf)
	elseif args[1] == "contract" then
		suggest_fold(job.folds, false, true, toggle, errf)
	elseif args[1] == "toggle" then
		suggest_fold(job.folds, false, true, toggle, errf)
	elseif args[1] == "remove" then
		suggest_fold(job.folds, false, true, function(set)
			for i,v in ipairs(set.folds) do
				if tostring(v.start) == args[2] then
					v:delete()
				end
			end
		end, errf)
-- set fold function validates
	elseif args[1] == "set" then
		return job:set_fold(tonumber(args[2]), tonumber(args[3]))
	end

	return err == nil, err
end
end
