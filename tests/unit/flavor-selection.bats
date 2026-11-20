#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/flavor-selection"
    MOCK_BIN="${TEST_ROOT}/bin"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    mkdir -p "${MOCK_BIN}" "${SANDBOX_REPO}"

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

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
    confirm) exit 0 ;;
    choose)
        printf '%s\n' "${MOCK_FLAVOR:-}"
        exit "${MOCK_CHOOSE_STATUS:-0}"
        ;;
    style)
        for argument in "$@"; do
            last_argument="${argument}"
        done
        printf '%s\n' "${last_argument}"
        exit 0
        ;;
    input) exit 0 ;;
    file) exit 0 ;;
    *) exit 0 ;;
esac
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1}" = "-E" ]; then
    printf '%s\n' "42"
fi
EOF

    chmod +x "${MOCK_BIN}/gum" "${MOCK_BIN}/rpm"
    export PATH="${MOCK_BIN}:${PATH}"
}

@test "cancelling flavor selection aborts before configuration" {
    run bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_failure
    assert_output_contains "No Fedora flavour was selected"

    assert_file_absent "${SANDBOX_REPO}/archives"
    assert_file_absent "${SANDBOX_REPO}/deploys"
}

@test "the implicit invocation keeps the chooser even when detection is available" {
    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    run bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_failure
    assert_output_contains "No Fedora flavour was selected"
}

@test "the implicit invocation keeps the chooser when an environment flavor is set" {
    run env \
        POSTINSTALL_FLAVOR=workstation \
        bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ \
        "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_failure
    assert_output_contains "No Fedora flavour was selected"
    refute_output_contains "You are running Fedora Workstation"
}

@test "a failed flavor chooser aborts even when it printed a flavor" {
    export MOCK_FLAVOR="Workstation"
    export MOCK_CHOOSE_STATUS=7

    run bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_failure
    assert_output_contains "Unable to read the Fedora flavour selection"
    refute_output_contains "You are running Fedora Workstation"
}

@test "an unknown non-empty flavor selection aborts" {
    export MOCK_FLAVOR="Unknown Fedora"

    run bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_failure
    assert_output_contains "Invalid Fedora flavour 'Unknown Fedora'"
}

@test "a checkout reached through a directory symlink remains usable" {
    ln -s "${SANDBOX_REPO}" "${TEST_ROOT}/checkout"

    run bash -c 'cd "$1" && exec bash "$2/fedora-postinstall.sh"' _ "${TEST_ROOT}" "${TEST_ROOT}/checkout"
    assert_failure
    assert_output_contains "No Fedora flavour was selected"
    refute_output_contains "resolves outside the repository"
}
