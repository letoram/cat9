local gnuplot_defaults =
{
	terminal = "svg dynamic enhanced background rgb 'white'",
	title = "",
	xlabel = "",
	ylabel = "",
	separator = ",",
	xmin = -1,
	xmax = 1,
	ymin = -1,
	ymax = 1
}

return
{
	graphviz =
	{
	},
	gnuplot =
	{
		histogram =
		function(opts)
			return string.format(
[[
%s
while (1){
	reset
	set datafile separator "%s",
}
]],
			opts.terminal or gnuplot_default.terminal
			)
		end,
		points =
		function(opts)
			return string.format(
[[
set terminal %s
set title "%s"
set xlabel "%s"
set ylabel "%s"
set xrange [%d:%d]
set yrange [%d:%d]
set datafile separator "%s"
plot "-" using 1:2 with points
]],
				opts.terminal or gnuplot_defaults.terminal,
				opts.title or gnuplot_defaults.title,
				opts.xlabel or gnuplot_defaults.xlabel,
				opts.ylabel or gnuplot_defaults.ylabel,
				opts.xmin or gnuplot.defaults.xmin,
				opts.xmax or gnuplot.defaults.xmax,
				opts.ymin or gnuplot.defaults.ymin,
				opts.ymax or gnuplot.defaults.ymax,
				opts.separator or gnuplot_defaults.separator,
				1, 1
		)
		end
	}
}
