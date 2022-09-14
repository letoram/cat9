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
	table.insert(dev.pending, {cmd, res})

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

local function add_ent(dev, bssid, freq, sig, fl, ssid)
	if not bssid or not ssid then
		return
	end

	if not dev.results then
		dev.results = {}
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
	if dev.results[bssid] then
		add_job_data(dev, "BSSID collision in response for " .. bssid, true)
	else
		dev.results[bssid] =
		{
			ssid = ssid,
			bssid = bssid,
			frequency = freq,
			strength = sig,
			flags = fl
		}
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

-- WPS-AP-AVAILABLE-AUTH
-- CTRL-EVENT-REGDOM-CHANGED
mon_cmd["WPS-AP-AVAILABLE"] =
function(job, arg1, arg2, arg3)
end

mon_cmd["CTRL-EVENT-NETWORK-NOT-FOUND"] =
function(job, arg1, arg2)
end

local function parse_mon(dev, data)
	if data == "OK\n" then
		return
	end

	local ents = string.split(data, "<3>")
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
		if not root.wpa_devs["_default"] then
			root.wpa_devs["_default"] = dev
		end

-- one connection for oob data, this is not line-buffered but separated
-- with <3> because wpa_supplicant is what it is ...
		dev.mon:lf_strip(false)
		dev.mon:write("ATTACH")
		dev.mon:data_handler(dh_from_con(dev, dev.mon, fn, parse_mon, true))
		dev.mon:flush(-1)

-- while data_handler is typically line-buffered, there are different
-- terminators for depending on commands, e.g. OK\n not provided for
-- SCAN_RESULTS
		dev.con:lf_strip(false)
		dev.con:data_handler(dh_from_con(dev, dev.con, fn, parse))
		scan_device(dev)
	end
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
function builtins.wifi(dev, ...)


	builtins["_default"] =
	function(args)
		local strset, err = cat9.expand_string_table(args)

		if err then
			cat9.add_message(err)
			return
		end

		local dev = root.wpa_devs["_default"]
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
				if status == true then
					add_job_data(dev, set)
				elseif status == false then
					add_job_data(dev, msg or (cmd .. " failed (unknown error)"))
				end
			end
		)
	end
end

function suggest.wifi(args, raw)
-- do we want to add/remove/connect/disconnect/rescan/monitor
	if args[2] and not args[3] then
-- connect [complete ssid] monitor key ""
-- define [ssid | bssid] [psk] ..
-- status
	elseif args[3] and not args[4] then
		if args[2] ~= "connect" then
			cat9.add_message(string.format(
				"builtin:network - wifi: unexpected command (%s)", args[2]
			))
			return
		end

-- when committing, send adding to..
	end
end

end
