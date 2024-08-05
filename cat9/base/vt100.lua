-- support script for vt"100" state machine
--
-- to eventually evolve into a more complete terminal emulator for the !!
-- execution mode, but focus for now is just getting basic formatting to work.
--
-- the structure is built / modelled after vt100.net/emu/dec_ansi_parser (the
-- vt500 series parser by paul flo williams).
--

local esc_lut = {}
local esc_direct_lut = {}
local c0c1_lut = {}
local gnd_lut = {}

local csi_lut = loadfile(
	string.format("%s/cat9/base/vt100_csi.lua", lash.scriptdir))()

local osc_lut = {}
local dsc_lut = {}

-- special, contains the 'can come from anywhere' transitions
local any_lut = {}

-- track any seen commands that we lack an implementation for
local missing = { csi = {} }

local enter_esc, enter_osc, enter_csi, enter_dsc

-- helpers for building the state tables
local
function set_range(dst, state, tbl)
	for _,v in ipairs(tbl) do
		dst[v] = state
	end
end

local
function get_range(low, high)
	local res = {}
	while low <= high do
		table.insert(res, low)
		low = low + 1
	end
	return res
end

-- default catch all state
local
function state_gnd(state, dst, ch, val)
	if gnd_lut[val] then
		gnd_lut[val](state, dst, ch, val)
		return state_gnd
	end

-- 0x80+
	if val >= 0x20 then
		table.insert(dst, ch)
	end

	return state_gnd
end

local
function exec_esc(state, dst, ch, val)
-- 20-2f: collect
	if val >= 0x20 and val <= 0x2f then
		table.insert(state.esc, val)
		return exec_esc
	end

-- 30-7e: dispatch
	if esc_lut[val] then
		esc_lut[val](state, dst, ch, val)
		return val >= 0x30 and exec_gnd or exec_esc
	end

-- transitions:
-- osc, dsc, apc: mask c0c1
	if val == 0x5d then
		return enter_osc
	elseif val == 0x5b then
		return enter_csi
	elseif val == 0x50 then
		return enter_dsc
	elseif val == 0x58 or val == 0x5e or val == 0x5f then
		return enter_apc
	end

-- ignore
	if val == 0x7f then
		return exec_esc
	end

-- and the default fallbacks
	return any_lut[val] or exec_esc
end

local
function
csi_ignore(state, dst, ch, val)
	if val >= 0x40 and val <= 0x7e then
		return state_gnd
	end
	return csi_ignore
end

local
function
csi_dispatch(state, dst, ch, val)
	if #state.csi.collect > 0 then
		table.insert(state.csi.param, state.csi.collect)
		state.csi.collect = ""
	end

	if csi_lut[val] then
		csi_lut[val](state, dst, state.csi)
	else
		if not missing.csi[val] then
			missing.csi[val] = true
			print(string.format("EIMPL: CSI(%x)", val))
		end
	end
	return state_gnd
end

local
function
csi_param(state, dst, ch, val)
	if ch == ';' then
		table.insert(state.csi.param, state.csi.collect)
		state.csi.collect = ""
		return csi_param

-- perhaps go for separate table here
	elseif ch == ':' then
	end

	if val == 0xa or (val >= 0x3c and val <= 0x3f) then
		return csi_ignore

	elseif val >= 0x40 and val <= 0x7e then
		return csi_dispatch(state, dst, ch, val)
	end

	state.csi.collect = state.csi.collect .. ch
	return csi_param
end

local
function
exec_csi(state, dst, ch, val)
	if val == 0x3a then
		return csi_ignore

-- dispatch
	elseif val >= 0x40 and val <= 0x7e then
		return csi_dispatch(state, dst, ch, val)

-- collect (0x3c-0x3f)
	elseif val >= 0x20 and val <= 0x2f then
		state.csi.collect = state.csi.collect .. ch
		return csi_param

-- step parameter (0x30 - 0x39, 0x3b)
	elseif val >= 0x30 and val <= 0x39 or val == 0x3b then
		return csi_param(state, dst, ch, val)
	end

	return state_gnd
end

enter_csi =
function(state, dst, ch, val)
	state.csi = {collect = "", param = {}}
	state.mask_c0c1 = false
	return exec_csi
end

enter_esc =
function(state, dst, ch, val)
	state.esc = {}
	state.mask_c0c1 = false
	return exec_esc
end

enter_osc =
function(state, dst, ch, val)
	state.mask_c0c1 = true
	if val == 0x9c then
		return state_gnd
	end
	return enter_osc
end

enter_dcs =
function(state, dst, ch, val)
	state.mask_c0c1 = true
	if val == 0x9c then
		return state_gnd
	end
	return enter_dcs
end

-- won't actually be executed, it's a non-state prefilter to any ch
local
function state_c0c1(state, dst, ch, val)
end

local function state_any(state, dst, ch, val)
	table.insert(dst, ch)
	return state_any
end

local state_lut = {
	[state_any] = "any",
	[state_c0c1] = "c0c1",
	[enter_osc] = "osc-in",
	[enter_esc] = "esc-in",
	[enter_dcs] = "dcs-in",
	[state_gnd] = "gnd",
	[exec_esc] = "esc",
	[csi_param] = "csi-param",
	[csi_ignore] = "csi-ign",
}

-- [from anywhere, execute:]
set_range(any_lut, state_gnd, {0x18, 0x1a, 0x99, 0x9a})
set_range(any_lut, state_gnd, get_range(0x80, 0x8f))
set_range(any_lut, state_gnd, get_range(0x91, 0x97))
set_range(any_lut, enter_apc, {0x98, 0x9e, 0x0f})
any_lut[0x1b] = enter_esc
any_lut[0x9d] = enter_osc
any_lut[0x90] = enter_dcs
set_range(c0c1_lut, state_c0c1, get_range(0x00, 0x17))
set_range(c0c1_lut, state_c0c1, {0x19, 0x1c, 0x1d, 0x1f})

-- return a table of format attr+strings tables for passing to
-- tui:write (when necessary), along with the raw 'stripped' data
local
function parse_vt100(state, data)
	local inbuf = state.buffer_raw
	local statefn = state_any

-- run through the state machine,
-- this will populate buffer_raw with the production results (line-mode)
-- and buffer_fmt with [buffer_raw_index, formattbl]
	state.cat9.each_ch(
		data,
		function(ch, pos)
			local val = string.byte(ch)
			local newstate
-- alter parser state accordingly
			if any_lut[val] then
				newstate = any_lut[val](state, inbuf, ch, val)
-- otherwise process the state
			else
				newstate = statefn(state, inbuf, ch, val)
			end

			if newstate and newstate ~= statefn then
--				print("state transition", newstate, ch, val)
				statefn = newstate
			end

-- or if we need to exit out from anywhere
			if state.short then
				statefn = state_gnd
				state.short = false
			end
		end,
		state.on_error
	)

	local res = state.buffer_raw
	local fmt = state.buffer_fmt

	state.buffer_raw = {}
	state.buffer_fmt = {}

	return table.concat(res, ""), fmt
end

return function(cat9, root, config)
	cat9.vt100_state =
	function()
		local state =
		{
			config = config,
			cat9 = cat9,
			root = root,
			line_mode = true,
			consume = parse_vt100,
			parser_state = ground,
			buffer_raw = {},
			buffer_fmt = {},
			default_attr =
			{
				fc = tui.colors.text,
				bc = tui.colors.text
			},
			on_error = function() end,
		}
		return state
	end
end
