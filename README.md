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

One of the bigger convenience, on top of being quite snappy, is being able to
run and cleanly separate multiple concurrent jobs asynchronously, with the
results from 'out' and 'err' being kept until you decide to forget it. At the
same time, traditionally noisy tasks like changing directories are kept from
polluting your view with irrelevant information.

(embed video)

This allows for neat visuals like changing layouts, reordering presentation,
folding and unfolding. It also allows for reusing results of a previous job
without thinking much about it - caching is the default and you don't need to
redirect results to files just for reuse.

(embed video)

It is also designed with the intention of being able to frontend- legacy cli
tools with little effort - the set of builtins that the shell provides can be
contextually swapped for something specific to working with some domain or tool
specific context. In this way, famously unfriendly tools can be worked around
and integrated into your workflow as seemless as possible.

(embed video)

It cooperates with your desktop window manager (should you have one), letting
it take care of splitting out things into new windows or even embeddnig media
or graphical application output into clipped regions of its own window.

(embed video)

Installation
============

Building and setting this up is currently not for the faint of heart. It might
look simple at first glance, but going against the grain of decades of
accumulated legacy comes with some friction.

For starters you need an Arcan build that comes straight from the source. The
things needed here are really new, not covered by any release and is actively
worked on. [Arcan](https://github.com/letoram/arcan) is a pain to build from
source and, if you want it to replace your entire display server, also a pain
to setup. Twice the fun.

For our ends here, it works just fine as a window that looks strangely much
like a terminal emulator would look, but its innards are entirely different.

If you managed to build Arcan- to your liking, you then need to start Arcan
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

This should not only convince Arcan to setup a simple fullscreen graphical
shell that then runs the textual command-line shell in lash. Alas the shell
will be kindof useless. This is where Cat9 comes in.

Underneath the surface it actually runs:

    ARCAN_ARG=cli=lua afsrv_terminal

copy or link cat9.lua to $HOME/.arcan/lash/default.lua (make the directory
should it not exist) as well as the cat9 subdirectory so that there is a
$HOME/.arcan/lash/cat9.

Similarly, in durden it would be global/open/terminal=cli=lua and for
safespaces, tack on cli=lua to the terminal spawn line, e.g.
layers/current/terminal=cli=lua

Next time you start the arcan console like above, it should switch to cat9s
ruleset. You can also run it immediately with the shell command:

    shell cat9

This scans LASH\_BASE, HOME/.arcan/lash and XDG\_CONFIG\_HOME/arcan/lash
for a matching cat9.lua and switches over to that.

Mouse gestures and rendering can be tuned by editing the config table at the
beginning of the cat9 script file.

Use
===

Most strings entered will be executed as non-tty jobs. To run something
specifically as a tty (ncurses or other 'terminal-tui' like application), mark
it with a ! to spawn a new window.

    !vim

Window creation and process environment can be controlled (e.g. vertical
split):

    v!vim

To forego any parsing or internal pipelineing and run the entire line verbatim
(forwarded to sh -c) use !!:

		!!find /usr |grep share

Certain clients really want a pty, though there is no high-level vt100+ decoder
yet.

    p!vim

## Builtins

There are a number of builtin commands. These are defined by a basedir, filled
with separate files per builtin command along with a chainloader that match
the name of the basedir:

    cat9/default.lua
		cat9/default/cd.lua
		...

The reason for this structure is to allow lash to be reused for building CLI
frontends to other tools and maintain a unified look and feel. You can also
modify/extend this to mimic the behaviour of other common shells. The ones
included by default are as follows:

### Signal

    signal #jobid or pid [signal: kill, hup, user1, user2, stop, quit, continue]

The signal commands send a signal to an active running job or a process based
on a process identifier (number).

### Config

    config key value

The config options changes the runtime shell behavior configuration.

### Open

    open file or #job [hex] [new | vnew | tab]

This tries to open the contents of [file] through a designated handler. For the
job mode specifically, it either switches the window to a text or hex buffer.
It is also possible to pop it out as a new window or tab.

### Forget

    forget #job1 #job2
		forget #job1  .. #job3
		forget all

This will remove the contents and tracking of previous jobs, either by
specifying one or several distinct jobs, or a range. If any marked job is still
active and tied to a running process, that process will be killed.

### Repeat

    repeat #job [flush]

This will re-execute a previously job that has completed. If the flush argument
is specified, any collected data from its previous run will be discarded.

### Cd

    cd directory

### View

    view #job stream [opt1] [opt2] .. [optn]

Changes job presentation based on the provided set of options.
The possible options are:

* scroll n - move the starting presentation offset from the last line read
             to n lines or bytes backwards.

* out or stdout - set the presentation buffer to be what is read from the
                  standard output of the job.

* err or stderr - set the presentation buffer to be twhat is read from the
                  standard error output of the job.

* col or collapse - only present a small number of lines.

* exp or expand - present as much of the buffer as possible.

* tog or toggle - switch between col and exp mode

* filter ptn - present lines that match the lua pattern defined by 'ptn'

### Copy

    copy src dst

The copy command is used to copy data in and out of Cat9 itself, such as taking
the output of a previous job and storing it in a file or into another running
job.

By default, src and dst are treated as just names with normal semantics for
absolute or relative paths. Depending on a prefix used, the role can change:

Using # will treat it as a job reference.

Using pick: will treat it as a request to an outer graphical shell (i.e. your
wm) to provide a file, optionally with an extension hint:

    copy pick:iso test.iso

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
to the TUI API and its widgets. This is LASH.
