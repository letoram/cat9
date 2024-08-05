-- missing some form of persistence or per builtin- group setting

return
function(cat9, root, builtins, suggest)

local default = lash.root:getenv()

function builtins.env(key, val, path)
	if key == "=clear" then
		cat9.env = {}
		return
	end

	if key == "=default" then
		cat9.env = {}
		for k,v in pairs(default) do
			cat9.env[k] = v
		end
		return
	end

	if key == "=alias" then
		cat9.aliases[val] = path
		return
	end

	cat9.env[key] = val
end

-- careful not to let a "set job context"
cat9.state.export["env"] =
function()
	local denv = cat9.env
	if cat9.job_stash then
		denv = cat9.job_stash.env
	end

-- prefix with env_ for environment, _alias for alias etc.
--
-- don't actually export the keys that match default env so any inherited
-- connection primitives doesn't get exposed and then overwritten.
	local res = {}
	for k,v in pairs(denv) do
		if default[k] and default[k] == v then
		else
			res["env_" .. k] = v
		end
	end
	for k,v in pairs(cat9.aliases) do
		res["alias_" .. k] = v
	end
	return res
end

-- instead of blending or replacing, have an explicit 'default' argument
cat9.state.import["env"] =
function(tbl)
	for k,v in pairs(tbl) do
		if string.sub(k, 1, 4) == "env_" then
			default[string.sub(k, 5)] = v
		elseif string.sub(k, 1, 6) == "alias_" then
			cat9.aliases[string.sub(k, 7)] = v
		end
	end
end

local special =
{
	"=clear",
	"=alias",
	'=default',
-- previous thought here was to have sets, e.g. =new bla =set bla
-- but jobs indirectly already have that effect. instead add that
-- to saving / configuring a job.
}

builtins.hint["env"] = "Change new process environment"

function suggest.env(args, raw)
	local set = {}

-- with =alias we take key and then grab the rest of raw at offset
	if #args > 3 then
		if args[2] ~= "=alias" then
			cat9.add_message("too many arguments (=opt or key [val])")
			return
		end
	end

	if args[2] == "=alias" then
		cat9.add_message("=alias name string")
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
