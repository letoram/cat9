return
function(cat9, root, builtins, suggest)

cat9.state.import["config"] =
function(tbl)
	for k,v in pairs(tbl) do
-- ignore any non-matching keys
		if cat9.config[k] then
			if type(cat9.config[k]) == "number" then
				if tonumber(v) then
					cat9.config[k] = tonumber(v)
				end
			elseif type(cat9.config[k]) == "boolean" then
				cat9.config[k] = v == "true"
			elseif type(cat9.config[k]) == "string" then
				cat9.config[k] = v
			end
		end
	end
end

cat9.state.export["config"] =
function()
	return cat9.config
end

function builtins.config(key, val)
	if not key or cat9.config[key] == nil then
		cat9.add_message("missing / unknown config key")
		return
	end

	if not val then
		cat9.add_message("missing value to set for key " .. key)
		return
	end

	local t = type(cat9.config[key])

	if t == "boolean" then
		if val == "true" or val == "1" then
			cat9.config[key] = true
		elseif val == "false" or val == "0" then
			cat9.config[key] = false
		else
			cat9.add_message(key .. " expects boolean (true | false)")
		end
	elseif t == "number" then
		local num = tonumber(val)
		if not num then
			cat9.add_message(" invalid number value")
		else
			cat9.config[key] = num
		end
	elseif t == "string" then
		cat9.config[key] = val
	end
end

function suggest.config(args, raw)
	if not cat9.config_cache then
		cat9.config_cache = {}
		for k,v in pairs(cat9.config) do
			if type(v) ~= "table" then
				table.insert(cat9.config_cache, k)
			end
		end
		table.sort(cat9.config_cache)
	end

	local set = cat9.config_cache

	if #args == 2 then
-- actually finished with the argument but hasn't begun on the next
		set = cat9.prefix_filter(cat9.config_cache, args[2])
		cat9.readline:suggest(set, "word")
		return

	elseif #args == 1 then
		cat9.readline:suggest(set, "insert")
		return
	end

-- entering the value, just set the message to current/type
	if cat9.config[args[2]] == nil then
		cat9.add_message("unknown key")
		return
	end

	local last = cat9.config[args[2]]
	cat9.add_message(tostring(last) .. " (" .. type(last) .. ")")
end

end
