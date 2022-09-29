local set =
{
	"../default/view.lua",
}

-- these should be dynamically probed os-wise for availability,
-- and pick one that fits (wpa, nm, nw, ..)

table.insert(set, 'wifi_wpa.lua')

return set
