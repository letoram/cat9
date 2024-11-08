return
function(cat9, root, builtins, suggest, views, builtin_cfg)

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

local in_monitor
local config = cat9.config
local update_prompt
local build_data
local scan_fossil_output

local function write_monitor(job, x, y, row, set, ind, _, selected, cols)
	local mouse = job.mouse

-- show most significant characters
	if #row > cols then
		row = "..." .. string.sub(row, #row - cols * 0.5)
	end

	local attr = cat9.config.styles.data

-- expand action verbs when on a row with items
	if mouse and mouse.on_row and mouse.on_row == ind then
		local tag = set.tags[ind]
		mouse.click_handler = nil

		if tag then
			attr = tag.attr

			if tag.action_words then
				_, x, y = job.root:write_to(x, y, row, attr)

-- prioritize action_words on overflow
				local count = 0
				for i,v in ipairs(tag.action_words) do
					count = count + #v[1] + 1
				end

				if x + count > cols then
					x = cols - count
					if x < 0 then
						x = 0
					end
				end

				for i,v in ipairs(tag.action_words) do
					local attr = v[2]
					if not attr then
						print("no attr for", v[1])
						attr = {}
					end
					_, x, y = job.root:write_to(x, y, " ")

					if mouse[1] >= x and mouse[1] <= x + #v[1] then
						attr = cat9.table_copy_shallow(attr)
						mouse.click_handler = v[3]
						attr.border_down = true
					end

					_, x, y = job.root:write_to(x, y, v[1], attr)
				end
			else
				job.root:write_to(x, y, row, attr)
			end
			return
		end
	end

	job.root:write_to(x, y, row, attr)
end

local function monitor_click(job, btn, ofs, yofs, mods)
	local fn = job.data.tags and job.data.tags[yofs]

-- figure out the action word at which offset
	if fn and fn.click then
		fn.click()
	elseif job.mouse and job.mouse.click_handler then
		job.mouse.click_handler()
	end

	return yofs > 0
end

local function parse_fossil_changes(scan, mon, code)
	if mon ~= in_monitor then
		return
	end

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

local function append_staging(f, dir, ent, new)
-- create staging area if it doesn't exist
	if not f.staging then
		f.staging = {
			dir = dir,
			short = "dev:scm fossil:staging",
			raw = "dev:scm fossil:staging",
		}
		cat9.import_job(f.staging)
		f.staging.write_override = write_monitor
		f.staging.handlers.mouse_button = monitor_click

		f.staging:add_line("Staging:")
-- should probably add the 'commit' part as an action word on staging which
-- would run the fossil commit command as a shell job which would spawn the
-- fossil configured editor. The other option would be mutating f.staging into
-- an editor view.
	end

	local found = false

-- ensure no duplicates
	for i,v in ipairs(f.staging.data) do
		if v == ent then
			found = true
			break
		end
	end

-- add it
	if not found then
		local aw = {action_words = {}}
		table.insert(aw.action_words,
			{"Unstage", cat9.config.styles.data,
				function()
					cat9.remove_match(f.staging.data, ent)
					f.staging.linecount = #f.staging.data
					cat9.flag_dirty(f.staging)
				end
			})

		f.staging:add_line(ent, aw)
	end
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

	promptstr = string.format("Fossil(%s)", table.concat(prompttbl, " "))
	if not dst.add_line then
		return promptstr
	end

	local toggle_expand =
	function()
		f.expanded = not f.expanded
		build_data(dst)
		cat9.flag_dirty(dst)
	end

	if not f.expanded then
		dst:add_line("Fossil (status):",
			{click = toggle_expand,
			 attr = cat9.config.styles.data_highlight
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
	dst:add_line("Fossil (expanded):",
		{
			click = toggle_expand,
			attr = cat9.config.styles.data_highlight,
		}
	)

	for k,v in pairs(monitor_groups) do
		local group = string.upper(k)

		if f[group] and #f[group] > 0 then
			dst:add_line(string.format("\t%s:", k), {attr = cat9.config.styles.data})

			for i,j in ipairs(f[group]) do
				local action_words = {}
				local ent = dst.dir .. "/" .. j

-- can't stage what isn't there
				if group ~= "MISSING" then
					table.insert(action_words, {
						"Stage", cat9.config.styles.data,
							function()
								append_staging(f, dst.cdir, ent, group == "EXTRA")
							end
					})

-- can't revert what isn't in the set
					if group ~= "EXTRA" then
						table.insert(
							action_words, {"Revert",
							cat9.config.styles.error_line,
							function()
								cat9.background_chain({
									{"fossil", "fossil", "revert", ent}}, {},
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
							cat9.config.styles.error_line,
							function()
								lash.root:funlink(ent)
								scan_fossil_output()
							end
						})
					end

-- if it already is in the set, we can view it like that
					if group ~= "ADDED" and group ~= "DELETED" then
						table.insert(action_words,
							{"Open",
								cat9.config.styles.data,
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
						table.insert(action_words, {"Diff",
							cat9.config.styles.data,
							function()
								cat9.setup_shell_job(
									{"fossil", "fossil", "diff", dst.dir .. "/" .. j}
								)
							end
						})
					end
				end

-- group specfiic actions:
				dst:add_line(string.format("\t\t%s", j), {action_words = action_words})
			end
		end
	end
end

build_data =
function()
	in_monitor.data = {linecount = 0, bytecount = 0}
	local promptstr = ""

	if in_monitor.fossil then
		promptstr = append_fossil_data(in_monitor)
		if in_monitor.prompt then
			in_monitor.prompt = promptstr
		end
		return
	end

	if in_monitor.git then
	end
end

-- set of fossil external binary commands and their parsers that
-- is used to process the tracking table that is used to generate
-- the active view
scan_fossil_output =
function()
	local commands =
	{
		{"fossil", "changes", "--differ", handler = parse_fossil_changes},
		{"fossil", "stash", "list", handler = parse_fossil_stash},
--	{"fossil", "timeline"},
-- check stash
-- check extras
	}

	local expanded = false
	if in_monitor.fossil then
		expanded = in_monitor.fossil.expanded
	end

	in_monitor.fossil = {expanded = expanded}
	in_monitor.pending = in_monitor.pending + 1
	cat9.background_chain(commands, {lf_strip = true}, in_monitor,
		function(job)
			in_monitor.pending = in_monitor.pending - 1
			if in_monitor.pending == 0 then
				build_data(job)
				last_monitor = nil
			end
		end
	)
end

local function scan_git_output()
	-- git status -s -z with lf_strip = '\0'
	-- short format:
	-- XY PATH
	-- XY ORIG_PATH -> PATH
end

local function refresh_monitor()
	local job = in_monitor
	local set = string.split(in_monitor.dir, "/")
	local got_fossil, got_git
	job.data = {linecount = 0, bytecount = 0}
	job.pending = 0

	while #set > 0 do
		local base = table.concat(set, "/")

		if not got_fossil then
			local ok, _, _ = root:fstatus(base .. "/.fslckout")
			if ok then
				got_fossil = base
			end
		end

		if not got_git then
			ok, kind, _ = root:fstatus(base .. "/.git")
			if kind == "directory" then
				got_git = base
			end
		end

		table.remove(set, #set)
	end

-- it is possible to have both SCMs active (say a fossil repository with
-- subdirectories populated by git) so need to scan separately then join
-- together into data and flag dirty accordingly
	job.got_fossil = got_fossil
	if got_fossil then
		if job.add_line then
			job:add_line("Fossil: (scanning)", {})
		end
		scan_fossil_output()
	end

	job.got_git = got_git
	if got_git then
		if job.add_line then
			job:add_line("Git:", {})
		end
		scan_git_output()
	end

	if not got_fossil and not got_git then
		if job.add_line then
			job:add_line("No source control active", {})
		end

		if job.prompt then
			job.prompt = "dev.scm:none"
		end
	end

	cat9.flag_dirty(job)
end

local function drop_prompt()
	if not in_monitor or not in_monitor.prompt then
		return
	end

	local tgt_i
	for i=1,#config.prompt_focus do
		if config.prompt_focus[i] == update_prompt then
			tgt_i = i
			break
		end
	end

	if tgt_i then
		table.remove(config.prompt_focus, tgt_i-1) -- drop $begin
		table.remove(config.prompt_focus, tgt_i-1) -- drop update_prompt
		table.remove(config.prompt_focus, tgt_i-1) -- drop $end
	end

-- if we own the monitor, just clear it and the handles
	if not in_monitor.imported then
		cat9.dir_monitor[in_monitor] = nil
		in_monitor = nil
	else -- otherwise just remove the prompt tracking
		in_monitor.prompt = nil
	end
end

update_prompt =
function()
	if in_monitor then
		return in_monitor.prompt
	else
		return "dev:scm()"
	end
end

local function attach_prompt()
	local insert_ind

	for i,v in ipairs(config.prompt_focus) do
		if v == '$dynamic' then
			insert_ind = i
			break
		end
	end
	if not insert_ind then
		cat9.add_message("dev:scm prompt - config.prompt_focus lacks $dynamic slot")
	else
		table.insert(config.prompt_focus, insert_ind, "$begin")
		table.insert(config.prompt_focus, insert_ind+1, update_prompt)
		table.insert(config.prompt_focus, insert_ind+2, "$end")
		return true
	end
end

local function cmd_monitor(arg)
-- 'prompt' form
	local prompt = (arg and arg == "prompt") or nil

-- toggle prompt form on / off
	if in_monitor and in_monitor.prompt then
		if prompt then
			drop_prompt()
			return
		end
	end

-- necessary tracking: where we are
	local cdir = root:chdir()
	local job = {
		short = string.format("dev:scm monitor(%s)", cdir),
		raw = "dev:scm monitor",
		dir = cdir,
		scroll_lock = true,
		check_status = function() return true; end,
		prompt = prompt
	}

-- find where in the prompt we can attach
	if prompt then
		if not attach_prompt() then
			return
		end

-- already got a monitor session, mark prompt as available
		if in_monitor then
			in_monitor.prompt = prompt
			return
		end

-- or import the job as a 'proper' one
	else
		if in_monitor then
			if in_monitor.imported then -- unless it already is
				return
			end
			job = in_monitor
		end

		cat9.import_job(job)
		job.imported = true
		job.show_line_number = false
		job["repeat"] = refresh_monitor

		table.insert(
			job.hooks.on_destroy,
			function()
				job.imported = false

				if not job.prompt then -- only release if we don't also have a prompt monitor
					in_monitor = nil
					cat9.dir_monitor[job] = nil
				end
			end
		)
	end

	job.write_override = write_monitor
	job.handlers.mouse_button = monitor_click

-- attach to directory changes and use it to trigger rescan
	cat9.dir_monitor[job] =
		function(new, old)
			job.dir = new
			refresh_monitor()
		end

	in_monitor = job
	refresh_monitor()
end

local cmds =
{
	monitor = cmd_monitor
}

builtins.hint.scm = "Create a job tracking source-control state"

function suggest.scm(args, raw)
	if #args == 2 then
	end
end

function builtins.scm(cmd, ...)
	if cmd and cmds[cmd] then
		return cmds[cmd](...)
	end
end

end
