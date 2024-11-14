return
function(cat9, root, builtin_cfg, write_monitor, click_monitor, rebuild, in_monitor)

-- fossil should show timeline, chat, issues to inject into commit message, ...
--
-- mouse over should have:
--       tag: [attr, handler, action verbs (offset + trigger)]
--
-- fossil monitor should have an optional timer that:
--        runs update -n, checks changes
--                        and if desired / no conflict: updates
--                        with triggers on issues
--
--        runs curl (with credentials) into chaturl (if config:ed) into chat endpoint
--
-- issues command (initial probe + cache and on-update trigger)
--

local function parse_fossil_changes(scan, mon, code)
	for i,v in ipairs(scan.data) do
		local ma, mb = string.find(v, "%s+")
		if ma and ma > 2 then
			local cat = string.sub(v, 1, ma-1)
			local path = string.sub(v, mb+1)

			if not mon.fossil[cat] then
				mon.fossil[cat] = {}
			end
			table.insert(mon.fossil[cat], path)
		end
	end
end

local function parse_fossil_stash(job, code)
end

-- take in_monitor.fossil / in_monitor.git and pack into .data
-- this is where we add per-line handlers as well
local prompt_kvt =
{
	ADDED = "A:", EDITED = "Ed:", MERGED = "M:", EXTRA = "Ex:", MISSING = "M:", DELETED = "D:"
}

local monitor_groups =
{
	Edited = "Edited", Merged = "Merged",
	Added = "Added", Extra = "Extra",
	Missing = "Missing", Deleted = "Deleted"
}

local function append_staging(f, dir, ent, action)
-- create staging area if it doesn't exist
	if not f.staging then
		local staging = {
			dir = dir,
			short = "dev:scm fossil:staging",
			raw = "dev:scm fossil:staging",
		}
		cat9.import_job(staging)

		staging.write_override = write_monitor
		staging.handlers.mouse_button = click_monitor
		table.insert(staging.hooks.on_destroy,
			function()
				f.staging = nil
			end
		)

-- add the 'commit' part as an action word on staging, this will just send the changeset
-- to fossil right now as a shell job that takes the place of the staging area. what we
-- would like is to switch to an edit view with prefilled options that takes care of all
-- the different commit flags (allow-conflict/fork/older/color/branch/branchcolor/tags/
-- signature) and helper with inserting issues markers that should be closed.
--
-- the compromise would be to add such options to the staging area.
		local aw = {}
		table.insert(aw,
			{
				"Commit",
				builtin_cfg.scm.strong_action,
				function()
					local commit_set = {}
					local add_set = {}

					for i=2,#staging.data do
						if staging.data.tags[i].action == "add" then
							table.insert(add_set, staging.data[i])
						else
							table.insert(commit_set, '"' .. staging.data[i] .. '"')
						end
					end

					if #add_set > 0 then
						table.insert(add_set, 1, "fossil")
						table.insert(add_set, 2, "add")
						cat9.background_chain({add_set}, function()
							cat9.parse_string(nil, "!fossil commit " .. table.concat(commit_set, " "))
						end)
					else
						cat9.parse_string(nil, "!fossil commit " .. table.concat(commit_set, " "))
					end
				end
			}
		)

		staging:add_line("Staging:", {action_words = aw})
		f.staging = staging
	end

	local found = false

-- ensure no duplicates
	for i,v in ipairs(f.staging.data) do
		if v == ent then
			found = true
			break
		end
	end

	f.staging.unstage =
	function(f, ent)
		local ok, i = cat9.remove_match(f.data, ent)
		if ok then
			table.remove(f.data.tags, i)
		end
		f.data.linecount = #f.data
		cat9.flag_dirty(f)
	end

-- add it
	if not found then
		local aw = {action_words = {}, action = action}
		table.insert(aw.action_words,
			{"Unstage", builtin_cfg.scm.action, function() f.staging:unstage(ent) end})

		f.staging:add_line(ent, aw)
	end

	cat9.flag_dirty(f.staging)
end

local function parse_fossil_remotes(scan, mon, code)
	mon.fossil.remotes = {}
	for i,v in ipairs(scan.data) do
		local beg = string.find(v, "%s(%a+)://")
		if beg then
			local name = string.trim(string.sub(v, 1, beg))
			local url = string.sub(v, beg+1)
			table.insert(mon.fossil.remotes, {name, url})
		end
	end
end

-- Set of fossil external binary commands and their parsers that is used to
-- process the tracking table that is used to generate the active view. Better
-- caching and masking of these is the main performance bottleneck.
local function scan_fossil_output()
	local commands =
	{
		{"fossil", "changes", "--differ", handler = parse_fossil_changes},
		{"fossil", "stash", "list", handler = parse_fossil_stash},
		{"fossil", "remote", "list", handler = parse_fossil_remotes},
-- check stash
-- check extras
	}

-- since we reset the monitor context, we need to transfer any option local to it
	local expanded = false
	local message
	if in_monitor.fossil then
		message = in_monitor.fossil.message
		expanded = in_monitor.fossil.expanded
	end

	in_monitor.fossil = {expanded = expanded, message = message}
	in_monitor.pending = in_monitor.pending + 1
	cat9.background_chain(commands, {lf_strip = true}, in_monitor,
		function(job)
			in_monitor.pending = in_monitor.pending - 1
			if in_monitor.pending == 0 then
				rebuild()
				last_monitor = nil
			end
		end
	)
end

local function fossil_update(dst)
	local update_cmd = {"fossil", "update"}
	update_cmd.handler =
	function(job, arg, code)
		if code == 0 then
			dst.message = os.date("%Y-%m-%d %T")
		else
			dst.message = "update failed"
		end
		rebuild(root:chdir())
	end
	cat9.background_chain({update_cmd}, {}, dst)
end

local function fossil_set_remote(dst, name, save)
	local create_main = true
	local cmd = {}

	if save then
		table.insert(cmd, {"fossil", "remote", "add", "main", "default"})
	end

	if not name then
		name = "off"
	end

	table.insert(cmd, {"fossil", "remote", name})
	cat9.background_chain(cmd, {}, dst, function()
		rebuild(root:chdir())
	end)
end

local function fossil_timeline(f, p)
-- spawn a new window
-- run fossil timeline -n [limit] -v -W 0
-- then format is:
--   === date ===
--   h:m:s [hash] comment (user: ... tags: ...)
--   %s+COMMAND file
end

local function tickets_to_data(dst, report_id, filter, closure)
-- action word for switching report type (and listing them)
-- option to convert to spreadsheet
	cat9.background_chain(
		{
			{"fossil", "ticket", "show", tostring(report_id), filter,
				handler =
				function(job, mon, code)
					if code == 0 then
						if job.data.linecount == 0 then
							dst.data = {linecount = 0, bytecount = 0}
							dst:add_line("No ticket data found for report type")
							return
						end

-- unpack ticket database
						local fields = string.split(job.data[1], string.char(0x09))
						local columns = {}
						local set = {}

						for i,v in ipairs(fields) do
							columns[i] = v
						end

						for i=2,#job.data do
							local ent = {}
							local fields = string.split(job.data[i], string.char(0x09))

							for i,v in ipairs(fields) do
								ent[columns[i]] = v
							end
							table.insert(set, ent)
						end

						closure(set)
					else
						dst.data = {linecount = 0, bytecount = 0}
						dst:add_line(string.format("Scanning failed, error: %d", code))
					end
				end
			}
		}
	)
end

local key_to_label =
{
	tkt_mtime = "Modified",
	tkt_ctime = "Created",
	tkt_uuid = "UUID",
	tkt_id = "ID",
	type = "Type",
	status = "Status",
	subsystem = "Subsystem",
	priority = "Priority",
	severity = "Severity",
	foundin = "Found In",
	private_contact = "Private Contact",
	resolution = "Resolution",
	title = "Title",
	comment = "Comment"
}

local function build_ticket(ticket, closure)
-- we need to do a lot more work to resolve out the change history for
-- the ticket in order to properly view the contents of the ticket. We
-- still lack a markdown (or rather, pandoc to djot and have a djot
-- view) that can embed diagrams etc.
--
-- fossil sql "SELECT icomment,tkt_rid FROM ticketchng WHERE tkt_id = 2 ORDER BY tkt_mtime DESC"
--
	closure(ticket)
end

local function rebuild_ticket_view(wnd)
	wnd.data = {bytecount = 0, linecount = 0}
	cat9.flag_dirty(wnd)
	local aw = {}

--	for i,v in ipairs(builtin_cfg.scm.ticket_columns) do

-- first line is overview / tickets
	wnd:add_line(
		string.format("Tickets(%d)", #wnd.tickets),
		{
				attr = builtin_cfg.scm.heading,
				click = function()
					wnd.ticket = nil
					rebuild_ticket_view(wnd)
				end,
				action_words = aw
		}
	)

-- sort based on preferred key, this will process the entire ticket report, for
-- large number of tickets the report selector in fossil itself should limit scope
	local la = builtin_cfg.scm.ticket_heading
	local da = builtin_cfg.scm.data
	local ticket = wnd.ticket

	if ticket then
		wnd:add_line(
			string.format("%s;%s", ticket.tkt_id, ticket.title),
			{
				attr = la,
				columns = {
					{
						label = ticket.tkt_id .. ": ", label_attr = la,
						data = ticket.title, data_attr = da
					}
				}
			}
		)

-- action words should be based on presets for the default commands,
-- e.g. changing to resolved etc.
		for key, val in pairs(ticket) do
			if string.find(key, "_%atime") then
				val = os.date("%c",
					(tonumber(val) - 2440587.5) * 86400) -- os to epoch
			end

			if key_to_label[key] then
				key = key_to_label[key]
			end

			if #val > 0 then
				wnd:add_line(
					string.format("%s;%s", key, val),
					{
						attr = la,
						columns = {
							{
								label = "\t" .. key .. ": ", label_attr = la,
								data = tostring(val), data_attr = da
							}
						}
					}
				)
			end
		end
		return
	end

	for _, ticket in ipairs(wnd.tickets) do
		local linear = {}
		local tag = {
			columns = {},
			click = function()
				build_ticket(
					ticket, function(ticket)
						wnd.ticket = ticket
						rebuild_ticket_view(wnd)
					end
				)
			end
		}

		for _, column in ipairs(builtin_cfg.scm.ticket_columns) do
			if ticket[column] then
				table.insert(linear, ticket[column])

				table.insert(
					tag.columns,
					{
						label = column .. ": ", label_attr = la,
						data  = ticket[column], data_attr = da,
					}
				)
			end
		end

		if #linear > 0 then
			wnd:add_line(table.concat(linear, ";"), tag)
		end
	end
end

local function fossil_tickets(f, filter)
-- spawn a new window
	local wnd = {
		dir = dir,
		short = "dev:scm fossil:tickets",
		raw = "dev:scm fossil:tickets"
	}

	cat9.import_job(wnd)
	wnd.write_override = write_monitor
	wnd.handlers.mouse_button = click_monitor
	wnd:add_line("Scanning for tickets...", {})

-- just convert the window to a spreadsheet
	tickets_to_data(
		wnd, 0, filter,
		function(data)
-- then reference the presentation columns
			wnd.tickets = data
			rebuild_ticket_view(wnd)
		end
	)
end

local function append_fossil_data(dst)
	local f = dst.fossil
	local promptstr
	local prompttbl = {}

	for k,v in pairs(prompt_kvt) do
		if f[k] and #f[k] > 0 then
			table.insert(prompttbl, v .. tostring(#f[k]))
		end
	end

	local main_aw = {}

	promptstr = string.format("Fossil(%s)", table.concat(prompttbl, " "))
	if not dst.add_line then
		return promptstr
	end

	local toggle_expand =
	function()
		f.expanded = not f.expanded
		rebuild(dst)
		cat9.flag_dirty(dst)
	end

	if not f.expanded then
		dst:add_line("Fossil (status):",
			{click = toggle_expand,
			 attr = builtin_cfg.scm.heading,
			 action_words = main_aw
			}
		)

		dst:add_line(string.format(
			"\tEdited: %d, Merged: %d, Added: %d, Extra: %d, Removed: %d, Missing: %d",
			f.EDITED and #f.EDITED or 0,
			f.MERGED and #f.MERGED or 0,
			f.ADDED and #f.ADDED or 0,
			f.EXTRA and #f.EXTRA or 0,
			f.MISSING and #f.MISSING or 0,
			f.DELETED and #f.DELETED or 0
		))
		return promptstr
	end

-- we re-use the existing view with overwrites in order to not have to provide
-- all the scroll/view/slice/... overrides that would be necessary.
	dst:add_line(string.format(
	"Fossil (expanded)%s:", f.message and ("(" .. f.message .. ")") or ""
	),
		{
			click = toggle_expand,
			attr = builtin_cfg.scm.heading,
			action_words = main_aw
		}
	)

	if builtin_cfg.scm.ticket_filters then
		local tag = {
			attr = builtin_cfg.scm.heading,
			action_words = {}
		}

		dst:add_line("Tickets:", tag)

		for k,v in pairs(builtin_cfg.scm.ticket_filters) do
			table.insert(tag.action_words,
				{
					k,
					builtin_cfg.scm.action,
					function()
						fossil_tickets(f, v)
					end
				}
			)
		end
	end

-- action words for remote controls
	if f.remotes then
		local def_remote_url
		local def_remote_match
		local aw = {}

		for i,v in ipairs(f.remotes) do
			if v[1] == "default" then
				def_remote_url = v[2]
				def_remote_match = "default"
				break
			end
		end

-- mark the non-'default' ones
		for i,v in ipairs(f.remotes) do
			if v[1] ~= "default" then
				if v[2] == def_remote_url then
					def_remote_match = v[1]
				end
				table.insert(
					aw,
					{
						v[1], builtin_cfg.scm.action,
						function()
							fossil_set_remote(f, v[1])
						end
					}
				)
			end
		end

-- add the 'airplane mode' from the help, if the default remote url only match
-- default, then save it as main before proceeding to disable remote
		table.insert(aw, 1, {
			"Off",
			builtin_cfg.scm.strong_action,
			function()
				fossil_set_remote(f, nil, def_remote_match == "default")
			end
		})

-- we have a valid remote, add the option to update from it
		table.insert(main_aw, 1,
			{"Update", builtin_cfg.scm.action,
			function()
				fossil_update(f)
			end
			}
		)

--		table.insert(main_aw, 1,
--			{"Timeline", builtin_cfg.scm.action,
--				function()
--					fossil_timeline(f)
--		end
--			}
--	)

		dst:add_line(
			string.format("\tRemote (%s):", def_remote_match or "off"),
			{attr = builtin_cfg.scm.heading, action_words = aw}
		)
	end

	for k,v in pairs(monitor_groups) do
		local group = string.upper(k)

		if f[group] and #f[group] > 0 then
			dst:add_line(string.format("\t%s:", k), {attr = builtin_cfg.scm.heading})

			for i,j in ipairs(f[group]) do
				local action_words = {}
				local ent = dst.dir .. "/" .. j

-- can't stage what isn't there
				if group ~= "MISSING" then

					table.insert(action_words, {
						"Stage", builtin_cfg.scm.action,
							function()
								append_staging(f,
									dst.cdir, ent, group == "EXTRA" and "add" or "commit")
							end
					})

-- can't revert what isn't in the set
					if group ~= "EXTRA" then
						table.insert(
							action_words, {"Revert",
							builtin_cfg.scm.strong_action,
							function()
								cat9.background_chain({
									{"fossil", "revert", ent}}, {}, f.staging,
									function()
										scan_fossil_output()
									end
								)
							end
						})
					else
-- might not belong at all
						table.insert(
							action_words, {"Delete",
							builtin_cfg.scm.strong_action,
							function()
								lash.root:funlink(ent)
								scan_fossil_output()
							end
						})
					end

-- if it already is in the set, we can view it like that
					if group ~= "ADDED" and group ~= "DELETED" then
						table.insert(action_words, 1,
							{"Open",
								builtin_cfg.scm.action,
								function()
									cat9.term_handover(
										cat9.config.open_spawn_default,
										cat9.config.term_plumber,
										ent
									)
								end
							}
						)
					end

-- and if it has changed we want to see what has changed
					if group == "EDITED" or group == "MERGED" then
						table.insert(action_words, 1, {"Diff",
							builtin_cfg.scm.action,
							function()
								cat9.setup_shell_job(
									{"fossil", "fossil", "diff", dst.dir .. "/" .. j}
								)
							end
						})
					end
				end

-- group specfiic actions:
				dst:add_line(string.format("\t\t%s", j),
					{attr = builtin_cfg.scm.data, action_words = action_words})
			end
		end
	end
end

-- if we get a path, the working directory for the monitor has changed
-- otherwise we should rebuild the dataset
return
	function(path)
		if path then
			local set = string.split(in_monitor.dir, "/")

			while #set > 0 do
				local base = table.concat(set, "/")
				local ok, _, _ = root:fstatus(base .. "/.fslckout")
				if ok then
					scan_fossil_output()
					return true
				end
				table.remove(set, #set)
			end
		else
			append_fossil_data(in_monitor)
		end
	end
end
