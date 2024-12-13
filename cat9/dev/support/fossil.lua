return
function(cat9, root, builtin_cfg, write_monitor, click_monitor, rebuild, in_monitor)

-- should show chat
--   if there is a chat url configured, otherwise set one, the config store for that
--   is uncertain, it doesn't seem like we can just add custom key vales?
--
--   issues to inject into commit message (requires custom editor) and forum
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

local rebuild_ticket_view

local function parse_fossil_changes(scan, mon, code)
	for i,v in ipairs(scan.data) do
		local ma, mb = string.find(v, "%s+")
		if ma and ma > 2 then
			local cat = string.sub(v, 1, ma-1)
			local path = string.sub(v, mb+1)

			if not mon.fossil[cat] then
				mon.fossil[cat] = {}
			end

-- filter out undesirable build artifacts etc.
			local exclude = false
			if builtin_cfg.scm.exclude[cat] then
				for i,v in ipairs(builtin_cfg.scm.exclude[cat]) do
					if string.match(path, v) then
						exclude = true
						break
					end
				end
			end

			if not exclude then
				table.insert(mon.fossil[cat], path)
			end
		end
	end
end

local function julian_to_str(val)
	val = tonumber(val) or 0
	return os.date(
		builtin_cfg.scm.time_format, (tonumber(val) - 2440587.5) * 86400) -- os to epoch
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

	-- problem with this approach is that we don't get a return status for the chain of
	-- terminal -> fossil -> vim so we don't know if there was something wrong with the
	-- staged commit or not.
	--
	-- possibly that ARCAN_TERMINAL_EXEC can return the exit status and that would go
	-- into the window/job bound to the commit_action, in that case we'd need to first
	-- catch the created job/window, add an on_destroy and grab the code from there.
						cat9.background_chain({add_set}, {}, nil, function()
							cat9.parse_string(nil, builtin_cfg.scm.commit_action .. table.concat(commit_set, " "))
						end)
					else
						cat9.parse_string(nil, builtin_cfg.scm.commit_action .. table.concat(commit_set, " "))
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

local function parse_fossil_describe(scan, mon, code)
	mon.fossil.version = scan.data[1]
end

local function parse_fossil_fields(scan, mon, code)
	local fmap = {}
	for i,v in ipairs(scan.data) do
		fmap[string.trim(v)] = true
	end

	mon.fossil.ticket_fields = fmap
end

-- Set of fossil external binary commands and their parsers that is used to
-- process the tracking table that is used to generate the active view. Better
-- caching and masking of these is the main performance bottleneck.
local function scan_fossil_output(base)
	local commands =
	{
		{"fossil", "changes", "--differ", handler = parse_fossil_changes},
		{"fossil", "stash", "list", handler = parse_fossil_stash},
		{"fossil", "remote", "list", handler = parse_fossil_remotes},
		{"fossil", "describe", handler = parse_fossil_describe},
		{"fossil", "ticket", "list", "fields", handler = parse_fossil_fields}
-- check stash
-- check extras
	}

-- since we reset the monitor context, we need to transfer any option local to it
	local expanded = false
	local message
	local dir = base

	if in_monitor.fossil then
		message = in_monitor.fossil.message
		expanded = in_monitor.fossil.expanded
		dir = in_monitor.fossil.directory
	end

	in_monitor.fossil = {
		expanded = expanded, message = message, ticket_fields = {},
		directory = dir
	}

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

local function action_to_symbol(action)
	return prompt_kvt[action] or action
end

local function rebuild_patch_job(job)
	job.data = {linecount = 0, bytecount = 0}
	local cfg = builtin_cfg.scm
	local patch = job.patches[job.patch_index]

	if not patch then
		job:add_line("Empty patchset", {
			attr = cfg.error_heading,
			passive_attr = cfg.error_heading
		})
		return
	end

	local aw = {}

	job:add_line(
		string.format("File: %d / %d", job.patch_index, #job.patches),
		{
			attr = cfg.heading,
			passive_attr = cfg.passive_heading,
			action_words = aw
		}
	)

	if #job.patches > 1 then
		table.insert(aw,
			{
				"Next",
				cfg.action,
				function()
					job.patch_index = job.patch_index + 1
					if job.patch_index > #job.patches then
						job.patch_index = 1
					end
					rebuild_patch_job(job)
				end
			}
		)
		table.insert(aw,
			{
				"Previous",
				cfg.action,
				function()
					job.patch_index = job.patch_index - 1
					if job.patch_index == 0 then
						job.patch_index = #job.patches
					end
					rebuild_patch_job(job)
				end
			}
		)
	end

	local opt_tbl = {}
	opt_tbl[in_monitor.diff.DIFF_DELETE] = {"-", cfg.strong_action}
	opt_tbl[in_monitor.diff.DIFF_INSERT] = {"+", cfg.action}
	opt_tbl[in_monitor.diff.DIFF_EQUAL]  = {" ", cfg.data}

	for i,v in ipairs(patch.diff) do
		local op = opt_tbl[v[1]]
		job:add_line(v[2], {
			passive_attr = op[2]
		})
	end

	cat9.flag_dirty(job)
end

local function setup_diff_job(diff, instr)
	local idx = 1
	local ok, obj = pcall(cat9.json.decode, instr, dex)

	if not ok then
		cat9.add_message(res)
		return
	end

-- convert the json output to match the patch format from the diff support script.
	local patches = {}
	local name = obj[1].leftname or ""

	for i,v in ipairs(obj) do
		local cmd = 0
		local ind = 1
		local line = 0
		local patch = {
			old = v.leftname,
			new = v.rightname,
			diff = {}
		}

		repeat
			cmd = v.diff[ind]
			local arg = v.diff[ind+1]

			if cmd == 1 then -- SKIP
				line = line + arg
			elseif cmd == 2 then -- COMMON -> DIFF_EQUAL
				table.insert(patch.diff, {
					in_monitor.diff.DIFF_EQUAL,
					arg
				}
			)
			elseif cmd == 3 then -- INSERT --> DIFF_INSERT
				table.insert(patch.diff, {
					in_monitor.diff.DIFF_INSERT,
					arg
				}
			)
			elseif cmd == 4 then -- DELETE --> DIFF_DELETE
				table.insert(patch.diff, {
					in_monitor.diff.DIFF_DELETE,
					arg
				}
			)
			elseif cmd == 5 then -- SUBARRAY -> ARRAY OF 3 * N + 1, [common, prev, new]n + suffix
-- reconstruct as a DELETE and INSERT, for that we need to build two strings
				local str_a = ""
				local str_b = ""
				local suff  = ""
				if #arg % 3 == 1 then
					suff = table.remove(arg, #arg)
				end

				for i=1, #arg, 3 do
					str_a = str_a .. arg[i+0]
					str_b = str_b .. arg[i+0]
					str_a = str_a .. arg[i+1]
					str_b = str_b .. arg[i+2]
				end

				str_a = str_a .. suff
				str_b = str_b .. suff
				table.insert(patch.diff, {
					in_monitor.diff.DIFF_DELETE,
					str_a
				})
				table.insert(patch.diff, {
					in_monitor.diff.DIFF_INSERT,
					str_b
				})

			else
				break
			end
			ind = ind + 2
		until cmd == 0

		table.insert(patches, patch)
	end

-- controls for unstaging parts of a patch or to just add a single one to the stage
-- set would require a revert of the file, apply the desired patchset, commit, then
-- re-apply the remaining patches.
--
-- We can do this by converting the patch object toText and set that as the fossil
-- input to the reverted checkout.
--
	local title = "Diff: " .. diff

	local job = {
		raw = title .. " " .. name,
		short = title,
		patches = patches,
		patch_index = 1
	}

	cat9.import_job(job)
	job.write_override = write_monitor
	job.handlers.mouse_button = click_monitor
	rebuild_patch_job(job)
end

local function add_timeline_item(wnd, item)
	local lines = string.split(item.msg, "\n")
	lines[1] = string.gsub(lines[1], "^%*CURRENT%*", "* ")
-- contract *CURRENT* into >, if the first line is empty after the swapped CURRENT we
-- should merge in the next line for formatting to work.

	local aw = {
	}

	wnd:add_line(
		item.time,
		{
			attr = builtin_cfg.scm.data,
			columns = {
				{
					label = "    ",
					data = lines[1]
				},
			},
			click = function()
				item.expanded = not item.expanded
				wnd:draw_timeline()
			end,
			action_words = aw
		}
	)

	if item.expanded then
		wnd:add_line("", {
			attr = builtin_cfg.scm.data,
			columns = {
				{
					label = "ID: ",
					data = item.hash
				},
				{
					label = "Author: ",
					data = item.author
				}
			}
		})

		for i,v in ipairs(lines) do
			wnd:add_line(v, {attr = builtin_cfg.scm.data})
		end

		for i, v in ipairs(item.set) do
			local iaw = {
				{
					"Open", builtin_cfg.scm.action,
					function()
						cat9.background_chain(
						{
							{"fossil", "cat", wnd.fossil.directory .. "/" .. v[2], "-r", item.hash,
							handler =
							function(scan, _, code)
								local title = string.format("[%s] %s", item.hash, v[2])
								local job = {
									short = title,
									raw = title,
									data = code == 0 and scan.data or scan.err_buffer
								}
								cat9.import_job(job)
							end
						}
						})
					end
				}
			}

			if v[1] == "ADDED" or v[1] == "EDITED" or v[1] == "MERGED" then
				table.insert(iaw, {
					"Diff", builtin_cfg.scm.action,
					function()
						cat9.background_chain(
							{
								{
									"fossil", "diff", "--json", "--from", item.hash,
									wnd.fossil.directory .. "/" .. v[2],
								handler =
								function(scan, _, code)
									setup_diff_job(item.hash, table.concat(scan.data, ""))
								end
								}
							}
						)
					end
				})
			end

			wnd:add_line(
				string.format("\t%s %s", action_to_symbol(v[1]), v[2]),
			{
				attr = builtin_cfg.scm.data,
				action_words = iaw
			}
			)
		end
	end
end

local function draw_timeline(wnd)
	wnd.data = {linecount = 0, bytecount = 0}
	local aw = {}
	local set

	if wnd.compact then
		wnd:add_line(
		string.format("Timeline: (%d / %d)", wnd.item_index, #wnd.dates),
		{
			attr = builtin_cfg.scm.heading,
			action_words = aw
		}
		)
		table.insert(aw,
		{
			"Full",
			builtin_cfg.scm.action,
			function()
				wnd.compact = false
				draw_timeline(wnd)
			end
		})
		table.insert(aw,
		{
			"Previous",
			builtin_cfg.scm.action,
			function()
				wnd.item_index = wnd.item_index == 1 and #wnd.dates or (wnd.item_index - 1)
				draw_timeline(wnd)
			end
		})
		table.insert(aw,
		{
			"Next",
			builtin_cfg.scm.action,
			function()
				wnd.item_index = wnd.item_index == #wnd.dates and 1 or (wnd.item_index + 1)
				draw_timeline(wnd)
			end
		})
		set = {wnd.dates[wnd.item_index]}
	else
		table.insert(aw,
		{
			"By Date",
			builtin_cfg.scm.action,
			function()
				wnd.compact = true
				draw_timeline(wnd)
			end
		}
		)
		set = wnd.dates
	end

	for _,date in ipairs(set) do
		wnd:add_line(date .. ":", {
			passive_attr = builtin_cfg.scm.passive_heading, attr = builtin_cfg.scm.heading})
		for i,v in ipairs(wnd.entries[date]) do
			add_timeline_item(wnd, v)
		end
	end
	cat9.flag_dirty(wnd)
end

local function fossil_timeline(f)
	local wnd = {
		dir = f.dir,
		short = "dev:scm fossil:timeline",
		raw = "dev:scm fossil:timeline",
		fossil = f,
		compact = true,
		item_index = 1,
		draw_timeline = draw_timeline,
		dates = {},
		entries = {
			bad = {}
		}
	}

	cat9.import_job(wnd)
	wnd.write_override = write_monitor
	wnd.handlers.mouse_button = click_monitor
	wnd.protected = true
	local cmd = {
		{
			"fossil", "timeline", "-n", builtin_cfg.scm.timeline_cap, "-t", "ci", "-v", "-W", "0",
			handler =
			function(scan, mon, code)
				wnd.protected = false
				if code ~= 0 then
					wnd:add_line("Couldn't get timeline: " .. tostring(code))
					return
				end

				local in_item
				local date = "bad"
				for i,v in ipairs(scan.data) do
					local ch = string.sub(v, 1, 1)
-- new date?
					if ch == "=" then
						if in_item then
							table.insert(wnd.entries[date], in_item)
							in_item = nil
						end

						date = string.sub(v, 5, -5)
						wnd.entries[date] = {}
						table.insert(wnd.dates, date)

-- limit reached or eof
					elseif ch == "-" or ch == "+" then
						if in_item then
							table.insert(wnd.entries[date], in_item)
							in_item = nil
							break
						end
					elseif ch == " " then
						local cmd, file = string.match(v, "%s+(%a+)%s+(.+)")
						if in_item then
							table.insert(in_item.set, {cmd, file})
						end
-- new or first item entry?
					else
						local ts, hash, msg =
							string.match(v, "(%d%d:%d%d:%d%d)%s+%[(%w+)%]%s+(.+)")
						if ts and hash and msg then
							if in_item then
								table.insert(wnd.entries[date], in_item)
							end
							local author = ""
-- extract (user: void tags: sub, trunk) from end of msg, pattern gets
-- annoying as there's both (user: ... tags: ...) and (user: ...) as well
-- as the thing possibly occuring in the message
							for i=#msg,1,-1 do
								if string.sub(msg, i, i) == "(" then
									author = string.sub(msg, i)
									break
								end
							end
							in_item = {
								time = ts,
								hash = hash,
								msg = msg,
								author = author,
								set = {}
							}
						end
					end
-- file change status
				end
				draw_timeline(wnd)
			end
		}
	}

	cat9.background_chain(cmd, {lf_strip = true})
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

local function unpack_sql(msg, separator, fields)
	local set = string.split(msg, separator)
	local res = {}

-- seed with empty
	for i=1,#fields do
		res[fields[i]] = ""
	end

	if #set ~= #fields then
		print("record count mismatch", #set, #fields, msg)
		return {}
	end
	for i,v in ipairs(set) do
		if string.sub(v, 1, 1) == "'" then
			v = string.gsub(string.sub(v, 2, -2), "''", "'")
			res[fields[i]] = v
-- missing, X'
		end
	end

	return res
end

local function build_ticket(ticket, closure)
-- use element and record separator (0x1d = 029, 0x1e = 030) ascii characters for separation
	local sepcmd = ".separator \"\\x1d\" \"\\x1e\""
	local changes =
	{
		"fossil", "sql", "-cmd", sepcmd,
			string.format(
				"SELECT tkt_rid,tkt_mtime,tkt_user,mimetype,icomment FROM " ..
				"ticketchng WHERE tkt_id = %d ORDER BY tkt_mtime ASC",
				ticket.tkt_id
				),
		handler =
		function(job, arg, code)
			ticket.changes = {}
			if code ~= 0 then
				return
			end

-- attachments is a separate table that can be queried from the ticket.uuid in the attachments
-- table, the output will be a hex literal X' then hexenc into the final blob.
			for i,v in ipairs(job.data) do
				table.insert(
					ticket.changes,
					unpack_sql(v, "\029", {"resource_id", "time", "user", "mime", "comment"})
				)
			end
		end
	}

	local attachments =
	{
		"fossil", "sql", "-cmd", sepcmd,
			string.format(
				"SELECT src, filename, comment, user FROM attachment WHERE target = '%s' AND isLatest = 1",
				ticket.tkt_uuid
			),
		handler =
		function(job, arg, code)
			ticket.attachments = {}
			if code ~= 0 then
				return
			end
			for i,v in ipairs(job.data) do
				table.insert(
					ticket.attachments,
					unpack_sql(v, "\029", {"src", "filename", "comment", "user"})
				)
			end
		end
	}

	cat9.background_chain(
		{changes, attachments},
		{lf_strip = "\030"},
		nil,
		function()
			closure(ticket)
		end
	)
end

local function change_ticket(wnd, ticket, key, value)
-- if the command returns 0, we assume it went through and just update the
-- internal cached without causing a full rebuild of the ticket view itself
	cat9.background_chain({
		{"fossil", "ticket", "change", ticket.tkt_uuid, key, value}}, {}, nil,
		function()
			ticket[key] = value
			rebuild_ticket_view(wnd)
		end
	)
end

local function build_pending(wnd, f)
	wnd.data = {linecount = 0, bytecount = 0}
	local pending = wnd.pending_ticket
	local fields = {}

-- Make a copy then remove each as we process, then generate generic setters
-- for each. The point of this is that we populate first from ticket_new_fields
-- in config, then filter that against what is actually defined in the repository.
-- Fossil allows admin to define arbitrary ticket fields, so we should reflect
-- that.
	for k,v in pairs(pending) do
		fields[k] = true
	end

-- mandatory
	fields.title = nil
	wnd:add_line("Title: " .. pending.title,
		{
			attr = builtin_cfg.scm.heading,
			click = function()
				cat9.custom_readline(wnd,
					function()
						return {"(Title) "}
					end,
					pending.title ~= "Click to set title" and pending.title or "",
					function(line)
						pending.title = line or "Click to set title"
						build_pending(wnd, f)
					end
				)
			end
		}
	)

-- version can be prefilled but also not always present
	if fields.version and f.ticket_fields.version then
		fields.version = nil
		wnd:add_line("Version: " .. pending.version,
			{
				attr = builtin_cfg.scm.heading,
				click = function()
					cat9.custom_readline(wnd,
						function()
							return {"(Version) "}
						end,
						pending.version,
						function(version)
							if version and #version > 0 then
								pending.version = version
							end
							build_pending(wnd, f)
						end
					)
				end,
			}
		)
	end

	if fields.type and f.ticket_fields.type then
		fields.type = nil

		wnd:add_line(
			"Type: " .. pending.type,
			{
				attr = builtin_cfg.scm.heading,
				action_words = {}
			}
		)

		for i,v in ipairs(builtin_cfg.scm.ticket_type) do
			table.insert(wnd.data.tags[#wnd.data].action_words,
				{
					v,
					builtin_cfg.scm.data,
					function()
						pending.type = v
						build_pending(wnd, f)
					end
				}
			)
		end
	end

	if fields.severity and f.ticket_fields.severity then
		fields.severity = nil

		wnd:add_line(
			"Severity: " .. pending.severity,
			{
				attr = builtin_cfg.scm.heading,
				action_words = {},
			}
		)

		for i,v in ipairs(builtin_cfg.scm.ticket_severity) do
			table.insert(wnd.data.tags[#wnd.data].action_words,
			{
				v,
				builtin_cfg.scm.data,
				function()
					pending.severity = v
					build_pending(wnd, f)
				end
			})
		end
	end

	for k,v in pairs(fields) do
		if f.ticket_fields[k] then
			local lbl = string.upper(string.sub(k, 1, 1)) .. string.sub(k, 2)
			wnd:add_line(lbl .. ": " .. pending[k],
			{
				attr = builtin_cfg.scm.heading,
				click =
				function()
					cat9.custom_readline(wnd,
						function()
							return {"(" .. lbl .. ") "}
						end,
						pending[k],
						function(val)
							if val and #val > 0 then
								pending[k] = val
							end
							build_pending(wnd, f)
						end
				)
			end
			})
		end
	end

	cat9.flag_dirty(wnd)
end

local function fossil_submit_ticket(pending, fields, closure)
	local args = {"fossil", "ticket", "add"}

	for k,v in pairs(pending) do
		if fields[k] then
			table.insert(args, k)
			table.insert(args, v)
		end
	end

	args.handler =
	function(job, arg, code)
		closure(code, job.data[1] or job.err_buffer[1])
	end

	cat9.background_chain({args})
end

local function add_ticket(f, ticket)
-- spawn a new window
	local wnd = {
		dir = f.dir,
		short = "dev:scm fossil:tickets",
		raw = "dev:scm fossil:tickets"
	}

	cat9.import_job(wnd)

	wnd.write_override = write_monitor
	wnd.handlers.mouse_button = click_monitor
	wnd.pending_ticket = {}

	for i,v in ipairs(builtin_cfg.scm.ticket_new_fields) do
		wnd.pending_ticket[v] = ""
	end

	wnd.pending_ticket.comment = "Click to change comment"
	wnd.pending_ticket.severity = "Important"
	wnd.pending_ticket.type = "Feature_request"
	wnd.pending_ticket.status = "Open"

	wnd.selected_bar =
	{
		{
			"Submit"
		},
		m1 =
		{
			function()
				fossil_submit_ticket(
					wnd.pending_ticket,
					f.ticket_fields,
					function(code, msg)
						if code == 0 then
							cat9.remove_job(wnd)
						else
							cat9.add_message(
								string.format(
									"Fossil rejected ticket: %s",
									msg or ""
								)
							)
						end
					end
				)
			end
		}
	}
	build_pending(wnd, f)
end

rebuild_ticket_view =
function(wnd)
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
	local ha = builtin_cfg.scm.strong_action
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
				val = julian_to_str(val)
			end

			local aw = {}
			local cfg_group = "ticket_" .. key

			if builtin_cfg.scm[cfg_group] then
				for _,v in ipairs(builtin_cfg.scm[cfg_group]) do
					table.insert(aw, {
						v,
						ha,
						function()
							change_ticket(wnd, ticket, key, v)
						end
					}
				)
				end
			end

			local keylbl = key
			if key_to_label[key] then
				keylbl = key_to_label[key]
			end

			if key ~= "changes" and key ~= "attachments" and #val > 0 then
				wnd:add_line(
					string.format("%s;%s", key, val),
					{
						attr = la,
						columns = {
							{
								label = "\t" .. keylbl .. ": ", label_attr = la,
								data = tostring(val), data_attr = da,
							}
						},
						action_words = aw
					}
				)
			end
		end

		if #ticket.attachments > 0 then
			wnd:add_line("Attachments:", {attr = la})
			for i,v in ipairs(ticket.attachments) do
				wnd:add_line("\t" .. v.filename, {
					attr = la,
					action_words = {
						{
							"Open",
							la,
							function()
								print("open")
							end
						}
					}
				})
			end
		end

		wnd:add_line("Comments:",
		{
			attr = la,
			action_words = {
				{"Add", la,
				function()
					print("request comment")
				end
				}
			}
		}
		)

		for i,v in ipairs(ticket.changes) do
			wnd:add_line(
				string.format("\t%s %s:%.72s", julian_to_str(v.time), v.user, v.comment),
				{
					action_words = {
						{
							"Open",
							la,
							function()
								print("open comment")
							end
						},
						{
							"Reply",
							la,
							function()
								print("reply")
							end
						}
					}
				}
			)
-- action word should be to reply or open in new job
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

	table.insert(main_aw,
		{"Timeline", builtin_cfg.scm.action,
		function()
			fossil_timeline(f)
		end
		}
	)

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

		table.insert(tag.action_words,
			{
				"Create",
				builtin_cfg.scm.strong_action,
				function()
					add_ticket(f, ticket, ha)
				end
			}
		)

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
								cat9.background_chain({
									{
										"fossil", "diff", "--json", dst.dir .. "/" .. j,
										handler = function(scan, _, code)
											setup_diff_job("CURRENT", table.concat(scan.data, ""))
										end
									}
								})
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
					scan_fossil_output(base)
					return true
				end
				table.remove(set, #set)
			end
		else
			append_fossil_data(in_monitor)
		end
	end
end
