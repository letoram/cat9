return
{
	debug =
	{
		dap_default = {"gdb", "gdb", "-i", "dap", "-q"},
		default_views = {"stderr", "stdout", "threads", "errors"},
		hide_while_runnning = false,
		thread = {bc = tui.colors.text, fc = tui.colors.text},
		thread_expanded = {bc = tui.colors.text, fc = tui.colors.text},
		thread_selected = {bc = tui.colors.alert, fc = tui.colors.text, border_down = true},
		source_line = {bc = tui.colors.text, fc = tui.colors.text},
		breakpoint_line = {bc = tui.colors.alert, fc = tui.colors.text},
		disassembly = {bc = tui.colors.text, fc = tui.colors.text},
		disassembly_selected = {bc = tui.colors.alert, fc = tui.colors.text, border_down = true},
		options = {
			"set disassembly-flavor intel"
		}
	}
}
