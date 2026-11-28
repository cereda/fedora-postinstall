#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/snapshot"
    TEST_HOME="${TEST_ROOT}/home"
    MANAGED_ROOT="${TEST_HOME}/.host"
    STORAGE_ROOT="${MANAGED_ROOT}/backups/snapshots"

    mkdir -p \
        "${TEST_HOME}" \
        "${MANAGED_ROOT}/config" \
        "${TEST_ROOT}/tmp"

    printf '%s\n' 'original' > "${MANAGED_ROOT}/config/file.txt"
    printf '%s\n' 'keep' > "${MANAGED_ROOT}/keep.txt"
}

run_snapshot() {
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" "$@"
}

snapshot_id() {
    find "${STORAGE_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
        sort |
        head -1
}

latest_snapshot_id() {
    find "${STORAGE_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
        sort |
        tail -1
}

run_snapshot_with_failpoint() {
    local failpoint="${1}"
    local kind="${2:-exception}"
    local target="${3:-}"
    shift 3

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="${failpoint}" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="${kind}" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_TARGET="${target}" \
        python3 "${REPO_ROOT}/common/snapshot.py" "$@"
}

run_snapshot_shell_api() {
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        bash -c \
        'source "$1/common/snapshot.sh"; shift; "$@"' \
        snapshot-shell "${REPO_ROOT}" "$@"
}

assert_no_restore_artifacts() {
    local siblings
    local selective

    siblings="$(find "${TEST_HOME}" -maxdepth 1 \
        \( -name '..host.snapshot-stage-*' \
        -o -name '..host.pre-snapshot-restore-*' \
        -o -name '..host.failed-snapshot-restore-*' \
        -o -name '..host.snapshot-storage-*' \) -print)"
    assert_equal "${siblings}" ""
    selective="$(find "${MANAGED_ROOT}" -maxdepth 1 \
        \( -name '.snapshot-selective-*' \
        -o -name '.*.snapshot-restore-backup-*' \) -print)"
    assert_equal "${selective}" ""
}

@test "snapshot create list and diff report verified changes" {
    run_snapshot create first
    assert_success
    local first
    first="$(snapshot_id)"
    assert_file_exists "${STORAGE_ROOT}/${first}/snapshot.tar.gz"
    assert_file_exists "${STORAGE_ROOT}/${first}/manifest.json"
    assert_file_exists "${STORAGE_ROOT}/${first}/metadata.json"

    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    run_snapshot create second
    assert_success

    run_snapshot list
    assert_success
    assert_output_contains "first"
    assert_output_contains "second"

    run_snapshot diff first second
    assert_success
    assert_output_contains "changed	config/file.txt"
}

@test "snapshot creation rediscovers a custom managed root from runtime state" {
    local custom_root="${TEST_HOME}/custom-managed"
    local state_file="${TEST_ROOT}/state.tsv"
    local snapshot
    local metadata

    mkdir -p "${custom_root}/config"
    printf '%s\n' 'custom-root' > "${custom_root}/config/file.txt"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${custom_root}" > "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create discovered-root
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${custom_root}"
    run jq -e '.entries["config/file.txt"].sha256 != null' "${STORAGE_ROOT}/${snapshot}/manifest.json"
    assert_success
}

@test "runtime state discovery uses the latest valid root for one flavor" {
    local first_root="${TEST_HOME}/first-root"
    local latest_root="${TEST_HOME}/latest-root"
    local state_file="${TEST_ROOT}/latest-root-state.tsv"
    local snapshot
    local metadata

    mkdir -p "${first_root}" "${latest_root}"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${first_root}" > "${state_file}"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-02T00:00:00Z\n' \
        "${latest_root}" >> "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create latest-root
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${latest_root}"
}

@test "root snapshot dispatch resolves a relative state file from the invocation directory" {
    local state_file="relative-state.tsv"
    local snapshot
    local metadata

    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${MANAGED_ROOT}" > "${TEST_ROOT}/${state_file}"

    run bash -c \
        'cd "$1" && HOME="$2" TMPDIR="$3" PATH="/usr/bin:/bin" bash "$4" snapshot create relative-state --state-file "$5" --cache-dir "$6"' \
        _ \
        "${TEST_ROOT}" \
        "${TEST_HOME}" \
        "${TEST_ROOT}/tmp" \
        "${REPO_ROOT}/fedora-postinstall.sh" \
        "${state_file}" \
        "${TEST_ROOT}/cache"
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${MANAGED_ROOT}"
}

@test "root snapshot dispatch rediscovers the configured managed root" {
    local custom_root="${TEST_HOME}/custom-managed"
    local state_file="${TEST_ROOT}/state.tsv"
    local snapshot
    local metadata

    mkdir -p "${custom_root}/config"
    printf '%s\n' 'custom-root' > "${custom_root}/config/file.txt"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${custom_root}" > "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot create root-dispatch \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${custom_root}"

    run env \
        HOME="${TEST_HOME}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot list \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_success
    assert_output_contains "root-dispatch"
}

@test "root snapshot dispatch scopes ambiguous managed roots by flavor" {
    local workstation_root="${TEST_HOME}/workstation-root"
    local silverblue_root="${TEST_HOME}/silverblue-root"
    local state_file="${TEST_ROOT}/flavor-state.tsv"
    local snapshot
    local metadata

    mkdir -p "${workstation_root}" "${silverblue_root}"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${workstation_root}" > "${state_file}"
    printf 'value\tsilverblue:silverblue/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${silverblue_root}" >> "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot create scoped-root \
        --flavor workstation \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${workstation_root}"
}

@test "root snapshot creation reports an operation-level state failure" {
    local state_file="${TEST_ROOT}/missing-state.tsv"

    run env \
        HOME="${TEST_HOME}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot create missing-state \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_equal "${status}" "1"
    assert_output_contains "managed root is unavailable"
    assert_output_contains "Snapshot create failed: 0 completed, 0 skipped, 1 failed in"
}

@test "root snapshot restore confirms and restores the discovered managed root" {
    local custom_root="${TEST_HOME}/custom-managed"
    local state_file="${TEST_ROOT}/state.tsv"
    local mock_bin="${TEST_ROOT}/bin"
    local snapshot
    local prompt

    mkdir -p "${custom_root}/config" "${mock_bin}"
    printf '%s\n' 'original' > "${custom_root}/config/file.txt"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${custom_root}" > "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${custom_root}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create root-restore
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${custom_root}/config/file.txt"

    cat > "${mock_bin}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--version)
    printf '%s\n' 'gum version v2.0.2'
    ;;
choose)
    printf '%s\n' '--no-limit' '--header' '--height' '--selected'
    ;;
confirm)
    if [ "${2:-}" = "--help" ]; then
        printf '%s\n' '--show-output' '--affirmative' '--negative' \
            '--prompt.foreground' '--selected.background'
    else
        printf '%s\n' "${!#}"
        exit "${MOCK_GUM_CONFIRM_STATUS:-0}"
    fi
    ;;
input)
    printf '%s\n' '--value' '--prompt'
    ;;
file)
    printf '%s\n' '--file' '--directory' '--all' '--[no-]permissions'
    ;;
esac
EOF
    chmod +x "${mock_bin}/gum"

    run env \
        GUM="${mock_bin}/gum" \
        HOME="${TEST_HOME}" \
        NO_COLOR=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        python3 "${REPO_ROOT}/tests/helpers/run-with-pty.py" \
        -- bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot restore "${snapshot}" \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_success

    run cat "${custom_root}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
}

@test "root snapshot restore cancellation leaves the managed root unchanged" {
    local custom_root="${TEST_HOME}/custom-managed"
    local state_file="${TEST_ROOT}/state.tsv"
    local mock_bin="${TEST_ROOT}/bin"
    local snapshot

    mkdir -p "${custom_root}/config" "${mock_bin}"
    printf '%s\n' 'original' > "${custom_root}/config/file.txt"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${custom_root}" > "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${custom_root}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create root-restore-decline
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${custom_root}/config/file.txt"

    cat > "${mock_bin}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--version)
    printf '%s\n' 'gum version v2.0.2'
    ;;
choose)
    printf '%s\n' '--no-limit' '--header' '--height' '--selected'
    ;;
confirm)
    if [ "${2:-}" = "--help" ]; then
        printf '%s\n' '--show-output' '--affirmative' '--negative' \
            '--prompt.foreground' '--selected.background'
    else
        prompt="${!#}"
        printf '%s %s\n' "${prompt}" "Cancel"
        exit 1
    fi
    ;;
input)
    printf '%s\n' '--value' '--prompt'
    ;;
file)
    printf '%s\n' '--file' '--directory' '--all' '--[no-]permissions'
    ;;
esac
EOF
    chmod +x "${mock_bin}/gum"

    run env \
        GUM="${mock_bin}/gum" \
        HOME="${TEST_HOME}" \
        NO_COLOR=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        python3 "${REPO_ROOT}/tests/helpers/run-with-pty.py" \
        -- bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot restore "${snapshot}" \
        --state-file "${state_file}" \
        --cache-dir "${TEST_ROOT}/cache"
    assert_equal "${status}" "1"
    assert_output_contains "Snapshot restore was canceled"
    assert_output_contains "Snapshot restore canceled: 0 completed, 1 skipped, 0 failed in"

    run cat "${custom_root}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
}

@test "snapshot list and diff do not depend on current runtime state" {
    local state_file="${TEST_ROOT}/malformed-state.tsv"

    run_snapshot create independent-one
    assert_success
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    run_snapshot create independent-two
    assert_success
    printf '%s\n' 'not-a-runtime-record' > "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" list
    assert_success
    assert_output_contains "independent-one"
    assert_output_contains "independent-two"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" diff \
        independent-one independent-two
    assert_success
    assert_output_contains $'changed\tconfig/file.txt'
}

@test "snapshot roots are canonicalized when HOME is a symbolic link" {
    local home_link="${TEST_ROOT}/home-link"
    local snapshot
    local metadata

    ln -s "${TEST_HOME}" "${home_link}"
    run env \
        HOME="${home_link}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${home_link}/.host" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create symlink-home
    assert_success

    snapshot="$(snapshot_id)"
    metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    run jq -r '.root' "${metadata}"
    assert_success
    assert_equal "${output}" "${MANAGED_ROOT}"
}

@test "snapshot creation rejects runtime control paths inside the managed root" {
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_CACHE_DIR="${MANAGED_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create unsafe-cache
    assert_equal "${status}" "64"
    assert_output_contains "installer cache directory"
    assert_output_contains "inside the managed root"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_LOCK_FILE="${MANAGED_ROOT}/postinstall.lock" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create unsafe-lock
    assert_equal "${status}" "64"
    assert_output_contains "installer lock file"
    assert_output_contains "inside the managed root"
}

@test "snapshot restore rejects runtime control paths inside the managed root" {
    local snapshot

    run_snapshot create control-path
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_CACHE_DIR="${MANAGED_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" --yes
    assert_equal "${status}" "64"
    assert_output_contains "inside the managed root"

    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
}

@test "managed-root overrides are unavailable outside the test harness" {
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create test-override
    assert_equal "${status}" "64"
    assert_output_contains "only with POSTINSTALL_SNAPSHOT_TEST_MODE=1"
}

@test "runtime state discovery rejects ambiguous flavor roots unless scoped" {
    local workstation_root="${TEST_HOME}/workstation-root"
    local silverblue_root="${TEST_HOME}/silverblue-root"
    local state_file="${TEST_ROOT}/flavor-state.tsv"

    mkdir -p "${workstation_root}" "${silverblue_root}"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${workstation_root}" > "${state_file}"
    printf 'value\tsilverblue:silverblue/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${silverblue_root}" >> "${state_file}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create ambiguous-roots
    assert_equal "${status}" "1"
    assert_output_contains "multiple managed roots"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_FLAVOR=workstation \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create workstation-root
    assert_success

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_FLAVOR=silverblue \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create silverblue-root
    assert_success
}

@test "runtime state discovery enforces the runtime record format" {
    local state_file="${TEST_ROOT}/invalid-state.tsv"

    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\tinvalid-timestamp\n' \
        "${MANAGED_ROOT}" > "${state_file}"
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create invalid-state
    assert_equal "${status}" "1"
    assert_output_contains "malformed record"

    printf 'unknown\tkey\tvalue\t2026-01-01T00:00:00Z\n' > "${state_file}"
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create unknown-state
    assert_equal "${status}" "1"
    assert_output_contains "malformed record"
}

@test "runtime state discovery rejects unsafe parent directories" {
    local state_directory="${TEST_ROOT}/state-directory"
    local state_link="${TEST_ROOT}/state-link"
    local state_file

    mkdir -p "${state_directory}"
    state_file="${state_directory}/state.tsv"
    printf 'value\tworkstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE\t%s\t2026-01-01T00:00:00Z\n' \
        "${MANAGED_ROOT}" > "${state_file}"
    ln -s "${state_directory}" "${state_link}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_link}/state.tsv" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create symlink-state-parent
    assert_equal "${status}" "1"
    assert_output_contains "symbolic-link"

    chmod 0777 "${state_directory}"
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create writable-state-parent
    assert_equal "${status}" "1"
    assert_output_contains "writable by another user"
}

@test "missing runtime state is an operational snapshot failure" {
    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${TEST_ROOT}/missing-state.tsv" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create missing-state
    assert_equal "${status}" "1"
    assert_output_contains "managed root is unavailable"
}

@test "snapshot storage and metadata remain private" {
    run_snapshot create private
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"

    run stat -c '%a' "${MANAGED_ROOT}"
    assert_success
    assert_equal "${output}" "700"
    run stat -c '%a' "${MANAGED_ROOT}/backups"
    assert_success
    assert_equal "${output}" "700"
    run stat -c '%a' "${STORAGE_ROOT}"
    assert_success
    assert_equal "${output}" "700"
    run stat -c '%a' "${STORAGE_ROOT}/${snapshot}/metadata.json"
    assert_success
    assert_equal "${output}" "600"
}

@test "selective restore replaces only the requested path" {
    run_snapshot create selected
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    printf '%s\n' 'still-current' > "${MANAGED_ROOT}/keep.txt"

    run_snapshot restore "${snapshot}" --path config/file.txt --yes
    assert_success

    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
    run cat "${MANAGED_ROOT}/keep.txt"
    assert_success
    assert_equal "${output}" "still-current"
}

@test "selective restore rejects a symbolic-link ancestor" {
    run_snapshot create safe-path
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    local external="${TEST_ROOT}/external"
    mkdir -p "${external}"
    rm -rf "${MANAGED_ROOT}/config"
    ln -s "${external}" "${MANAGED_ROOT}/config"

    run_snapshot restore "${snapshot}" --path config/file.txt --yes
    assert_failure
    assert_output_contains "unsafe symbolic-link ancestor"
    assert_file_absent "${external}/file.txt"
}

@test "whole-tree restore retains a private rollback sibling and relocates storage" {
    run_snapshot create whole
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/keep.txt"

    run_snapshot restore "${snapshot}" --yes
    assert_success
    assert_output_contains "Previous managed directory retained at"

    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
    run cat "${MANAGED_ROOT}/keep.txt"
    assert_success
    assert_equal "${output}" "keep"
    assert_file_exists "${STORAGE_ROOT}/${snapshot}/snapshot.tar.gz"

    run find "${TEST_HOME}" -maxdepth 1 -type d -name '..host.pre-snapshot-restore-*'
    assert_success
    assert_output_contains "pre-snapshot-restore"
}

@test "restore rejects metadata that redirects the managed root" {
    run_snapshot create trusted-root
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    local metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    local victim="${TEST_HOME}/victim"
    mkdir -p "${victim}"
    printf '%s\n' 'victim' > "${victim}/file.txt"
    jq --arg root "${victim}" '.root = $root' "${metadata}" > "${metadata}.new"
    mv "${metadata}.new" "${metadata}"

    run_snapshot restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "does not match the currently configured managed root"
    run cat "${victim}/file.txt"
    assert_success
    assert_equal "${output}" "victim"
}

@test "malformed snapshot metadata produces a controlled diagnostic" {
    run_snapshot create malformed
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' '[]' > "${STORAGE_ROOT}/${snapshot}/metadata.json"

    run_snapshot list
    assert_success
    assert_output_contains "skipping invalid snapshot"
    refute_output_contains "Traceback"
}

@test "snapshot creation fails instead of silently omitting special files" {
    mkfifo "${MANAGED_ROOT}/pipe"

    run_snapshot create incomplete
    assert_failure
    assert_output_contains "unsupported file type"
    assert_file_absent "${STORAGE_ROOT}/incomplete"
}

@test "the snapshot helper requires explicit restore confirmation" {
    run_snapshot create confirmation
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"

    run_snapshot restore "${snapshot}"
    assert_equal "${status}" "64"
    assert_output_contains "snapshot restore requires explicit confirmation"
    refute_output_contains "tuple"
}

@test "snapshot list and diff root dispatch do not require Gum" {
    run_snapshot create dispatch-one
    assert_success
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    run_snapshot create dispatch-two
    assert_success

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot list
    assert_success
    assert_output_contains "dispatch-one"
    assert_output_contains "dispatch-two"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot diff \
        dispatch-one dispatch-two
    assert_success
    assert_output_contains "changed	config/file.txt"
    refute_output_contains "Fetching Gum"
}

@test "snapshot restore rejects a tampered archive checksum" {
    run_snapshot create checksum
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'tampered' >> "${STORAGE_ROOT}/${snapshot}/snapshot.tar.gz"

    run_snapshot restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "archive checksum does not match"
    refute_output_contains "Traceback"
}

@test "snapshot restore rejects malformed manifest field types" {
    run_snapshot create malformed-field
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    local manifest="${STORAGE_ROOT}/${snapshot}/manifest.json"
    local metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    jq '.entries["config/file.txt"].mode = "invalid"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"
    local checksum
    checksum="$(sha256sum "${manifest}" | cut -d' ' -f1)"
    jq --arg checksum "${checksum}" '.manifest_sha256 = $checksum' \
        "${metadata}" > "${metadata}.new"
    mv "${metadata}.new" "${metadata}"

    run_snapshot restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "invalid mode"
    refute_output_contains "Traceback"
}

@test "selective restore creates a missing destination parent safely" {
    run_snapshot create missing-parent
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    rm -rf "${MANAGED_ROOT}/config"

    run_snapshot restore "${snapshot}" --path config/file.txt --yes
    assert_success
    assert_file_exists "${MANAGED_ROOT}/config/file.txt"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
}

@test "an unrelated malformed snapshot does not block a valid snapshot" {
    run_snapshot create valid-one
    assert_success
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    run_snapshot create valid-two
    assert_success
    mkdir -p "${STORAGE_ROOT}/malformed-snapshot"
    printf '%s\n' '[]' > "${STORAGE_ROOT}/malformed-snapshot/metadata.json"

    run_snapshot diff valid-one valid-two
    assert_success
    assert_output_contains $'changed\tconfig/file.txt'

    run_snapshot list
    assert_success
    assert_output_contains "skipping invalid snapshot malformed-snapshot"
    refute_output_contains "Traceback"
}

@test "snapshot restore requires a terminal before creating runtime state" {
    run_snapshot create terminal
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot restore "${snapshot}"
    assert_equal "${status}" "64"
    assert_output_contains "terminal is required"
    assert_file_absent "${TEST_ROOT}/cache/fedora-postinstall"
}

@test "selective restore replaces the complete requested subtree" {
    run_snapshot create exact-subtree
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    mkdir -p "${MANAGED_ROOT}/config/new-directory"
    printf '%s\n' 'new' > "${MANAGED_ROOT}/config/new-directory/file.txt"
    printf '%s\n' 'new' > "${MANAGED_ROOT}/config/new-file.txt"

    run_snapshot restore "${snapshot}" --path config --yes
    assert_success
    assert_file_exists "${MANAGED_ROOT}/config/file.txt"
    assert_file_absent "${MANAGED_ROOT}/config/new-directory/file.txt"
    assert_file_absent "${MANAGED_ROOT}/config/new-file.txt"
    assert_no_restore_artifacts
}

@test "overlapping selective restore requests are collapsed to one exact subtree" {
    run_snapshot create overlapping
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'new' > "${MANAGED_ROOT}/config/new-file.txt"

    run_snapshot restore "${snapshot}" \
        --path config \
        --path config/file.txt \
        --yes
    assert_success
    assert_file_absent "${MANAGED_ROOT}/config/new-file.txt"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
    assert_no_restore_artifacts
}

@test "an interrupted selective restore rolls back the committed subtree" {
    run_snapshot create selective-interrupt
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run_snapshot_with_failpoint \
        after_selective_commit \
        signal \
        config/file.txt \
        restore "${snapshot}" --path config/file.txt --yes
    assert_equal "${status}" "143"
    assert_output_contains "interrupted by signal 15"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
    assert_no_restore_artifacts
}

@test "a selective restore interrupted after commit is finalized without rollback" {
    run_snapshot create selective-commit-interrupt
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run_snapshot_with_failpoint \
        after_selective_commit_point \
        signal \
        "" \
        restore "${snapshot}" --path config/file.txt --yes
    assert_equal "${status}" "143"
    assert_output_contains "committed before interruption"

    run_snapshot recover
    assert_success
    assert_output_contains "Recovered pending snapshot transaction"

    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "original"
    run find "${MANAGED_ROOT}" -maxdepth 2 \
        -name '.*.snapshot-restore-backup-*' -print
    assert_success
    assert_equal "${output}" ""
    run jq -r '.status' \
        "${TEST_HOME}/.fedora-postinstall-snapshot-recovery-"*.json
    assert_success
    assert_equal "${output}" "completed"
}

@test "an interrupted whole-tree restore preserves storage and rolls back the root" {
    run_snapshot create whole-interrupt
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run_snapshot_with_failpoint \
        after_storage_relocation \
        signal \
        "" \
        restore "${snapshot}" --yes
    assert_equal "${status}" "143"
    assert_file_exists "${STORAGE_ROOT}/${snapshot}/snapshot.tar.gz"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
    assert_no_restore_artifacts
}

@test "a failed whole-tree rollback retains explicit recovery data" {
    run_snapshot create rollback-failure
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run_snapshot_with_failpoint \
        after_storage_relocation,fail_root_rollback \
        exception \
        "" \
        restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "rollback was incomplete"
    assert_output_contains "recovery data retained at"

    run find "${TEST_HOME}" -maxdepth 1 -type d \
        -name '..host.pre-snapshot-restore-*' -print -quit
    assert_success
    assert_output_contains "pre-snapshot-restore"
    run find "${TEST_HOME}" -maxdepth 1 -type d \
        -name '..host.snapshot-storage-*' -print -quit
    assert_success
    assert_output_contains "snapshot-storage"
}

@test "snapshot artifacts are never read through symbolic links" {
    run_snapshot create nofollow
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    local archive="${STORAGE_ROOT}/${snapshot}/snapshot.tar.gz"
    local outside="${TEST_ROOT}/outside.tar.gz"
    mv "${archive}" "${outside}"
    ln -s "${outside}" "${archive}"

    run_snapshot restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "must not be a symbolic link"
    refute_output_contains "Traceback"
}

@test "a manifest cannot be changed to disagree with the verified archive" {
    run_snapshot create manifest-integrity
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    local manifest="${STORAGE_ROOT}/${snapshot}/manifest.json"
    local metadata="${STORAGE_ROOT}/${snapshot}/metadata.json"
    jq '.entries["config/file.txt"].mode = 384' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"
    local checksum
    checksum="$(sha256sum "${manifest}" | cut -d' ' -f1)"
    jq --arg checksum "${checksum}" '.manifest_sha256 = $checksum' \
        "${metadata}" > "${metadata}.new"
    mv "${metadata}.new" "${metadata}"

    run_snapshot restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "contents do not match its manifest"
    refute_output_contains "Traceback"
}

@test "duplicate metadata keys are rejected without a traceback" {
    run_snapshot create duplicate-key
    assert_success
    local snapshot
    snapshot="$(snapshot_id)"
    printf '%s\n' \
        '{"schema_version":1,"schema_version":1}' \
        > "${STORAGE_ROOT}/${snapshot}/metadata.json"

    run_snapshot list
    assert_success
    assert_output_contains "duplicate JSON key"
    refute_output_contains "Traceback"
}

@test "snapshot list and diff honor installer lock contention without Gum" {
    local lock_file="${TEST_ROOT}/snapshot-contended.lock"
    local marker_file="${TEST_ROOT}/snapshot-lock-holder-ready"
    local release_file="${TEST_ROOT}/snapshot-release-lock-holder"
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

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="/usr/bin:/bin" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" snapshot list \
        --lock-file "${lock_file}"
    touch "${release_file}"
    wait "${holder}" 2>/dev/null || true

    assert_equal "${status}" "75"
    assert_output_contains "another installer is already running"
    refute_output_contains "Fetching Gum"
}
