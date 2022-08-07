-- just restore the default state, could possibly add vt100 processing here as well
return
function(cat9, root, builtins, suggest, views)
function views.crop(job, suggest)
	if not suggest then
		job.view = cat9.view_raw
		job.view_state = nil
		job.view_name = "crop"
	end
end
end
