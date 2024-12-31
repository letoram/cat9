return
{
	scm =
	{
		heading = {bc = tui.colors.text, fc= tui.colors.ref_yellow, border_down = true},
		passive_heading = {bc = tui.colors.text, fc= tui.colors.ref_yellow},
		error_heading = {bc = tui.colors.alert, fc = tui.colors.alert},

		action = {bc = tui.colors.text, fc = tui.colors.ref_green},
		strong_action = {bc = tui.colors.ref_red, fc = tui.colors.text},
		data = {bc = tui.colors.text, fc = tui.colors.text},
		time_format = "%y-%m-%d %H:%M",
		timeline_cap = 100,
		ticket_filters = {
			Open = "status == 'Open'",
			Fixed = "status == 'Fixed'",
			Closed = "status == 'Closed'"
		},
-- lifted from fossil ui
		ticket_status = {
			"Open", "Verify", "Review", "Deferred", "Fixed", "Tested", "Closed"
		},
		ticket_type = {
			"Code_Defect", "Build_Problem", "Documentation", "Feature_Request", "Incident"
		},
		ticket_priority = {
			"Immediate", "High", "Medium", "Low", "Zero"
		},
		ticket_severity = {
			"Critical", "Severe", "Important", "Minor", "Cosmetic"
		},
		ticket_resolution = {
			"Open", "Fixed", "Rejected", "Workaround", "Unable_To_Reproduce",
			"Works_As_Designed", "External_Bug", "Not_A_Bug", "Duplicate",
			"Overcome_By_Events", "Drive_By_Patch", "Misconfiguration"
		},
-- these are filtered further by the fields scanned from fossil itself
		ticket_new_fields = {
			"version",
			"title",
			"type",
			"subsystem",
			"comment",
			"severity",
		},
		exclude = {
			EXTRA = {"^build"}
		},
		edit_action = "s!(nokeep) vim",
		commit_action = "s!(nokeep) fossil commit",
		ticket_columns = {"date", "title", "severity", "type"},
		ticket_heading = {bc = tui.colors.text, fc = tui.colors.ref_yellow}
	},
	debug =
	{
		arcan_default_mode = "split-r",
		dap_default = {"gdb", "gdb", "-i", "dap", "-q"},
--		dap_default = {"lldb-dap", "lldb-dap"},
		dap_create = {
--		"target create %s",
		},
		dap_id = {"gdb"},
--		dap_default = {"lldb-dap", "lldb-dap"}, },
		dap_id = {"gdb"},
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
		variable = {bc = tui.colors.text, fc = tui.colors.text},

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
