return
{
	debug =
	{
--		dap_default = {"gdb", "gdb", "-i", "dap", "-q"},
		dap_default = {"lldb-dap", "lldb-dap"},
		dap_create = {
			"target create %s",
		},
		dap_id = {"lldb"},
		default_views = {"stderr", "stdout", "threads", "errors"},
		hide_while_runnning = false,
		thread = {bc = tui.colors.text, fc = tui.colors.text},
		thread_expanded = {bc = tui.colors.text, fc = tui.colors.text},
		thread_selected = {bc = tui.colors.alert, fc = tui.colors.text, border_down = true},
		source_line = {bc = tui.colors.text, fc = tui.colors.text},
		breakpoint_line = {bc = tui.colors.ref_red, fc = tui.colors.text},
		disassembly = {bc = tui.colors.text, fc = tui.colors.text},
		disassembly_selected = {bc = tui.colors.alert, fc = tui.colors.text, border_down = true},
		file = {bc = tui.colors.text, fc = tui.colors.text},
		file_selected = {bc = tui.colors.alert, fc = tui.colors.text, border_down = true},
		register = {fc = tui.colors.ref_green, bc = tui.colors.text},
		register_value = {fc = tui.colors.ref_red, bc = tui.colors.text},

		reggroups = {
-- x84_64 right now, complete with more as needed
			general = {
				"rax", "rbx", "rcx", "rdx", "rsi", "rrdi", "rbp", "rsp",
				"r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip", "eflags"
			},
			segment = {
				"cs", "ss", "ds", "es", "fs", "gs", "fs_base", "gs_base"
			},
			floating_point = {
				"st0", "st1", "st2", "st3", "st4", "st5", "st6", "st7",
				"fctrl", "fstat", "ftag", "fiseg", "fioff", "foseg", "fooff", "fop",
				"mxcsr"
			},
			vector = {
				"ymm%d+"
			}
		},
-- commands to run when debugger is initalised
		options = {
			"set disassembly-flavor intel",
			"set debug dap-log-file /tmp/dap.log"
		}
	}
}
