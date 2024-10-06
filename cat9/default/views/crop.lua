-- just restore the default state, could possibly add vt100 processing here as well
return
function(cat9, root, builtins, suggest, views)
views.hint["crop"] = "Crop overflowing lines"

function views.crop(job, suggest)
	if not suggest then
		job:set_view(cat9.view_raw, nil, nil, "crop")
	end
end
end
