Cat9
====

What is it?
===========

Cat9 is a user shell script for LASH - a command-line shell that discriminates
against terminal emulators, written in Lua. You probably have not heard of LASH
before. If you really must know, check the Backstory section below.

LASH just provides some basic shared infrastructure and a recovery shell. It
then runs a user provided script that actually provides most of the rules for
how the command line is supposed to look and behave.

That brings us back to Cat9, which is my such script. You can use it as is or
remix it into something different that fits you - see HACKING.md for more tips.

What can it do?
===============

One of the bigger conveniences, on top of being quite snappy, is to run and
cleanly separate multiple concurrent jobs asynchronously, with the results from
'out' and 'err' being kept until you decide to reuse or forget it. At the same
time, traditionally noisy tasks like changing directories are blocked from
polluting your view with irrelevant information.

https://user-images.githubusercontent.com/5888792/161494772-2abccac4-bb92-4a12-9a69-987e66201719.mp4

This allows for neat visuals like changing layouts, reordering presentation,
folding and unfolding. It also allows for reusing results of a previous job
without thinking much about it - caching is the default and you don't need to
redirect results to files just for reuse or re-execute pipelines when all you
wanted was different processing of its old outputs.

It is also designed with the intention of being able to frontend- legacy cli
tools with little effort - the set of builtins that the shell provides can be
contextually swapped for something specific to working with some domain or tool
specific context. In this way, famously unfriendly tools can be worked around
and integrated into your workflow as seemless as possible.

It cooperates with your desktop window manager (should you have one), letting
it take care of splitting out things into new windows or even embedding media
or graphical application output into clipped regions of its own window.

https://user-images.githubusercontent.com/5888792/161494402-9e5636e3-dd78-4fcf-bff0-fe5c3dd0a369.mp4

Installation
============

Building and setting this up is currently not for the faint of heart. It might
look simple at first glance, but going against the grain of decades of
accumulated legacy comes with some friction.

For starters you want an Arcan build that comes straight from the source. The
things needed here are new, unlikely covered by any release, and is actively
worked on. [Arcan](https://github.com/letoram/arcan) is unpleasant to build
from source and, if you want it to replace your entire display server, also a
pain to setup. Twice the fun.

For our ends here, it works just fine as a window that looks strangely much
like a terminal emulator would look, but its innards are entirely different.

If you managed to build Arcan to your liking, you then need to start Arcan
with a suitable window manager.

There are several to chose from, notable ones being:

 * Durden - Full tiling/stacking will all bells and whistles imaginable.
 * Pipeworld - ZUI dataflow which is both crazy and awesome at the same time.
 * Safespaces - VR, some say it is the future and others the future of the past.

Then there is the much more humble 'console' that mimics the BSD/Linux console
with just fullscreen and invisible tabs. Since it comes included with Arcan
itself, we will go for that one. The way to actually start lash from within
these vary, for console it is easy:

    arcan console lash

This should convince Arcan to setup a simple fullscreen graphical shell that
then runs the textual command-line shell in lash. Alas the shell will be kindof
useless. This is where Cat9 comes in.

Underneath the surface it actually runs:

    ARCAN_ARG=cli=lua afsrv_terminal

copy or link cat9.lua to $HOME/.arcan/lash/default.lua or cat9.lua (make the
directory should it not exist) as well as the cat9 subdirectory so that there
is a $HOME/.arcan/lash/cat9.

Similarly, in Durden it would be global/open/terminal=cli=lua and for
safespaces, tack on cli=lua to the terminal spawn line, e.g.
layers/current/terminal=cli=lua. In recent Durden versions this has a shortcut
as global/open/lash, and is also bound to m1+m2+enter.

Next time you start the arcan console like above, if you picked the default.lua
route it will start immediately - otherwise you have to manually tell lash to
run the cat9 rulset with the shell command:

    shell cat9

This scans LASH\_BASE, HOME/.arcan/lash and XDG\_CONFIG\_HOME/arcan/lash
for a matching cat9.lua and switches over to that. It is also possible to
set LASH\_SHELL=cat9 and cat9.lua will be tried immediately instead of
default.lua

This extra set of steps is to allow multiple shells to coexist, so that there
is a premade path for other rulesets to join the scene with less of a
disadvantage.

Use
===

By default, commands will get tracked as a 'job'.
These get numeric identifiers and are referenced by a pound sign:

    find /tmp
    repeat #0 flush

These pounds can also use relative addresses, #-2 would point to the second
latest job to be created. There are also special jobs, like #csel pointing to
the currently cursor-selected job, and #last pointing to the latest created
job.

Most builtin commands use job references in one way or another. The context of
these jobs, e.g. environment variables and path is tracked separately. By
starting a command with a job reference, the current context is temporarily
set to that of a previous job.

    cd /usr/share
    find . -> becomes job #0
    cd /tmp
    #0 pwd -> /usr/share

Most strings entered will be executed as non-tty jobs. To run something
specifically as a tty (ncurses or other 'terminal-tui' like application),
mark it with a ! to spawn a new window bound to a terminal emulator.

    !vim

Window creation and process environment can be controlled (e.g. vertical
split):

    v!vim

To forego any parsing or internal pipelineing and run the entire line verbatim
(forwarded to sh -c) use !!:

    !!find /usr |grep share

This is also useful when you need to do shell expansions:

    !!rm -rf *

Certain clients really want a pseudoterminal or they refuse to do anything,
for those clients, start with p! like so:

    p!vim

These will default switch to 'view wrap vt100' that has a rudimentary terminal
emulator state machine that need some more work (see base/vt100\*).

Data can be sliced out of a job into the current command-line with ctrl+space:

    rm #0(1,3)

and pressing ctrl+space would copy lines 1 and 3 and expand them into the
current command line. This argument format is also supported by some builtins,
typing:

    copy #0(1-5)

and pressing enter would copy the lines 1 to 5 into a new job.

## Customisation

The config/config.lua file can be edited to change presentation, layout and
similar options, including the formats for prompts and titlebars. Most of these
options can also be reached at runtime via the 'config' builtin, further below.

Keybindings and mouse button presses act just like lines typed on the prompt,
but are defined in the config/bindings.lua file. Keybindings are activated on
ctrl+[key]. The following:

    bnd[tui.keys.A] = "forget #-1"

would create a binding that whenever ctrl-A is pressed, the latest job created
would be removed.

Mouse buttons are similar, but the 'key' is slightly more complex as they are
split based on where you are clicking (titlebar, data body, ...). The currently
most complex binding looks something like this:

    bnd.m2_data_col_click = "view #csel select $=crow"

Would apply the builtin view command on the mouse-selected job at the current
row offset if the second mouse button was clicked on the first column
(line-number).

## Builtins

There are a number of builtin commands. These are defined by a basedir, filled
with separate files per builtin command along with a chainloader that match
the name of the basedir:

    cat9/default.lua
    cat9/default/cd.lua
    ...

The reason for this structure is to allow lash to be reused for building CLI
frontends to other tools, maintain a unified look and feel and swap between
them quickly at will. You can also modify/extend this to mimic the behaviour
of other common shells.

These also include a set of views. A view is a script that defines how to
present the data within a job, and controls things like colour and formatting,
optional elements like line numbers as well as wrapping behaviour.

These have a separate config store that follows the pattern:

    cat9/config/(basedir).lua

The commands included in the default set are as follows:

### Input

The input command is for controlling how parts of the UI responds to mouse or
keyboard inputs. By default the keyboard is grabbed by the command-line. This
grab can be released with CTRL+ESCAPE.

    input #jobid

This will only trigger for jobs that have a working input sink, and retain
current focus if it does not.

### Signal

    signal #jobid or pid [signal: kill, hup, user1, user2, stop, quit, continue]

The signal commands send a signal to an active running job or a process based
on a process identifier (number).

### Config

    config key value

The config options changes the runtime shell behavior configuration. It is
populated by the keys and values in config/config.lua.

Certain targets also allow properties to set, e.g. persistence or an alias:

    config #id alias myname
    config #myname persist auto

It can be used to hot-reload settings and the code for default builtins:

    config =reload

It can be used to define aliases:

    config myalias "my longer command"

When ctrl+space is used with readline, the last word will be swapped for the
alias. This will not have a commit action, so the expansion is visible to avoid
unpleasant surprises.

### Open

    open file or #job [hex] [new | vnew | tab]

This tries to open the contents of [file] through a designated handler. For the
job mode specifically, it either switches the window to a text or hex buffer.
It is also possible to pop it out as a new window or tab.

### Forget

    forget #job1 #job2
    forget #job1  .. #job3
    forget all-bad
    forget all-passive
    forget all-hard

This will remove the contents and tracking of previous jobs, either by
specifying one or several distinct jobs, or a range. If any marked job is still
active and tied to a running process, that process will be killed. There are
also special presets: all-bad, all-hard and all-passive; all-bad forgets the
completed jobs with !0 return status code; all-hard removes all jobs, passive
and running; all-passive removes all jobs that have completed running.

### Repeat

    repeat #job [flush | edit]

This will re-execute a previously job that has completed. If the flush argument
is specified, any collected data from its previous run will be discarded. If
the edit argument is specified, the command-line which spawned the job will be
copied into the command line - and if executed, will append or flush into the
existing job identifier.

### Cd

    cd directory
    cd #job

Change the current directory to the specified one, with regular absolute or
relative syntax. It is also possible to cd back into the directory that was
current when a specific job was created.

Cd also tracks which directories commands are being run from and adds them
to a history. This can be accessed via the special:

    cd f ...

Where the f will be omitted and the set of suggested completions will come
from the list of favourites. This can be manually altered, using f- to
remove a path and f+ . or f+ /some/path to add it to the favorites.

### View

    view #job stream [opt1] [opt2] .. [optn]

Changes job presentation based on the provided set of options.
The possible options are:

* scroll n - move the starting presentation offset from the last line read
             to n lines or bytes backwards.

* out or stdout - set the presentation buffer to be what is read from the
                  standard output of the job.

* err or stderr - set the presentation buffer to be what is read from the
                  standard error output of the job.

* col or collapse - only present a small number of lines.

* exp or expand - present as much of the buffer as possible.

* tog or toggle - switch between col and exp mode

* linenumber - toggle showing a column with line numbers on/off

There are also a number of dynamic views that can apply higher level transforms
on the contents to change how it presents. One such view is 'wrap':

    view #job wrap [vt100] [max-col]

This implements word wrap, optionally filtered through a terminal state machine
(vt100) and with a custom column cap.

### Copy

    copy src [opts] [dst]

The copy command is used to copy data in and out of Cat9 itself, such as taking
the output of a previous job and storing it in a file, into another running job
or into a new job (if dst is not provided).

By default, src and dst are treated as just names with normal semantics for
absolute or relative paths. Depending on a prefix used, the role can change:

Using # will treat it as a job reference.

Using pick: will treat it as a request to an outer graphical shell (i.e. your
wm) to provide a file, optionally with an extension hint:

    copy pick:iso test.iso

The optional source arguments can be used to slice out subranges, e.g.

    copy #0 (1-10,20) dst

Which would copy lines 1 to 10 and line 20 of the current view buffer into
the destination.

Copy destinations do not have to be files, they can also be other interactive
jobs, or special ones like clipboard: that would forward to the outer WM
clipboard.

### Env

    env [#job] key value

This is used to change the environment for new jobs. It can also be used to
update the cached environment for an existing job. This environment will be
applied if the job is repeated, or if a new job is derived from the context
of one:

    env #0 LS_COLOR yes
    #0 ls /tmp

### Trigger

    trigger #job condition [delay n] action

It is possible to attach several event triggers to a job that has an external
action attached. The command for that is 'trigger'. The condition can be either
'ok' or 'fail', with an optional delay in seconds. The action is any regular
command-line string (remember to encapsulate with "").

To remove previously set triggers, use 'flush' instead of action.

A common case for trigger is to repeat a job that finished:

    trigger #0 ok delay 10 "repeat #0"

Would keep the job #0 relaunching 10 seconds after completing until removed:

    trigger #0 ok flush

Backstory
=========

Arcan is what some would call an ambitious project that takes more than a few
minutes to wrap your head around. Among its many subprojects are SHMIF and TUI.
SHMIF is an IPC system -- initially to compartment and sandbox media parsing
that quickly evolved to encompass all inter-process communication needed for
something on the scale of a full desktop.

TUI is an API layered on top of SHMIF client side, along with a text packing
format (TPACK). It was first used to write a terminal emulator that came
bundled with Arcan, and then evolved towards replacing all uses of ECMA-48 and
related escape codes, as well as kernel-tty and userspace layers. The end goal
being completely replacing all traces of ncurses, readline, in-band signalling
and so on -- to get much needed improved CLIs and TUIs that cooperate with an
outer graphical desktop shell rather than obliviously combat it.

This journey has been covered in several articles, the most important ones
being 'the dawn of a new command line interface' and the more recent 'the day
of a new command line interface: shell'.

The later steps then has been a migration toggle in the previous arcan terminal
emulator that allows a switch over to scripts with embedded Lua based bindings
to the TUI API and its widgets. This later mode and support scripts is what we
refer to as Lash. Lash in turn is too barebones to be useful, and a set of user
scripts are plugged in, Cat9 is one such set.
