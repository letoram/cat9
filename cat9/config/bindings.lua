return
function(cat9, root, config)
	local bnd = cat9.bindings
	bnd[tui.keys.D] = "forget #last"
	bnd[tui.keys.Q] = "repeat #last edit flush"
	bnd.m1_click = "view #csel toggle"
	bnd.m2_click = "open #csel hex"
	bnd.m1_data_col1_click = "view #csel select $=crow"
	bnd.m4_data_click = "view #csel scroll -1"
	bnd.m5_data_click = "view #csel scroll +1"
end
