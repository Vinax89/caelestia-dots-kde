#!/usr/bin/env bash
# check_shell_quality.sh - Shell script quality checks for CI.
#
# Checks performed:
#   1. All shell scripts parse with `bash -n` (syntax check)
#   2. All shell scripts pass shellcheck at warning severity
#   3. All .sh files inside scripts/ use `set -euo pipefail`
#   4. Scripts in scripts/ do not bypass the PATH sudo wrapper
#   5. No hardcoded insecure patterns (e.g. curl | bash)
#
# "Shell script" means a tracked *.sh file OR a tracked extensionless file
# whose shebang names sh/bash -- the src/bin/caelestia-* entrypoints are the
# latter, and they carry the updater, so they must not be skipped.
#
# Usage: bash .github/scripts/check_shell_quality.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

EXIT_CODE=0
VIOLATIONS=()

log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()   { echo -e "${RED}[ERR]${RESET}   $*"; VIOLATIONS+=("$*"); EXIT_CODE=1; }

# Returns 0 if the file's shebang names a POSIX shell or bash.
#
# The previous pattern was '^#!.*/(ba)?sh', which requires a literal "/sh" or
# "/bash" and therefore never matched "#!/usr/bin/env bash" -- the shebang every
# script in this repository actually uses. That silently excluded setup.sh,
# update.sh, uninstall.sh, the sdata installers and all of src/bin.
is_shell_script() {
    local file="$1"
    head -c 64 "$file" 2>/dev/null | head -n 1 | grep -qE '^#!.*\b(ba)?sh\b'
}

# Every tracked shell script, NUL-delimited so paths with spaces survive.
get_shell_files() {
    {
        git ls-files -z '*.sh'
        git ls-files -z | while IFS= read -r -d '' f; do
            case "$f" in
                *.sh) ;;
                *) if [[ -f "$f" ]] && is_shell_script "$f"; then printf '%s\0' "$f"; fi ;;
            esac
        done
    } | sort -zu
}

mapfile -t -d '' SHELL_FILES < <(get_shell_files)
echo -e "${BOLD}Discovered ${#SHELL_FILES[@]} shell script(s).${RESET}"

# ─── 1. Syntax check: bash -n on every shell script ───
echo ""
echo -e "${BOLD}=== Shell Syntax Check (bash -n) ===${RESET}"
for f in "${SHELL_FILES[@]}"; do
    if ! err_output="$(bash -n "$f" 2>&1)"; then
        log_err "Syntax error in $f: $err_output"
    fi
done
if [[ "$EXIT_CODE" -eq 0 ]]; then
    log_ok "All shell scripts passed syntax check"
fi

# ─── 2. shellcheck ───
echo ""
echo -e "${BOLD}=== ShellCheck Lint ===${RESET}"
if command -v shellcheck &>/dev/null; then
    shellcheck_failed=0
    for f in "${SHELL_FILES[@]}"; do
        if ! shellcheck -S warning "$f"; then
            log_err "shellcheck violations in $f"
            shellcheck_failed=1
        fi
    done
    if [[ "$shellcheck_failed" -eq 0 ]]; then
        log_ok "shellcheck passed on all ${#SHELL_FILES[@]} scripts"
    fi
else
    log_err "shellcheck is not installed - the lint gate cannot run"
fi

# ─── 3. Strict mode check (set -euo pipefail) ───
echo ""
echo -e "${BOLD}=== Strict Mode Check ===${RESET}"
# Enforced for scripts/ where every script follows the convention. src/bin/*
# are covered by syntax + shellcheck above but deliberately vary their `set`
# flags (e.g. caelestia-check-updates relies on explicit exits), so they are
# not forced to -euo here.
strict_failed=0
while IFS= read -r -d '' f; do
    if ! grep -qE 'set\s+-euo\s+pipefail|set\s+-eu\s+-o\s+pipefail' "$f" 2>/dev/null; then
        log_err "$f is missing 'set -euo pipefail' (required for scripts in scripts/)"
        strict_failed=1
    fi
done < <(git ls-files -z 'scripts/*.sh')
if [[ "$strict_failed" -eq 0 ]]; then
    log_ok "All scripts in scripts/ use strict mode"
fi

# ─── 4. Privilege wrapper bypass ───
echo ""
echo -e "${BOLD}=== Privilege Wrapper Check ===${RESET}"
# The installer and the updater both prepend a private bin/ containing a `sudo`
# shim to PATH, so plain `sudo` resolves to the wrapper. Calling sudo by
# absolute path bypasses it, defeating the non-interactive credential handling.
# src/bin/caelestia-update is exempt: it *writes* the wrapper and must call the
# real binary to avoid recursing into itself.
wrapper_failed=0
while IFS= read -r -d '' f; do
    if grep -nE '(^|[^[:alnum:]_/])/(usr/)?bin/sudo\b' "$f" >/dev/null 2>&1; then
        log_err "$f calls sudo by absolute path, bypassing the PATH privilege wrapper"
        wrapper_failed=1
    fi
done < <(git ls-files -z 'scripts/*.sh')
if [[ "$wrapper_failed" -eq 0 ]]; then
    log_ok "No scripts bypass the privilege wrapper"
fi

# ─── 5. No curl-pipe-bash patterns ───
echo ""
echo -e "${BOLD}=== Unsafe Pattern Detection ===${RESET}"
CURL_PIPE_FOUND=0
for f in "${SHELL_FILES[@]}"; do
    # Skip this checker itself — it describes patterns, not uses them.
    [[ "$f" == ".github/scripts/check_shell_quality.sh" ]] && continue
    # Skip comment-only lines so doc strings don't self-match.
    if grep -nE 'curl\s.*\|\s*(sudo\s+)?(ba)?sh\b' "$f" 2>/dev/null | grep -vE '(^[0-9]+:\s*#|ci:allow-curl-pipe)'; then
        log_err "$f contains unsafe 'curl | bash' pattern"
        CURL_PIPE_FOUND=1
    fi
    # Flag wget -O - | sh patterns too
    if grep -nE 'wget\s.*-O\s*-\s*.*\|\s*(sudo\s+)?(ba)?sh\b' "$f" 2>/dev/null | grep -vE '(^[0-9]+:\s*#|ci:allow-curl-pipe)'; then
        log_err "$f contains unsafe 'wget -O - | sh' pattern"
        CURL_PIPE_FOUND=1
    fi
done
if [[ "$CURL_PIPE_FOUND" -eq 0 ]]; then
    log_ok "No unsafe curl/wget-pipe-shell patterns found"
fi

# ─── Summary ───
echo ""
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}All shell quality checks passed.${RESET}"
else
    echo -e "${BOLD}${RED}${#VIOLATIONS[@]} shell quality violation(s) found.${RESET}"
fi

exit "$EXIT_CODE"
