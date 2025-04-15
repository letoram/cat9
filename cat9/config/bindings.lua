return
function(cat9, root, config)
	local bnd = cat9.bindings
	bnd.modifier = tui.modifiers.CTRL -- default, shared with readline, bitmap so only tui.modifiers.[symbol]

-- used to give input focus to a specific job
	bnd.readline_toggle = tui.keys.ESCAPE
	bnd.window_next = tui.keys.H
	bnd.window_prev = tui.keys.L

-- generic specific window navigation controls doesn't take modifier
	bnd.window = {
		[tui.keys.PAGEUP] = "view #csel scroll page -1",
		[tui.keys.PAGEDOWN] = "view #csel scroll page +1",
		[tui.keys.HOME] = "view #csel scroll absolute 0",
		[tui.keys.END] = "view #csel scroll absolute -1",
		[tui.keys.UP] = "view #csel scroll relative -1",
		[tui.keys.DOWN] = "view #csel scroll relative +1",
		[tui.keys.ESCAPE] = "view #csel search \"\"",
		[tui.keys.SLASH] = "view #csel search",
	}

	bnd[tui.keys.D] = "forget #last"
	bnd[tui.keys.Q] = "repeat #last edit flush"
	bnd[tui.keys.F2] = "builtin"
	bnd[tui.keys.F3] = "view monitor"
--	bnd[tui.keys.F3] = "builtin dev"
	bnd.m1_click = "view #csel toggle"
	bnd.m2_click = "open terminal #csel"
	bnd.m1_data_col1_click = "view #csel mark $=crow"
	bnd.m4_data_click = "view #csel scroll relative -1"
	bnd.m5_data_click = "view #csel scroll relative 1"
-- uncomment for chorded input
	bnd.chord[tui.keys.SPACE] = {} -- enter chord state
end
