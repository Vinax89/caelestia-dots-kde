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

for directory in (Path("/usr/share/applications"), Path.home() / ".local/share/applications"):
    for path in sorted(directory.glob("*.desktop")):
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        try:
            parser.read(path, encoding="utf-8")
            entry = parser["Desktop Entry"]
            if needle not in entry.get("Name", "").casefold() or entry.get("NoDisplay", "false").casefold() == "true":
                continue
            command = entry.get("Exec", "")
            if not command:
                continue
            argv = [part for part in shlex.split(command) if not part.startswith("%")]
            if argv:
                subprocess.Popen(argv, start_new_session=True, env=os.environ.copy())
                raise SystemExit(0)
        except (OSError, configparser.Error, ValueError):
            continue
raise SystemExit(1)
