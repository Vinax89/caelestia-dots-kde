#!/usr/bin/env bash
set -euo pipefail

case "${TEST_DISTRO:?}" in
    arch)
        real_pm=/usr/bin/pacman
        package_script=sdata/arch-dist/installDP.sh
        packages="tree jq"
        query=(pacman -Q)
        remove=(pacman -Rns --noconfirm)
        rollback_pkg=which
        "$real_pm" -Syu --noconfirm --needed bash coreutils git jq tree
        ;;
    fedora)
        real_pm=/usr/bin/dnf
        package_script=sdata/fedora-dist/installDP_fedora.sh
        packages="tree jq"
        query=(rpm -q)
        remove=(dnf remove -y)
        rollback_pkg=which
        "$real_pm" install -y bash coreutils git jq tree
        ;;
    debian)
        real_pm=/usr/bin/apt-get
        package_script=sdata/debian-dist/installDP_debian.sh
        packages="tree jq"
        query=(dpkg -s)
        remove=(apt-get purge -y)
        rollback_pkg=gnu-which
        "$real_pm" update
        DEBIAN_FRONTEND=noninteractive "$real_pm" install -y --no-install-recommends bash coreutils git jq tree
        ;;
    *) echo "unsupported distro: $TEST_DISTRO" >&2; exit 2 ;;
esac

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/home" "$test_root/cache"

# Scripts use sudo even in root-owned containers. Keep privilege behavior in
# the command line while avoiding an unnecessary sudo package dependency.
cat > "$test_root/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$test_root/bin/sudo"

# Arch's production path uses yay for both repository and AUR packages. For
# this repository-only test set, delegate yay to the real pacman binary.
if [[ "$TEST_DISTRO" == arch ]]; then
    cat > "$test_root/bin/yay" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/pacman "$@"
EOF
    chmod +x "$test_root/bin/yay"
fi

export PATH="$test_root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="$test_root/home"
export XDG_CACHE_HOME="$test_root/cache"
export BASE_DISTRO="$TEST_DISTRO"
export PACKAGE_GROUP=core
export CAELESTIA_INTEGRATION_PACKAGES="$packages"

echo "[case] idempotent real package install"
bash "$package_script"
bash "$package_script"
for package in $packages; do
    "${query[@]}" "$package" >/dev/null
done

echo "[case] batch failure followed by real-manager retry"
"${remove[@]}" tree
state="$test_root/fail-once"
touch "$state"
case "$TEST_DISTRO" in
    arch) proxy=yay; real_for_proxy=/usr/bin/pacman ;;
    fedora) proxy=dnf; real_for_proxy=/usr/bin/dnf ;;
    debian) proxy=apt-get; real_for_proxy=/usr/bin/apt-get ;;
esac
cat > "$test_root/bin/$proxy" <<EOF
#!/usr/bin/env bash
if [[ -f "$state" && "\$*" == *"tree jq"* ]]; then
    rm -f "$state"
    echo "injected first batch failure" >&2
    exit 75
fi
exec "$real_for_proxy" "\$@"
EOF
chmod +x "$test_root/bin/$proxy"
bash "$package_script"
[[ ! -e "$state" ]]
"${query[@]}" tree >/dev/null

echo "[case] cancellation terminates the active package transaction"
cat > "$test_root/bin/$proxy" <<EOF
#!/usr/bin/env bash
trap 'exit 130' INT TERM
sleep 30 &
wait
EOF
chmod +x "$test_root/bin/$proxy"
set +e
timeout --signal=TERM --kill-after=2 1 bash "$package_script" >"$test_root/cancel.log" 2>&1
cancel_status=$?
set -e
[[ $cancel_status -eq 124 || $cancel_status -eq 137 || $cancel_status -eq 143 ]]

echo "[case] rollback returns package state to the captured baseline"
rm -f "$test_root/bin/$proxy"
was_present=0
if "${query[@]}" "$rollback_pkg" >/dev/null 2>&1; then
    was_present=1
fi
case "$TEST_DISTRO" in
    arch) /usr/bin/pacman -S --needed --noconfirm "$rollback_pkg" ;;
    fedora) /usr/bin/dnf install -y "$rollback_pkg" ;;
    debian) DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install -y --no-install-recommends "$rollback_pkg" ;;
esac
if [[ $was_present -eq 0 ]]; then
    "${remove[@]}" "$rollback_pkg"
    ! "${query[@]}" "$rollback_pkg" >/dev/null 2>&1
fi

echo "[ok] $TEST_DISTRO installer integration scenarios passed"
