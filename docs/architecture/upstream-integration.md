# Upstream integration (2026-09-30)

The fork at `9be5c89d` contributed 47 commits absent from upstream. This merge
combines that history with upstream `e34b6957` (v2.5.1), including 975 upstream
commits absent from the fork. Both histories remain ancestors of the result.

## Resolution decisions

- Keep upstream's current installer in `installer/tui`, distro configuration in
  `installer/distro`, and installer data in `installer/data`. Port password wiping,
  private IPC/state permissions, cleanup, failure reporting and package ownership
  into that implementation instead of restoring the retired installer.
- Preserve the fork's update signature policy, pinned target support, optional
  privilege acquisition, staged config deployment/restoration, archive checks,
  package provenance, and safe uninstall behavior. Prebuilt downloads default to
  source builds until a signer is pinned; shell bundles require explicit unsigned
  opt-in and a checksum.
- Retain the current upstream plugin architecture and Discord IPC state machine.
  Port applicable path, socket, HTTP, async lifetime and uniform bounds checks.
  Keep KWin's active-output file for the current recorder.
- Retain upstream's translations and new screenshot action model. Port upload
  consent/HTTPS checks, Wi-Fi saved-profile protection, JSON fallbacks, safe XML
  news parsing, AI action opt-in and Wallhaven keyring handling.
- Keep upstream's replacement greeter and environment files. Retired lockscreen,
  tmux, KMYC/Hypr components, old RC-writing logic and the obsolete OpenCV ABI
  symlink workaround are not revived. Their fixes apply only to retired paths.
- Adapt the fork's lint/build/test checks to the current paths, preserve real
  package-manager container coverage, and keep release no-op behavior without
  force-updating existing tags. Release jobs use push triggers rather than a
  privileged `workflow_run`. Fork URLs remain consistent throughout the tree.

## Fork history retained

All 47 commits below are preserved in merge ancestry. Individual fixes are
retained in place, ported as described above, or superseded by upstream's
replacement of the affected component; merge commits preserve their original
parents without replaying obsolete trees.

| Commit | Original change |
| --- | --- |
| `0c608661` | fix: harden installer runtime and fix plugin races |
| `665278fd` | security: harden installer and shell execution |
| `e41ff773` | Merge pull request #2 from Vinax89/fix/installer-security-and-plugin-races |
| `4ee2a775` | Potential fix for code scanning alert no. 1: Bad HTML filtering regexp |
| `18e84d97` | Merge pull request #3 from Vinax89/alert-autofix-1 |
| `f0ea8ebe` | test installer flows and verify release updates |
| `f89c7627` | reduce shell process overhead and polling |
| `cba18c51` | reduce qml convention baseline |
| `476aa61b` | fix validation environments |
| `81980d03` | fix remaining validation gates |
| `1fe22f00` | make qml lint compatible with qt 6.4 |
| `ccb0d70c` | Merge pull request #4 from Vinax89/fix/installer-security-and-plugin-races |
| `728c6630` | fix qml and production build validation |
| `7576257a` | install qml baseline comparison tool |
| `873ad79e` | Merge pull request #5 from Vinax89/codex/fix-validation-gates |
| `8a280fb2` | fix push-only hygiene reporting |
| `c592d3a9` | Merge pull request #6 from Vinax89/codex/fix-push-hygiene |
| `dc5de8e7` | skip releases for unchanged versions |
| `da602b48` | Merge pull request #7 from Vinax89/codex/fix-release-noop |
| `68c31f18` | fix: remediate 32 findings from the repository security and code audit |
| `b614de1f` | fix: exclude the identity checker from its own scan, strip trailing whitespace |
| `4b1e4c01` | fix: close the last two sub-items of the audit's finding 32 |
| `cd7a82e6` | fix: replace the three documented-only mitigations with real ones |
| `b1fbbd89` | fix: strip trailing whitespace from aiconfig.hpp |
| `6d422291` | fix: actually apply the private OpenCV compat dir to the recorder |
| `382363ff` | Merge pull request #8 from Vinax89/fix/audit-remediation |
| `13bba285` | fix: run submodule init against the repo, not the caller's directory |
| `e9aa55b0` | Merge pull request #9 from Vinax89/fix/build-script-cwd |
| `121add32` | fix: avoid SIGPIPE abort in OpenCV compat-link creation |
| `9cdcee24` | Merge pull request #10 from Vinax89/fix/build-script-cwd |
| `1a4e3814` | fix: remediate all 50 findings from the 2026-08 security and code audit |
| `9bb267e5` | fix: drop unused ssl import and extra blank lines flagged by flake8 |
| `44edee23` | fix: redeclare error_code removed during bundle-dir validation restructure |
| `11923404` | Merge pull request #11 from Vinax89/fix/audit-2026-08-15 |
| `682ffb1c` | merge: assimilate upstream/dev (55 commits through 091a38a1) |
| `6cc7059b` | fix: post-merge CI fixes — kf6-networkmanager-qt dep, trailing whitespace, section separator |
| `ffa846d1` | Merge pull request #12 from Vinax89/merge/upstream-dev |
| `a30827bf` | fix: make update privilege priming non-fatal |
| `b01c7d42` | Merge pull request #13 from Vinax89/fix/updater-optional-privilege |
| `654702aa` | Merge remote-tracking branch 'upstream/main' |
| `18c6841d` | fix(ci): close workflow_run privilege-escalation path in releases |
| `8aa69f85` | fix(installer): verify prebuilt binaries and restore the bundle root |
| `ccef6fbe` | fix: harden the update, uninstall and deploy paths |
| `29d6b308` | fix(shell): repair a dead singleton call and guard JSON parsing |
| `d4de9b11` | ci: widen the strict-mode gate to every shell script |
| `6a7463c4` | Merge pull request #15 from Vinax89/fix/security-audit-remediation |
| `9be5c89d` | [skip ci] Update contributor stats for v2.3.2 |

## Validation

- Release CMake builds of the installer and all production QML plugin modules,
  with `REQUIRE_CAVA=ON`; dependencies used from temporary directories where
  development headers were unavailable on the host.
- Shell syntax/ShellCheck, Python lint, QML conventions/structural syntax/imports,
  embedded Bash, config/deployment checks, workflow Actionlint, template checks,
  static lifetime checks and repository identity checks.
- Bash helper tests, Python repository tests and installer JSON validation.
  Package ownership regression coverage checks repeat installs and inventory
  failures without invoking the real package manager.
- Qt6 QML parser comparison against upstream, preserving existing baseline
  failures rather than introducing new parser failures.

The real package-manager container matrix is retained in CI but was not run
locally because the Docker daemon is unavailable. No desktop installation,
interactive Plasma runtime test, hosted CI run or remote push is implied by the
local checks. The plugin build still emits upstream conversion warnings.
