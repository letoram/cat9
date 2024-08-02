local tb = tui.colors.ui + 1
local sgr_attr_lut =
{
	[1] = {"bold",          true},
	[2] = {"dim",           true}, -- 1*
	[3] = {"italic",        true},
	[4] = {"underline",     true},
	[5] = {"blink",         true},
	[6] = {"blink",         true},
	[7] = {"inverse",       true},
	[8] = {"conceal",       true}, -- 1*
	[9] = {"strikethrough", true},
	[21]= {"underline_alt", true},
	[22] = {"bold",         false},
	[23] = {"dim",          false}, -- 1*
	[24] = {"italic",       false},
	[25] = {"underline",    false},
	[26] = {"blink",        false},
	[27] = {"blink",        false},
	[28] = {"inverse",      false},
	[29] = {"conceal",      false}, -- 1*
	[30] = {"fc", tb+0},
	[31] = {"fc", tb+1},
	[32] = {"fc", tb+2},
	[33] = {"fc", tb+3},
	[34] = {"fc", tb+4},
	[35] = {"fc", tb+5},
	[36] = {"fc", tb+6},
	[37] = {"fc", tb+7},
	[39] = {"fc", TUI_COL_PRIMARY},
	[40] = {"bc", tb+0},
	[41] = {"bc", tb+1},
	[42] = {"bc", tb+2},
	[43] = {"bc", tb+3},
	[44] = {"bc", tb+4},
	[45] = {"bc", tb+5},
	[46] = {"bc", tb+6},
	[47] = {"bc", tb+7},
	[49] = {"bc", TUI_COL_PRIMARY},
	[90] = {"fc", tb+8},
	[91] = {"fc", tb+9},
	[92] = {"fc", tb+10},
	[93] = {"fc", tb+11},
	[94] = {"fc", tb+12},
	[95] = {"fc", tb+13},
	[96] = {"fc", tb+14},
	[97] = {"fc", tb+15},
	[100] = {"bc", tb+8},
	[101] = {"bc", tb+9},
	[102] = {"bc", tb+10},
	[103] = {"bc", tb+11},
	[104] = {"bc", tb+12},
	[105] = {"bc", tb+13},
	[106] = {"bc", tb+14},
	[107] = {"bc", tb+15}
}

local function sgr(state, dst, ch, val)
	local p = state.csi.param
-- set format at character index
	local di = #dst + 1

	if #p == 0 then
		state.buffer_fmt[di] = state.default_attr
		return
	end

	if not state.buffer_fmt[di] then
		state.buffer_fmt[di] = {}
	end

	local cofs = 0
	local fmt = state.buffer_fmt[di]
	for i=1,#p do
		local v = tonumber(p[i])
		if v then
			local alut = sgr_attr_lut[v]

			if alut then
				fmt[alut[1]] = alut[2]
			end
		end
	end

-- 48: more advanced color options (index, r, g, b)
end

return
{
	[string.byte('m', 1)] = sgr
-- b : repeat last printed n times
-- c : send device attribute
-- d : vertical line position absolute
-- A : up n
-- eB : down n
-- aC : right n
-- D  : left n
-- E  : next line
-- F  : prev line
-- g  : clear ts
-- g prim : cursor horiz abs
-- fH : move cursor
-- J : cursor screen relative erase
-- K : cursor line relative erase
-- L : scroll
-- M : scroll
-- P : delete n
-- @ : insert character(s)
-- S/T : region scroll
-- X : erase
-- I : tab forward
-- Z : tab back
-- h : mode set
-- l : mode reset
-- r : scroll
-- s : save cursor
-- u : restore cursor
--
}
