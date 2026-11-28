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
    GUM_MARKER="${TEST_ROOT}/gum-called"
    DEPENDENCY_MARKER="${TEST_ROOT}/dependency-source-called"
    OS_RELEASE_FILE="${TEST_ROOT}/os-release"
    STDOUT_FILE="${TEST_ROOT}/stdout"
    STDERR_FILE="${TEST_ROOT}/stderr"

    mkdir -p \
        "${SANDBOX_REPO}" \
        "${TEST_HOME}" \
        "${MOCK_BIN}" \
        "${TMP_ROOT}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    printf '\n: > "%s"\n' "${DEPENDENCY_MARKER}" >> \
        "${SANDBOX_REPO}/common/dependencies.sh"
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
: > "${MOCK_GUM_MARKER}"
case "${1:-}" in
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
    export MOCK_GUM_MARKER="${GUM_MARKER}"
    export POSTINSTALL_OS_RELEASE_FILE="${OS_RELEASE_FILE}"
}

run_cli() {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" "$@"
}

@test "help is available without invoking installation dependencies" {
    run_cli help
    assert_success
    assert_output_contains "Usage: bash fedora-postinstall.sh <command> [OPTIONS]"
    assert_output_contains "A command is required"
    refute_output_contains "install              Run the Fedora post-installation flow (default)"
    assert_output_contains "--cache-dir PATH"
    assert_output_contains "--lock-file PATH"
    assert_file_absent "${FORBIDDEN_MARKER}"
    assert_file_absent "${GUM_MARKER}"
}

@test "a command is required and no-command invocation has no side effects" {
    run_cli
    assert_equal "${status}" 64
    assert_output_contains "command is required"
    assert_file_absent "${DEPENDENCY_MARKER}"
    assert_file_absent "${FORBIDDEN_MARKER}"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall/postinstall.lock"
    assert_file_absent "${TEST_ROOT}/state/fedora-postinstall/state.tsv"
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

@test "snapshot labels and identifiers reject unsafe terminal text" {
    run_cli snapshot create $'unsafe\nlabel'
    assert_equal "${status}" "64"
    assert_output_contains "invalid snapshot label"

    run_cli snapshot diff valid $'unsafe\nidentifier'
    assert_equal "${status}" "64"
    assert_output_contains "invalid snapshot identifier"

    run_cli snapshot restore $'unsafe\nidentifier'
    assert_equal "${status}" "64"
    assert_output_contains "invalid snapshot identifier"
}

@test "cache and lock options require values" {
    run_cli plan --cache-dir
    assert_equal "${status}" 64
    assert_output_contains "--cache-dir requires a value"

    run_cli plan --lock-file
    assert_equal "${status}" 64
    assert_output_contains "--lock-file requires a value"

    run_cli plan --cache-dir=
    assert_equal "${status}" 64
    assert_output_contains "--cache-dir requires a value"

    run_cli plan --lock-file=
    assert_equal "${status}" 64
    assert_output_contains "--lock-file requires a value"
}

@test "state and log file options reject empty values" {
    run_cli plan --state-file=
    assert_equal "${status}" 64
    assert_output_contains "--state-file requires a value"

    run_cli plan --log-file=
    assert_equal "${status}" 64
    assert_output_contains "--log-file requires a value"
}

@test "plans report the default cache and lock paths" {
    run_cli plan --json
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${TEST_ROOT}"'/cache/fedora-postinstall" and
        .paths.lock_file == "'"${TEST_ROOT}"'/cache/fedora-postinstall/postinstall.lock"
    ' <<<"${output}"
    assert_success
    assert_file_absent "${GUM_MARKER}"
}

@test "the default lock follows the effective cache directory" {
    local cache_dir="${TEST_ROOT}/cache-only"

    run_cli plan --json --cache-dir "${cache_dir}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${cache_dir}"'/postinstall.lock"
    ' <<<"${output}"
    assert_success
}

@test "an explicit lock path is independent of the cache option order" {
    local cache_dir="${TEST_ROOT}/ordered-cache"
    local lock_file="${TEST_ROOT}/ordered.lock"

    run_cli plan --json --lock-file "${lock_file}" --cache-dir "${cache_dir}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${lock_file}"'"
    ' <<<"${output}"
    assert_success

    run_cli plan --json --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${lock_file}"'"
    ' <<<"${output}"
    assert_success
}

@test "relative cache and lock paths resolve from the invocation directory" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c \
            'cd "$1" && exec bash "$2/fedora-postinstall.sh" plan --json --cache-dir relative/cache --lock-file relative.lock' \
            _ "${TEST_ROOT}" "${SANDBOX_REPO}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${TEST_ROOT}"'/relative/cache" and
        .paths.lock_file == "'"${TEST_ROOT}"'/relative.lock"
    ' <<<"${output}"
    assert_success
}

@test "cache and lock paths reject control characters" {
    run_cli plan --cache-dir $'bad\ncache'
    assert_equal "${status}" 64
    assert_output_contains "invalid cache directory path"

    run_cli plan --lock-file $'bad\nlock'
    assert_equal "${status}" 64
    assert_output_contains "invalid lock file path"
}

@test "cache and lock paths reject parent-directory components" {
    run_cli plan --cache-dir "${TEST_ROOT}/cache/../cache"
    assert_equal "${status}" 64
    assert_output_contains "invalid cache directory path"

    run_cli plan --lock-file "${TEST_ROOT}/locks/../install.lock"
    assert_equal "${status}" 64
    assert_output_contains "invalid lock file path"
}

@test "command-line cache and lock paths override the environment" {
    local cache_dir="${TEST_ROOT}/custom cache"
    local lock_file="${TEST_ROOT}/locks/custom lock"

    run env \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        POSTINSTALL_CACHE_DIR="${TEST_ROOT}/environment-cache" \
        POSTINSTALL_LOCK_FILE="${TEST_ROOT}/environment-lock" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json \
        --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${lock_file}"'"
    ' <<<"${output}"
    assert_success
}

@test "environment cache and lock paths are reported" {
    local cache_dir="${TEST_ROOT}/environment-cache"
    local lock_file="${TEST_ROOT}/environment-lock"

    run env \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${lock_file}"'"
    ' <<<"${output}"
    assert_success
}

@test "detect reports the operating system, flavor, and architecture" {
    run_cli detect
    assert_success
    assert_output_contains "Fedora Workstation"
    assert_output_contains "Selected flavor: workstation"
    assert_output_contains "Selected architecture: x86_64"
    assert_file_absent "${GUM_MARKER}"
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
    assert_file_absent "${GUM_MARKER}"
}

@test "JSON output remains parseable when runtime logs are enabled" {
    run bash -c '
        env \
            HOME="$1" \
            XDG_CONFIG_HOME="$2" \
            XDG_STATE_HOME="$3" \
            XDG_CACHE_HOME="$4" \
            TMPDIR="$5" \
            PATH="$6" \
            POSTINSTALL_STATE_FILE="$7" \
            bash "$8" detect --json --log-stdout \
            >"$9" 2>"${10}"
    ' _ \
        "${TEST_HOME}" \
        "${TEST_ROOT}/config" \
        "${TEST_ROOT}/state" \
        "${TEST_ROOT}/cache" \
        "${TMP_ROOT}" \
        "${MOCK_BIN}:/usr/bin:/bin" \
        "${TEST_ROOT}/state.tsv" \
        "${SANDBOX_REPO}/fedora-postinstall.sh" \
        "${STDOUT_FILE}" \
        "${STDERR_FILE}"

    assert_success
    run jq -e '.schema_version == 1 and .os.id == "fedora"' "${STDOUT_FILE}"
    assert_success
    run grep -F 'Runtime initialized.' "${STDERR_FILE}"
    assert_success
    assert_file_absent "${GUM_MARKER}"
}

@test "removed option and value aliases are rejected" {
    local argument

    for argument in \
        "--flavour=workstation" \
        "--flavour" \
        "--arch=x86_64" \
        "--arch"; do
        run_cli plan "${argument}"
        assert_equal "${status}" 64
        assert_output_contains "unknown option"
    done

    run_cli plan --flavour workstation
    assert_equal "${status}" 64
    assert_output_contains "unknown option"

    run_cli plan --arch x86_64
    assert_equal "${status}" 64
    assert_output_contains "unknown option"

    for argument in amd64 x64 arm64; do
        run_cli plan "--architecture=${argument}"
        assert_equal "${status}" 64
        assert_output_contains "invalid architecture"
    done

    run_cli plan --log-format text
    assert_equal "${status}" 64
    assert_output_contains "invalid log format"

    run_cli plan --log-level warning
    assert_equal "${status}" 64
    assert_output_contains "invalid log level"

    export POSTINSTALL_ARCHITECTURE=amd64
    run_cli plan
    assert_equal "${status}" 64
    assert_output_contains "invalid architecture"
    unset POSTINSTALL_ARCHITECTURE

    export POSTINSTALL_LOG_FORMAT=text
    run_cli plan
    assert_equal "${status}" 64
    assert_output_contains "invalid log format"
    unset POSTINSTALL_LOG_FORMAT

    export POSTINSTALL_LOG_LEVEL=warning
    run_cli plan
    assert_equal "${status}" 64
    assert_output_contains "invalid log level"
    unset POSTINSTALL_LOG_LEVEL
}

@test "the retired CLI_TOOLS_ONLY environment variable is ignored" {
    export CLI_TOOLS_ONLY=1
    run_cli plan --json
    assert_success
    run jq -e '
        .extras.mode == "interactive" and
        (.extras.tools | length == 0)
    ' <<<"${output}"
    assert_success
    unset CLI_TOOLS_ONLY
}

@test "canonical x86_64 architecture selects the matching manifest asset" {
    run_cli plan --json --architecture x86_64 --tool fd
    assert_success
    run jq -e '
        .architecture.selected == "x86_64" and
        (.extras.tools | length == 1) and
        (.extras.tools[0].id == "fd") and
        (.extras.tools[0].url | contains("x86_64"))
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
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
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
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
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
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
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
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=silverblue \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json --flavor workstation
    assert_success
    run jq -e '.flavor.selected == "workstation"' <<<"${output}"
    assert_success
}

@test "command-line options replace invalid environment defaults" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=invalid \
        POSTINSTALL_ARCHITECTURE=invalid \
        POSTINSTALL_LOG_FORMAT=invalid \
        POSTINSTALL_LOG_LEVEL=invalid \
        POSTINSTALL_TOOLS=INVALID \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json \
        --flavor workstation \
        --architecture x86_64 \
        --log-format json \
        --log-level debug \
        --tool fd
    assert_success
    run jq -e '
        .flavor.selected == "workstation" and
        .architecture.selected == "x86_64" and
        (.extras.tools | length == 1) and
        (.extras.tools[0].id == "fd")
    ' <<<"${output}"
    assert_success
}

@test "CLI parsing exposes effective command-line replacements" {
    run env \
        POSTINSTALL_INVOCATION_DIRECTORY="${TEST_ROOT}" \
        POSTINSTALL_FLAVOR=invalid \
        POSTINSTALL_ARCHITECTURE=invalid \
        POSTINSTALL_LOG_FORMAT=invalid \
        POSTINSTALL_LOG_LEVEL=invalid \
        POSTINSTALL_TOOLS=INVALID \
        bash -c '
            source "$1/common/cli.sh" || exit 1
            cli_parse_arguments plan \
                --flavor workstation \
                --architecture x86_64 \
                --log-format json \
                --log-level debug \
                --tool fd || exit 1
            printf "%s\n" "${CLI_FLAVOR}" "${CLI_ARCHITECTURE}" \
                "${CLI_LOG_FORMAT}" "${CLI_LOG_LEVEL}" \
                "${CLI_SELECTED_TOOLS[*]}"
        ' _ "${REPO_ROOT}"
    assert_success
    assert_equal "${output}" $'workstation\nx86_64\njson\ndebug\nfd'
}

@test "all extras replaces an environment tool selection" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_TOOLS=not-a-tool \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json \
        --architecture x86_64 --all-extras
    assert_success
    run jq -e '
        .extras.mode == "all" and
        (.extras.tools | length > 1) and
        (any(.extras.tools[]; .id == "fd"))
    ' <<<"${output}"
    assert_success
}

@test "an invalid environment tool selection is rejected without a CLI replacement" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_TOOLS=INVALID \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan
    assert_equal "${status}" "64"
    assert_output_contains "invalid tool identifier"
}

@test "an explicit install honors the environment flavor" {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR=silverblue \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" install --dry-run --json
    assert_success
    run jq -e '.flavor.selected == "silverblue"' <<<"${output}"
    assert_success
}
