-- just restore the default state
return
function(cat9, root, builtins, suggest, views)
function views.crop(job, suggest)
	print("crop", cat9.view_raw)
	if not suggest then
		job.view = cat9.view_raw
		job.view_state = nil
	end
end
end
