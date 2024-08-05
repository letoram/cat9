-- similar to jobmeta, possible entries that can be referenced in
-- config.lua to generate the dynamic prompt.

return
function(cat9, root, config)

local battery =
{
	state =
	{
		current_now = 0,
		voltage_now = 0,
		power_now = 0
	},
	failed = false,
}

function battery.enable(self)
	if self.ok then
		return true
	end

	local dev = self:device("/uevent")
	if dev then
		dev:close()
	end
	return not battery.failed
end

function battery.percent(self)
	local now = tonumber(self.state.charge_now)
	local tot = tonumber(self.state.charge_full)

	if not now then
		now = tonumber(self.state.energy_now)
		tot = tonumber(self.state.energy_full)
	end

	if now and tot and now > 0 and tot > 0 then
		return math.min(math.ceil(now / tot * 100), 100)
	end
end

function battery.device(self, suffix)
	local names = {"BAT0", "BAT1", "BATT", "BATC"}

	if self.ok then
		return root:fopen(self.path.. suffix, "r")
	elseif self.failed then
		return
	end

	for _,v in ipairs(names) do
		self.path = "/sys/class/power_supply/" .. v
		dev = root:fopen(self.path.. suffix, "r")
		if dev then
			self.ok = true
			break
		end
	end
	return dev
end

function battery.charging(self)
	local prefix = ""

	if not self.state.status then
		return nil, "?"
	end

	if self.state.status == "Charging" then
		return true, "+"
	end

	if self.state.status == "Discharging" then
		return false, "-"
	end

	if self.state.status == "Not Charging" then
		return false, "!"
	end

	if self.state.status == "Full" then
		return nil, "*"
	end

	return nil, ""
end

function battery.synch(self)
-- update uevent every second
	if self.state.last and cat9.time - self.state.last < 25 then
		return
	end

	local dev = self:device("/uevent")
	if not dev then
		return ""
	end

	local line = true
	local state = {
		last = cat9.time
	}
	alive = true

-- spin/read everything and split out the k/v into a table
	while line do
		line = dev:read(false)
		if line then
			local k, v = string.match(string.trim(line), 'POWER_SUPPLY_(.-)=(.*)')
			if k then
				state[string.lower(k)] = v
			end
		end
	end
	dev:close()

-- current and power aren't guaranteed - calculate if necessary
	if state.current_now then
		state.voltage_now = tonumber(state.voltage_now) * 1e-6
		state.current_now = tonumber(state.current_now) * 1e-6
		state.power_now = state.current_now * state.voltage_now
		self.state = state

	elseif state.voltage_now and state.power_now then
		state.voltage_now = tonumber(state.voltage_now) * 1e-6
		state.power_now = tonumber(state.power_now) * 1e-6
		state.current_now = state.power_now / state.voltage_now
		self.state = state
	else
		state.voltage_now = 0
		state.power_now = 0
		state.current_now = 0
	end
end

cat9.promptmeta["chord_state"] =
function()
	return cat9.in_chord and "(C)" or ""
end

cat9.promptmeta["lastdir"] =
function()
	return #cat9.lastdir > 0 and cat9.lastdir or "/"
end

cat9.promptmeta["jobs"] =
function()
	return tostring(cat9.activevisible)
end

cat9.promptmeta["battery_power"] =
function()
	battery:synch()
	return string.format(
		"%.0f", battery.state.current_now * battery.state.voltage_now
	)
end

cat9.promptmeta["battery_pct"] =
function()
	battery:synch()
	local num = battery:percent()

	if not num or num <= 0 then
		return "? %"
	end

	return string.format("%.0f",num)
end

cat9.promptmeta["builtin_name"] =
function()
	if not cat9.builtin_name or cat9.builtin_name == "default" then
		return ""
	else
		return cat9.builtin_name
	end
end

cat9.promptmeta["builtin_status"] =
function()
	if cat9.builtins["_status"] then
		return cat9.builtins["_status"]()
	end
end

cat9.promptmeta["battery_charging"] =
function()
	battery:synch()
	local _, ch = battery:charging()
	return ch
end
end
