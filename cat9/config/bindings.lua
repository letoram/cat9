return
function(cat9, root, config)
	local bnd = cat9.bindings
	bnd.modifier = tui.modifiers.CTRL -- default, shared with readline, bitmap so only tui.modifiers.[symbol]
	bnd[tui.keys.D] = "forget #last"
	bnd[tui.keys.Q] = "repeat #last edit flush"
	bnd[tui.keys.F2] = "builtin"
	bnd[tui.keys.F3] = "view monitor"
--	bnd[tui.keys.F3] = "builtin dev"
	bnd.m1_click = "view #csel toggle"
	bnd.m2_click = "open terminal #csel"
	bnd.m1_data_col1_click = "view #csel select $=crow"
	bnd.m4_data_click = "view #csel scroll -1"
	bnd.m5_data_click = "view #csel scroll +1"
-- uncomment for chorded input
	bnd.chord[tui.keys.SPACE] = {} -- enter chord state
	bnd.chord[tui.keys.SPACE][tui.keys.D] = "builtin dev"
	bnd.chord[tui.keys.SPACE][tui.keys.S] = "builtin system"
	bnd.chord[tui.keys.SPACE][tui.keys.L] = "debug launch /home/void/testf"
	bnd.chord[tui.keys.SPACE][tui.keys.V] = "view monitor"
end
