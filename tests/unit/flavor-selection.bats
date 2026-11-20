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
    cp "${REPO_ROOT}/fedora-postinstall.sh" "${SANDBOX_REPO}/"

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
    confirm) exit 0 ;;
    choose) exit 0 ;;
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
