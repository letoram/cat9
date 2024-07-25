return
function(cat9, cfg, job, osfun, pid)

local function var_click(job, btn, ofs, yofs, mods)

	local jd = job.data.raw[yofs]
	if not jd or btn ~= 1 then
		return
	end

-- we can use this to issue a readMemory call through parse_line
	return true
end

-- useful:
--
--  architecture specific helpers for pretty-printing registers
--  and provide hover / suggestions for flags etc.
--
local wnd =
	cat9.import_job({
		short = "Debug:maps",
		parent = job,
		thread = th,
	})

	wnd.invalidated =
	function()
		osfun.maps(pid,
		function(set)
			wnd.data = {bytecount = 0, linecount = 0, raw = set}
			for i=1,#set do
				local base = tonumber(set[i].base, 16)
				local endpt = tonumber(set[i].endptr, 16)
				local sz = endpt - base
				local pref, sz_pref = cat9.sz_to_human(sz)
				local line =
					string.format("(%s) 0x%s + %d%s",
						set[i].perm, set[i].base, math.floor(sz_pref), pref)
				if set[i].file and #set[i].file > 0 then
					if set[i].ofs == "00000000" then
						line = string.format("%s %s", line, set[i].file)
					else
						line = string.format("%s %s + %s", line, set[i].file, set[i].ofs)
					end
				end
				table.insert(wnd.data, line)
			end
			wnd.data.linecount = #wnd.data

			cat9.flag_dirty(wnd)
		end)
	end

	wnd:invalidated()
	wnd.show_line_numbers = false
	wnd.handlers.mouse_button = var_click
	return wnd
end
