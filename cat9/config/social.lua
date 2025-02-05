return
{
	mail = {
		client = {"/usr/bin/himalaya", "-o", "json"},
		page_size = 512,
		read = {bc = tui.colors.text, fc = tui.colors.text},
		unread = {bc = tui.colors.text, fc = tui.colors.label},
		important = {bc = tui.colors.text, fc = tui.colors.alert},
		error = {bc = tui.colors.text, fc = tui.colors.alert}
	}
}
