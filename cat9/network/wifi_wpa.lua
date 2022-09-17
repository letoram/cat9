-- wifi [dev=_default] connect -> ssid, authopt.
--                     disconnect
--                     auto [ssid1, ssid2, ssid3, ...]
--                     power [on, off, low, ...]
--                     status [on, off or just toggle]
--
-- 0. handle existing networks on the device
-- 1. 2.4GHz v. 2.5GHz on the same device
-- a. need to interface with dhcp as well to control things on that end
-- b. commands for AP setup
-- c. commands for P2P discovery
-- d. macchanger (really just SIOCSIFHWADDR)
-- e. dynamic pollrate / signal strength plot and throughput
-- f. vpn integration on top of that? tor?
-- g. dpp? qr?
-- h. captive portal detection?
--

return
function(cat9, root, builtins, suggest, argv)

local scanarg = {"/usr/bin/ls", "cat9-wifi", "/var/run/wpa_supplicant"}

-- for command passthrough, having a separate job that absorbs the
-- replies (with possible command) helps a bit
local function add_job_data(dev, msg, bad)
	local job
	if not dev.sponge then
		job =
		{
			short = "Wifi:" .. dev.name,
			raw = "Wifi: " .. dev.name,
			attr_lookup = attr_lookup,
			badlines = {}
		}
		cat9.import_job(job)
		dev.sponge = job
	else
		job = dev.sponge
	end

	if type(msg) == "table" then
		for _,v in ipairs(msg) do
			table.insert(job.data, v)
			job.data.linecount = job.data.linecount + 1
			job.data.bytecount = job.data.bytecount + #v
		end
	elseif type(msg) == "string" then
		table.insert(job.data, msg)
		job.data.linecount = job.data.linecount + 1
		job.data.bytecount = job.data.bytecount + #msg
	end

	if bad then
		job.badlines[job.data.linecount] = true
	end

	cat9.flag_dirty()
end

-- add the job to the outgoing pending queue, and dispatch if we
-- don't have anything outbound already
local function queue_rep(dev, cmd, res)
	table.insert(dev.pending, {cmd, res or function() end})

	if #dev.pending == 1 then
		dev.con:write(cmd)
		dev.con:flush(-1)
	end
end

-- Ingoing data on the command socket, since this is using DGRAM they rely on
-- not being chunked or short so the termination between jobs is strictly on
-- reading. This means that we need to treat it as serial and assume that when
-- we get no more data it is good to go.
local function parse(dev, data)
	local dst = table.remove(dev.pending, 1)
	if not dst then
		return
	end

	dst[2](data)
	if not dev.pending[1] then
		return
	end

-- dispatch next queued request
	dev.con:write(dev.pending[1][1])
	dev.con:flush(-1)
end

local function hex_decode(ssid)
	local pos = string.find(ssid, "\\x")

	if not pos then
		return ssid
	end

	local epos = pos
	local out = {}

	for i=pos,#ssid,4 do
		if string.sub(ssid, i, i+1) == "\\x" and
			string.sub(ssid, i, i+3) then

			local num = tonumber( string.sub(ssid, i+2, i+3), 16 )

			if not num then
				break
			end

			table.insert(out, string.char(num))
			epos = i+4
		else
			break
		end
	end

	local out_pre = ""
	if pos > 1 then
		out_pre = string.sub(ssid, 1, pos-1)
	end
	local out_suf = string.sub(ssid, epos)

-- and recurse without this sequence in the string
	return hex_decode(out_pre .. table.concat(out, "") .. out_suf)
end

local function add_ent(dev, bssid, freq, sig, fl, ssid)
	if not bssid or not ssid then
		return
	end

	if not dev.bssid then
		dev.bssid = {}
		dev.ssid = {}
	end

--
-- flags is context-sensitive [] though the amount of patterns seem limited
-- enough that we should just preset it (e.g. WPA-PSK-TKIP+CCMP WPS ESS)
--
-- need to read up some on bssid verification when switching between nets..
--
-- if we don't have a network and one appears from saved context/state,
-- here is the place to add_network and set it up..
--
	local known = false
	if dev.bssid[bssid] then
		if ssid ~= dev.bssid[bssid].ssid_raw then
			print(ssid, dev.bssid[bssid].ssid_raw)
			add_job_data(dev, "BSSID collision in response for " .. bssid, true)
			return
		end

		known = true
-- otherwise we might just have an update
	end

	local empty = string.match(ssid, "%s+")
	empty = (not ssid or #ssid == 0) or
		       (empty and #empty == #ssid)

	if empty then
		ssid = "(" .. bssid .. ")"
	end

-- hex decode is needed in the cases where there are \xaa\xcc like encoded
-- characters, part of emoji-ssid-fun.
	dev.bssid[bssid] =
	{
		empty_ssid = empty,
		ssid = hex_decode(ssid),
		ssid_raw = ssid,
		bssid = bssid,
		frequency = freq,
		strength = tonumber(sig) or -128,
		flags = fl,
		timestamp = cat9.time
	}

	ssid = dev.bssid[bssid].ssid

	if dev.ssid[ssid] then
		local found = false
		for _,v in ipairs(dev.ssid[ssid]) do
			if v == bssid then
				found = true
				break
			end
		end

		if not found then
			table.insert(dev.ssid[ssid], bssid)
		end
	else
		dev.ssid[ssid] = {bssid}
	end

end

-- shell out to wpa_passphrase? (ssid + pw)
-- empty password == key_mgmt NONE

local function scan_device(dev)
	dev.timestamp = cat9.time
	queue_rep(dev,
		"SCAN_RESULTS",
		function(set, status, msg)
			local ents = string.split(set, "\n")
			if #ents <= 1 then
				add_job_data(dev, "Scan: no responses", true)
				return
			end

			dev.old_results = dev.results
			dev.results = {}

-- this is fixed: bssid \t frequence \t signal \t flags \t ssid so strip header
			table.remove(ents, 1)
			for _,v in ipairs(ents) do
				local args = string.split(v, "\t")
				if #args >= 5 then
					local args = string.split(v, "\t")
					add_ent(dev, args[1], args[2], args[3], args[4], args[5])
				end
			end
		end
	)
end

-- known OOB results and respective actions
local mon_cmd = {}
mon_cmd["CTRL-EVENT-SCAN-STARTED"] =
function(dev, args)
	dev.in_scan = true
end

-- request the results and update our cache
mon_cmd["CTRL-EVENT-SCAN-RESULTS"] =
function(dev, args)
	dev.in_scan = false
	scan_device(dev)
end

mon_cmd["CTRL-EVENT-BSS-ADDED"] =
function(job, arg1, arg2, arg3)
end

mon_cmd["CTRL-EVENT-BSS-REMOVED"] =
function(job, arg1, arg2, arg3)
end

mon_cmd["CTRL-EVENT-REGDOM-CHANGE"] =
function(job, init, rtype)
-- init=BEACON_HINT or CORE
-- type=UNKNOWN or WORLD
--
end

-- WPS-AP-AVAILABLE-AUTH
-- CTRL-EVENT-REGDOM-CHANGED
mon_cmd["WPS-AP-AVAILABLE"] =
function(job, arg1, arg2, arg3)
end

mon_cmd["CTRL-EVENT-NETWORK-NOT-FOUND"] =
function(job, arg1, arg2)
	add_job_data(job, "couldn't find network")
end

mon_cmd["CTRL-EVENT-NETWORK-ADDED"] =
function(job, net)
-- we already get response to our own add requests though
end

mon_cmd["WPS-AP-AVAILABLE-AUTH"] =
function(job)
-- how do we distinguish ok from failure?
end

mon_cmd["CTRL-EVENT-DISCONNECTED"] =
function(job)
-- trigger to update status
end

mon_cmd["CTRL-EVENT-CONNECTED"] =
function(job)
-- trigger to update status
end

mon_cmd["CTRL-EVENT-SUBNET-STATUS-UPDATE"] =
function(job)
end

mon_cmd["SME:"] =
function(job)
end

mon_cmd["Trying"] =
function(job)
end

mon_cmd["Associated"] =
function(job)
end

mon_cmd["OK"] =
function(job)
end

local function parse_mon_line(dev, line)
	local ents = string.split(line, "<3>")
	for _,v in ipairs(ents) do
		if #v > 0 then
			local set = string.split(v, "%s")
			if #set == 0 then
			elseif mon_cmd[set[1]] then
				mon_cmd[set[1]](dev, unpack(set, 2))
			else
				add_job_data(dev, "Unknown control event: " .. v, true)
			end
		end
	end
end

local function parse_mon(dev, data)
	for _,v in ipairs(string.split(data, "\n")) do
		parse_mon_line(dev, v)
	end
end

local function drop_interface(dev, fn)
	root.wpa_devs[fn] = nil
	dev.con:write("DISCONNECT")
	dev.con:close()
end

-- Just read until there is no more data to be read and assume this belongs to
-- the same reply. Might need to add a timeout as well and keep going between
-- calls. When finished, dispatch the next command.
local function dh_from_con(dev, ud, fn, parse, nonbuf)
	return
	function()
		local data = {}
		local inb

		repeat
			inb, _ = ud:read(nonbuf)
			table.insert(data, inb)
		until not inb

		parse(dev, table.concat(data, ""))
		return true
	end
end

local function reprobe(fn)
	local con = root.wpa_devs[fn]

	if not con then
		local fpath = "/var/run/wpa_supplicant/" .. fn
		local mon = root:fopen(fpath, "unix")
		if not mon then
			cat9.add_message("net:wifi - couldn't open socket at " .. fn)
			return
		end

		local dev =
		{
			name = fn,
			con = root:fopen(fpath, "unix"),
			mon = mon,
			con_in = {},
			pending = {}
		}

-- track the first one and assume that is the 'targeted' interface
		root.wpa_devs[fn] = dev
		if not root.wpa_devs["=default"] then
			root.wpa_devs["=default"] = dev
		end

-- one connection for oob data, this is not line-buffered but separated
-- with <3> because wpa_supplicant is what it is ...
		dev.mon:lf_strip(false)
		dev.mon:write("ATTACH")
		dev.mon:data_handler(dh_from_con(dev, dev.mon, fn, parse_mon, true))
		dev.mon:flush(-1)

-- While data_handler is typically line-buffered, there are different
-- terminators for depending on commands, e.g. OK\n not provided for
-- SCAN_RESULTS.
		dev.con:lf_strip(false)
		dev.con:data_handler(dh_from_con(dev, dev.con, fn, parse))
		queue_rep(dev, "SCAN")
	end
end

local function poll_device_signal(dev)
-- this will give:
-- RSSI=-n
-- LINKSPEED=
-- NOISE=n (or 9999)
-- FREQUENCY=
-- WIDTH=
-- CENTER_FRQ1=
-- AVG_RSSI=-
--
	queue_rep(dev, "SIGNAL_POLL",
		function(set, status, msg)
			local lines = table.split(set, "\n")
			local kvs = {}
			for _,v in ipairs(lines) do
				local kvp = string.split(v, "=")
				kvs[kvp[1]] = kvp[2] or true
			end
		end
	)
end

local function poll_device_status(dev)
-- this
end

-- blocklisting would go here
local function new_device(fn)
	reprobe(fn)
end

local function lost_device(fn)
end

local function scan_paths()
-- store state here as builtin swapping will cause us to reload
	if not root.wpa_paths then
		cat9.set_scanner(scanarg,
			function(data)
				if not data then
					return
				end
				if #data == 0 then
					cat9.add_message("net:wifi - no supplicant socket found")
					return
				end
				root.wpa_paths = data
				root.wpa_devs = {}

				for _,v in ipairs(data) do
					new_device(v)
				end
			end
		)
-- interfaces may come and go, low n so just brute force it
	else
		cat9.set_scanner(scanarg,
			function(data)
				if not data then
					return
				end
				local known = {}

				for k, _ in ipairs(root.wpa_paths) do
					table.insert(known, k)
				end

-- anything left in known is now 'lost' and if it wasn't removed we have new
				for _,v in ipairs(data) do
					if not cat9.remove_match(known, v) then
						table.insert(root.wpa_paths, v)
						new_device(v)
					end
				end
			end
		)
	end
end

scan_paths()

-- color-code the separate results,
-- having it as an alternate data stream makes less sense here
local function attr_lookup(job, set, i, pos, highlight)
	return (highlight or job.badlines[i])
		and config.styles.data_highlight or config.styles.data
end

--
-- [dev (last or only possible)]
--  some controls to expose -
--   monitor (poll scan and update with differences)
--
function builtins.wifi(...)
	local args = {...}
	local dev = "=default"

	if args[1] == "device" then
		if not args[2] or not root.wpa_devs[args[2]] then
			cat9.add_message("builtin:network - wifi device >name< unknown or missing")
			return
		end
		table.remove(args, 1)
		dev = table.remove(args, 1)
	end

	if args[1] == "connect" then
		if not args[2] then
			cat9.add_message("builtin:network - wifi connect >ssid< missing")
			return
		end

		dev = root.wpa_devs[dev]
		if not dev then
			cat9.add_message("builtin:network - wifi device missing: ", dev)
			return
		end

-- go through bssid to get the ssid_raw in order for hexencoded to be fed back
-- into the string used to create the network
		local bssid = dev.ssid[args[2]]
		if not bssid then
			cat9.add_message("builtin:network - uknown ssid: ", args[2])
		end

		local key = args[3]

-- check the flags if we need a passport
		local tgt = dev.bssid[bssid[1]]

		queue_rep(dev,
			"ADD_NETWORK",
			function(set, status, msg)
				local id = tonumber(set)
				if not id then
					add_job_data(dev, "couldn't create new network", true)
					return
				end

-- set ssid or bssid, just dispatch this ignoring, results, monitor will tell us
				queue_rep(dev,
					string.format("SET_NETWORK %d ssid \"%s\"", id, tgt.ssid),
					function(set)
						if set == "FAIL\n" then
							cat9.add_message("builtin:network - ssid rejected")
						end
					end
				)

-- if there is no password needed, key management need to be manually disabled
				if key then
					queue_rep(dev, string.format("SET_NETWORK %d psk \"%s\"", id, key))
				else
					queue_rep(dev, string.format("SET_NETWORK %d key_mgmt NONE", id))
				end
				queue_rep(dev, string.format("ENABLE_NETWORK %d", id))
			end
		)

-- Now can create the network, then set the ssid and the password or generate
-- the ssid | password psk to lookup and re-inject.

	else
		cat9.add_message("builtin:network - missing command")
		return
	end
end

builtins["_default"] =
function(args)
	local strset, err = cat9.expand_string_table(args)

	if err then
		cat9.add_message(err)
		return
	end

	local dev = root.wpa_devs["=default"]
	if not dev then
		cat9.add_message("builtin:network - no default device receiver")
		return
	end

-- wpa commands are always uppercase
	if strset[1] then
		strset[1] = string.upper(strset[1])
	end

-- share implementation / parser with other modes
	if strset[1] == "SCAN" then
		scan_device(dev)
		return
	end

	local cmd = table.concat(strset, " ")

	queue_rep(dev, cmd,
		function(set, status, msg)
				add_job_data(dev, cmd .. ":")
				local set = string.split(set, "\n")
				for i, v in ipairs(set) do
					set[i] = "  " .. string.gsub(v, "\t", "    ")
				end

				add_job_data(dev, set)
				add_job_data(dev, "")
		end
	)
end

function suggest.wifi(args, raw)
-- args[2] can be device otherwise we assume first and just go with results

	local dev = "=default"
	local set = {}
	local argi = #args
	local carg = args[argi]

	if argi <= 2 then
		table.insert(set, "dev");
		table.insert(set, "connect");
		cat9.readline:suggest(cat9.prefix_filter(set, carg), "word")
		return
	end

-- dev or just assume default?
	if args[2] == "dev" then
		if argi < 4 then
			for k,v in pairs(root.wpa_devs) do
				table.insert(set, k)
			end
			table.sort(set)
			cat9.readline:suggest(cat9.prefix_filter(set, carg), "word")
			return
		end
		dev = args[3]
	elseif args[2] ~= "connect" then
		cat9.add_message(string.format(
			"builtin:network - wifi: unexpected command (%s)", args[2]
		))
		return
	end

	if not root.wpa_devs[dev] then
		cat9.add_message(string.format(
			"builtin:network - wifi: unknown device (%s)", dev))
		return
	end

-- allow either query (=prompt) for psk, last known psk (=last)
	if args[2] == "connect" or args[3] == "connect" then
	end

-- sort not by name but by signal, and add the signal to the hint set
	local dev = root.wpa_devs[dev]
	if not dev.bssid then
		return
	end

	local function find_best(list)
		local best = dev.bssid[list[1]]
		for _,v in ipairs(list) do
			if dev.bssid[v].strength > best.strength then
				best = dev.bssid[v]
			end
		end
		return best
	end

-- there can be 1:* bssid to ssid, add only the best strength one and sort on that
	local tmp = {}
	for k,v in pairs(dev.ssid) do
		table.insert(tmp, {k, find_best(v).strength})
	end

	table.sort(tmp, function(a, b) return a[2] > b[2]; end)

	set.hint = {}
	for _,v in ipairs(tmp) do
		local ssid = v[1]

		table.insert(set, ssid)
		set.hint[#set] =
			string.format(
				"(%s%s)",
				#dev.ssid[ssid] > 1 and (tostring(#dev.ssid[ssid]) .. "x:") or "",
				v[2]
			)
	end

	cat9.readline:suggest(cat9.prefix_filter(set, carg), "word", "\"", "\"")
end

end
