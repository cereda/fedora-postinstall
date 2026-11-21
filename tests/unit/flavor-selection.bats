#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/flavor-selection"
    MOCK_BIN="${TEST_ROOT}/bin"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    mkdir -p \
        "${MOCK_BIN}" \
        "${SANDBOX_REPO}" \
        "${TEST_ROOT}/home" \
        "${TEST_ROOT}/cache" \
        "${TEST_ROOT}/state" \
        "${TEST_ROOT}/tmp"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/silverblue" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/workstation" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/profiles" "${SANDBOX_REPO}/"
    cp "${REPO_ROOT}/fedora-postinstall.sh" "${SANDBOX_REPO}/"

    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=45
EOF
    export POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release"
    export HOME="${TEST_ROOT}/home"
    export XDG_CACHE_HOME="${TEST_ROOT}/cache"
    export XDG_STATE_HOME="${TEST_ROOT}/state"

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_GUM_LOG}"
case "${1}" in
    confirm)
        : > "${MOCK_GUM_CONFIRM_MARKER}"
        exit 0
        ;;
    choose)
        : > "${MOCK_GUM_CHOOSE_MARKER}"
        printf '%s\n' "${MOCK_FLAVOR:-}"
        exit 0
        ;;
    style)
        for argument in "$@"; do
            last_argument="${argument}"
        done
        printf '%s\n' "${last_argument}"
        exit 0
        ;;
    input | file) exit 0 ;;
    *) exit 0 ;;
esac
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-E" ]; then
    if [ "${MOCK_RPM_VERSION_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    printf '%s\n' "42"
    exit 0
fi
if [ "${1:-}" = "-q" ]; then
    printf '%s\n' "package ${2} is not installed"
    exit 1
fi
exit 0
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "x86_64"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    chmod +x "${MOCK_BIN}/gum" "${MOCK_BIN}/rpm" "${MOCK_BIN}/uname"
    export MOCK_GUM_CONFIRM_MARKER="${TEST_ROOT}/gum-confirm-called"
    export MOCK_GUM_CHOOSE_MARKER="${TEST_ROOT}/gum-choose-called"
    export MOCK_GUM_LOG="${TEST_ROOT}/gum.log"
    export MOCK_RPM_VERSION_FAIL=0
    export PATH="${MOCK_BIN}:/usr/bin:/bin"
}

run_installer() {
    run env \
        HOME="${TEST_ROOT}/home" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" "$@"
}

@test "an invocation without a command is a usage error" {
    run_installer
    assert_equal "${status}" 64
    assert_output_contains "command is required"
    assert_file_absent "${MOCK_GUM_CONFIRM_MARKER}"
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall/postinstall.lock"
}

@test "an unknown detected flavor requires --flavor before mutation" {
    run_installer install
    assert_equal "${status}" 69
    assert_output_contains "unable to detect Fedora flavor"
    assert_output_contains "--flavor"
    assert_file_absent "${MOCK_GUM_CONFIRM_MARKER}"
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall/postinstall.lock"
}

@test "an ambiguous detected flavor requires --flavor before mutation" {
    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Silverblue"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    run_installer install
    assert_equal "${status}" 69
    assert_output_contains "flavor detection is ambiguous"
    assert_output_contains "--flavor"
    assert_file_absent "${MOCK_GUM_CONFIRM_MARKER}"
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall/postinstall.lock"
}

@test "an explicit flavor succeeds through a mocked dry-run" {
    run_installer install --flavor workstation --dry-run --json
    assert_success
    run jq -e '.flavor.selected == "workstation"' <<<"${output}"
    assert_success
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
}

@test "POSTINSTALL_FLAVOR selects the flavor for an explicit install" {
    run env \
        HOME="${TEST_ROOT}/home" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=silverblue \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" install --dry-run --json
    assert_success
    run jq -e '.flavor.selected == "silverblue"' <<<"${output}"
    assert_success
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
}

@test "automatic detection selects the flavor without a chooser" {
    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    run_installer install --dry-run --json
    assert_success
    run jq -e '.flavor.selected == "workstation"' <<<"${output}"
    assert_success
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
}

@test "a real install exits with the lock contention status before prompting" {
    local lock_file="${TEST_ROOT}/install-contended.lock"
    local marker_file="${TEST_ROOT}/lock-holder-ready"
    local release_file="${TEST_ROOT}/release-lock-holder"
    local holder

    flock "${lock_file}" bash -c \
        'touch "$1"; while [ ! -e "$2" ]; do sleep 0.05; done' \
        _ "${marker_file}" "${release_file}" &
    holder="${!}"
    for _ in {1..100}; do
        [ -e "${marker_file}" ] && break
        sleep 0.05
    done
    if [ ! -e "${marker_file}" ]; then
        kill "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
        return 1
    fi

    run_installer install --flavor workstation --lock-file "${lock_file}"
    touch "${release_file}"
    wait "${holder}" 2>/dev/null || true

    assert_equal "${status}" 75
    assert_output_contains "another installer is already running"
    assert_file_absent "${MOCK_GUM_CONFIRM_MARKER}"
    assert_file_absent "${MOCK_GUM_CHOOSE_MARKER}"
}

@test "a failed real install releases its installation lock" {
    local lock_file="${TEST_ROOT}/cache/fedora-postinstall/postinstall.lock"
    export MOCK_RPM_VERSION_FAIL=1

    run_installer install --flavor workstation
    assert_failure
    assert_output_contains "Unable to determine the Fedora version"
    refute_output_contains "another installer is already running"
    assert_file_exists "${lock_file}"

    run_installer install --flavor workstation
    assert_failure
    assert_output_contains "Unable to determine the Fedora version"
    refute_output_contains "another installer is already running"
}

@test "a checkout reached through a directory symlink remains usable" {
    ln -s "${SANDBOX_REPO}" "${TEST_ROOT}/checkout"

    run bash -c \
        'cd "$1" && exec bash "$2/fedora-postinstall.sh" install --flavor workstation --dry-run --json' \
        _ "${TEST_ROOT}" "${TEST_ROOT}/checkout"
    assert_success
    run jq -e '.flavor.selected == "workstation"' <<<"${output}"
    assert_success
    refute_output_contains "resolves outside the repository"
}
