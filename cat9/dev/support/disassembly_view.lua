return
function(cat9, cfg, job, th, frameid, opts)

-- options:
--
--  when we have a callsite, annotate with arguments
--  colorize symbols with addresses differently
--
--  * use external 'to C'
--      test jump instructions based on current registers and determine
--      if it is going to be taken
--
--  * copy / lift into emulator to test with different arguments and
--    register states
--

local function view_disasm(job, x, y, cols, rows, probe)
-- prep based on column preferences
	return cat9.view_fmt_job(job, job.data, x, y, cols, rows, probe)
end

local function view_override(job, x, y, row, set, ind, col, selected, cols)
	--	job.pc and cfg.disassembly_selected or cfg.disassembly
	local frame = th:frame(frameid)
	local attr = cfg.debug.disassembly

	if frame and frame.pc == set.source[ind].addr then
		attr = cfg.debug.disassembly_selected
	end
	job.root:write_to(x, y, set[ind], attr)
end

local function slice_disasm(job, lines)
	local res = {}

	return cat9.resolve_lines(
		job, res, lines,
			function(i)
				return job.data.set and job.data.set[i].str or "broken"
			end
		)
end

local wnd =
	cat9.import_job({
		short = "Debug:disassembly",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

	wnd:set_view(view_disasm, slice_disasm, {}, "disassembly")
	wnd.write_override = view_override

	wnd.invalidated =
	function()
-- if frame changed, re-request disassembly
		local frame = th:frame(frameid)
		if not frame then
			wnd.data = {bytecount = 0, linecount = 0, "invalid frame: " .. tostring(frameid)}
			return
		end

		wnd.pc = frame.pc
		th.dbg:disassemble(frame.pc, 0, 100,
			function(set)
				wnd.data = {bytecount = 0, linecount = 0}
				if not set then
					table.insert(wnd.data, "Disassembly Failed")
					return
				end
				wnd.data.source = {}
				for i=1,#set do
-- this is debugger dependent (seriously why not an attribute?!)
					if set[i].valid then
						table.insert(wnd.data, set[i].str)
						table.insert(wnd.data.source, set[i])
						wnd.data.bytecount = wnd.data.bytecount + #set[i].bytes
					else
						break
					end
				end
				wnd.data.linecount = #wnd.data
			end
		)
	end

	wnd.selected_bar =
	{
		{"Step"},
		m1 = {
			string.format("#%d debug #%d thread %d stepi", wnd.id, wnd.id, th.id)
		}
	}

	wnd:invalidated()

	return wnd
end
