return
{
	mail = {
		client = {"/usr/bin/himalaya", "-o", "json"},
		page_size = 512,
		show_from = 20,
		read = {bc = tui.colors.text, fc = tui.colors.text},
		unread = {bc = tui.colors.text, fc = tui.colors.label},
		important = {bc = tui.colors.text, fc = tui.colors.alert},
		error = {bc = tui.colors.text, fc = tui.colors.alert},
		action = {bc = tui.colors.text, fc = tui.colors.ref_green},
		strong_action = {bc = tui.colors.ref_red, fc = tui.colors.text}
	}
}
