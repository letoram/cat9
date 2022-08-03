return
function(cat9, root, config)
	cat9.jobmeta["id"] =
	function(job)
		return tostring(job.id)
	end

	cat9.jobmeta["pid_or_exit"] =
	function(job)
		local extid = -1
		if job.pid then
			extid = job.pid
		elseif job.exit then
			extid = job.exit
		end
		return tostring(extid)
	end

	cat9.jobmeta["memory_use"] =
	function(job)
		return cat9.bytestr(job.data.bytecount)
	end

	cat9.jobmeta["data"] =
	function(job)
		return string.format(
			"%d:%d",
			job.data.linecount, #job.err_buffer
		)
	end

	cat9.jobmeta["dir"] =
	function(job)
		return job.dir
	end

	cat9.jobmeta["full"] =
	function(job)
		return job.raw
	end

	cat9.jobmeta["short"] =
	function(job)
		return job.short
	end
end
