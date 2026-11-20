#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/cli"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    TMP_ROOT="${TEST_ROOT}/tmp"
    FORBIDDEN_MARKER="${TEST_ROOT}/forbidden-command"
    OS_RELEASE_FILE="${TEST_ROOT}/os-release"

    mkdir -p \
        "${SANDBOX_REPO}" \
        "${TEST_HOME}" \
        "${MOCK_BIN}" \
        "${TMP_ROOT}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/profiles" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/docs" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/workstation" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/silverblue" "${SANDBOX_REPO}/"
    cp "${REPO_ROOT}/fedora-postinstall.sh" "${SANDBOX_REPO}/"

    cat > "${OS_RELEASE_FILE}" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_ARCHITECTURE:-x86_64}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -E)
        printf '%s\n' "45"
        ;;
    -q)
        printf '%s\n' "package ${2} is not installed"
        exit 1
        ;;
esac
EOF

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    style)
        for argument in "$@"; do
            last_argument="${argument}"
        done
        printf '%s\n' "${last_argument}"
        ;;
    *) exit 0 ;;
esac
EOF

    cat > "${MOCK_BIN}/forbidden" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FORBIDDEN_MARKER}"
printf 'forbidden command invoked: %s\n' "$*" >&2
exit 99
EOF

    for command in sudo dnf flatpak gsettings hostnamectl curl wget toolbox git; do
        cp "${MOCK_BIN}/forbidden" "${MOCK_BIN}/${command}"
    done

    chmod +x "${MOCK_BIN}"/*

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_FORBIDDEN_MARKER="${FORBIDDEN_MARKER}"
    export POSTINSTALL_OS_RELEASE_FILE="${OS_RELEASE_FILE}"
}

run_cli() {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" "$@"
}

@test "help is available without invoking installation dependencies" {
    run_cli help
    assert_success
    assert_output_contains "Usage: bash fedora-postinstall.sh"
    assert_file_absent "${FORBIDDEN_MARKER}"
}

@test "unknown commands fail with the usage exit status" {
    run_cli unknown
    assert_equal "${status}" 64
    assert_output_contains "unknown command"
}

@test "missing option values fail with the usage exit status" {
    run_cli --flavor
    assert_equal "${status}" 64
    assert_output_contains "requires a value"
}

@test "empty profile option values fail with the usage exit status" {
    run_cli plan --profile=
    assert_equal "${status}" 64
    assert_output_contains "--profile requires a value"

    run_cli plan --profile-file=
    assert_equal "${status}" 64
    assert_output_contains "--profile-file requires a value"
}

@test "CLI_TOOLS_ONLY keeps its presence-based default" {
    run env \
        CLI_TOOLS_ONLY=0 \
        bash -c "source '${SANDBOX_REPO}/common/cli.sh'; cli_parse_arguments; printf '%s\\n' \"\${CLI_COMMAND}\""

    assert_success
    assert_equal "${output}" "extras"
}

@test "an explicit install still honors a present CLI_TOOLS_ONLY variable" {
    run env \
        CLI_TOOLS_ONLY= \
        bash -c "source '${SANDBOX_REPO}/common/cli.sh'; cli_parse_arguments install; printf '%s\\n' \"\${CLI_COMMAND}\""

    assert_success
    assert_output_contains "using the extras command"
    assert_output_contains "extras"
}

@test "detect reports the operating system, flavor, and architecture" {
    run_cli detect
    assert_success
    assert_output_contains "Fedora Workstation"
    assert_output_contains "Selected flavor: workstation"
    assert_output_contains "Selected architecture: x86_64"
}

@test "detect can emit stable JSON" {
    run_cli detect --json
    assert_success
    run jq -e '
        .schema_version == 1 and
        .os.id == "fedora" and
        .flavor.detected == "workstation" and
        .architecture.selected == "x86_64"
    ' <<<"${output}"
    assert_success
}

@test "architecture aliases select only canonical manifest keys" {
    run_cli plan --json --architecture amd64 --tool fd
    assert_success
    run jq -e '
        .architecture.selected == "x86_64" and
        (.extras.tools | length == 1) and
        (.extras.tools[0].id == "fd") and
        (.extras.tools[0].url | contains("x86_64") or contains("amd64"))
    ' <<<"${output}"
    assert_success
}

@test "all extras omits tools without a declared AArch64 asset" {
    run_cli plan --json --architecture aarch64 --all-extras
    assert_success
    run jq -e '
        (.extras.tools | length > 0) and
        (all(.extras.tools[]; .id != "jless"))
    ' <<<"${output}"
    assert_success
}

@test "an unsupported explicit tool architecture fails before any command" {
    run_cli plan --architecture aarch64 --tool jless
    assert_equal "${status}" 69
    assert_output_contains "not available for architecture aarch64"
    assert_file_absent "${FORBIDDEN_MARKER}"
}

@test "conflicting profile options are rejected" {
    local profile="${TEST_ROOT}/profile.json"
    printf '{"schema_version":1,"name":"test","description":"test"}\n' > "${profile}"

    run_cli plan --profile default --profile-file "${profile}"
    assert_equal "${status}" 64
    assert_output_contains "cannot be used together"
}

@test "conflicting profile environment variables are rejected" {
    local profile="${TEST_ROOT}/profile.json"
    printf '{"schema_version":1,"name":"test","description":"test"}\n' > "${profile}"

    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_PROFILE=default \
        POSTINSTALL_PROFILE_FILE="${profile}" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan
    assert_equal "${status}" 64
    assert_output_contains "cannot be used together"
}

@test "a command-line profile overrides a conflicting environment file" {
    local profile="${TEST_ROOT}/profile.json"
    printf '{"schema_version":1,"name":"invalid","description":"invalid"}\n' > "${profile}"

    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_PROFILE_FILE="${profile}" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --profile default
    assert_success
}

@test "a command-line profile overrides conflicting environment profile settings" {
    local profile="${TEST_ROOT}/profile.json"
    printf '{"schema_version":1,"name":"invalid","description":"invalid"}\n' > "${profile}"

    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_PROFILE=invalid \
        POSTINSTALL_PROFILE_FILE="${profile}" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --profile default
    assert_success
}

@test "detect rejects profile selection options" {
    run_cli detect --profile default
    assert_equal "${status}" 64
    assert_output_contains "not valid for detect"
}

@test "a command-line flavor overrides the environment" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=silverblue \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json --flavor workstation
    assert_success
    run jq -e '.flavor.selected == "workstation"' <<<"${output}"
    assert_success
}

@test "an explicit install honors the environment flavor" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=silverblue \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" install --dry-run --json
    assert_success
    run jq -e '.flavor.selected == "silverblue"' <<<"${output}"
    assert_success
}
