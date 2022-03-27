return
function(cat9, root, builtins, suggest)

function builtins.env(key, val)
	if key == "=clear" then
		cat9.env = {}
		return
	end
	cat9.env[key] = val
end

local special =
{
	"=clear",
-- "=new" [ create a new named set of envs that can be used in !(...) ]
-- "=set" [ switch active set from the default to the current ]
}

function suggest.env(args, raw)
	local set = {}

	if #args > 3 then
		cat9.add_message("too many arguments (=opt or key [val])")
		return
	end

-- only on key
	if #args < 3 then
		for _,v in ipairs(special) do
			table.insert(set, v)
		end

		for k,_ in pairs(cat9.env) do
			table.insert(set, k)
		end

		local cur = args[2] and args[2] or ""

-- but might start on val
		if cur and #cur > 0 and string.sub(raw, -1) == " " then
			args[3] = ""
		else
			cat9.readline:suggest(cat9.prefix_filter(set, cur, 0), "word")
			return
		end
	end

	if type(args[2]) ~= "string" then
		cat9.add_message("env >key | opt< [val] expected string, got: " .. type(args[2]))
		return
	end

	if type(args[3]) ~= "string" then
		cat9.add_message("env [key | opt] >val< expected string, got: " .. type(args[3]))
		return
	end

-- key already known? show what the value is
	if (#args[2] > 0 and cat9.env[args[2]]) then
		local val = cat9.env[args[2]]
		cat9.add_message(args[2] .. "=" .. val)
	else
		table.insert(set, args[2])
		cat9.readline:suggest({})
	end
end

end
