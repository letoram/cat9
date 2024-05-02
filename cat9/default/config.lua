-- missing: doesn't provide help or suggestions for builtin- config sets

return
function(cat9, root, builtins, suggest)

builtins.hint["config"] = "View or change current Lash or job configuration"
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

local function config_job(job, key, val)
	if not key or type(key) ~= "string"
		or not val or type(val) ~= "string" then
		cat9.add_message("config job: missing/bad key/val")
		return
	end

	if not job.factory then
		cat9.add_message("config job: job does not define a factory")
		return
	end

	if key == "alias" then
		if tonumber(val) then
			cat9.add_message("config job: alias must be non-numeric")
			return
		end
		job.alias = val
		return
	end

-- Other options would be persisting data / history which can make
-- the state blob seriously large. This should ultimately not be a
-- problem, but enable that gradually when we also have signing
-- and compression as part of the state store (something for lua-tui).
	if val ~= "off" and val ~= "auto" and val ~= "manual" then
		cat9.add_message("config job: bad")
		return
	end

	job.factory_mode = val
end

function builtins.config(key, val, opt)
	if type(key) == "table" then
		return config_job(key, val, opt)
	end

	if not key or cat9.config[key] == nil then
		if key == "=reload" then
			local ok, msg = pcall(cat9.reload)
			if not ok then
				cat9.add_message("reload failed: " .. msg)
			end
			return
		end

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
	local set = {"=reload"}

	for k,v in pairs(cat9.config) do
		if type(v) ~= "table" then
			table.insert(set, k)
		end
	end
	table.sort(set)

	set.hint = {}
-- we don't n-index hints as done elsewhere, so k- match and build post sort
	for _, v in ipairs(set) do
		table.insert(set.hint, cat9.config.hint[v] or "")
	end

	if #args == 2 then
-- actually finished with the argument but hasn't begun on the next
		set = cat9.prefix_filter(set, args[2])
		cat9.readline:suggest(set, "word")
		return

-- filter out the jobs that we can't configure right now
	elseif #args == 1 then
		cat9.add_job_suggestions(set, false,
			function(job)
				return job.factory ~= nil
			end
		)
		cat9.readline:suggest(set, "insert")
		return
	end

-- job configuration needs are rather sparse, persistance?
	if type(args[2]) == "table" then
		if #args == 3 then
			cat9.readline:suggest(cat9.prefix_filter({"persist", "alias"}, args[3]), "word")

		elseif #args == 4 and (args[3] == "persist" or args[3] == "alias") then
			cat9.readline:suggest(cat9.prefix_filter(
				{"off", "manual", "auto"}, args[4]), "word")

		else
			cat9.add_message("config: too many arguments")
		end
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
