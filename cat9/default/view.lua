local viewlut
local function build_lut()
	lut = {}
	function lut.out(set, i, job)
		job.view = job.data
		return i + 1
	end
	lut.stdout = lut.out

	function lut.err(set, i, job)
		job.view = job.errbuffer
		return i + 1
	end
	lut.stderr = lut.err

	function lut.exp(set, i, job)
		job.expanded = -1
		return i + 1
	end
	lut.expand = lut.exp

	function lut.tog(set, i, job)
		if job.expanded ~= nil then
			job.expanded = nil
		else
			job.expanded = -1
		end
	end
	lut.toggle = lut.tog

	function lut.col(set, i, job)
		job.expanded = nil
	end
	lut.collapse = lut.col
	viewlut = lut
-- also need scroll, filter, ...
end

build_lut()

return
function(cat9, root, builtins, suggest)

function builtins.view(job, ...)
	if type(job) ~= "table" then
		cat9:add_message("view >jobid< - invalid job reference")
		return
	end

	cat9.run_lut("view", job, viewlut, {...})
	cat9.flag_dirty()
end

end
