#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/doctor"
    MOCK_BIN="${TEST_ROOT}/bin"
    TEST_HOME="${TEST_ROOT}/home"
    GUM_MARKER="${TEST_ROOT}/gum-called"

    mkdir -p \
        "${MOCK_BIN}" \
        "${TEST_HOME}/.local/bin" \
        "${TEST_ROOT}/tmp"

    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
EOF

    cat > "${MOCK_BIN}/fwupdmgr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_FWUPDMGR_LOG}"
if [ "${MOCK_FWUPDMGR_STATUS:-2}" -eq 0 ]; then
    printf '%s\n' 'Firmware update available'
fi
exit "${MOCK_FWUPDMGR_STATUS:-2}"
EOF

    cat > "${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_SYSTEMCTL_LOG}"
printf '%s\n' "${MOCK_SYSTEMCTL_OUTPUT:-enabled}"
exit "${MOCK_SYSTEMCTL_STATUS:-0}"
EOF

    cat > "${MOCK_BIN}/dnf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DNF_LOG}"
printf '%s\n' "${MOCK_DNF_OUTPUT:-No process needs to be restarted.}"
exit "${MOCK_DNF_STATUS:-0}"
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_GUM_MARKER}"
exit 99
EOF

    chmod +x \
        "${MOCK_BIN}/fwupdmgr" \
        "${MOCK_BIN}/systemctl" \
        "${MOCK_BIN}/dnf" \
        "${MOCK_BIN}/rpm" \
        "${MOCK_BIN}/gum"

    export MOCK_FWUPDMGR_LOG="${TEST_ROOT}/fwupdmgr.log"
    export MOCK_SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
    export MOCK_DNF_LOG="${TEST_ROOT}/dnf.log"
    export MOCK_GUM_MARKER="${GUM_MARKER}"
    export MOCK_FWUPDMGR_STATUS=2
}

run_doctor_json() {
    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash -c \
            'source "$1/common/doctor.sh"; doctor_run --json' \
            _ "${REPO_ROOT}"
}

@test "doctor JSON reports every required read-only check" {
    run_doctor_json
    assert_success

    run jq -e '
        .schema_version == 1 and
        .status == "ok" and
        ([.checks[].id] | sort) == ([
            "fedora-system",
            "firmware-updates",
            "fstrim-timer",
            "local-bin-path",
            "restart-required",
            "snapshot-recovery"
        ] | sort) and
        all(.checks[]; .status == "ok")
    ' <<<"${output}"
    assert_success

    run grep -Fx 'get-updates' "${MOCK_FWUPDMGR_LOG}"
    assert_success
    run grep -Fx 'is-enabled fstrim.timer' "${MOCK_SYSTEMCTL_LOG}"
    assert_success
    run grep -Fx -- '--cacheonly needs-restarting -r' "${MOCK_DNF_LOG}"
    assert_success
}

@test "doctor treats fwupdmgr status two as a successful no-update result" {
    export MOCK_FWUPDMGR_STATUS=2

    run_doctor_json
    assert_success

    run jq -e '
        .checks[] | select(.id == "firmware-updates") |
        .status == "ok" and
        (.message | contains("No firmware updates"))
    ' <<<"${output}"
    assert_success
}

@test "doctor reports available firmware updates as a warning" {
    export MOCK_FWUPDMGR_STATUS=0

    run_doctor_json
    assert_success

    run jq -e '
        .status == "warning" and
        (.checks[] | select(.id == "firmware-updates") | .status == "warning")
    ' <<<"${output}"
    assert_success
}

@test "doctor reports a failed firmware query as an error" {
    export MOCK_FWUPDMGR_STATUS=1

    run_doctor_json
    assert_equal "${status}" "1"

    run jq -e '
        .status == "error" and
        (.checks[] | select(.id == "firmware-updates") | .status == "error")
    ' <<<"${output}"
    assert_success
}

@test "doctor reports a pending Workstation restart as a warning" {
    export MOCK_DNF_STATUS=1
    export MOCK_DNF_OUTPUT="Reboot is required."

    run_doctor_json
    assert_success

    run jq -e '
        .status == "warning" and
        (.checks[] | select(.id == "restart-required") | .status == "warning")
    ' <<<"${output}"
    assert_success
}

@test "doctor distinguishes a restart-pending result from a DNF failure" {
    export MOCK_DNF_STATUS=1
    export MOCK_DNF_OUTPUT="Unknown command: needs-restarting"

    run_doctor_json
    assert_equal "${status}" "1"

    run jq -e '
        .status == "error" and
        (.checks[] | select(.id == "restart-required") | .status == "error")
    ' <<<"${output}"
    assert_success
}

@test "a flavor override does not suppress Workstation host checks" {
    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR="silverblue" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash -c \
            'source "$1/common/doctor.sh"; doctor_run --json' \
            _ "${REPO_ROOT}"
    assert_success

    run jq -e '
        .flavor == "workstation" and
        .selected_flavor == "silverblue" and
        (.checks[] | select(.id == "restart-required") | .status) == "ok"
    ' <<<"${output}"
    assert_success
    run grep -Fx -- '--cacheonly needs-restarting -r' "${MOCK_DNF_LOG}"
    assert_success
}

@test "doctor treats a runtime-disabled fstrim timer as a warning" {
    export MOCK_SYSTEMCTL_OUTPUT="disabled-runtime"

    run_doctor_json
    assert_success

    run jq -e '
        .status == "warning" and
        (.checks[] | select(.id == "fstrim-timer") | .status == "warning")
    ' <<<"${output}"
    assert_success
}

@test "doctor treats an unreadable fstrim timer state as an error" {
    export MOCK_SYSTEMCTL_STATUS=1
    export MOCK_SYSTEMCTL_OUTPUT="Failed to connect to the system manager."

    run_doctor_json
    assert_equal "${status}" "1"

    run jq -e '
        .status == "error" and
        (.checks[] | select(.id == "fstrim-timer") | .status == "error")
    ' <<<"${output}"
    assert_success
}

@test "doctor reports a missing local executable path as a warning" {
    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash -c \
            'source "$1/common/doctor.sh"; doctor_run --json' \
            _ "${REPO_ROOT}"
    assert_success

    run jq -e '
        .status == "warning" and
        (.checks[] | select(.id == "local-bin-path") | .status == "warning")
    ' <<<"${output}"
    assert_success
}

@test "doctor recognizes the local executable path through a symbolic-link HOME" {
    local home_link="${TEST_ROOT}/home-link"

    ln -s "${TEST_HOME}" "${home_link}"
    run env \
        HOME="${home_link}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash -c \
            'source "$1/common/doctor.sh"; doctor_run --json' \
            _ "${REPO_ROOT}"
    assert_success

    run jq -e '
        .checks[] | select(.id == "local-bin-path") | .status == "ok"
    ' <<<"${output}"
    assert_success
}

@test "doctor skips the Workstation restart check on a Silverblue host" {
    cat > "${TEST_ROOT}/os-release" <<'EOF'
NAME="Fedora Silverblue"
ID=fedora
VARIANT_ID=silverblue
VERSION_ID=45
EOF

    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash -c \
            'source "$1/common/doctor.sh"; doctor_run --json' \
            _ "${REPO_ROOT}"
    assert_success

    run jq -e '
        (.checks[] | select(.id == "restart-required") | .status) == "skipped"
    ' <<<"${output}"
    assert_success
    assert_file_absent "${MOCK_DNF_LOG}"
}

@test "doctor dispatch is JSON and Gum-independent" {
    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" doctor --json
    assert_success

    run jq -e '.schema_version == 1 and (.checks | length) == 6' <<<"${output}"
    assert_success
    refute_output_contains "Gum"
    assert_file_absent "${GUM_MARKER}"
    assert_file_absent "${TEST_HOME}/.cache/fedora-postinstall"
}

@test "doctor dispatch propagates a failed check status" {
    export MOCK_FWUPDMGR_STATUS=1

    run env \
        HOME="${TEST_HOME}" \
        PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
        POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
        bash "${REPO_ROOT}/fedora-postinstall.sh" doctor --json
    assert_equal "${status}" "1"

    run jq -e '
        .status == "error" and
        (.checks[] | select(.id == "firmware-updates") | .status == "error")
    ' <<<"${output}"
    assert_success
    assert_file_absent "${GUM_MARKER}"
    assert_file_absent "${TEST_HOME}/.cache/fedora-postinstall"
}

@test "doctor rejects runtime logging options instead of silently ignoring them" {
    local argument

    for argument in \
        "--log-file ${TEST_ROOT}/doctor.log" \
        "--log-format json" \
        "--log-level debug" \
        "--log-stdout"; do
        run env \
            HOME="${TEST_HOME}" \
            PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
            POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
            bash "${REPO_ROOT}/fedora-postinstall.sh" doctor --json \
            ${argument}
        assert_equal "${status}" "64"
        assert_output_contains "logging options are not valid for doctor"
        assert_file_absent "${TEST_ROOT}/doctor.log"
        assert_file_absent "${TEST_HOME}/.cache/fedora-postinstall"
    done
}

@test "doctor rejects logging inherited from the environment" {
    local variable
    local value

    for variable in \
        POSTINSTALL_LOG_FILE \
        POSTINSTALL_LOG_FORMAT \
        POSTINSTALL_LOG_LEVEL \
        POSTINSTALL_LOG_STDOUT; do
        case "${variable}" in
        POSTINSTALL_LOG_FILE)
            value="${TEST_ROOT}/doctor.log"
            ;;
        POSTINSTALL_LOG_FORMAT)
            value=json
            ;;
        POSTINSTALL_LOG_LEVEL)
            value=debug
            ;;
        *)
            value=1
            ;;
        esac
        run env \
            HOME="${TEST_HOME}" \
            PATH="${MOCK_BIN}:${TEST_HOME}/.local/bin:/usr/bin:/bin" \
            POSTINSTALL_OS_RELEASE_FILE="${TEST_ROOT}/os-release" \
            "${variable}=${value}" \
            bash "${REPO_ROOT}/fedora-postinstall.sh" doctor --json
        assert_equal "${status}" "64"
        assert_output_contains "logging options are not valid for doctor"
        assert_file_absent "${TEST_ROOT}/doctor.log"
        assert_file_absent "${TEST_HOME}/.cache/fedora-postinstall"
    done
}

@test "doctor discloses snapshot recovery artifacts" {
    local transaction_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local journal="${TEST_HOME}/.fedora-postinstall-snapshot-recovery-${transaction_id}.json"
    local stage_name=".snapshot-selective-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local backup_name=".file.txt.snapshot-restore-backup-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local backup_path="${TEST_HOME}/.host/config/${backup_name}"

    cat > "${journal}" <<EOF
{
  "schema_version": 2,
  "transaction_id": "${transaction_id}",
  "kind": "selective",
  "status": "committed",
  "root": "${TEST_HOME}/.host",
  "snapshot_id": "20260101T000000Z-00000000",
  "stage_name": "${stage_name}",
  "records": [
    {
      "relative": "config/file.txt",
      "target_name": "file.txt",
      "backup_name": "${backup_name}",
      "backup_path": "${backup_path}",
      "had_old": true,
      "created_parents": [],
      "status": "backup_retained"
    }
  ]
}
EOF

    run_doctor_json
    assert_equal "${status}" "1"

    run jq -e \
        --arg stage "${TEST_HOME}/.host/${stage_name}" \
        --arg backup "${backup_path}" '
        .status == "error" and
        (.checks[] | select(.id == "snapshot-recovery") |
            .status == "error" and
            (.details | contains("artifact=" + $stage)) and
            (.details | contains("artifact=" + $backup)))
    ' <<<"${output}"
    assert_success
}

@test "doctor does not inspect backup tools" {
    run grep -Eiq '(borg|restic|duplicity|resticore)' \
        "${REPO_ROOT}/common/doctor.sh"
    assert_failure
}
