#!/usr/bin/env python3
"""Check repository file hygiene for files changed in this PR only.

Checks:
  1. No files > 500 KB (prevents accidental large binary commits)
  2. No unresolved merge conflict markers (<<<<<<<, =======, >>>>>>>)
  3. No trailing whitespace in code files
  4. No tab indentation in QML / Python / CMake / C++ files
  5. No binary files in text-only directories (docs/, scripts/)
  6. .sh files have the correct extension and shebang
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
BOLD = "\033[1m"
RESET = "\033[0m"

MAX_FILE_SIZE_KB = 500

EXIT_CODE = 0
VIOLATIONS: list[str] = []

# Files and directories to always skip
SKIP_PATTERNS = [
    "diff_upstream.txt",
    "QMLTermWidget",
    "json.hpp",
]

# Files/dirs skipped for whitespace/tab checks (vendored/generated)
STYLE_SKIP_DIRS = {"QMLTermWidget", "build", "__pycache__", ".git"}


def error(msg: str) -> None:
    global EXIT_CODE
    print(f"{RED}[ERR]{RESET}  {msg}")
    VIOLATIONS.append(msg)
    EXIT_CODE = 1


def warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


def ok(msg: str) -> None:
    print(f"{GREEN}[OK]{RESET}   {msg}")


def is_text_file(filepath: Path) -> bool:
    """Heuristic: a NUL byte in the first 8 KB means binary.

    Sniffing a prefix rather than decoding the whole file matters in --all mode,
    where the alternative is decoding every .mp4, .wav and .png in an 88 MB tree.
    """
    try:
        with filepath.open("rb") as handle:
            chunk = handle.read(8192)
    except OSError:
        return False
    if b"\0" in chunk:
        return False
    try:
        chunk.decode("utf-8")
    except UnicodeDecodeError as exc:
        # Tolerate a multi-byte character split by the 8 KB read boundary; only
        # a failure earlier in the buffer is evidence of a binary file.
        return len(chunk) == 8192 and exc.start >= len(chunk) - 4
    return True


def should_skip(rel_path: str, patterns: list[str] | None = None) -> bool:
    """Check if a path should be skipped based on patterns."""
    for pat in (patterns or SKIP_PATTERNS):
        if pat in rel_path.replace("\\", "/"):
            return True
    return False


def _git(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        ["git", *args], capture_output=True, text=True, cwd=ROOT,
    )
    return result.returncode, result.stdout


def _is_merge_commit(rev: str = "HEAD") -> bool:
    code, out = _git("rev-list", "--no-walk", "--count", "--merges", rev)
    return code == 0 and out.strip() == "1"


def get_changed_files() -> list[str]:
    """Return the files this PR or push changed.

    Every strategy here must either produce a real file list or fall through to
    the next one -- returning an empty list on failure silently disables the
    gate, which is exactly what this function used to do on pull requests.
    """
    strategies: list[tuple[str, list[str]]] = []

    # 1. Pull request: diff against the merge base with the target branch.
    #    Requires fetch-depth: 0, which the workflow now sets.
    base_ref = os.environ.get("GITHUB_BASE_REF")
    if base_ref:
        strategies.append(
            (f"merge base with origin/{base_ref}",
             ["diff", "--name-only", f"origin/{base_ref}...HEAD"])
        )

    # 2. Pull request without a usable remote ref: actions/checkout leaves HEAD
    #    as the synthesized merge commit, whose first parent is the base tip.
    #    `diff-tree HEAD` prints nothing at all for a merge, so it must not be
    #    the fallback -- diffing against the first parent is what we want.
    if _is_merge_commit():
        strategies.append(
            ("first parent of the merge commit",
             ["diff", "--name-only", "HEAD^1", "HEAD"])
        )

    # 3. Push events: compare against the default branch when it is available.
    code, _ = _git("rev-parse", "--verify", "origin/main")
    if code == 0:
        strategies.append(
            ("origin/main", ["diff", "--name-only", "origin/main...HEAD"])
        )

    # 4. Single non-merge commit.
    strategies.append(
        ("HEAD commit", ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
    )

    for label, argv in strategies:
        code, out = _git(*argv)
        if code != 0:
            print(f"{YELLOW}[skip]{RESET} {label}: git exited {code}")
            continue
        files = [f.strip() for f in out.splitlines() if f.strip()]
        if files:
            print(f"Checking {len(files)} changed file(s) via {label}")
            return files
        print(f"{YELLOW}[skip]{RESET} {label}: produced no files")

    raise RuntimeError(
        "Unable to determine changed files for hygiene check. "
        "Ensure the workflow checks out with fetch-depth: 0."
    )


TEXT_FILE_EXTS = {".qml", ".py", ".cpp", ".hpp", ".h", ".cmake", ".txt",
                  ".md", ".json", ".yml", ".yaml", ".sh", ".bash",
                  ".css", ".js", ".ts", ".xml", ".html", ".conf",
                  ".desktop", ".service", ".timer", ".env", ".toml"}

SPACE_ONLY_EXTS = {".qml", ".py", ".cpp", ".hpp", ".h"}


def check_large_files(changed_files: list[str]) -> None:
    """Check for files larger than MAX_FILE_SIZE_KB in changed files."""
    for rel_path in changed_files:
        if should_skip(rel_path):
            continue

        filepath = ROOT / rel_path
        if not filepath.is_file():
            continue

        try:
            size_kb = filepath.stat().st_size / 1024
        except OSError:
            continue

        if size_kb > MAX_FILE_SIZE_KB:
            if any(skip in rel_path for skip in ("wallpapers", "sounds", "assets")):
                warn(f"Large asset file: {rel_path} ({size_kb:.0f} KB)")
            else:
                error(f"File too large ({size_kb:.0f} KB): {rel_path} - max allowed is {MAX_FILE_SIZE_KB} KB")


def check_merge_conflicts(changed_files: list[str]) -> None:
    """Check for unresolved merge conflict markers in changed files."""
    conflict_markers = (
        re.compile(rb"^<{7} "),
        re.compile(rb"^={7}$"),
        re.compile(rb"^>{7} "),
    )

    for rel_path in changed_files:
        if should_skip(rel_path):
            continue

        filepath = ROOT / rel_path
        if not filepath.is_file():
            continue
        # Conflict markers only appear in text we would ever merge; skipping by
        # extension first avoids sniffing every asset in --all mode.
        if filepath.suffix not in TEXT_FILE_EXTS:
            continue
        if not is_text_file(filepath):
            continue

        try:
            content = filepath.read_bytes()
        except OSError:
            continue

        for line_no, line in enumerate(content.split(b"\n"), 1):
            for marker in conflict_markers:
                if marker.match(line):
                    error(f"Unresolved merge conflict in {rel_path}:{line_no}")
                    break


def check_trailing_whitespace(changed_files: list[str]) -> None:
    """Check for trailing whitespace in changed code files."""
    for rel_path in changed_files:
        if should_skip(rel_path, SKIP_PATTERNS):
            continue

        filepath = ROOT / rel_path
        if not filepath.is_file():
            continue

        ext = filepath.suffix
        if ext not in TEXT_FILE_EXTS:
            continue
        if not is_text_file(filepath):
            continue

        # Skip vendored directories
        if any(d in rel_path.replace("\\", "/").split("/") for d in STYLE_SKIP_DIRS):
            continue

        try:
            lines = filepath.read_text(encoding="utf-8").split("\n")
        except OSError:
            continue

        for line_no, line in enumerate(lines, 1):
            # `lines` is already split on "\n", so a difference after rstrip()
            # is trailing whitespace and nothing else.
            if line.rstrip() != line:
                error(f"Trailing whitespace: {rel_path}:{line_no}")


def check_tab_indentation(changed_files: list[str]) -> None:
    """Check that code files use spaces, not tabs."""
    for rel_path in changed_files:
        if should_skip(rel_path, SKIP_PATTERNS):
            continue

        filepath = ROOT / rel_path
        if not filepath.is_file():
            continue

        if filepath.suffix not in SPACE_ONLY_EXTS:
            continue
        if not is_text_file(filepath):
            continue

        if any(d in rel_path.replace("\\", "/").split("/") for d in STYLE_SKIP_DIRS):
            continue

        try:
            lines = filepath.read_text(encoding="utf-8").split("\n")
        except OSError:
            continue

        for line_no, line in enumerate(lines, 1):
            if line.startswith("\t"):
                error(f"Tab indentation in {rel_path}:{line_no} - use spaces instead")
                break


def check_binary_in_text_dirs(changed_files: list[str]) -> None:
    """Flag binary files in directories that should only contain text."""
    text_only_dirs = ["docs", "scripts", ".github/scripts"]

    for rel_path in changed_files:
        for check_dir in text_only_dirs:
            if rel_path.replace("\\", "/").startswith(check_dir + "/"):
                filepath = ROOT / rel_path
                if filepath.is_file() and not is_text_file(filepath):
                    error(f"Binary file in text-only directory: {rel_path}")
                break


def check_shell_extensions(changed_files: list[str]) -> None:
    """Ensure .sh files are shell scripts with proper shebangs."""
    for rel_path in changed_files:
        if not rel_path.endswith(".sh"):
            continue
        if should_skip(rel_path):
            continue

        filepath = ROOT / rel_path
        if not filepath.is_file():
            continue

        try:
            first_line = filepath.read_text(encoding="utf-8").split("\n")[0]
        except (OSError, UnicodeDecodeError):
            continue

        if not first_line.startswith("#!"):
            warn(f"Shell script missing shebang: {rel_path}")
        elif "sh" not in first_line.split("/")[-1]:
            warn(f"Shell script has unexpected shebang: {rel_path}: {first_line}")


def main() -> int:
    # --all scans every git-tracked file (used for push events where there is
    # no PR diff to diff against). Without it, only changed files are checked.
    all_files = "--all" in sys.argv
    report_only = "--report-only" in sys.argv
    if all_files:
        result = subprocess.run(
            ["git", "ls-files"],
            capture_output=True, text=True, cwd=ROOT,
        )
        changed_files = [f.strip() for f in result.stdout.splitlines() if f.strip()]
        print(f"Checking {len(changed_files)} tracked file(s) (full-repo mode)")
    else:
        changed_files = get_changed_files()

    if not changed_files:
        print(f"{YELLOW}No files to check.{RESET}")
        return 0

    print(f"{BOLD}=== File Size Check ==={RESET}")
    check_large_files(changed_files)
    if EXIT_CODE == 0:
        ok("No oversized files found")

    print(f"\n{BOLD}=== Merge Conflict Marker Check ==={RESET}")
    check_merge_conflicts(changed_files)
    if EXIT_CODE == 0:
        ok("No unresolved merge conflicts")

    print(f"\n{BOLD}=== Trailing Whitespace Check ==={RESET}")
    check_trailing_whitespace(changed_files)
    if EXIT_CODE == 0:
        ok("No trailing whitespace")

    print(f"\n{BOLD}=== Tab Indentation Check ==={RESET}")
    check_tab_indentation(changed_files)
    if EXIT_CODE == 0:
        ok("No tab indentation in code files")

    print(f"\n{BOLD}=== Binary in Text Directories Check ==={RESET}")
    check_binary_in_text_dirs(changed_files)
    if EXIT_CODE == 0:
        ok("No binary files in text-only directories")

    print(f"\n{BOLD}=== Shell Script Extension Check ==={RESET}")
    check_shell_extensions(changed_files)
    if EXIT_CODE == 0:
        ok("All .sh files have proper shebangs")

    print()
    if EXIT_CODE == 0:
        print(f"{BOLD}{GREEN}All file hygiene checks passed.{RESET}")
    else:
        print(f"{BOLD}{RED}{len(VIOLATIONS)} file hygiene violation(s) found.{RESET}")
        if report_only:
            print(f"{YELLOW}Full-repository scan is report-only; changed-file checks remain blocking.{RESET}")

    return 0 if report_only else EXIT_CODE


if __name__ == "__main__":
    sys.exit(main())
