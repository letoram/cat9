# How to use

## The prompt

The prompt displays basic information like the time, the active `builtin`
and the current directory.  By default, it does not give the full path
of the current directory. See [Customisation](README.md) if you want a
custom prompt.

If you ever lose the prompt (eg.: after an `input` command)

	CTRL-ESCAPE

Returns you to the prompt

	CTRL-r

Opens history auto-complete. This history includes any command, regardless
of the related job still existing or not.

## Jobs

Each job corresponds to a command.

### `#jobid`

A numeric identifier for the job, prepended by the `#` symbol.

The `#jobid` can also be a relative address

	#-2

Points to the second latest job to be created.

### Buffer

Each job has it's own buffer. It can be clicked to crop / uncrop it's
contents. Standard out and standard in are tracked seperately, see `view`.

### Buffer title

The title contains the `#jobid`, the size of the output in KiB, the currently
active view and the name of the command.  There is also an `X` to delete
the buffer and a repeat/flush button to repeat the command and replace
the buffer with the new output.

### Line Numbers

See `view #jobid linenumber` for configuration of buffer line numbers.

Certain builtin commands can directly refer to lines in job buffers, see
`rm #jobid(lineNb)` and `cp #jobid(lineNb), but arbitrary commands will not.

	CTRL-SPACE

Expands any `#jobid(lineNb)` in the prompt

	#jobid(3-8)

Refers to the range of lines in `#jobid` going from line 3 to line 8.

### `!``

Since commands are executed as non-tty jobs by default, `!` can be used
to override the default behaviour.

	!command

Spawns a new window with a real terminal emulator to execute `command`

	v!command
	s!command
	h!command

Instructs the window manager on how to spawn the new window

 - v= vertical
 - h = horizontal
 - s = swallow

	p!command

Spawns a job with `view wrap vt100`, a pseudo terminal with basic
emulation capacities, see the `input` command to interact with it further.

	!!command

Spawns a job without string expansion.

## Commands

These commands interact with `#jobid` in different ways, most of them will
affect the targeted job without leaving a trace in the console history.

### view

the `view #jobid` command allows for manipulation of the visible buffer,
it does not permanently modify the buffers contents.

#### err / out

`view #jobid err` will display standard error instead of standard
out. `view #jobid out` will display standard out

#### expand / collapse

`view #jobid expand` will display the full uncropped buffer, while `view
#jobid collapse` will only show part of a buffer, it will respect the
scroll command, but shows the buffers tail by default.

#### scroll

`view #jobid scroll lineNb` on a collapsed job will move the top of the
displayed buffer to the desired line number (lineNb). Omitting the line
number will make it use the first line.

#### toggle

`view #jobid toggle` is a toggle to collapse / expand the buffer title

#### linenumber

`view #jobid linenumber` is a toggle to display / hide line numbers at
the beginning of lines

#### filter

`view #jobid filter` triggers an interactive prompt that will dynamically
filter the contents of the targeted buffer.

You can combine any of the following filtering methods.

##### substring

`view #jobid filter substring` will hide any line that does not contain
the substring

##### match

`view #jobid filter match regex` will hide any text that does not match
the `regex`, while maintaining line separation. It can also be used with
the OR gate.

##### not

`view #jobid filter not substring` will hide any line that matches
the substring.

##### logical gates (or)

`view #jobid filter A or B` will hide any lines that do not contain A or B

### signal

`signal #jobid kill` will send the kill signal to the targeted job. The
accepted signals are:

 - kill 
 - continue
 - hup 
 - quit
 - stop
 - user1
 - user2

### cd

`cd directory` will switch to the targeted directory.

`#jobid cd` will switch to the current working directory of the
referenced job.
