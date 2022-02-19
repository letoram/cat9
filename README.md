About
=====

Cat9 is a user shell script for LASH - a command-line shell that discriminates
against terminal emulators and is written in Lua. You probably have not heard
of LASH before. If you really must know, check the Backstory section below.

LASH actually just sets up some basic shared infrastructure and a recovery
shell. It then runs a user provided script that actually provides most of the
rules for how the command line is supposed to look and behave.

That brings us back to Cat9, which is mine. You can use it, write your own,
or hack on it to create something different. Think of it as a .bashrc or
similar that has much more to say about things.

On a cloudy day, it can look something like this:

![Cat9 Example](demo.gif)

Setup/Installation
==================

Building and setting this up is currently not for the faint of heart.

For starters you need an Arcan build that comes straight from the source. The
things needed here are really new, not covered by any release and is actively
worked on. [Arcan](https://github.com/letoram/arcan) is a pain to build from
source and, if you want it to replace your entire display server, also a pain
to setup. Twice the fun.

For our ends here, it works just fine as a window that looks strangely much
like a terminal emulator would look, but its innards are entirely different. If
you managed to build Arcan- you then need to start Arcan with a suitable window
manager.

There are several to chose from, notable ones being:

 * Durden - Full tiling/stacking will all bells and whistles imaginable.
 * Pipeworld - ZUI dataflow which is both crazy and awesome at the same time.
 * Safespaces - VR, some say it is the future and others the future of the past.

Then there is the much more humble 'console' that mimics the BSD/Linux console
with just fullscreen and invisible tabs. Since it comes included with Arcan
itself, we will go for that one:

    arcan console lash

This should not only convince Arcan to setup a simple fullscreen graphical
shell that then runs the textual command-line shell in lash. Alas the shell
will be kindof useless. This is where Cat9 comes in.

copy or link cat9.lua to $HOME/.arcan/lash/default.lua (make the directory
should it not exist. Next time you start the arcan console like above, it
should switch to cat9s ruleset. You can also run it immediately with the
usershell command:

    usershell cat9

This scans LASH\_BASE, HOME/.arcan/lash and XDG\_CONFIG\_HOME/arcan/lash
for a matching cat9.lua and switches over to that.

Use
===

The capabilities and use of Cat9 is still very much in flux, most default
inputs and behaviour should be similar to that of any other readline based cli
shell.

Backstory
=========

Arcan is what some would call an ambitious project that takes more than a few
minutes to wrap your head around. Among its many subprojects is that of SHMIF
and TUI. SHMIF is an IPC system -- initially to compartment and sandbox media
parsing that quickly evolved to encompass all process communication needed for
something of the scale of a desktop.

TUI is an API layered on top of SHMIF client side, along with a text packing
format (TPACK). It was first used to write a terminal emulator that came
bundled with arcan, and then evolved towards replacing all uses of ECMA-48 and
related escape codes, as well as pty kvrnel and userspace layers. The end goal
being completely replacing all traces of ncurses, readline, in-band signalling
and so on -- to get much needed improved CLIs and TUIs that cooperate with an
outer graphical desktop shell rather than obliviously combat it.

This journey has been covered in several articles, the most important ones
being 'the dawn of a new command line interface' and the more recent 'the day
of a new command line interface: shell'.

The later steps then has been a migration toggle in the previous arcan terminal
emulator that allows a switch over to scripts with embedded Lua based bindings
to the TUI API and its widgets. This is LASH.
