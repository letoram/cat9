return
function(cat9, root, builtins, suggest, views, builtin_cfg)

local list_envelopes_in_folder
local open_envelope

-- launch background probe for integration (himalaya now)
--   need to check version >= 1.0 due to interface break
--
-- then also for the separate tool that monitors, 'mirador'.
--
-- for viewing envelope, need to have a jobctl for the action view
-- that lets us wrap based on some width.
--
-- there is a query language on envelopes list that we can update:
--   subject [xxx] and/or body [xxx]
--   before, after, date : yyyy-mm-dd
--   from, to
--   flag
--
--   order by
--       [date | from | to | subject] [desc] [subcategory]
--
-- easiest to first have these as mail presets in config along with
-- some dynamic "step month, year"
--
-- 📎
-- command:
--  accounts
--  folders
--  flags
--  template
--  attachments
--  monitor
--  template
--  attachments
--  list
--  sort
--  watch
--
-- basic bringup:
--       properly formatted mailbox
--       action to open, open-in-new, reply, delete
--
-- reply inside EDITOR
--       action to view attachments
--
-- new, new-to (completion from known list or address book)
--
-- watch for changes into social
--
-- default 'on-load' action,
--
-- data filtering vs. tags?!
--
builtin_cfg = builtin_cfg.mail

local errors =
{
	prefix = "social:mail - ",
	no_accounts = "no accounts found",
	no_folder = "no matching folder",
	couldnt_run = "mail client doesn't respond",
	unknown_command = "unknown mail command",
	missing_argument = "missing argument",
	too_many_arguments = "too many arguments to command",
	list_envelopes = "couldn't list envelopes in mailbox",
	parse_envelopes = "couldn't parse json output"
}

if not builtin_cfg or not builtin_cfg.client then
	return
end

local mstate = {}

local function name_from_item(v)
	return v.from.name or (" < " .. v.from.addr .. " >")
end

local function args_for_cmd(...)
	local ret = {}
	for i,v in ipairs(builtin_cfg.client) do
		table.insert(ret, v)
	end
	for i,v in ipairs({...}) do
		table.insert(ret, v)
	end
	return ret
end

local function probe_accounts()
	local args = args_for_cmd("accounts", "list")
	mstate.accounts = {}

	args.handler =
	function(scan, _, code)
		if code == 0 then
			local json = cat9.json.decode(table.concat(scan.data, "\n"))
			for i,v in ipairs(json) do
				table.insert(mstate.accounts, v)
				if v.default and not mstate.account then
					mstate.account = v
				end
			end
		else
			cat9.add_message(errors.prefix .. errors.couldnt_run)
		end
	end

	cat9.background_chain({args}, {lf_strip = true}, nil)
end

probe_accounts()

local function add_retry_line(job, msg, func)
	job.data = {linecount = 0, bytecount = 0}
	job:add_line(
		msg,
		{
			action_words = {
				{
					"Retry",
					builtin_cfg.error,
					function(btn, mods)
						func()
					end
				}
			}
		}
	)
end

local function envelope_to_job(job, data)
-- if job has .folder then we need a back action
	job.data = {linecount = 0, bytecount = 0}
	local status, data =
		pcall(
			function()
				local msg = table.concat(data, "")
				return cat9.json.decode(msg)
			end
		)

	if not status then
		ioh:write(data)
		add_retry_line(job, errors.parse_envelopes,
			function()
				open_envelope(job, job.envelope, false)
			end
		)
		return
	end

-- these are column views (until its not) but not with an index
	local in_headers = true
	local hstart = 1
	local hend = 1
	local maxw = 1

	for i,v in ipairs(string.split(data, "\n")) do
		if #v ~= 0 then
			if not in_headers then
				job:add_line(v, {horizontal_step = 0})
			else
				local label, data = string.match(v, "(%a+:)%s(.+)")
				if label and data then
					maxw = #label > maxw and #label or maxw
					job:add_line(v,
						{
							columns =
							{
								{
									label = label,
									data = data,
									label_attr = builtin_cfg.header_label,
									data_attr = builtin_cfg.header_data,
								}
							}
						}
					)
-- should have action words here for reply, forward, write-to, copy, move also
-- need to parse <#part > and if we have [...](...) that should be moved to URL
-- somehow. It doesn't fit with the column approach so another thing to add to
-- action_job for future re-use.
				else
					in_headers = false
					hend = #job.data
					job:add_line("")
					job:add_line(v, {horizontal_step = 0})
				end
			end
		end
	end

	if hstart ~= hend then
		for i=hstart,hend do
			job.data.tags[i].columns[1].label_width = maxw
		end
	end
end

-- message [read]
-- thread doesn't work
--  reply
--  forward
--  writems
--  copy - folder
--  move - folder
--  delete
--
open_envelope =
function(job, ref, new)
	if new then
		cat9.new_window(job.root, "tui",
			function(wnd, new)
				if not new then
					open_envelope(job, ref, false)
				end
				local job =
				{
					raw = string.format("Mail:%s - %s", name_from_item(ref), ref.subject or ""),
					short = ref.id,
					check_status = cat9.always_active,
					show_line_number = false,
					scroll_lock = true,
					folder = job.folder,
					envelope = ref,
				}

				cat9.build_action_job(job)
				open_envelope(job, ref, false)
			end,
			builtin_cfg.new_mode
		)
		return
	end

	local args = args_for_cmd("message", "read",
		"-f", job.folder.name, "-a", mstate.account.name, ref.id)

	args.handler =
	function(scan, _, code)
		if code == 0 then
			envelope_to_job(job, scan.data, "")
		else
			cat9.add_message(errors.prefix .. errors.open_envelope)
		end
	end

	cat9.background_chain({args}, {lf_strip = false}, nil)
end

local function reply_envelope(job, envelope)

end

local function toggle_seen_envelope(job, envelope)

end

local function move_to_trash(job, envelope)

end

local function move_to_spam(job, envelope)
end

list_envelopes_in_folder =
function(job, folder, page)
	local args =
		args_for_cmd(
			"envelope", "list",
			"-f", folder,
			"--page", page, "--page-size", builtin_cfg.page_size
		)

	args.handler =
	function(scan, _, code)
		if code == 0 and scan.data.linecount > 0 then
			job.data = {linecount = 0, bytecount = 0}
			job.folder = {name = folder, page = page}

			local msg = table.concat(scan.data, "")
			local status, data = pcall(function()
				return cat9.json.decode(msg)
				end
			)

			if not status then
				add_retry_line(job, errors.parse_envelopes,
					function()
						list_envelopes_in_folder(job, folder, page)
					end
				)
				return
			end

-- Need a way for action_job to format column headers based on width, consuming
-- top row and toggle collapsed / sorting by clicking, flags to symbol or flags
-- to attribute mapping and arguments to hide.
--
-- Repeat action should rescan.
--
-- Configurable click action to open in existing job or spawn new (possibly
-- detached) one.
			job.data.column_index = 1
			for i,v in ipairs(data) do
				job:add_line(
					v.subject,
				{
					columns =
					{
						{
							label = "From: ",
							data = name_from_item(v),
							width = builtin_cfg.show_from,
						},
						{
							label = "Subject: ",
							data = v.subject or "",
							width = 0.8
						},
						{
							label = "Date: ",
							data = v.date or "",
						}
					},
					action_words = {
					{
						"Open",
						builtin_cfg.action,
						function(btn, mods)
							open_envelope(job, v, mods > 0)
						end,
						"Open in New",
					},
					{
						"Reply",
						builtin_cfg.action,
						function(btn, mods)
							reply_envelope(job, v)
						end
					},
					{
						"Toggle Seen",
						builtin_cfg.action,
						function()
							toggle_seen_envelope(job, v)
						end
					},
					{
						"Trash",
						builtin_cfg.strong_action,
						function()
							move_to_trash(job, v)
						end
					},
	-- need folder specific action as well
				}}
				)
			end
			cat9.flag_dirty(job)
		else
			add_retry_line(job, errors.list_envelopes,
				function()
					list_envelopes_in_folder(job, folder, page)
				end
			)
			cat9.add_message(errors.prefix .. errors.list_envelopes)
		end
	end

	cat9.background_chain({args}, {lf_strip = false}, nil)
end

function get_folders_for_account(account, closure)
	if not account.folders then
		account.folders = {pending = closure}
	elseif account.folders.pending then
		account.folders.pending = closure
		return
	end

	local args = args_for_cmd("folders", "list", "-a", account.name)
	args.handler =
	function(scan, _, code)
		if code == 0 then
			local json = cat9.json.decode(table.concat(scan.data, "\n"))
			for i,v in ipairs(json) do
				table.insert(account.folders, v.name)
			end
		else
			account.folders.error = code
		end
		local closure = account.folders.pending
		account.folders.pending = nil
		closure()
	end
	cat9.background_chain({args}, {lf_strip = true}, nil)
end

-- if we have an active monitor or get one in the future, attach to it, monitor
-- for e-mail events and alert with clickable reference

local cmd_sugg = {}
local cmd = {
	hint = {
		account = "Set active account",
		folder = "Open a folder in a new job",
		new = "Compose a new mail",
		search = "Search a mailbox"
	}
}

function cmd.account(name)
	local _, account = table.find_key_i(mstate.accounts, "name", name)
	if not account then
		return false, errors.no_account
	end

	mstate.account = account
end

function cmd.folder(arg)
	local name = table.remove(arg, 1)
	if not name then
		return false, errors.prefix .. errors.missing_argument
	end

	if not mstate.account.folders then
		get_folders_for_account(mstate.account,
			function()
				cmd.folder(name)
			end
		)
		return
	end

	local _, folder = table.find_i(mstate.account.folders, name)

	if not folder then
		return false, string.format("%s%s %s", errors.prefix, errors.no_folder, name)
	end

	local job = {
		raw = string.format("Mail:%s - %s", mstate.account.name, name),
		short = name,
		check_status = cat9.always_active,
		folder = folder,
		show_line_number = false,
		scroll_lock = true
-- missing: tbar actions for sorting, convert to action-words while scanning
	}

	cat9.build_action_job(job)
	job:add_line("Scanning...")
	list_envelopes_in_folder(job, name, 1)
end

function cmd_sugg.folder(args, raw)
	if #args > 1 then
		cat9.add_message(errors.prefix .. errors.too_many_arguments)
		return false, 13 + #args[1] -- folder name XXX
	end

	local set = {}
	if not mstate.account.folders then
		get_folders_for_account(mstate.account,
			function()
				cmd_sugg.folder(args, raw)
			end
		)
		return
	end

	cat9.readline:suggest(
		cat9.prefix_filter(mstate.account.folders, args[1]), "word")
end

function cmd_sugg.account(args, raw)
	if #args > 1 then
		cat9.add_message(errors.prefix .. errors.too_many_arguments)
		return false, 14 + #args[1] -- account name XXXX
	end

	local set = {}
	for i,v in ipairs(mstate.accounts) do
		table.insert(set, v.name)
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[1]), "word")
end

function suggest.mail(args, raw)
	if #raw == 4 then
		return
	end

-- sanity check
	if #mstate.accounts == 0 then
		cat9.add_message(errors.prefix .. errors.no_accounts)
		return false, 0
	end

-- just forward to cmd_sugg if we have a valid command
	table.remove(args, 1)
	if #args > 1 then
		if cmd_sugg[args[1]] then
			local cmd = table.remove(args, 1)
			return cmd_sugg[cmd](args)
		end
		cat9.add_message(errors.prefix .. errors.unknown_command)
		return false, 5
	end

-- flatten / expand basic commands
	local set = {
		hint = {}
	}

	for k,v in pairs(cmd.hint) do
		table.insert(set, k)
		table.insert(set.hint, v)
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[1]), "word")
end

function builtins.mail(...)
	local argv = {...}
	local action = table.remove(argv, 1)
	if cmd[action] then
		return cmd[action](argv)
	end
	return false, errors.prefix .. errors.unknown_command
end

end
