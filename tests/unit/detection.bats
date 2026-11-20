#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/detection"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"

    mkdir -p "${SANDBOX_REPO}/common" "${TEST_HOME}" "${MOCK_BIN}"
    cp "${REPO_ROOT}/common/runtime.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/cli.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/detection.sh" "${SANDBOX_REPO}/common/"

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-q" ]; then
    case "${2}" in
        fedora-release-identity-workstation|fedora-release-workstation)
            if [ "${MOCK_RPM_WORKSTATION:-0}" = "1" ]; then
                printf '%s\n' "${2}-45-1.noarch"
                exit 0
            fi
            ;;
        fedora-release-identity-silverblue|fedora-release-silverblue)
            if [ "${MOCK_RPM_SILVERBLUE:-0}" = "1" ]; then
                printf '%s\n' "${2}-45-1.noarch"
                exit 0
            fi
            ;;
    esac
    printf '%s\n' "package ${2} is not installed"
    exit 1
fi
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_ARCHITECTURE:-x86_64}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF
    chmod +x "${MOCK_BIN}/rpm" "${MOCK_BIN}/uname"
}

detect_flavor() {
    local os_release="${1}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${os_release}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; source '${SANDBOX_REPO}/common/cli.sh'; source '${SANDBOX_REPO}/common/detection.sh'; detection_detect_flavor; status=\$?; printf '%s\\n' \"\${DETECTION_FLAVOR}\"; exit \${status}"
}

@test "os-release identifies Fedora Workstation" {
    local os_release="${TEST_ROOT}/workstation-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    detect_flavor "${os_release}"
    assert_success
    assert_equal "${output}" "workstation"
}

@test "os-release identifies Fedora Silverblue" {
    local os_release="${TEST_ROOT}/silverblue-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Silverblue"
ID=fedora
VERSION_ID=45
VARIANT_ID=silverblue
EOF

    detect_flavor "${os_release}"
    assert_success
    assert_equal "${output}" "silverblue"
}

@test "RPM metadata provides a flavor fallback" {
    local os_release="${TEST_ROOT}/generic-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=45
EOF

    export MOCK_RPM_SILVERBLUE=1
    detect_flavor "${os_release}"
    assert_success
    assert_equal "${output}" "silverblue"
}

@test "conflicting os-release and RPM flavor signals are ambiguous" {
    local os_release="${TEST_ROOT}/workstation-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    export MOCK_RPM_SILVERBLUE=1
    detect_flavor "${os_release}"
    assert_failure
    assert_equal "${output}" ""
}

@test "architecture detection normalizes the host machine name" {
    export MOCK_ARCHITECTURE="arm64"
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; source '${SANDBOX_REPO}/common/detection.sh'; detection_detect_architecture; printf '%s\\n' \"\${DETECTION_ARCHITECTURE}\""
    assert_success
    assert_equal "${output}" "aarch64"
}

@test "simultaneous Workstation and Silverblue RPM identities are ambiguous" {
    local os_release="${TEST_ROOT}/generic-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=45
EOF

    export MOCK_RPM_WORKSTATION=1
    export MOCK_RPM_SILVERBLUE=1
    detect_flavor "${os_release}"
    assert_failure
    assert_equal "${output}" ""
}

@test "conflicting os-release flavor fields are ambiguous" {
    local os_release="${TEST_ROOT}/conflicting-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Silverblue"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    detect_flavor "${os_release}"
    assert_failure
    assert_equal "${output}" ""
}

@test "an explicit flavor resolves ambiguous detection" {
    local os_release="${TEST_ROOT}/conflicting-os-release"
    cat > "${os_release}" <<'EOF'
NAME="Fedora Silverblue"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${os_release}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; source '${SANDBOX_REPO}/common/cli.sh'; source '${SANDBOX_REPO}/common/detection.sh'; CLI_FLAVOR=workstation; detection_resolve_flavor"
    assert_success
    assert_equal "${output}" "workstation"
}
