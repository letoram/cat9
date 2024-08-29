local types = lash.types

return
{
	concat =
	{
		handler =
		function(...)
			local arg = {...}
			return table.concat(arg)
		end,
		args = {types.STRING, types.STRING, types.VARARG},
		argc = 2,
		help = "Concatenate strings",
		type_helper = {}
	},

	len =
	{
		handler =
		function(a)
			return #a
		end,
		args = {types.NUMBER, types.STRING},
		argc = 1,
		help = "Returns the length of the supplied string",
		type_helper = {}
	},

	max =
	{
		handler =
		function(...)
			local arg = {...}
			local max = arg[1]
			for i=2,#arg do
				if arg[i] > max then
					max = arg[i]
				end
			end
			return max
		end,
		args = {types.NUMBER, types.NUMBER, types.VARARG},
		argc = 1,
		help = "Returns the highest value among the supplied arguments",
		type_helper = {}
	},

	min =
	{
		handler =
		function(...)
			local arg = {...}
			local min = arg[1]
			for i=2,#arg do
				if arg[i] < min then
					min = arg[i]
				end
			end
			return min
		end,
		args = {types.NUMBER, types.NUMBER, types.VARARG},
		argc = 1,
		help = "Returns the lowest value among the supplied arguments",
		type_helper = {}
	},

	random =
	{
		handler =
		function(a, b)
			if a >= b then
				eval_scope.cell:set_error("(1:low) should be less than (2:high)")
				return
			end
			return math.random(a, b)
		end,
		args = {types.NUMBER, types.NUMBER, types.VARARG},
		argc = 2,
		names = {
			low = 1,
			high = 2
		},
		help = "Return a random number between (low, high)",
		type_helper = {}
	},

	reverse =
	{
		handler =
		function(str)
			local lst = {}
			local pos = 1
			local len = #str
			while true do
				local step = string.utf8forward(str, pos)
				table.insert(lst, 1, string.sub(str, pos, step-1))
				if step == pos then
					break
				end
				pos = step
			end
			return tabel.concat(lst, "")
		end,
		args = {types.STRING, types.STRING},
		names = {},
		argc = 1,
		help = "Reverse the input string",
		type_helper = {}
	},

	string = {
		handler = function(instr) return instr end,
		args = {types.STRING, types.STRING},
		argc = 1,
		help = "Copy or convert a reference or literal to a string",
		type_helper = {}
	},

	strrep = {
		handler = function(str, times) return string.rep(str, times) end,
		args = {types.STRING, types.STRING, types.NUMBER},
		argc = 2,
		help = "Repeat text input a fixed number of time",
		type_helper = {},
	},

	datetime = {
		handler = function(str)
			local res = os.date(str and str or "%Y-%m-%d %T")
			if not res then
				eval_scope.cell:set_error("invalid datetime format string")
				return
			end
			return res
		end,
		args = {types.STRING, types.STRING},
		argc = 0,
		names = {
			format = 1
		},
		help = "Return the system date-time with an optional format string (strftime)",
		type_helper = {
			{
				"%Y-%m-%d - year month day",
				"%H-%M:%S - hour minute second"
			}
		}
	}
}
