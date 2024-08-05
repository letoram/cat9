return
function(cat9, cfg, job, osfun, pid)

local function attr_lookup(job, set, i, pos, highlight)
	return highlight and cfg.debug.file_selected or cfg.debug.file
end

local function var_click(job, btn, ofs, yofs, mods)
end

-- useful:
--
--  architecture specific helpers for pretty-printing registers
--  and provide hover / suggestions for flags etc.
--
local wnd =
	cat9.import_job({
		short = "Debug:files",
		parent = job,
		thread = th,
		data = {bytecount = 0, linecount = 0}
	})

	wnd.invalidated =
	function()
		local set = osfun.files(pid,
			function(set)
				wnd.data = set
				wnd.data.linecount = #set
				wnd.data.bytecount = 0
				cat9.flag_dirty(wnd)
			end
		)
	end

	wnd.attr_lookup = attr_lookup
	wnd:invalidated()
--	wnd.handlers.mouse_button = var_click
--	click should just map to open and stash with a timer option on verify
	return wnd
end
