-- new window requests can add window hints on tabbing, sizing and positions,
-- those are rather annoying to write so have this alias table
local dir_lut =
{
	new = "split",
	tnew = "split-t",
	lnew = "split-l",
	dnew = "split-d",
	vnew = "split-d",
	tab = "tab"
}

return
function(cat9, root, builtins, suggest)

function builtins.open(file, ...)
	local trigger
	local opts = {...}
	local spawn = false

	if type(file) == "table" and file.data then
		trigger =
		function(wnd)
			local arg = {read_only = true}
			for _,v in ipairs(opts) do
				if v == "hex" then
					arg[cat9.config.hex_mode] = true
				end
			end
			wnd:revert()
			buf = table.concat(file.view, "")

			if not spawn then
				wnd:bufferview(buf, cat9.reset, arg)
			else
				wnd:bufferview(buf,
					function()
						wnd:close()
					end, arg
				)
			end
		end
-- this can only be done through handover,
-- some special sources: #.clip
	else
		trigger =
		function(wnd)
		end
		spawn = "new"
		return
	end

	for _,v in ipairs(opts) do
		if dir_lut[v] then
			spawn = dir_lut[v]
		end
	end

	if spawn then
		root:new_window("tui",
			function(par, wnd)
				if not wnd then
					cat9.add_message("window request rejected")
					return
				end
				trigger(wnd)
			end, spawn
		)
		return false
	else
		cat9.readline = nil
		trigger(root)
		return true
	end
end

end
