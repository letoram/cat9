return
function(cat9, root, config)

if config.accessibility then
	root:new_window("accessibility",
		function(wnd, new)
			if not new then
				cat9.add_message("no access")
				return
			end

			cat9.a11y = wnd
			new:hint({max_cols = 80, max_rows = 2})

-- first row will be claimed by readline, >1 are for us to populate
			new:write_to(0, 0, "hi access")
			new:alert("this is an alert")
			new:notification("this is a notification")
			new:failure("something went wrong")
			new:refresh()
		end
	)
end

end
