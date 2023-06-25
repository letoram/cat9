Organisation
============

    cat9/base - support functions to help with builtins
	  cat9/base/ioh.lua - input event handlers, anything key/mouse goes here
		cat9/base/jobctl.lua - process lifecycle, reading / buffering / writing
		cat9/base/layout.lua - drawing / window management / prompt
		cat9/base/misc.lua - support functions
		cat9/base/promptmeta.lua - data formatters for the prompt
		cat9/base/jobmeta.lua - data formatters for titlebars
		cat9/default.lua - loader for standard builtin- functions
		cat9/default/... - builtin functions picked by cat9/default.lua
		cat9/base/osdev/... - sensor and hardware interfaces

Builtins
========
To add a new builtin, create a new file in the suitable subfolder. The ones in
'default' will be added first when loading a set on builtin, unless the user
explicitly provided the 'nodef' argument.

As an example, we will create a builtin set called 'myset'.

Create the file cat9/myset.lua with the lines:

    return {"mycmd.lua"}

Create the fiile cat9/myset/mycmd.lua with the lines:

    return
		function(cat9, root, builtins, suggest, views, config)
		    function builtins.mycmd(arg1, arg2)
				end
		end

The arguments 'cat9' contains support functions (populated by the various .lua
in base/, see how other builtins use it for common patterns).

The 'root' argument is the arcan-tui root window (with documentation and
examples in github:letoram/tui-bindings).

The 'builtins', 'suggest', 'views' and 'config' tables are ones to be populated
by your script but only the 'builtins' entries added are necessary in order to
introduce new commands.

Suggest is used for providing interactive suggestion and feedback to the user
as they are constructing the command line. It is more complicated to write as
the arguments are by its nature incomplete. Settle on how you want the command
to work first before trying to provide suggestions for it.

Views will be covered further down, but is only really useful if you want to
provide other visualisers for the data that you add to any jobs created.

Config is normally an empty table, but you can provide a static source for it
as a separate file. For our example, create cat9/config/myset.lua:

    return
		{
		   mybin = "/usr/bin/mybin"
		}

From the builtins.mycmd example above, you could then access config.mybin.

With this you should be able to type "builtin myset" from the prompt and have
access to mycmd.

You can also dynamically probe for necessary tools and provide an error message
to inform the user that some things might need to be provided for it to function
though it is less ergonomic:

In cat9/myset.lua:

    if not lash.root:fstatus(lash.builtin_cfg.mybin) then
		    return "myset: cannot load, missing 'mytool'"
    end

	  return {'mycmd.lua'}

Now when 'builtin myset' is activated, if the 'mybin' config entry for myset
is not present, the prompt will refuse to switch and instead show the returned
error message.

Jobs spawned will remember the set of builtins used, so switching a job context
(> #0) will activate that set without dynamically reloading it.

Builtin-Catch all
=================

A special case that is recurring is having an external oracle that should
process commands that do not match a builtin in the current set. This has
the reserved name of \_default and with special argument semantics:

    builtins["_default"] =
		function(args)
		    local set, err = cat9.expand_string_table(args)
				-- forward arguments in set to external oracle
		end

The reason for this other argument form rather than the expanded one is to
defer the choice of expanions like #0 or #0(1-3). In the example above the
helper function makes sure to apply arguments for resolving into a set of
strings, but tokenised args can still be accessed in order to extract more data
from specific #job references.

If no 'catch all' handler is set for a particular builtin, the shell will
always try and just 'run arg[1] with arg[2..n] as its argv and map the data
to a visible job.

Views
=====

It is possible to add alternate input/output handlers as well. These are
refered to as views, and are defined and added in the same way as builtins -
but added to another argument table, 'views' instead. It is suggested that a
'views' subfolder is addded to the builtin set, so it is easier to distinguish
and transplant across sets.

       cat9/default/default.lua:
		   ...
			 "views/wrap.lua"

and in cat9/default/views/wrap.lua:

    return
		function(cat9, root, builtins, suggest, view)
		    function view.wrap(job, x, y, cols, rows, probe, hidden)
				    return rows
				end
		end

and should return the number of rows consumed to present job.data at a
possible job.row\_offset and job.col\_offset. If probe or hidden is set, just
estimate the upper bound for layouting purposes - otherwise draw into the
provided root.

The corresponding view function will then be called each time the view is to
be drawn, and whenever it is marked as hidden. The function is still expected
to return the number of rows presenting the dataset would consume, in order
for decorations like scrollbars to be accurate.

Job
===
The main data container is that of the job. It is being passed around
everywhere and partially inherited from lash itself should the usershell be
swapped out. It can either be visible and part of the layouting / windowing or
an invisible 'background job'.

A common pattern for running a background command:

    local _, output, _, pid = root:popen("/usr/bin/cmd", "r")
    cat9.add_background_job(output, pid, {lf_strip = true},
		    function(job, code)
				    if code == 0 then
					     -- parse job.data
						else
						   -- some error handling
						end
			  end
		)

This would run /usr/bin/cmd asynchronously and trigger the anonymous
function when the process has completed along with its exit code (0 == success).

For a visible/interactive job, it is a bit more involved. There is a factory
function, 'cat9.import\_job' that takes an input job table, validates it and
ensures a set of defaults / expected values are present.

		local job = cat9.import_job({})
    -- patch job to add in desired behaviour, data sources, ...

The reason for this structure is that should there be some unhandled error that
is recoverable, cat9 can throw away any other state and re-run all tracked and
visible jobs through the same import\_job function and expect to get something
usable out of it, at least enough for the user to recover data.

You could/should track whatever state your command needs inside of a job, but
most of its members are useful only for the base/default builtins and for
providing a view.

The exceptions are 'data', 'short', 'raw' and event handlers. Data is a table
of lines that is to be presented based on the current view (which controls
scrolling, wrapping, coloring and so on).

Add n- indexed lines to data, update the linecount and bytecount keys to match,
call cat9.flag\_dirty() to signal a relayout and the rest should sort itself.

To fully control rendering you'd need to write a different view handler, which
is one of the harder things in cat9. To ease the burden of that to just provide
formatting, the attr\_lookup function can be replaced:

    job.attr_lookup =
		function(job, set, i, pos, highlight)
		    -- return the cell formatting attribute table (see tui-bindings doc)
				-- for set[i] (set is a slice of job.data) at view index (i) with
				-- horisontal offset (pos) and if highlighting is requested.
		end

To add more interactive behaviour, there are event handlers that can be attached:

    job.handlers.mouse_button =
		function(job, btn, xofs, yofs, modifiers)
		    -- capture mouse button [btn] press at job-origo relative x/y with
				-- keyboard modifiers (mods) held, cat9.modifier_string(mods) to get
				-- a readable lshift_lctrl like representation.
		end

Input
=====
There are other ways of getting data than by adding a background job and letting
cat9 itself perform the reading and buffering. This might be needed when you want
stream processing or interactively work with an external application.

While root:popen -> in, out, err, pid is used to spawn and setup the io streams
for a command line, there is alsop root:fopen(path, [mode]) for accessing files
or unix stream/datagram sockets. This returns a non-blocking IO stream as covered
in the tui-bindings documentation.

To balance between throughput and interactivity, there is the option of adding
a timer:

    table.insert(cat9.timers,
			function()
-- read and process data or dequeue / run command, return true to be reinvoked
-- or false to have the timer removed
			end
		)

The actual frequency the timer will invoke is up to an internal setting and
just represents 'about how often background data polling should be processed'
as that is something that could/should be defered to the user, but the default
is about 25Hz.

Other
=====
Lash itself comes with some minor support functions, one with much utility here is:

    lash.tokenize\_command(str) -> tokens, errmsg, errofs, typetable

It operates in either a simplified or a full mode, where the full mode is intended
more for complete expression evaluation (a=1+2/myfun(myfun2(1, "hi", "there"))) style
and the simple mode (used here) masks out some operators and treat them as strings.

Where each member of tokens are [1] : type, [2] : typedata, [3] pos.
See base/parse.lua for more advanced use of it.

The source-code to lash, as well as the documentation on how the Lua bindings for
the tui API works can be found at:

    https://github.com/letoram/tui-bindings

These bindings can also be used to run lash without the afsrv\_terminal chainloader,
which might make it easier to debug lower level problems. Simply build them as you
any other lua bindings, and run the examples/lash.lua script.

With afsrv\_terminal and getting trace/stdio output:

    ARCAN_ARG=cli=lua afsrv_terminal

Layout
======
One of the more complicated pieces of this is drawing and laying out jobs. The basic
flow is as follows:

layout.lua:cat9.redraw() is called every time the window is dirty and should be redrawn.
1. clear screen
2. estimate the number of columns consumed and set width accordingly.
3. reserve vertical space for the prompt and a possible message area.
4. for each non-hidden, non-visited job with an active view, add to working set.
5. estimate the number of rows consumed by the jobs in the set to determine if
	 the simple path should be used.

the number of rows consumed by each job is limited by if the job is viewed as
collapsed or expanded.

For jobs with external / embedded contents, send hint about the current state
(expanded / collapsed) with scaling preferences and anchoring row/column.

simple mode:
   work from top to bottom
   for each job, draw the job and its header
	 mark the consumed bounding volume as part of the job (for mouse picking)
	 draw message
	 draw readline area

advanced mode:
   work from bottom to top
   for the number of estimated columns:
	 layout the column based on the number of cells reserved
	 repeat until set is empty
