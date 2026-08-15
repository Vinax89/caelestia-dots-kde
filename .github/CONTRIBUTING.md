# Contributing to Caelestia KDE

We're glad you're here! This guide covers everything you need to start
contributing.

## Quick start

```bash
git clone https://github.com/Vinax89/caelestia-dots-kde ~/caelestia-dots-kde
cd ~/caelestia-dots-kde
bash setup.sh          # Full install - do this at least once
```

Make your changes in the cloned repo, test them (see below), then open a PR.
That's it.

## What makes a good PR?

- **One thing at a time.** If you have three features, send three PRs. It is much
  faster to review.
- **Keep your personal config out.** Do not include your wallpaper path, custom
  keybinds, or local settings.
- **Experimental features off by default.** If it is flashy or niche, add a
  config toggle and default it to `false`.
- **Big ideas? Open an issue first.** It saves you from writing code we might
  not be able to accept.

## Where stuff lives

| Area | Directory | Tech |
|------|-----------|------|
| Shell UI (launcher, bar, notifications, etc.) | `shell/` | QML + Quickshell |
| KWin plugin (window management, shortcuts) | `shell/plugin/` | C++ |
| TUI installer | `installer/src/` | C++ |
| Installer menus | `installer/menu.json` | JSON |
| Install step scripts | `scripts/` | Bash |
| User-facing update scripts | `src/bin/` | Bash |

## Development workflow

### For QML / shell changes

Edit files in `~/.config/quickshell/caelestia/`. Changes reload automatically;
no restart is needed.

```bash
# View live logs
caelestia-shell-ipc log

# Restart the shell cleanly
caelestia shell -k && caelestia shell -d
```

**Editor setup:**

- Run `touch ~/.config/quickshell/caelestia/.qmlls.ini` for QML language server
  support
- In VS Code, install the "Qt Qml" extension and set the `qmlls` path to
  `/usr/bin/qmlls6`

### For C++ plugin changes

```bash
bash scripts/08-build-shell.sh   # Recompiles and installs the plugins
caelestia shell -k && caelestia shell -d   # Restart to pick up the new .so
```

### For installer changes

```bash
cd installer
cmake -B build && cmake --build build   # Compile
./build/caelestia-install               # Run (use with care!)
```

## Code style (the short version)

**QML:**

- Spaces between operators: `if (condition) {` not `if(condition){`
- Prefer early returns: `if (!ok) return;` over deep nesting
- Group related properties with blank lines
- Import order: QtQuick, Qt, Quickshell, Caelestia, components, services,
  then modules
- Run `python3 shell/scripts/qml-lint-conventions.py`; it catches most issues

**Shell scripts:**

- Use `set -euo pipefail` at the top
- Prefer `[[ ]]` over `[ ]`
- Quote variables: `"$VAR"` not `$VAR`
- Run `shellcheck` on your scripts

## Security

- When calling shell commands from QML, pass arguments as an array. Never
  concatenate strings:

  ```js
  // Good
  Quickshell.execDetached(["bash", "-c", "echo \"$1\"", "--", myVar])
  // Bad
  Quickshell.execDetached(["bash", "-c", "echo " + myVar])
  ```

- Use `Paths.runtimeTemp("filename")` for temporary files instead of hardcoded
  `/tmp/` paths.

- Workflows triggered by `issues`, `issue_comment` or `pull_request_review_comment`
  run in the base repository with a write token, and their input is text any
  stranger can write. `moderator.yml` feeds that text to a third-party AI action
  holding `issues: write` and `pull-requests: write`, so a crafted comment is a
  prompt-injection surface against a privileged token. Pin such actions by
  commit SHA (as it is), give them the narrowest permissions that work, and do
  not add steps that act on model output without a human in the loop.

- The shell's own AI assistant has a separate boundary, written up in
  [AI assistant trust](docs/ai_assistant_trust.md). Read it before adding a tool
  to the dispatcher.

## Architecture docs

- [KWin port architecture](docs/kwin_port_architecture.md): C++ and QML APIs
- [Installer configuration](docs/installer_config.md): theme and menu reference
- [Lock screen architecture](docs/lockscreen_architecture.md): lockscreen design

## Stuck?

Open a
[Discussion](https://github.com/Vinax89/caelestia-dots-kde/discussions)
or ask in an issue. We are happy to help.
