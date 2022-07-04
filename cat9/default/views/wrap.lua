return
function(cat9, root, builtins, suggest, views)

function views.wrap(job, x, y, cols, rows, probe, hidden)
	if not job.expanded then
		if probe then
			return 1
		end
		local dataattr = {fc = tui.colors.inactive, bc = tui.colors.background}
		root:write_to(x + config.content_offset, y, "expand me", dataattr)
		return 1
	end

	if probe then
		return rows
	end

	for i=1,rows do

	end

-- if selected, we can hint about scrollbar here
-- lash has a basic wrapping algorithm, use that
-- consume what we have
	return rows
end

end
