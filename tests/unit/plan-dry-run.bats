#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/plan-dry-run"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    TMP_ROOT="${TEST_ROOT}/tmp"
    STATE_FILE="${TEST_ROOT}/state.tsv"
    FORBIDDEN_MARKER="${TEST_ROOT}/forbidden-command"
    MODULE_MARKER="${TEST_ROOT}/module-executed"
    OS_RELEASE_FILE="${TEST_ROOT}/os-release"

    mkdir -p \
        "${SANDBOX_REPO}" \
        "${TEST_HOME}" \
        "${MOCK_BIN}" \
        "${TMP_ROOT}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/profiles" "${SANDBOX_REPO}/"
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
    printf '%s\n' "x86_64"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-E" ]; then
    printf '%s\n' "45"
    exit 0
fi
printf '%s\n' "package ${2} is not installed"
exit 1
EOF

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FORBIDDEN_MARKER}"
exit 99
EOF

    cat > "${MOCK_BIN}/forbidden" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FORBIDDEN_MARKER}"
printf 'forbidden command invoked: %s\n' "$*" >&2
exit 99
EOF

    for command in sudo dnf flatpak gsettings hostnamectl curl wget toolbox git flock; do
        cp "${MOCK_BIN}/forbidden" "${MOCK_BIN}/${command}"
    done

    chmod +x "${MOCK_BIN}"/*
    printf '\n: > "%s"\n' "${MODULE_MARKER}" >> \
        "${SANDBOX_REPO}/common/hostname-configuration.sh"

    export MOCK_FORBIDDEN_MARKER="${FORBIDDEN_MARKER}"
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
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" "$@"
}

@test "install dry-run performs no downloads, prompts, or module execution" {
    run_cli install --dry-run --profile default
    assert_success
    assert_output_contains "Fedora post-installation plan"
    assert_file_absent "${FORBIDDEN_MARKER}"
    assert_file_absent "${MODULE_MARKER}"
    assert_file_absent "${STATE_FILE}"
    run find "${TMP_ROOT}" -maxdepth 1 -name 'fedora-postinstall-extras.*' -print
    assert_success
    refute_output_contains "fedora-postinstall-extras."
}

@test "extras dry-run validates and describes tools without downloading" {
    run_cli extras --dry-run --tools fd
    assert_success
    assert_output_contains "Extras selection: explicit"
    assert_output_contains "fd"
    refute_output_contains "unsupported module inventory"
    assert_file_absent "${FORBIDDEN_MARKER}"
    assert_file_absent "${STATE_FILE}"
}

@test "extras dry-run rejects tools with conflicting command targets" {
    local manifest="${SANDBOX_REPO}/extras/tools-manifest.json"
    jq '.tools.fd.assets.x86_64.files |= with_entries(.value = "rg")' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_cli extras --dry-run --tools fd,ripgrep
    assert_equal "${status}" 69
    assert_output_contains 'extras: tools "fd" and "ripgrep" deploy the same command "rg"'
    refute_output_contains "error:"
    assert_file_absent "${FORBIDDEN_MARKER}"
    assert_file_absent "${STATE_FILE}"
}

@test "dry-run JSON remains machine-readable" {
    run_cli install --dry-run --json
    assert_success
    run jq -e '
        .schema_version == 1 and
        .dry_run == true and
        .flavor.selected == "workstation" and
        .architecture.selected == "x86_64" and
        (.paths.cache_dir | length > 0) and
        (.paths.lock_file | length > 0)
    ' <<<"${output}"
    assert_success
}

@test "plans report paths without creating the cache or lock" {
    local cache_dir="${TEST_ROOT}/reported-cache"
    local lock_file="${TEST_ROOT}/locks/reported.lock"

    run_cli plan --json --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    run jq -e '
        .paths.cache_dir == "'"${cache_dir}"'" and
        .paths.lock_file == "'"${lock_file}"'"
    ' <<<"${output}"
    assert_success
    assert_file_absent "${cache_dir}"
    assert_file_absent "${lock_file}"
    assert_file_absent "${FORBIDDEN_MARKER}"

    run_cli plan --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    assert_output_contains "Cache directory: ${cache_dir}"
    assert_output_contains "Lock file: ${lock_file}"

    run_cli install --dry-run --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    assert_file_absent "${cache_dir}"
    assert_file_absent "${lock_file}"
    assert_file_absent "${FORBIDDEN_MARKER}"

    run_cli extras --dry-run --tools fd --cache-dir "${cache_dir}" \
        --lock-file "${lock_file}"
    assert_success
    assert_file_absent "${cache_dir}"
    assert_file_absent "${lock_file}"
    assert_file_absent "${FORBIDDEN_MARKER}"

    run_cli detect --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    assert_success
    assert_file_absent "${cache_dir}"
    assert_file_absent "${lock_file}"
    assert_file_absent "${FORBIDDEN_MARKER}"
}

@test "a plan succeeds while another process holds the selected lock" {
    local cache_dir="${TEST_ROOT}/held-lock-cache"
    local lock_file="${TEST_ROOT}/held.lock"
    local marker_file="${TEST_ROOT}/lock-holder-ready"
    local release_file="${TEST_ROOT}/release-lock-holder"
    local flock_bin
    local holder

    flock_bin=$(command -v flock)
    "${flock_bin}" "${lock_file}" bash -c \
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

    run_cli plan --cache-dir "${cache_dir}" --lock-file "${lock_file}"
    touch "${release_file}"
    wait "${holder}" 2>/dev/null || true

    assert_success
    assert_file_absent "${cache_dir}"
    assert_file_absent "${FORBIDDEN_MARKER}"
}

@test "a profile can omit the extras module" {
    run_cli install --dry-run --json --profile minimal
    assert_success
    run jq -r '.modules[] | select(.path == "extras/additional-tools.sh") | .selected' \
        <<<"${output}"
    assert_success
    assert_equal "${output}" "false"
}

@test "an explicit log file may be written during a dry-run" {
    local log_file="${TEST_ROOT}/dry-run.log"
    run_cli install --dry-run --log-file "${log_file}"
    assert_success
    assert_file_exists "${log_file}"
    assert_file_absent "${STATE_FILE}"
    run grep -F 'Dry-run plan generated' "${log_file}"
    assert_success
}

@test "a dry-run does not modify the home directory" {
    printf 'sentinel\n' > "${TEST_HOME}/sentinel"
    run_cli install --dry-run
    assert_success
    run cat "${TEST_HOME}/sentinel"
    assert_success
    assert_equal "${output}" "sentinel"
    run find "${TEST_HOME}" -mindepth 1 -maxdepth 1 -printf '%f\n'
    assert_success
    assert_equal "${output}" "sentinel"
}

@test "text and JSON plans agree on extras selection actions" {
    run_cli install --dry-run --json
    assert_success
    run jq -e '
        .extras.mode == "interactive" and
        (.modules[] | select(.path == "extras/additional-tools.sh") | .action == "choose")
    ' <<<"${output}"
    assert_success

    run_cli install --dry-run --json --tool fd
    assert_success
    run jq -e '
        .extras.mode == "explicit" and
        (.modules[] | select(.path == "extras/additional-tools.sh") | .action == "run")
    ' <<<"${output}"
    assert_success

    run_cli install --dry-run --json --all-extras
    assert_success
    run jq -e '
        .extras.mode == "all" and
        (.modules[] | select(.path == "extras/additional-tools.sh") | .action == "run")
    ' <<<"${output}"
    assert_success
}

@test "an empty profile tool selection is reported as none in both formats" {
    local profile="${TEST_ROOT}/none-profile.json"
    cat > "${profile}" <<'EOF'
{
  "schema_version": 1,
  "name": "none",
  "description": "Select no extra tools",
  "modules": {"include": ["extras/*"], "exclude": []},
  "extras": {"tools": []}
}
EOF

    run_cli install --dry-run --json --profile-file "${profile}"
    assert_success
    run jq -e '
        .extras.mode == "none" and
        (.modules[] | select(.path == "extras/additional-tools.sh") | .action == "skip-none")
    ' <<<"${output}"
    assert_success

    run_cli install --dry-run --profile-file "${profile}"
    assert_success
    assert_output_contains "skip-none"
}
