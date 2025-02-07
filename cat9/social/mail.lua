return
function(cat9, root, builtins, suggest, views, builtin_cfg)

-- launch background probe for integration (himalaya now)
-- command:
--  accounts
--  folders
--  flags
--  template
--  attachments
--  search
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
-- default 'on-load' action
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
	too_many_arguments = "too many arguments to command"
}

if not builtin_cfg or not builtin_cfg.client then
	return
end

local mstate = {}

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
	local args = args_for_cmd("accounts")
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
	job.add_line(
		errors.list_envelopes,
		{
			action_words = {
				{
					"Retry",
					builtin_cfg.error,
					function()
						func()
					end
				}
			}
		}
	)
end

function list_envelopes_in_folder(job, folder, page)
	local args =
		args_for_cmd(
			"list",
			"-f", folder,
			"--page", page, "--page-size", builtin_cfg.page_size
		)

-- list -f folder -o json -p page
-- id: flags["Seen"]
-- subject: ...
-- from: {name, addr}
-- date: ...
	args.handler =
	function(scan, _, code)
		if code == 0 and scan.data.linecount > 0 then
			job.data = {linecount = 0, bytecount = 0}
			local msg = table.concat(scan.data, "")
			local status, data = pcall(function()
				return cat9.json.decode(msg)
				end
			)

			if not status then
				add_retry_line(job, errors.list_envelopes,
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
							data = v.from.name or (" < " .. v.from.addr .. " >"),
							width = builtin_cfg.show_from,
						},
						{
							label = "Subject: ",
							data = v.subject or "",
						}
					}
				}
				)
			end
			cat9.flag_dirty(job)
		else
			add_retry_line(job, errors.list_envelopes,
				function()
					list_envelopes_in_folder(job, folder, page)
				end
			)
			cat9.add_message(errors.prefix .. errors.couldnt_list)
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

	local args = args_for_cmd("folders", "-a", account.name)
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
