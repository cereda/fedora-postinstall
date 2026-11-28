#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/snapshot-hardening"
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

assert_no_restore_artifacts() {
    local artifacts
    artifacts="$(find "${TEST_HOME}" \
        \( -name '..host.snapshot-stage-*' \
        -o -name '..host.pre-snapshot-restore-*' \
        -o -name '..host.failed-snapshot-restore-*' \
        -o -name '..host.snapshot-storage-*' \
        -o -name '.snapshot-selective-*' \
        -o -name '.*.snapshot-restore-backup-*' \) -print)"
    assert_equal "${artifacts}" ""
}

@test "snapshot recovery rejects journal-controlled paths outside the home directory" {
    local transaction_id="cccccccccccccccccccccccccccccccc"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local victim="${TEST_ROOT}/outside-victim"

    mkdir -p "${victim}"
    printf '%s\n' 'victim' > "${victim}/file.txt"
    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": "${victim}",
  "records": []
}
EOF

    run_snapshot recover
    assert_failure
    assert_output_contains "invalid staging name"
    assert_file_exists "${victim}/file.txt"
}

@test "whole-tree recovery accepts a journal for an initially absent root" {
    local custom_root="${TEST_HOME}/custom-root"
    local external_storage="${TEST_HOME}/snapshot-store"
    local snapshot

    mkdir -p "${custom_root}/config"
    printf '%s\n' 'original' > "${custom_root}/config/file.txt"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${custom_root}" \
        POSTINSTALL_SNAPSHOT_DIR="${external_storage}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" create absent-root
    assert_success
    snapshot="$(find "${external_storage}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)"
    rm -rf "${custom_root}"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${custom_root}" \
        POSTINSTALL_SNAPSHOT_DIR="${external_storage}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="before_root_replacement" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="exception" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "injected snapshot test failure at before_root_replacement"
    refute_output_contains "invalid backup name"
    assert_file_absent "${custom_root}"
    assert_file_exists "${external_storage}/${snapshot}/snapshot.tar.gz"
}

@test "a failed selective cleanup remains pending for recovery" {
    local snapshot
    local ready_file="${TEST_ROOT}/cleanup.ready"
    local release_file="${TEST_ROOT}/cleanup.release"
    local output_file="${TEST_ROOT}/cleanup.out"
    local pid
    local process_status=0
    local backup_path

    run_snapshot create cleanup-failure
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="before_selective_cleanup" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="pause" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_READY="${ready_file}" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_RELEASE="${release_file}" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" \
        --path config/file.txt --yes >"${output_file}" 2>&1 &
    pid="${!}"

    for _ in {1..200}; do
        [ -e "${ready_file}" ] && break
        sleep 0.05
    done
    if [ ! -e "${ready_file}" ]; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        printf '%s\n' 'selective cleanup failpoint did not become ready' >&2
        return 1
    fi

    chmod 0500 "${MANAGED_ROOT}/config"
    touch "${release_file}"
    wait "${pid}" || process_status="${?}"
    chmod 0700 "${MANAGED_ROOT}/config"

    assert_equal "${process_status}" "1"
    run cat "${output_file}"
    assert_success
    assert_output_contains "cleanup was incomplete"
    backup_path="$(find "${MANAGED_ROOT}/config" \
        -maxdepth 1 -name '.*.snapshot-restore-backup-*' -print -quit)"
    assert_file_exists "${backup_path}"

    run_snapshot recovery-status
    assert_success
    run jq -e '
        .status == "attention" and
        any(.transactions[]?.artifacts[]?; contains(".snapshot-restore-backup-"))
    ' <<<"${output}"
    assert_success

    run_snapshot recover
    assert_success
    assert_file_absent "${backup_path}"
    run jq -r '.status' \
        "${TEST_HOME}/.fedora-postinstall-snapshot-recovery-"*.json
    assert_success
    assert_equal "${output}" "completed"
}

@test "snapshot list and diff do not exhaust file descriptors" {
    local base_snapshot
    local metadata
    local index
    local snapshot_name
    local first_snapshot="20200101T000000Z-00000001"
    local last_snapshot="20200101T000000Z-00000050"

    run_snapshot create descriptor-base
    assert_success
    base_snapshot="$(snapshot_id)"

    for index in $(seq 1 80); do
        snapshot_name="$(printf '20200101T000000Z-%08x' "${index}")"
        cp -a "${STORAGE_ROOT}/${base_snapshot}" "${STORAGE_ROOT}/${snapshot_name}"
        metadata="${STORAGE_ROOT}/${snapshot_name}/metadata.json"
        jq --arg id "${snapshot_name}" '.id = $id' "${metadata}" > "${metadata}.new"
        mv "${metadata}.new" "${metadata}"
    done

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        bash -c 'ulimit -n 64; exec python3 "$1" list' \
        _ "${REPO_ROOT}/common/snapshot.py"
    assert_success
    assert_output_contains "${base_snapshot}"
    assert_output_contains "${last_snapshot}"
    refute_output_contains "Too many open files"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        bash -c 'ulimit -n 64; exec python3 "$1" diff "$2" "$3"' \
        _ \
        "${REPO_ROOT}/common/snapshot.py" \
        "${first_snapshot}" \
        "${last_snapshot}"
    assert_success
    assert_output_contains "Snapshots are identical."
    refute_output_contains "Too many open files"
}

@test "a failed selective restore removes newly created parent directories" {
    local snapshot
    local journal

    run_snapshot create created-parent-rollback
    assert_success
    snapshot="$(snapshot_id)"
    rm -rf "${MANAGED_ROOT}/config"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="after_selective_commit" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="exception" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_TARGET="config/file.txt" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" \
        --path config/file.txt --yes
    assert_failure
    assert_output_contains "injected snapshot test failure at after_selective_commit"
    assert_file_absent "${MANAGED_ROOT}/config"
    assert_file_absent "${MANAGED_ROOT}/config/file.txt"
    assert_no_restore_artifacts

    journal="$(find "${TEST_HOME}" -maxdepth 1 \
        -name '.fedora-postinstall-snapshot-recovery-*.json' -print -quit)"
    run jq -r '.status' "${journal}"
    assert_success
    assert_equal "${output}" "recovered"
}

@test "snapshot recovery cannot use the home directory as its managed root" {
    local transaction_id="dddddddddddddddddddddddddddddddd"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local victim_name=".snapshot-selective-dddddddddddddddddddddddddddddddd"
    local victim="${TEST_HOME}/${victim_name}"

    mkdir -p "${victim}"
    printf '%s\n' 'victim' > "${victim}/file.txt"
    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "in_progress",
  "root": "${TEST_HOME}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": "${victim_name}",
  "records": []
}
EOF

    run_snapshot recover
    assert_failure
    assert_output_contains "must not be the home directory"
    assert_file_exists "${victim}/file.txt"

    run_snapshot create automatic-recovery-check
    assert_failure
    assert_file_exists "${victim}/file.txt"
}

@test "snapshot recovery cannot rename an unrelated directory as a backup" {
    local transaction_id="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local victim="${TEST_HOME}/Documents"

    mkdir -p "${victim}"
    printf '%s\n' 'documents' > "${victim}/file.txt"
    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "whole",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "root_existed": true,
  "storage_path": "${STORAGE_ROOT}",
  "storage_relative": ["backups", "snapshots"],
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": "..host.snapshot-stage-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "backup_name": "Documents",
  "preserved_storage_name": "..host.snapshot-storage-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "failed_root_name": null
}
EOF

    run_snapshot recover
    assert_failure
    assert_output_contains "invalid backup name"
    assert_file_exists "${victim}/file.txt"
    assert_file_exists "${MANAGED_ROOT}/config/file.txt"

    run_snapshot create automatic-whole-recovery-check
    assert_failure
    assert_file_exists "${victim}/file.txt"
    assert_file_exists "${MANAGED_ROOT}/config/file.txt"
}

@test "whole-tree recovery records a failed-root rename before moving data" {
    local snapshot
    local journal
    local failed_root_name

    run_snapshot create durable-failed-root
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="after_root_replacement,after_failed_root_rename" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="exception" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" --yes
    assert_failure
    assert_output_contains "rollback was incomplete"

    journal="$(find "${TEST_HOME}" -maxdepth 1 \
        -name '.fedora-postinstall-snapshot-recovery-*.json' -print -quit)"
    run jq -r '.failed_root_name' "${journal}"
    assert_success
    failed_root_name="${output}"
    [[ "${failed_root_name}" =~ ^\.\.host\.failed-snapshot-restore-[0-9a-f]{32}$ ]]
    assert_file_exists "${TEST_HOME}/${failed_root_name}"

    run_snapshot recover
    assert_success
    assert_file_absent "${TEST_HOME}/${failed_root_name}"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
    run jq -r '.status' "${journal}"
    assert_success
    assert_equal "${output}" "recovered"
}

@test "snapshot recovery rejects malformed journal states before mutation" {
    local transaction_id="ffffffffffffffffffffffffffffffff"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local sentinel="${MANAGED_ROOT}/sentinel.txt"

    printf '%s\n' 'sentinel' > "${sentinel}"

    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "not-a-status",
  "root": "${MANAGED_ROOT}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": ".snapshot-selective-ffffffffffffffffffffffffffffffff",
  "records": []
}
EOF
    run_snapshot recover
    assert_failure
    assert_output_contains "invalid status"
    assert_file_exists "${sentinel}"

    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": ".snapshot-selective-ffffffffffffffffffffffffffffffff",
  "records": [
    {
      "relative": "config/file.txt",
      "target_name": "file.txt",
      "backup_name": ".file.txt.snapshot-restore-backup-ffffffffffffffffffffffffffffffff",
      "had_old": "false",
      "created_parents": [],
      "status": "backup_intent"
    }
  ]
}
EOF
    run_snapshot recover
    assert_failure
    assert_output_contains "invalid prior-target state"
    assert_file_exists "${sentinel}"

    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": ".snapshot-selective-ffffffffffffffffffffffffffffffff",
  "records": [
    {
      "relative": "config/file.txt",
      "target_name": "file.txt",
      "backup_name": ".file.txt.snapshot-restore-backup-ffffffffffffffffffffffffffffffff",
      "had_old": true,
      "created_parents": [],
      "status": "not-a-record-status"
    }
  ]
}
EOF
    run_snapshot recover
    assert_failure
    assert_output_contains "invalid restore-record status"
    assert_file_exists "${sentinel}"

    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "whole",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "root_existed": true,
  "storage_path": "${STORAGE_ROOT}",
  "storage_relative": "backups/snapshots",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": "..host.snapshot-stage-ffffffffffffffffffffffffffffffff",
  "backup_name": "..host.pre-snapshot-restore-20260101T000000Z-00000000-ffffffff",
  "preserved_storage_name": "..host.snapshot-storage-ffffffffffffffffffffffffffffffff",
  "failed_root_name": null
}
EOF
    run_snapshot recover
    assert_failure
    assert_output_contains "invalid storage path"
    assert_file_exists "${sentinel}"
}

@test "a selective restore with many paths does not exhaust file descriptors" {
    local snapshot
    local index
    local filename
    local restore_arguments=()

    mkdir -p "${MANAGED_ROOT}/many"
    for index in $(seq 1 80); do
        filename="$(printf 'file-%03d.txt' "${index}")"
        printf 'original-%03d\n' "${index}" > "${MANAGED_ROOT}/many/${filename}"
        restore_arguments+=(--path "many/${filename}")
    done

    run_snapshot create many-paths
    assert_success
    snapshot="$(snapshot_id)"
    for index in $(seq 1 80); do
        filename="$(printf 'file-%03d.txt' "${index}")"
        printf 'changed-%03d\n' "${index}" > "${MANAGED_ROOT}/many/${filename}"
    done

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        TMPDIR="${TEST_ROOT}/tmp" \
        bash -c 'ulimit -n 64; exec python3 "$1" restore "$2" --yes "${@:3}"' \
        _ \
        "${REPO_ROOT}/common/snapshot.py" \
        "${snapshot}" \
        "${restore_arguments[@]}"
    assert_success
    refute_output_contains "Too many open files"
    run cat "${MANAGED_ROOT}/many/file-001.txt"
    assert_success
    assert_equal "${output}" "original-001"
    run cat "${MANAGED_ROOT}/many/file-080.txt"
    assert_success
    assert_equal "${output}" "original-080"
    assert_no_restore_artifacts
}

@test "ambiguous snapshot labels do not leak file descriptors" {
    local checker="${TEST_ROOT}/check-label-fds.py"

    run_snapshot create duplicate-label
    assert_success
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"
    run_snapshot create duplicate-label
    assert_success

    cat > "${checker}" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

module_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("snapshot_helper", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
home = Path(os.environ["HOME"]).resolve()
layout = module.storage_layout(home)
storage = module.open_storage_directory(layout, home, create=False)
before = len(os.listdir("/proc/self/fd"))
try:
    module.load_snapshot("duplicate-label", storage)
except module.SnapshotError:
    pass
else:
    raise SystemExit("duplicate label unexpectedly resolved")
after = len(os.listdir("/proc/self/fd"))
os.close(storage)
print(after - before)
PY

    run env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        python3 "${checker}" "${REPO_ROOT}/common/snapshot.py"
    assert_success
    assert_equal "${output}" "0"
}

@test "a failed selective rollback keeps cleanup pending until recovery" {
    local snapshot
    local ready_file="${TEST_ROOT}/rollback-cleanup.ready"
    local release_file="${TEST_ROOT}/rollback-cleanup.release"
    local output_file="${TEST_ROOT}/rollback-cleanup.out"
    local pid
    local process_status=0
    local stage_path
    local journal

    run_snapshot create rollback-cleanup
    assert_success
    snapshot="$(snapshot_id)"
    printf '%s\n' 'changed' > "${MANAGED_ROOT}/config/file.txt"

    env \
        HOME="${TEST_HOME}" \
        POSTINSTALL_ROOT_DIRECTORY_STRUCTURE="${MANAGED_ROOT}" \
        POSTINSTALL_SNAPSHOT_TEST_MODE=1 \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT="after_selective_commit" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND="pause" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_READY="${ready_file}" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_RELEASE="${release_file}" \
        POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_TARGET="config/file.txt" \
        TMPDIR="${TEST_ROOT}/tmp" \
        python3 "${REPO_ROOT}/common/snapshot.py" restore "${snapshot}" \
        --path config/file.txt --yes >"${output_file}" 2>&1 &
    pid="${!}"

    for _ in {1..200}; do
        [ -e "${ready_file}" ] && break
        sleep 0.05
    done
    if [ ! -e "${ready_file}" ]; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        printf '%s\n' 'selective rollback failpoint did not become ready' >&2
        return 1
    fi

    chmod 0500 "${MANAGED_ROOT}"
    kill -TERM "${pid}"
    touch "${release_file}"
    wait "${pid}" || process_status="${?}"
    chmod 0700 "${MANAGED_ROOT}"

    assert_equal "${process_status}" "143"
    stage_path="$(find "${MANAGED_ROOT}" -maxdepth 1 \
        -name '.snapshot-selective-*' -print -quit)"
    assert_file_exists "${stage_path}"
    journal="$(find "${TEST_HOME}" -maxdepth 1 \
        -name '.fedora-postinstall-snapshot-recovery-*.json' -print -quit)"
    run jq -r '.status' "${journal}"
    assert_success
    assert_equal "${output}" "recovery_required"

    run_snapshot recovery-status
    assert_success
    run jq -e '.status == "attention"' <<<"${output}"
    assert_success

    run_snapshot recover
    assert_success
    assert_file_absent "${stage_path}"
    run cat "${MANAGED_ROOT}/config/file.txt"
    assert_success
    assert_equal "${output}" "changed"
    run jq -r '.status' "${journal}"
    assert_success
    assert_equal "${output}" "recovered"
}

@test "unsupported legacy recovery journals are disclosed without mutation" {
    local transaction_id="99999999999999999999999999999999"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local victim="${MANAGED_ROOT}/.snapshot-selective-99999999999999999999999999999999"

    mkdir -p "${victim}"
    printf '%s\n' 'victim' > "${victim}/file.txt"
    cat > "${journal}" <<EOF
{
  "schema_version": 1,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "in_progress",
  "root": "${MANAGED_ROOT}",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": ".snapshot-selective-99999999999999999999999999999999",
  "records": []
}
EOF

    run_snapshot recovery-status
    assert_success
    run jq -e '
        .status == "attention" and
        any(.transactions[]?; .status == "invalid")
    ' <<<"${output}"
    assert_success
    run_snapshot recover
    assert_failure
    assert_output_contains "unsupported snapshot recovery journal schema"
    assert_file_exists "${victim}/file.txt"
}
