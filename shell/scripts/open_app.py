#!/usr/bin/env python3
"""Open the first desktop entry whose Name matches the requested text."""
import configparser
import os
import shlex
import subprocess
import sys
from pathlib import Path

needle = " ".join(sys.argv[1:]).casefold().strip()
if not needle:
    raise SystemExit("missing application name")


def search_dirs():
    """Desktop-entry directories in XDG precedence order.

    Only /usr/share/applications and ~/.local/share/applications used to be
    searched, in that order, which meant Flatpak and Snap entries (which live
    under XDG_DATA_DIRS, not in either of those) were invisible, and a user's
    own override in ~/.local lost to the system entry it was meant to replace.

    XDG says the user's data home wins, then XDG_DATA_DIRS in order.
    """
    seen = set()
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    for base in [data_home, *data_dirs.split(":")]:
        if not base:
            continue
        path = Path(base) / "applications"
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        if path.is_dir():
            yield path


# Terminal emulators that can run a command, in preference order, with the flag
# that introduces it. Caelestia ships foot and konsole, so those come first.
TERMINAL_WRAPPERS = (
    ["foot"],
    ["konsole", "-e"],
    ["kitty"],
    ["x-terminal-emulator", "-e"],
    ["xterm", "-e"],
)


def which(name):
    return any((Path(d) / name).is_file() for d in os.get_exec_path())


def launch(argv, needs_terminal):
    """Run argv, wrapping it in a terminal when the entry asks for one."""
    if needs_terminal:
        # Terminal=true marks a console program. Launching it bare gives the
        # user a process with nowhere to draw, which reads as "nothing
        # happened"; this used to ignore the key entirely.
        for wrapper in TERMINAL_WRAPPERS:
            if which(wrapper[0]):
                argv = wrapper + argv
                break
    subprocess.Popen(argv, start_new_session=True, env=os.environ.copy())


for directory in search_dirs():
    for path in sorted(directory.glob("*.desktop")):
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        try:
            parser.read(path, encoding="utf-8")
            entry = parser["Desktop Entry"]
            if needle not in entry.get("Name", "").casefold() or entry.get("NoDisplay", "false").casefold() == "true":
                continue
            if entry.get("Hidden", "false").casefold() == "true":
                continue
            command = entry.get("Exec", "")
            if not command:
                continue
            argv = [part for part in shlex.split(command) if not part.startswith("%")]
            if argv:
                launch(argv, entry.get("Terminal", "false").casefold() == "true")
                raise SystemExit(0)
        except (OSError, configparser.Error, ValueError, KeyError):
            continue
raise SystemExit(1)
