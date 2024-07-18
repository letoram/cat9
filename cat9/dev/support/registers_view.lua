return
function(cat9, cfg, job, th, frame)

-- useful:
--
--  architecture specific helpers for pretty-printing registers
--  and provide hover / suggestions for flags etc.
--
local wnd =
	cat9.import_job({
		short = "Debug:registers",
		parent = job,
		data = {bytecount = 0, linecount = 0}
	})

	local locals = frame:locals()

	if locals.registers then
		local max = 0
		for i,v in ipairs(locals.registers.variables) do
			if #v.name > max then
				max = #v.name
			end
		end

		for i,v in ipairs(locals.registers.variables) do
			table.insert(wnd.data, string.lpad(v.name, max) .. " = " .. v.value)
		end

		wnd.data.linecount = #locals.registers.variables
	end

return wnd
end
