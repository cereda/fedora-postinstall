#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"
load "${BATS_TEST_DIRNAME}/../helpers/lock-events"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/runtime"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    STATE_FILE="${TEST_ROOT}/state.tsv"
    LOG_FILE="${TEST_ROOT}/postinstall.log"
    MOCK_BIN="${TEST_ROOT}/bin"

    mkdir -p \
        "${MOCK_BIN}" \
        "${SANDBOX_REPO}/common" \
        "${SANDBOX_REPO}/extras" \
        "${SANDBOX_REPO}/workstation" \
        "${SANDBOX_REPO}/silverblue" \
        "${SANDBOX_REPO}/modules" \
        "${TEST_ROOT}/tmp"

    cp "${REPO_ROOT}/common/runtime.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/runtime-file.py" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/lock-holder.py" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/gum-functions.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/flatpaks-to-install.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/fonts-to-install.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/color-themes.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/extras/tools-list.sh" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/workstation/packages-to-remove.sh" "${SANDBOX_REPO}/workstation/"
    cp "${REPO_ROOT}/workstation/packages-to-install.sh" "${SANDBOX_REPO}/workstation/"
    cp "${REPO_ROOT}/silverblue/packages-to-install.sh" "${SANDBOX_REPO}/silverblue/"
    cp "${REPO_ROOT}/silverblue/flatpak-cleanup.sh" "${SANDBOX_REPO}/silverblue/"

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "confirm" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/gum"
}

write_module() {
    local name="${1}"
    local content="${2}"

    printf '%s\n' "${content}" > "${SANDBOX_REPO}/modules/${name}"
}

run_runtime() {
    local script="${1}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_LOG_FILE="${LOG_FILE}" \
        POSTINSTALL_LOG_STDOUT="1" \
        POSTINSTALL_STATE_NAMESPACE="test" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; ${script}"
}

run_runtime_default_state() {
    local resume="${1:-0}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        XDG_STATE_HOME="${TEST_ROOT}/xdg-state" \
        TMPDIR="${TEST_ROOT}/tmp" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_RESUME="${resume}" \
        POSTINSTALL_LOG_FILE="${LOG_FILE}" \
        POSTINSTALL_LOG_STDOUT="1" \
        POSTINSTALL_STATE_NAMESPACE="test" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; ${2}"
}

@test "runtime modules execute in order and record completion" {
    write_module "first.sh" "RUNTIME_TEST_GLOBAL='visible'; printf 'first\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    write_module "second.sh" "printf 'second\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/order.txt'; runtime_run_module 'modules/first.sh'; test \"\${RUNTIME_TEST_GLOBAL}\" = visible; runtime_run_module 'modules/second.sh'"
    assert_success

    run cat "${TEST_ROOT}/order.txt"
    assert_success
    assert_equal "${output}" $'first\nsecond'
    run grep -F 'test:modules/first.sh' "${STATE_FILE}"
    assert_success
    run grep -F 'test:modules/second.sh' "${STATE_FILE}"
    assert_success
}

@test "runtime preserves global arrays declared by list modules" {
    run_runtime "runtime_run_module 'extras/tools-list.sh'; test \"\${#CLI_TOOLS_LIST[@]}\" -eq 40"
    assert_success
}

@test "runtime propagates module failures" {
    write_module "failure.sh" "return 7"

    run_runtime "runtime_run_module 'modules/failure.sh'"
    assert_equal "${status}" 7
    assert_output_contains "failed with status 7"
}

@test "runtime detects an intermediate command failure" {
    write_module "intermediate-failure.sh" "false; true"

    run_runtime "runtime_run_module 'modules/intermediate-failure.sh'"
    assert_equal "${status}" 1
    assert_output_contains "Command 'false' failed with status 1"
    assert_output_contains "failed with status 1"
}

@test "nested module failures are reported by both modules" {
    write_module "nested-failure.sh" "return 7"
    write_module "nested-parent.sh" "runtime_run_module 'modules/nested-failure.sh'; runtime_run_module 'modules/never-run.sh'"

    run_runtime "runtime_run_module 'modules/nested-parent.sh' orchestrator"
    assert_equal "${status}" 7
    assert_output_contains "Module 'modules/nested-failure.sh' failed with status 7"
    assert_output_contains "Module 'modules/nested-parent.sh' failed with status 7"
}

@test "a nested module failure cannot be masked by its parent" {
    write_module "masked-parent.sh" "runtime_run_module 'modules/missing-child.sh'; true"

    run_runtime "runtime_run_module 'modules/masked-parent.sh' orchestrator"
    assert_failure
    assert_output_contains "Unable to resolve module 'modules/missing-child.sh'"
    assert_output_contains "Module 'modules/masked-parent.sh' failed with status 1"
    refute_output_contains "Completed orchestrator 'modules/masked-parent.sh'"
}

@test "Silverblue Flatpak cleanup aborts when listing applications fails" {
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
    exit 9
fi
: > "${MOCK_FLATPAK_MARKER}"
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_FLATPAK_MARKER="${TEST_ROOT}/flatpak-uninstalled"

    run_runtime "section() { :; }; text() { :; }; info() { :; }; runtime_run_module 'silverblue/flatpak-cleanup.sh'"
    assert_failure
    assert_output_contains "Module 'silverblue/flatpak-cleanup.sh' failed with status 1"
    assert_file_absent "${MOCK_FLATPAK_MARKER}"
}

@test "Silverblue Flatpak cleanup succeeds when no applications are installed" {
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
    exit 0
fi
: > "${MOCK_FLATPAK_MARKER}"
EOF
    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_GUM_MARKER}"
exit 1
EOF
    chmod +x "${MOCK_BIN}/flatpak" "${MOCK_BIN}/gum"
    export MOCK_FLATPAK_MARKER="${TEST_ROOT}/flatpak-uninstalled"
    export MOCK_GUM_MARKER="${TEST_ROOT}/gum-called"

    run_runtime "section() { :; }; text() { printf '%s\\n' \"\$1\"; }; info() { :; }; GUM='${MOCK_BIN}/gum'; runtime_run_module 'silverblue/flatpak-cleanup.sh'"
    assert_success
    assert_output_contains "You haven't selected any items from the list"
    assert_file_absent "${MOCK_FLATPAK_MARKER}"
    assert_file_absent "${MOCK_GUM_MARKER}"
}

@test "Silverblue Flatpak cleanup aborts when the chooser fails" {
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
    printf '%s\n' 'org.example.Application'
    exit 0
fi
: > "${MOCK_FLATPAK_MARKER}"
EOF
    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    chmod +x "${MOCK_BIN}/flatpak" "${MOCK_BIN}/gum"
    export MOCK_FLATPAK_MARKER="${TEST_ROOT}/flatpak-uninstalled"

    run_runtime "section() { :; }; text() { :; }; info() { :; }; GUM='${MOCK_BIN}/gum'; runtime_run_module 'silverblue/flatpak-cleanup.sh'"
    assert_failure
    assert_output_contains "Module 'silverblue/flatpak-cleanup.sh' failed with status 1"
    assert_file_absent "${MOCK_FLATPAK_MARKER}"
}

@test "a captured command failure aborts the module" {
    write_module "capture-failure.sh" "runtime_capture_output CAPTURED_VALUE false || return 1; true"

    run_runtime "runtime_run_module 'modules/capture-failure.sh'"
    assert_equal "${status}" 1
    assert_output_contains "Module 'modules/capture-failure.sh' failed with status 1"
}

@test "an explicitly handled command substitution failure is recoverable" {
    write_module "recoverable-failure.sh" "if ! CAPTURED_VALUE=\$(false); then CAPTURED_VALUE=recovered; fi; test \"\${CAPTURED_VALUE}\" = recovered"

    run_runtime "runtime_run_module 'modules/recoverable-failure.sh'"
    assert_success
}

@test "runtime detects a failed command inside a pipeline" {
    write_module "pipeline-failure.sh" "printf 'not-a-version\\n' | grep -q '^version-'; true"

    run_runtime "runtime_run_module 'modules/pipeline-failure.sh'"
    assert_equal "${status}" 1
    assert_output_contains "failed with status 1"
}

@test "a declined question is not treated as a module failure" {
    write_module "declined-question.sh" "source '${SANDBOX_REPO}/common/gum-functions.sh'; if question 'Continue?'; then printf 'accepted\\n'; else printf 'declined\\n'; fi"

    run_runtime "runtime_run_module 'modules/declined-question.sh'"
    assert_success
    assert_output_contains "declined"
    refute_output_contains "Command 'question' failed"
}

@test "a genuine failure after a declined question is still reported" {
    write_module "declined-question-failure.sh" "source '${SANDBOX_REPO}/common/gum-functions.sh'; if question 'Continue?'; then printf 'accepted\\n'; fi; false"

    run_runtime "runtime_run_module 'modules/declined-question-failure.sh'"
    assert_failure
    assert_output_contains "Command 'false' failed with status 1"
}

@test "a normal run records state that a later resume can reuse" {
    write_module "default-state.sh" "printf 'run\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime_default_state 0 "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/default-state.txt'; runtime_run_module 'modules/default-state.sh'"
    assert_success
    assert_file_exists "${TEST_ROOT}/xdg-state/fedora-postinstall/state.tsv"

    run_runtime_default_state 1 "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/default-state.txt'; runtime_run_module 'modules/default-state.sh'"
    assert_success
    assert_output_contains "Resume: skipping completed module"

    run cat "${TEST_ROOT}/default-state.txt"
    assert_success
    assert_equal "${output}" "run"
}

@test "resume checksums include authoritative input lists" {
    local module dependency before after
    local -a pairs=(
        "common/flatpaks-installation.sh:common/flatpaks-to-install.sh"
        "common/fonts-installation.sh:common/fonts-to-install.sh"
        "common/terminal-colors.sh:common/color-themes.sh"
        "workstation/package-cleanup.sh:workstation/packages-to-remove.sh"
        "workstation/useful-packages.sh:workstation/packages-to-install.sh"
        "silverblue/useful-packages.sh:silverblue/packages-to-install.sh"
    )

    for pair in "${pairs[@]}"; do
        module="${pair%%:*}"
        dependency="${pair#*:}"
        printf '# checksum fixture\n' > "${SANDBOX_REPO}/${module}"

        before="$(env SCRIPT_PATH="${SANDBOX_REPO}" bash -c \
            "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_module_checksum '${module}' '${SANDBOX_REPO}/${module}'")"
        printf '# changed input\n' >> "${SANDBOX_REPO}/${dependency}"
        after="$(env SCRIPT_PATH="${SANDBOX_REPO}" bash -c \
            "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_module_checksum '${module}' '${SANDBOX_REPO}/${module}'")"

        if [ "${before}" = "${after}" ]; then
            printf 'checksum did not change for %s\n' "${module}" >&2
            return 1
        fi
    done
}

@test "resume skips an unchanged completed module" {
    write_module "counter.sh" "printf 'run\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/counter.txt'; runtime_run_module 'modules/counter.sh'"
    assert_success

    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/counter.txt'; runtime_run_module 'modules/counter.sh'"
    assert_success
    assert_output_contains "Resume: skipping completed module"

    run cat "${TEST_ROOT}/counter.txt"
    assert_success
    assert_equal "${output}" "run"
}

@test "resume reruns a module whose contents changed" {
    write_module "changed.sh" "printf 'run\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/changed.txt'; runtime_run_module 'modules/changed.sh'"
    assert_success

    write_module "changed.sh" "printf 'changed\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/changed.txt'; runtime_run_module 'modules/changed.sh'"
    assert_success
    refute_output_contains "Resume: skipping completed module"

    run cat "${TEST_ROOT}/changed.txt"
    assert_success
    assert_equal "${output}" $'run\nchanged'
}

@test "dry-run does not execute mutating modules" {
    write_module "dry.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "POSTINSTALL_DRY_RUN=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/dry.txt'; runtime_run_module 'modules/dry.sh'"
    assert_success
    assert_output_contains "Dry run: would run module"
    assert_file_absent "${TEST_ROOT}/dry.txt"
}

@test "dry-run can execute explicitly read-only modules" {
    write_module "read-only.sh" "printf 'read\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "POSTINSTALL_DRY_RUN=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/read-only.txt'; runtime_run_module 'modules/read-only.sh' read-only"
    assert_success
    assert_output_contains "Dry run: completed read-only module"
    assert_file_exists "${TEST_ROOT}/read-only.txt"
}

@test "runtime rejects module traversal" {
    run_runtime "runtime_run_module '../outside.sh'"
    assert_failure
    assert_output_contains "invalid module path"
}

@test "cleanup callbacks run once in reverse registration order" {
    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/cleanup.txt'; cleanup_one() { printf 'one\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; cleanup_two() { printf 'two\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; runtime_register_cleanup 'one' cleanup_one; runtime_register_cleanup 'two' cleanup_two; runtime_cleanup"
    assert_success

    run cat "${TEST_ROOT}/cleanup.txt"
    assert_success
    assert_equal "${output}" $'two\none'
}

@test "installation lock cleanup always runs last" {
    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/cleanup-order.txt'; cleanup_one() { printf 'one\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; cleanup_lock() { printf 'lock\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; cleanup_two() { printf 'two\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; runtime_register_cleanup 'one' cleanup_one; runtime_register_cleanup 'install-lock' cleanup_lock; runtime_register_cleanup 'two' cleanup_two; runtime_cleanup"
    assert_success

    run cat "${TEST_ROOT}/cleanup-order.txt"
    assert_success
    assert_equal "${output}" $'two\none\nlock'
}

@test "cleanup callbacks receive no implicit positional arguments" {
    run bash -c '
        source "$1/common/runtime.sh"
        runtime_initialize || exit $?
        ordinary_cleanup() {
            printf "ordinary:%s\n" "$#"
        }
        lock_cleanup() {
            printf "lock:%s\n" "$#"
        }
        runtime_register_cleanup "ordinary" ordinary_cleanup || exit $?
        runtime_register_cleanup "install-lock" lock_cleanup || exit $?
        runtime_cleanup
    ' _ "${SANDBOX_REPO}" "script-argument"
    assert_success
    assert_equal "${output}" $'ordinary:0\nlock:0'
}

@test "a failed cleanup callback fails an otherwise successful run" {
    run_runtime "cleanup_failure() { return 1; }; runtime_register_cleanup 'failure' cleanup_failure; runtime_cleanup"
    assert_failure
    assert_equal "${status}" "1"
}

@test "an exiting cleanup callback cannot skip installation lock cleanup" {
    local marker="${TEST_ROOT}/exiting-cleanup.lock-released"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            lock_marker="$2"
            function exiting_cleanup {
                exit 42
            }
            function lock_cleanup {
                : > "${lock_marker}"
            }
            runtime_register_cleanup "exiting" exiting_cleanup || exit $?
            runtime_register_cleanup "install-lock" lock_cleanup || exit $?
            runtime_cleanup
        ' _ "${SANDBOX_REPO}" "${marker}"
    assert_equal "${status}" "42"
    assert_file_exists "${marker}"
}

@test "owner loss is security-specific and survives cleanup" {
    run_runtime "RUNTIME_LOCK_ACQUIRED=1; RUNTIME_CRITICAL_DEPTH=1; runtime_handle_owner_loss; printf 'pending=%s name=%s\\n' \"\${RUNTIME_PENDING_SIGNAL_STATUS}\" \"\${RUNTIME_PENDING_SIGNAL_NAME}\""
    assert_equal "${status}" "141"
    assert_output_contains "pending=141 name=owner-loss"

    run_runtime "RUNTIME_LOCK_ACQUIRING=1; runtime_handle_owner_loss"
    assert_equal "${status}" "73"

    run_runtime "RUNTIME_LOCK_ACQUIRED=1; RUNTIME_LOCK_OWNER_RETIREMENT_ACK=1; RUNTIME_CRITICAL_DEPTH=1; runtime_handle_owner_loss; printf 'pending=%s name=%s\\n' \"\${RUNTIME_PENDING_SIGNAL_STATUS}\" \"\${RUNTIME_PENDING_SIGNAL_NAME}\""
    assert_equal "${status}" "141"
    assert_output_contains "pending=141 name=owner-loss"
}

@test "intentional helper teardown does not create a lock-loss status" {
    run_runtime "RUNTIME_LOCK_ACQUIRED=1; RUNTIME_LOCK_TEARDOWN_ACTIVE=1; RUNTIME_LOCK_DECISION_STATE=committed; runtime_handle_lock_loss 141 lock-loss; test \"\${RUNTIME_PENDING_LOCK_LOSS}\" -eq 0; test \"\${RUNTIME_PENDING_SIGNAL_STATUS}\" -eq 0"
    assert_success
}

@test "an unknown decision during helper teardown remains a generic lock loss" {
    run_runtime "RUNTIME_LOCK_ACQUIRED=1; RUNTIME_LOCK_TEARDOWN_ACTIVE=1; RUNTIME_LOCK_DECISION_STATE=unknown; RUNTIME_CRITICAL_DEPTH=1; runtime_handle_lock_loss 141 lock-loss; printf 'pending=%s name=%s\\n' \"\${RUNTIME_PENDING_SIGNAL_STATUS}\" \"\${RUNTIME_PENDING_SIGNAL_NAME}\""
    assert_equal "${status}" "141"
    assert_output_contains "pending=141 name=lock-loss"
}

@test "a cancellation during helper teardown retains its security-specific status" {
    run_runtime "RUNTIME_LOCK_ACQUIRED=1; RUNTIME_LOCK_TEARDOWN_ACTIVE=1; RUNTIME_LOCK_DECISION_STATE=cancelled; RUNTIME_CRITICAL_DEPTH=1; runtime_handle_lock_loss 141 lock-loss; printf 'pending=%s name=%s\\n' \"\${RUNTIME_PENDING_SIGNAL_STATUS}\" \"\${RUNTIME_PENDING_SIGNAL_NAME}\""
    assert_equal "${status}" "73"
    assert_output_contains "pending=73 name=lock-cancelled"
}

@test "shutdown signals during lock acquisition retain their exact statuses" {
    run_runtime "RUNTIME_LOCK_ACQUIRING=1; runtime_handle_signal 143 TERM"
    assert_equal "${status}" "143"
    assert_output_contains "aborting lock acquisition safely"

    run_runtime "RUNTIME_LOCK_ACQUIRING=1; runtime_handle_signal 130 INT"
    assert_equal "${status}" "130"

    run_runtime "RUNTIME_LOCK_ACQUIRING=1; runtime_handle_signal 129 HUP"
    assert_equal "${status}" "129"
}

@test "shutdown signals during helper startup retain their exact statuses" {
    local signal_case
    local signal_name
    local expected_status
    local case_root
    local mock_bin
    local output_file
    local installer_pid
    local installer_status=0
    local attempt

    for signal_case in TERM:143 INT:130 HUP:129; do
        signal_name="${signal_case%%:*}"
        expected_status="${signal_case##*:}"
        case_root="${TEST_ROOT}/acquisition-signal-${signal_name}"
        mock_bin="${case_root}/bin"
        output_file="${case_root}/output"
        installer_pid=""

        mkdir -p "${mock_bin}" "${case_root}/cache" "${case_root}/home"
        cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "validate-status" ] &&
    [ ! -e "${MOCK_ACQUISITION_SIGNAL_STARTED}" ]; then
    : > "${MOCK_ACQUISITION_SIGNAL_STARTED}"
    while [ ! -e "${MOCK_ACQUISITION_SIGNAL_RELEASE}" ]; do
        sleep 0.01
    done
fi
exec /usr/bin/python3 "$@"
EOF
        chmod +x "${mock_bin}/python3"

        env \
            PATH="${mock_bin}:${PATH}" \
            SCRIPT_PATH="${SANDBOX_REPO}" \
            HOME="${case_root}/home" \
            POSTINSTALL_CACHE_DIR="${case_root}/cache" \
            POSTINSTALL_LOCK_FILE="${case_root}/cache/postinstall.lock" \
            POSTINSTALL_LOG_STDOUT="1" \
            MOCK_ACQUISITION_SIGNAL_STARTED="${case_root}/started" \
            MOCK_ACQUISITION_SIGNAL_RELEASE="${case_root}/release" \
            /usr/bin/python3 -c '
                import os
                import signal
                import sys

                signal.signal(signal.SIGINT, signal.SIG_DFL)
                os.execvp(sys.argv[1], sys.argv[1:])
            ' bash -c '
                source "$1/common/runtime.sh"
                runtime_initialize || exit $?
                runtime_acquire_install_lock
                acquisition_status=$?
                printf "acquisition-status=%s pending=%s name=%s acquiring=%s\n" \
                    "${acquisition_status}" \
                    "${RUNTIME_PENDING_SIGNAL_STATUS}" \
                    "${RUNTIME_PENDING_SIGNAL_NAME}" \
                    "${RUNTIME_LOCK_ACQUIRING}"
                exit "${acquisition_status}"
            ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
        installer_pid="${!}"

        for ((attempt = 0; attempt < 200; attempt++)); do
            if [ -e "${case_root}/started" ]; then
                break
            fi
            sleep 0.05
        done
        if [ ! -e "${case_root}/started" ]; then
            kill -KILL "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
            cat "${output_file}" >&2
            return 1
        fi

        kill "-${signal_name}" "${installer_pid}" 2>/dev/null || true
        : > "${case_root}/release"
        wait "${installer_pid}" || installer_status="${?}"
        installer_pid=""

        run cat "${output_file}"
        assert_success
        assert_output_contains "Received ${signal_name}; aborting lock acquisition safely"
        assert_equal "${installer_status}" "${expected_status}"
    done
}

@test "a shutdown signal during owner handoff retains its exact status" {
    local cache_dir="${TEST_ROOT}/owner-handoff-signal-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local output_file="${TEST_ROOT}/owner-handoff-signal.out"
    local installer_pid=""
    local installer_status=0
    local attempt

    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        POSTINSTALL_LOG_STDOUT="1" \
        MOCK_OWNER_HANDOFF_STARTED="${TEST_ROOT}/owner-handoff-signal.started" \
        MOCK_OWNER_HANDOFF_RELEASE="${TEST_ROOT}/owner-handoff-signal.release" \
        bash -c '
            source "$1/common/runtime.sh"
            eval "$(declare -f runtime_close_lock_descriptor | sed '\''1s/runtime_close_lock_descriptor/runtime_close_lock_descriptor_original/'\'')"
            runtime_close_lock_descriptor() {
                if [ "${RUNTIME_TEST_HANDOFF_ACTIVE:-0}" -eq 1 ]; then
                    RUNTIME_TEST_HANDOFF_ACTIVE=0
                    : > "${MOCK_OWNER_HANDOFF_STARTED}"
                    while [ ! -e "${MOCK_OWNER_HANDOFF_RELEASE}" ]; do
                        sleep 0.01
                    done
                fi
                runtime_close_lock_descriptor_original "${1}"
            }
            RUNTIME_TEST_HANDOFF_ACTIVE=1
            runtime_initialize || exit $?
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        if [ -e "${TEST_ROOT}/owner-handoff-signal.started" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${TEST_ROOT}/owner-handoff-signal.started" ]; then
        kill -KILL "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -TERM "${installer_pid}" 2>/dev/null || true
    : > "${TEST_ROOT}/owner-handoff-signal.release"
    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""

    assert_equal "${installer_status}" "143"
    run cat "${output_file}"
    assert_success
    assert_output_contains "aborting lock acquisition safely"
}

@test "a shutdown signal received during cleanup becomes the final status" {
    run_runtime "cleanup_signal() { kill -TERM \$\$; return 0; }; runtime_register_cleanup 'signal' cleanup_signal; runtime_cleanup"
    assert_equal "${status}" "143"
}

@test "an interrupt received during cleanup becomes the final status" {
    run_runtime "cleanup_signal() { kill -INT \$\$; return 0; }; runtime_register_cleanup 'signal' cleanup_signal; runtime_cleanup"
    assert_equal "${status}" "130"
}

@test "a hangup received during cleanup becomes the final status" {
    run_runtime "cleanup_signal() { kill -HUP \$\$; return 0; }; runtime_register_cleanup 'signal' cleanup_signal; runtime_cleanup"
    assert_equal "${status}" "129"
}

@test "shutdown signals at the cleanup status boundary retain their exact statuses" {
    run_runtime "boundary_signal() { if [ \"\${RUNTIME_CLEANING:-0}\" -eq 0 ] && [ \"\${RUNTIME_CLEANED:-0}\" -eq 1 ]; then trap - DEBUG; kill -TERM \$\$; fi; }; set -T; trap boundary_signal DEBUG; runtime_cleanup"
    assert_equal "${status}" "143"

    run_runtime "boundary_signal() { if [ \"\${RUNTIME_CLEANING:-0}\" -eq 0 ] && [ \"\${RUNTIME_CLEANED:-0}\" -eq 1 ]; then trap - DEBUG; kill -INT \$\$; fi; }; set -T; trap boundary_signal DEBUG; runtime_cleanup"
    assert_equal "${status}" "130"

    run_runtime "boundary_signal() { if [ \"\${RUNTIME_CLEANING:-0}\" -eq 0 ] && [ \"\${RUNTIME_CLEANED:-0}\" -eq 1 ]; then trap - DEBUG; kill -HUP \$\$; fi; }; set -T; trap boundary_signal DEBUG; runtime_cleanup"
    assert_equal "${status}" "129"
}

@test "terminal status precedence is independent of signal arrival order" {
    local status_pair
    local current_status
    local candidate_status
    local expected_status

    for status_pair in \
        "0 143 143" \
        "143 0 143" \
        "143 130 143" \
        "130 143 143" \
        "130 129 130" \
        "129 130 130" \
        "129 143 143" \
        "0 73 73" \
        "130 73 73" \
        "73 143 73" \
        "0 141 141" \
        "130 141 141" \
        "141 143 141"; do
        read -r current_status candidate_status expected_status <<<"${status_pair}"
        run env \
            SCRIPT_PATH="${SANDBOX_REPO}" \
            bash -c 'source "$1/common/runtime.sh"; runtime_prefer_shutdown_status "$2" "$3"' \
            _ "${SANDBOX_REPO}" "${current_status}" "${candidate_status}"
        assert_success
        assert_equal "${output}" "${expected_status}"
    done
}

@test "a pending acquisition failure dominates a later ordinary shutdown signal" {
    run_runtime 'RUNTIME_LOCK_ACQUIRING=1; RUNTIME_PENDING_LOCK_LOSS=1; runtime_set_pending_signal_status 73 "lock-acquisition-failed"; runtime_handle_signal 143 TERM; printf "pending=%s\n" "${RUNTIME_PENDING_SIGNAL_STATUS}"'
    assert_equal "${status}" "73"
    assert_output_contains "pending=73"
}

@test "support loss during acquisition is an acquisition failure" {
    run_runtime 'RUNTIME_LOCK_ACQUIRING=1; RUNTIME_LOCK_ACQUIRED=0; runtime_handle_support_loss'
    assert_equal "${status}" "73"
    assert_output_contains "installation lock support failed during acquisition"
}

@test "a pending acquisition failure survives later loss notifications and cleanup failure" {
    run_runtime "RUNTIME_PENDING_LOCK_LOSS=1; runtime_set_pending_signal_status 73 'lock-acquisition-failed'; cleanup_failure() { kill -USR1 \$\$; return 1; }; runtime_register_cleanup 'failure' cleanup_failure; runtime_cleanup"
    assert_equal "${status}" "73"
    assert_output_contains "Cleanup callback 'failure' failed with status 1"
}

@test "cleanup failure does not replace an exact ordinary shutdown status" {
    run_runtime "RUNTIME_PENDING_SIGNAL_STATUS=143; RUNTIME_PENDING_SIGNAL_NAME=TERM; cleanup_failure() { return 1; }; runtime_register_cleanup 'failure' cleanup_failure; runtime_cleanup"
    assert_equal "${status}" "143"

    run_runtime "RUNTIME_PENDING_SIGNAL_STATUS=130; RUNTIME_PENDING_SIGNAL_NAME=INT; cleanup_failure() { return 1; }; runtime_register_cleanup 'failure' cleanup_failure; runtime_cleanup"
    assert_equal "${status}" "130"

    run_runtime "RUNTIME_PENDING_SIGNAL_STATUS=129; RUNTIME_PENDING_SIGNAL_NAME=HUP; cleanup_failure() { return 1; }; runtime_register_cleanup 'failure' cleanup_failure; runtime_cleanup"
    assert_equal "${status}" "129"
}

@test "runtime handles termination signals and runs cleanup" {
    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/signal-cleanup.txt'; cleanup_signal() { printf 'clean\\n' > \"\${RUNTIME_TEST_OUTPUT}\"; }; runtime_register_cleanup 'signal' cleanup_signal; kill -TERM \$\$"
    assert_equal "${status}" 143
    assert_file_exists "${TEST_ROOT}/signal-cleanup.txt"
}

@test "resume restores state exported by a completed module" {
    write_module "provider.sh" "RUNTIME_TEST_STATE='saved value'"

    run_runtime "runtime_run_module 'modules/provider.sh' mutating RUNTIME_TEST_STATE"
    assert_success

    run_runtime "POSTINSTALL_RESUME=1; runtime_run_module 'modules/provider.sh' mutating RUNTIME_TEST_STATE; test \"\${RUNTIME_TEST_STATE}\" = 'saved value'"
    assert_success
    assert_output_contains "Resume: skipping completed module"
}

@test "a failed rerun invalidates a previous completion" {
    write_module "invalidated.sh" "printf 'run\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/invalidated.txt'; runtime_run_module 'modules/invalidated.sh'"
    assert_success

    write_module "invalidated.sh" "return 7"
    run_runtime "POSTINSTALL_RESUME=1; runtime_run_module 'modules/invalidated.sh'"
    assert_equal "${status}" 7

    write_module "invalidated.sh" "printf 'run\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/invalidated.txt'; runtime_run_module 'modules/invalidated.sh'"
    assert_success
    refute_output_contains "Resume: skipping completed module"

    run cat "${TEST_ROOT}/invalidated.txt"
    assert_success
    assert_equal "${output}" $'run\nrun'
}

@test "a partially completed module is rerun on resume" {
    write_module "partial.sh" "printf 'partial\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; false; printf 'complete\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/partial.txt'; runtime_run_module 'modules/partial.sh'"
    assert_equal "${status}" 1

    write_module "partial.sh" "printf 'complete\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/partial.txt'; runtime_run_module 'modules/partial.sh'"
    assert_success
    refute_output_contains "Resume: skipping completed module"

    run cat "${TEST_ROOT}/partial.txt"
    assert_success
    assert_equal "${output}" $'partial\ncomplete'
}

@test "orchestrators always inspect their child modules on resume" {
    write_module "child.sh" "printf 'child\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    write_module "parent.sh" "runtime_run_module 'modules/child.sh' || return 1"

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/orchestrator.txt'; runtime_run_module 'modules/parent.sh' orchestrator"
    assert_success

    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/orchestrator.txt'; runtime_run_module 'modules/parent.sh' orchestrator"
    assert_success
    assert_output_contains "Resume: skipping completed module 'modules/child.sh'"

    write_module "child.sh" "printf 'changed child\\n' >> \"\${RUNTIME_TEST_OUTPUT}\""
    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/orchestrator.txt'; runtime_run_module 'modules/parent.sh' orchestrator"
    assert_success
    refute_output_contains "Resume: skipping completed module 'modules/child.sh'"

    run cat "${TEST_ROOT}/orchestrator.txt"
    assert_success
    assert_equal "${output}" $'child\nchanged child'
}

@test "unregistering and re-registering cleanup does not duplicate callbacks" {
    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/cleanup-re-register.txt'; cleanup_once() { printf 'once\\n' >> \"\${RUNTIME_TEST_OUTPUT}\"; }; runtime_register_cleanup 'once' cleanup_once; runtime_unregister_cleanup 'once'; runtime_register_cleanup 'once' cleanup_once; runtime_cleanup"
    assert_success

    run cat "${TEST_ROOT}/cleanup-re-register.txt"
    assert_success
    assert_equal "${output}" "once"
}

@test "signals received in a critical section are deferred" {
    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/critical.txt'; runtime_enter_critical_section 'test'; kill -TERM \$\$; printf 'continued\\n' > \"\${RUNTIME_TEST_OUTPUT}\"; runtime_leave_critical_section 'test'"
    assert_equal "${status}" 143
    assert_file_exists "${TEST_ROOT}/critical.txt"
    assert_output_contains "deferring shutdown"
}

@test "runtime rejects unsafe state file paths" {
    printf 'state\n' > "${TEST_ROOT}/state-target"
    ln -s "${TEST_ROOT}/state-target" "${STATE_FILE}"
    write_module "unsafe-state.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/unsafe-state.txt'; runtime_run_module 'modules/unsafe-state.sh'"
    assert_failure
    assert_output_contains "symbolic link"
    assert_file_absent "${TEST_ROOT}/unsafe-state.txt"
}

@test "runtime rejects state files under untrusted parent directories" {
    mkdir -p "${TEST_ROOT}/unsafe-parent"
    chmod 0777 "${TEST_ROOT}/unsafe-parent"
    STATE_FILE="${TEST_ROOT}/unsafe-parent/state.tsv"
    write_module "unsafe-parent-state.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/unsafe-parent.txt'; runtime_run_module 'modules/unsafe-parent-state.sh'"
    assert_failure
    assert_output_contains "writable by another user"
    assert_file_absent "${TEST_ROOT}/unsafe-parent.txt"
}

@test "runtime rejects state files under symlinked parent directories" {
    mkdir -p "${TEST_ROOT}/state-parent-target"
    ln -s "${TEST_ROOT}/state-parent-target" "${TEST_ROOT}/state-parent"
    STATE_FILE="${TEST_ROOT}/state-parent/state.tsv"
    write_module "symlink-parent-state.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/symlink-parent.txt'; runtime_run_module 'modules/symlink-parent-state.sh'"
    assert_failure
    assert_output_contains "symbolic link"
    assert_file_absent "${TEST_ROOT}/symlink-parent.txt"
}

@test "resume rejects a state file with multiple hard links" {
    write_module "hard-link-resume.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/hard-link-resume.txt'; runtime_run_module 'modules/hard-link-resume.sh'"
    assert_success
    ln "${STATE_FILE}" "${TEST_ROOT}/state-hard-link-resume"
    rm -f "${TEST_ROOT}/hard-link-resume.txt"

    run_runtime "POSTINSTALL_RESUME=1; RUNTIME_TEST_OUTPUT='${TEST_ROOT}/hard-link-resume.txt'; runtime_run_module 'modules/hard-link-resume.sh'"
    assert_failure
    assert_output_contains "multiple hard links"
    assert_file_absent "${TEST_ROOT}/hard-link-resume.txt"
}

@test "runtime rejects special state files" {
    mkfifo "${STATE_FILE}"
    write_module "fifo-state.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/fifo-state.txt'; runtime_run_module 'modules/fifo-state.sh'"
    assert_failure
    assert_output_contains "not a regular file"
    assert_file_absent "${TEST_ROOT}/fifo-state.txt"
}

@test "runtime rejects state files with multiple hard links" {
    printf 'state\n' > "${STATE_FILE}"
    ln "${STATE_FILE}" "${TEST_ROOT}/state-hard-link"
    write_module "hard-link-state.sh" "printf 'executed\\n' > \"\${RUNTIME_TEST_OUTPUT}\""

    run_runtime "RUNTIME_TEST_OUTPUT='${TEST_ROOT}/hard-link-state.txt'; runtime_run_module 'modules/hard-link-state.sh'"
    assert_failure
    assert_output_contains "multiple hard links"
    assert_file_absent "${TEST_ROOT}/hard-link-state.txt"
}

@test "runtime does not block on a special log file" {
    mkfifo "${LOG_FILE}"

    run_runtime "runtime_log 'INFO' 'test message'"
    assert_success
    assert_output_contains "unable to write log file"
}

@test "runtime rejects a symbolic-link cache directory" {
    local cache_target="${TEST_ROOT}/cache-target"
    local cache_link="${TEST_ROOT}/cache-link"
    mkdir -p "${cache_target}"
    ln -s "${cache_target}" "${cache_link}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_link}" \
        POSTINSTALL_LOCK_FILE="${TEST_ROOT}/install.lock" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_cache_directory"
    assert_failure
    assert_output_contains "symbolic link"
}

@test "runtime rejects a symbolic-link lock file" {
    local lock_target="${TEST_ROOT}/lock-target"
    local lock_link="${TEST_ROOT}/lock-link"
    printf 'unchanged\n' > "${lock_target}"
    ln -s "${lock_target}" "${lock_link}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${TEST_ROOT}/cache" \
        POSTINSTALL_LOCK_FILE="${lock_link}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_lock_file"
    assert_failure
    assert_output_contains "symbolic link"
    run cat "${lock_target}"
    assert_success
    assert_equal "${output}" "unchanged"
}

@test "runtime rejects a world-writable cache directory" {
    local cache_dir="${TEST_ROOT}/unsafe-cache"
    mkdir -p "${cache_dir}"
    chmod 0777 "${cache_dir}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${TEST_ROOT}/install.lock" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_cache_directory"
    assert_failure
    assert_output_contains "writable by another user"
}

@test "runtime rejects a sticky world-writable cache directory" {
    local cache_dir="${TEST_ROOT}/sticky-cache"
    mkdir -p "${cache_dir}"
    chmod 1777 "${cache_dir}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${TEST_ROOT}/install.lock" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_cache_directory"
    assert_failure
    assert_output_contains "writable by another user"
}

@test "runtime rejects a lock file under a world-writable parent" {
    local parent="${TEST_ROOT}/sticky-parent"
    mkdir -p "${parent}"
    chmod 1777 "${parent}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${TEST_ROOT}/cache" \
        POSTINSTALL_LOCK_FILE="${parent}/install.lock" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_lock_file"
    assert_failure
    assert_output_contains "writable by another user"
}

@test "runtime rejects a lock file with multiple hard links" {
    local lock_target="${TEST_ROOT}/lock-target"
    local lock_file="${TEST_ROOT}/lock-hard-link"
    printf 'lock\n' > "${lock_target}"
    ln "${lock_target}" "${lock_file}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${TEST_ROOT}/cache" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_lock_file"
    assert_failure
    assert_output_contains "multiple hard links"
}

@test "runtime rejects a special lock file" {
    local lock_file="${TEST_ROOT}/lock-fifo"
    mkfifo "${lock_file}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${TEST_ROOT}/cache" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_prepare_lock_file"
    assert_failure
    assert_output_contains "not a regular file"
}

@test "installer descendants do not retain the installation lock" {
    local cache_dir="${TEST_ROOT}/descendant-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local child_pid_file="${TEST_ROOT}/descendant.pid"
    local scope_fd

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock || exit $?
            nohup setsid sleep 30 >/dev/null 2>&1 &
            printf "%s\n" "$!" > "$2"
        ' _ "${SANDBOX_REPO}" "${child_pid_file}"
    assert_success

    local child_pid
    local child_alive_status
    local lock_status
    local scope_status
    local descendant_status=0
    child_pid=$(cat "${child_pid_file}")
    run kill -0 "${child_pid}"
    child_alive_status="${status}"

    # The child deliberately outlives the installer. Both lock domains must
    # be immediately reacquirable, and the child must not hold either
    # protected inode.
    run flock --exclusive --nonblock "${lock_file}" true
    lock_status="${status}"
    exec {scope_fd}<"${cache_dir}"
    run flock --exclusive --nonblock "/proc/self/fd/${scope_fd}" true
    scope_status="${status}"

    local descriptor_path
    local descriptor_target
    for descriptor_path in "/proc/${child_pid}/fd"/*; do
        [ -e "${descriptor_path}" ] || continue
        descriptor_target=$(readlink "${descriptor_path}" 2>/dev/null || true)
        if [ "${descriptor_target}" = "${lock_file}" ] ||
            [ "${descriptor_target}" = "${cache_dir}" ]; then
            descendant_status=1
        fi
    done

    kill "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true

    assert_equal "${child_alive_status}" "0"
    assert_equal "${lock_status}" "0"
    assert_equal "${scope_status}" "0"
    assert_equal "${descendant_status}" "0"
}

@test "lock identity validation pins the exact lock inode" {
    local cache_dir="${TEST_ROOT}/lock-identity-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local symlink_file="${cache_dir}/postinstall-link"

    mkdir -p "${cache_dir}"
    printf 'lock\n' > "${lock_file}"
    ln -s "${lock_file}" "${symlink_file}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" lock-identity "${symlink_file}"
    assert_failure

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" lock-identity "${lock_file}"
    assert_success
    local expected_identity
    expected_identity=$(stat -c '%d:%i' "${lock_file}")
    assert_equal "${output}" "${expected_identity}"
}

@test "lock state cleanup is limited to the acquired lock scope" {
    local cache_dir="${TEST_ROOT}/lock-scope-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local lock_scope
    local stale_file
    local other_scope_file

    mkdir -p "${cache_dir}"
    chmod 0700 "${cache_dir}"
    lock_scope=$(printf '%s' "${lock_file}" | sha256sum | cut -c '1-16')
    stale_file="${cache_dir}/.postinstall-lock-${lock_scope}-stale.acquired"
    other_scope_file="${cache_dir}/.postinstall-lock-0123456789abcdef-other.acquired"
    printf 'stale\n' > "${stale_file}"
    printf 'other\n' > "${other_scope_file}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_acquire_install_lock"
    assert_success
    assert_file_absent "${stale_file}"
    assert_file_exists "${other_scope_file}"
}

@test "lock state pruning preserves the current decision" {
    local cache_dir="${TEST_ROOT}/decision-prune-cache"
    local lock_scope="0123456789abcdef"
    local status_name=".postinstall-lock-${lock_scope}-current.acquired"
    local decision_name=".postinstall-lock-${lock_scope}-current.decision"
    local candidate_name="${decision_name}.123.tmp"
    local stale_name=".postinstall-lock-${lock_scope}-stale.decision"

    mkdir -p "${cache_dir}"
    chmod 0700 "${cache_dir}"
    printf 'status\n' > "${cache_dir}/${status_name}"
    printf 'cancelled' > "${cache_dir}/${decision_name}"
    printf 'candidate\n' > "${cache_dir}/${candidate_name}"
    printf 'stale\n' > "${cache_dir}/${stale_name}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" prune-lock-state \
        "${cache_dir}" \
        "${lock_scope}" \
        "${status_name}" \
        "${decision_name}"
    assert_success
    assert_file_exists "${cache_dir}/${status_name}"
    assert_file_exists "${cache_dir}/${decision_name}"
    assert_file_exists "${cache_dir}/${candidate_name}"
    assert_file_absent "${cache_dir}/${stale_name}"
}

@test "lock cancellation is published before the guardian is notified" {
    local decision_directory="${TEST_ROOT}/cancellation-decision"
    local decision_file="${decision_directory}/decision"
    local signal_log="${TEST_ROOT}/cancellation-signals.log"

    mkdir -p "${decision_directory}"
    chmod 700 "${decision_directory}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_DECISION_FILE="$2"
            signal_log="$3"
            runtime_background_job_is_known() {
                return 0
            }
            runtime_signal_background_job() {
                if [ ! -f "${RUNTIME_LOCK_DECISION_FILE}" ] ||
                    [ "$(cat "${RUNTIME_LOCK_DECISION_FILE}")" != "cancelled" ]; then
                    printf "early-%s\\n" "$2" >> "${signal_log}"
                    return 1
                fi
                printf "%s\\n" "$2" >> "${signal_log}"
                return 0
            }
            runtime_request_lock_cancellation 123 "boot-id:456" || exit 1
            printf "state=%s\\n" "${RUNTIME_LOCK_DECISION_STATE}"
        ' _ "${SANDBOX_REPO}" "${decision_file}" "${signal_log}"
    assert_success
    assert_output_contains "state=cancelled"

    run cat "${decision_file}"
    assert_success
    assert_equal "${output}" "cancelled"

    run cat "${signal_log}"
    assert_success
    assert_equal "${output}" $'CONT\nUSR2'
    refute_output_contains "early-"
}

@test "a failed owner retirement handshake never sets the acknowledgement flag" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_OWNER_PID=111
            RUNTIME_LOCK_OWNER_IDENTITY="boot-id:222"
            RUNTIME_LOCK_SENTINEL_PID=333
            RUNTIME_LOCK_SENTINEL_IDENTITY="boot-id:444"
            RUNTIME_LOCK_SENTINEL_ARMED=1
            RUNTIME_LOCK_SENTINEL_ACK_FILE="$2/ack"
            RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE="$2/marker"
            runtime_resume_lock_helper() {
                return 0
            }
            runtime_process_identity_matches() {
                return 0
            }
            runtime_signal_lock_helper() {
                return 0
            }
            runtime_validate_lock_retirement_ack() {
                return 1
            }
            runtime_terminate_lock_helper() {
                return 0
            }
            wait() {
                return 0
            }
            sleep() {
                return 0
            }
            runtime_retire_lock_owner || exit 1
            printf "ack=%s teardown=%s\\n" \
                "${RUNTIME_LOCK_OWNER_RETIREMENT_ACK}" \
                "${RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE}"
        ' _ "${SANDBOX_REPO}" "${TEST_ROOT}"
    assert_success
    assert_output_contains "ack=0 teardown=1"
}

@test "owner retirement does not continue after a failed owner resume" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_OWNER_PID=111
            RUNTIME_LOCK_OWNER_IDENTITY="boot-id:222"
            RUNTIME_LOCK_SENTINEL_PID=333
            RUNTIME_LOCK_SENTINEL_IDENTITY="boot-id:444"
            RUNTIME_LOCK_SENTINEL_ARMED=1
            signal_called=0
            runtime_process_identity_matches() {
                return 0
            }
            runtime_resume_lock_helper() {
                return 1
            }
            runtime_signal_lock_helper() {
                signal_called=1
                return 0
            }
            runtime_retire_lock_owner
            runtime_local_status="${?}"
            printf "status=%s pending=%s signal=%s\n" \
                "${runtime_local_status}" \
                "${RUNTIME_PENDING_SIGNAL_STATUS}" \
                "${signal_called}"
            exit "${runtime_local_status}"
        ' _ "${SANDBOX_REPO}"
    assert_equal "${status}" "1"
    assert_output_contains "status=1 pending=141 signal=0"
}

@test "owner retirement does not continue after a failed sentinel resume" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_OWNER_PID=111
            RUNTIME_LOCK_OWNER_IDENTITY="boot-id:222"
            RUNTIME_LOCK_SENTINEL_PID=333
            RUNTIME_LOCK_SENTINEL_IDENTITY="boot-id:444"
            RUNTIME_LOCK_SENTINEL_ARMED=1
            signal_called=0
            runtime_process_identity_matches() {
                return 0
            }
            runtime_resume_lock_helper() {
                if [ "$1" = "${RUNTIME_LOCK_OWNER_PID}" ]; then
                    return 0
                fi
                return 1
            }
            runtime_signal_lock_helper() {
                signal_called=1
                return 0
            }
            runtime_retire_lock_owner
            runtime_local_status="${?}"
            printf "status=%s pending=%s signal=%s\n" \
                "${runtime_local_status}" \
                "${RUNTIME_PENDING_SIGNAL_STATUS}" \
                "${signal_called}"
            exit "${runtime_local_status}"
        ' _ "${SANDBOX_REPO}"
    assert_equal "${status}" "1"
    assert_output_contains "status=1 pending=141 signal=0"
}

@test "a failed retirement request is classified by acquisition state" {
    local acquired
    local expected

    for acquired in 0 1; do
        if [ "${acquired}" -eq 0 ]; then
            expected=73
        else
            expected=141
        fi
        run env \
            SCRIPT_PATH="${SANDBOX_REPO}" \
            bash -c '
                source "$1/common/runtime.sh"
                RUNTIME_LOCK_ACQUIRED="$2"
                RUNTIME_LOCK_OWNER_PID=111
                RUNTIME_LOCK_OWNER_IDENTITY="boot-id:222"
                RUNTIME_LOCK_SENTINEL_PID=333
                RUNTIME_LOCK_SENTINEL_IDENTITY="boot-id:444"
                RUNTIME_LOCK_SENTINEL_ARMED=1
                runtime_process_identity_matches() {
                    return 0
                }
                runtime_resume_lock_helper() {
                    return 0
                }
                runtime_signal_lock_helper() {
                    return 1
                }
                runtime_retire_lock_owner
                runtime_local_status="${?}"
                printf "status=%s pending=%s\n" \
                    "${runtime_local_status}" \
                    "${RUNTIME_PENDING_SIGNAL_STATUS}"
                exit "${runtime_local_status}"
            ' _ "${SANDBOX_REPO}" "${acquired}"
        assert_equal "${status}" "1"
        assert_output_contains "status=1 pending=${expected}"
    done
}

@test "intentional support teardown does not create a new security loss" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=1
            RUNTIME_PENDING_SIGNAL_STATUS=143
            RUNTIME_PENDING_SIGNAL_NAME=TERM
            runtime_record_lock_retirement_loss support-loss
            printf "pending=%s loss=%s\\n" \
                "${RUNTIME_PENDING_SIGNAL_STATUS}" \
                "${RUNTIME_PENDING_LOCK_LOSS}"
        ' _ "${SANDBOX_REPO}"
    assert_success
    assert_output_contains "pending=143 loss=0"
}

@test "lock decision publication exposes one complete winner" {
    local cache_dir="${TEST_ROOT}/decision-publication-cache"
    local decision_file="${cache_dir}/decision"
    local cancelled_file="${cache_dir}/cancelled"
    local expected_file="${TEST_ROOT}/expected-decision"
    local expected_cancelled_file="${TEST_ROOT}/expected-cancelled"

    mkdir -p "${cache_dir}"
    chmod 0700 "${cache_dir}"
    printf 'committed' > "${expected_file}"
    printf 'cancelled' > "${expected_cancelled_file}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" claim-decision \
        "${decision_file}" committed
    assert_success
    assert_equal "${output}" "committed"
    run cmp "${expected_file}" "${decision_file}"
    assert_success

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" claim-decision \
        "${decision_file}" cancelled
    assert_equal "${status}" "75"
    assert_equal "${output}" "committed"
    run cmp "${expected_file}" "${decision_file}"
    assert_success

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" claim-decision \
        "${cancelled_file}" cancelled
    assert_success
    assert_equal "${output}" "cancelled"
    run cmp "${expected_cancelled_file}" "${cancelled_file}"
    assert_success
}

@test "lock decision publication preserves the rename winner after a sync failure" {
    local test_script="${TEST_ROOT}/decision-sync-failure.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

decision_path = sys.argv[2]
original_fsync = module.os.fsync
sync_count = 0


def fail_directory_sync(descriptor):
    global sync_count
    sync_count += 1
    if sync_count == 2:
        raise OSError(errno.EIO, "injected directory sync failure")
    return original_fsync(descriptor)


module.os.fsync = fail_directory_sync
try:
    module.claim_decision(decision_path, module.DECISION_COMMITTED)
except module.DecisionPublicationError as error:
    if error.decision != module.DECISION_COMMITTED:
        raise SystemExit("the published decision was lost after the sync failure")
else:
    raise SystemExit("the injected directory sync failure was not reported")

if module.read_decision(decision_path) != module.DECISION_COMMITTED:
    raise SystemExit("the published decision was not retained")
print("published decision retained")
PY

    mkdir -p "${TEST_ROOT}/decision-sync-cache"
    chmod 0700 "${TEST_ROOT}/decision-sync-cache"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        "${TEST_ROOT}/decision-sync-cache/decision"
    assert_success
    assert_output_contains "published decision retained"
}

@test "concurrent lock decisions publish exactly one complete winner" {
    local test_script="${TEST_ROOT}/decision-concurrent.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

decision_path = sys.argv[2]
ready_read, ready_write = os.pipe()
start_read, start_write = os.pipe()
children = []

for value in (module.DECISION_COMMITTED, module.DECISION_CANCELLED):
    result_read, result_write = os.pipe()
    process_id = os.fork()
    if process_id == 0:
        os.close(ready_read)
        os.close(start_write)
        os.close(result_read)
        os.write(ready_write, b"1")
        os.read(start_read, 1)
        try:
            created, decision = module.claim_decision(decision_path, value)
            os.write(result_write, f"{int(created)}|{decision}".encode("ascii"))
        except BaseException as error:
            os.write(result_write, f"error|{error}".encode("utf-8"))
        os._exit(0)
    os.close(result_write)
    children.append((process_id, result_read))

os.close(ready_write)
os.close(start_read)
ready = b""
while len(ready) < 2:
    ready += os.read(ready_read, 2 - len(ready))
os.write(start_write, b"12")
os.close(start_write)

results = []
for process_id, result_read in children:
    payload = b""
    while True:
        chunk = os.read(result_read, 4096)
        if not chunk:
            break
        payload += chunk
    os.close(result_read)
    os.waitpid(process_id, 0)
    created, decision = payload.decode("utf-8").split("|", 1)
    results.append((created == "1", decision))

winners = [result for result in results if result[0]]
if len(winners) != 1:
    raise SystemExit(f"expected one decision winner, got {results}")
published = module.read_decision(decision_path)
if published not in {module.DECISION_COMMITTED, module.DECISION_CANCELLED}:
    raise SystemExit("the published decision is incomplete")
if any(result[1] != published for result in results):
    raise SystemExit(f"contenders disagreed about the winner: {results}")
print("one decision winner")
PY

    mkdir -p "${TEST_ROOT}/decision-concurrent-cache"
    chmod 0700 "${TEST_ROOT}/decision-concurrent-cache"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        "${TEST_ROOT}/decision-concurrent-cache/decision"
    assert_success
    assert_output_contains "one decision winner"
}

@test "an unreadable committed decision remains unknown instead of cancellation" {
    local test_script="${TEST_ROOT}/decision-unknown-state.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

decision_path = sys.argv[2]
created, decision = module.claim_decision(decision_path, module.DECISION_COMMITTED)
if not created or decision != module.DECISION_COMMITTED:
    raise SystemExit("unable to establish the committed decision")

# Model a fresh observer that has not previously seen the authoritative
# winner. The observer must not infer cancellation from a read failure.
module.OBSERVED_DECISION_STATES.clear()
module.DECISION_RESOLUTION_ATTEMPTS = 3
module.DECISION_RESOLUTION_DELAY = 0
module.read_decision_from_parent = lambda _parent, _name: module.DECISION_UNKNOWN
state = module.resolve_cancellation_decision(decision_path)
if state != module.DECISION_UNKNOWN:
    raise SystemExit(f"an unreadable decision became {state}")
if module.cancellation_decision_requested(decision_path):
    raise SystemExit("the compatibility helper classified unknown as cancellation")

module.DECISION_PATH = decision_path
module.request_cancellation(0, None)
if module.CANCELLATION_REQUESTED:
    raise SystemExit("an unknown decision was classified as cancellation")
if not module.CANCELLATION_ABORT_REQUESTED:
    raise SystemExit("an unknown decision did not abort conservatively")
print("unknown decision preserved")
PY

    mkdir -p "${TEST_ROOT}/decision-unknown-cache"
    chmod 0700 "${TEST_ROOT}/decision-unknown-cache"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        "${TEST_ROOT}/decision-unknown-cache/decision"
    assert_success
    assert_output_contains "unknown decision preserved"
}

@test "a transient decision read failure preserves the committed winner" {
    local test_script="${TEST_ROOT}/decision-transient-read.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

decision_path = sys.argv[2]
created, decision = module.claim_decision(decision_path, module.DECISION_COMMITTED)
if not created or decision != module.DECISION_COMMITTED:
    raise SystemExit("unable to establish the committed decision")

original_read = module.read_decision_from_parent
read_count = 0


def transient_read(parent, name):
    global read_count
    read_count += 1
    if read_count <= 2:
        return module.DECISION_UNKNOWN
    return original_read(parent, name)


module.read_decision_from_parent = transient_read
state = module.resolve_cancellation_decision(decision_path)
if state != module.DECISION_COMMITTED:
    raise SystemExit(f"the committed winner became {state}")

module.DECISION_PATH = decision_path
module.request_cancellation(0, None)
if module.CANCELLATION_REQUESTED or module.CANCELLATION_ABORT_REQUESTED:
    raise SystemExit("a committed decision did not remain harmless")
print("transient read preserved commitment")
PY

    mkdir -p "${TEST_ROOT}/decision-transient-cache"
    chmod 0700 "${TEST_ROOT}/decision-transient-cache"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        "${TEST_ROOT}/decision-transient-cache/decision"
    assert_success
    assert_output_contains "transient read preserved commitment"
}

@test "background job status is bound to the shell job table" {
    run bash -c '
        source "$1/common/runtime.sh"
        bash -c "exit 75" &
        child_pid="${!}"
        runtime_wait_for_background_job "${child_pid}"
        child_status="${?}"
        printf "child_status=%s\n" "${child_status}"
    ' _ "${SANDBOX_REPO}"
    assert_success
    assert_output_contains "child_status=75"
}

@test "a completed background job is not mistaken for a reused live PID" {
    run timeout 2 bash -c '
        source "$1/common/runtime.sh"
        kill() {
            return 0
        }
        bash -c "exit 75" &
        child_pid="${!}"
        runtime_wait_for_background_job "${child_pid}"
        child_status="${?}"
        printf "child_status=%s\n" "${child_status}"
    ' _ "${SANDBOX_REPO}"
    assert_success
    assert_output_contains "child_status=75"
}

@test "an interrupted wait preserves the completed job status" {
    run timeout 3 bash -c '
        source "$1/common/runtime.sh"
        bash -c "sleep 0.1; exit 75" &
        child_pid="${!}"
        trap "sleep 0.2" USR2
        (sleep 0.02; kill -USR2 $$) &
        notifier_pid="${!}"
        runtime_wait_for_background_job "${child_pid}"
        child_status="${?}"
        wait "${notifier_pid}" 2>/dev/null || true
        printf "child_status=%s\n" "${child_status}"
    ' _ "${SANDBOX_REPO}"
    assert_success
    assert_output_contains "child_status=75"
}

@test "a stopped background job is resumed before its status is collected" {
    run timeout 3 bash -c '
        source "$1/common/runtime.sh"
        bash -c "sleep 0.2; exit 75" &
        child_pid="${!}"
        (sleep 0.05; kill -STOP "${child_pid}") &
        notifier_pid="${!}"
        runtime_wait_for_background_job "${child_pid}"
        child_status="${?}"
        wait "${notifier_pid}" 2>/dev/null || true
        printf "child_status=%s\n" "${child_status}"
    ' _ "${SANDBOX_REPO}"
    assert_success
    assert_output_contains "child_status=75"
}

@test "an unidentified support startup failure never signals a numeric PID" {
    local mock_bin="${TEST_ROOT}/unidentified-support-bin"
    local kill_log="${TEST_ROOT}/unidentified-support.kills"
    local child_pid_file="${TEST_ROOT}/unidentified-support.pid"

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${MOCK_SUPPORT_CHILD_PID}"
exec sleep 30
EOF
    chmod +x "${mock_bin}/python3"

    run env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        MOCK_SUPPORT_KILL_LOG="${kill_log}" \
        MOCK_SUPPORT_CHILD_PID="${child_pid_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_INSTALLER_PID="$$"
            RUNTIME_LOCK_INSTALLER_IDENTITY="boot-id:123"
            RUNTIME_RUN_ID="test-run"
            RUNTIME_LOCK_OWNER_STATUS_FILE="$2/owner.status"
            RUNTIME_LOCK_SENTINEL_STATUS_FILE="$2/sentinel.status"
            RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE="$2/owner-retiring"
            RUNTIME_LOCK_FILE_FD="3"
            RUNTIME_LOCK_SCOPE_FD="4"
            RUNTIME_LOCK_FILE_IDENTITY="1:2"
            RUNTIME_LOCK_SCOPE_IDENTITY="1:3"

            runtime_capture_process_identity() {
                return 1
            }

            kill() {
                printf "%s\n" "$*" >> "${MOCK_SUPPORT_KILL_LOG}"
                builtin kill "$@"
            }

            runtime_start_lock_owner
            startup_status=$?
            printf "startup-status=%s\n" "${startup_status}"
        ' _ "${SANDBOX_REPO}" "${TEST_ROOT}"
    assert_success
    assert_output_contains "startup-status=1"

    run cat "${kill_log}"
    assert_success
    assert_output_contains "%1"
    refute_output_contains "-KILL 12345"
    run grep -E -- '^-KILL [0-9]+$' "${kill_log}"
    assert_failure

    run cat "${child_pid_file}"
    assert_success
    local child_pid="${output}"
    if ! [[ "${child_pid}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    run test -e "/proc/${child_pid}/stat"
    assert_failure
}

@test "terminating a reaped worker never signals a reused PID" {
    local test_script="${TEST_ROOT}/worker-reuse.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
module.observe_process_identity = lambda _process_id, _identity: module.ProcessObservation.REPLACED
module.reap_child = lambda _process_id: True
signals = []
module.signal_process_by_identity = lambda *_arguments: signals.append(_arguments) or True
module.terminate_child(4242, identity)
if signals:
    raise SystemExit("a replacement process was signaled")
print("reused worker PID was not signaled")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "reused worker PID was not signaled"
}

@test "terminating a helper never signals a reused PID" {
    local test_script="${TEST_ROOT}/helper-reuse.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
module.observe_process_identity = lambda _process_id, _identity: module.ProcessObservation.REPLACED
signals = []
module.signal_process_by_identity = lambda *_arguments: signals.append(_arguments) or True
if not module.terminate_process_by_identity(4242, identity):
    raise SystemExit("a replacement process was not treated as terminated")
if signals:
    raise SystemExit("a replacement process was signaled")
print("reused helper PID was not signaled")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "reused helper PID was not signaled"
}

@test "identity-bound signaling fails closed when pidfd is unavailable" {
    local test_script="${TEST_ROOT}/helper-no-pidfd.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import signal
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.capture_process_identity(os.getpid())
if identity is None:
    raise SystemExit("unable to capture the test process identity")

module.open_verified_pidfd = lambda _process_id, _identity: -1


def forbidden_raw_kill(_process_id, _signal_number):
    raise AssertionError("raw PID signaling was used without a pidfd")


module.os.kill = forbidden_raw_kill
try:
    module.signal_process_by_identity(
        os.getpid(),
        identity,
        signal.SIGCONT,
    )
except (module.MonitoringUnavailable, OSError):
    pass
else:
    raise SystemExit("identity-bound signaling did not fail closed")
print("identity-bound signaling failed closed")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "identity-bound signaling failed closed"
}

@test "group teardown terminates a lock owner after its leader exits" {
    local test_script="${TEST_ROOT}/group-owner-without-leader.py"
    local lock_file="${TEST_ROOT}/group-owner.lock"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import signal
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

lock_path = sys.argv[2]
ready_read, ready_write = os.pipe()
leader_process_id = os.fork()
if leader_process_id == 0:
    os.close(ready_read)
    os.setsid()
    descriptor = os.open(lock_path, os.O_RDWR)
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    leader_identity = module.capture_process_identity(os.getpid())
    if leader_identity is None:
        os._exit(1)
    descendant_process_id = os.fork()
    if descendant_process_id == 0:
        os.write(
            ready_write,
            (
                f"{os.getpgrp()} {os.getpid()} "
                f"{module.encode_process_identity(leader_identity)}\n"
            ).encode("ascii"),
        )
        os.close(ready_write)
        while True:
            time.sleep(1)
    os._exit(0)

os.close(ready_write)
ready = os.read(ready_read, 4096).decode("ascii").strip()
os.close(ready_read)
os.waitpid(leader_process_id, 0)
process_group_id_text, descendant_process_id_text, leader_identity_text = ready.split()
process_group_id = int(process_group_id_text)
descendant_process_id = int(descendant_process_id_text)
leader_identity = module.parse_process_identity(leader_identity_text)
if leader_identity is None:
    raise SystemExit("unable to parse the leader identity")

metadata = os.stat(lock_path)
try:
    terminated = module.terminate_process_group(
        process_group_id,
        leader_identity,
        metadata.st_dev,
        metadata.st_ino,
    )
finally:
    try:
        os.kill(descendant_process_id, signal.SIGKILL)
    except ProcessLookupError:
        pass

if not terminated:
    raise SystemExit("the leaderless helper group was not terminated")
for _ in range(100):
    try:
        with open(f"/proc/{descendant_process_id}/stat", "r", encoding="ascii") as stat_file:
            status = stat_file.read()
            command_end = status.rfind(")")
            process_state = status[command_end + 2 :].split()[0]
    except (FileNotFoundError, ProcessLookupError):
        break
    if process_state in {"Z", "X", "x"}:
        break
    time.sleep(0.01)
else:
    raise SystemExit("the descendant lock owner remained alive")
print("leaderless helper group terminated")
PY

    : > "${lock_file}"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py" "${lock_file}"
    assert_success
    assert_output_contains "leaderless helper group terminated"
}

@test "a recycled helper process group is never terminated" {
    local test_script="${TEST_ROOT}/reused-group.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
module.observe_process_identity = lambda _process_id, _identity: module.ProcessObservation.REPLACED
signals = []
module.signal_process_by_identity = lambda *_arguments: signals.append(_arguments) or True
module.read_process_group_members = lambda _process_group_id: ({}, False)
if module.terminate_process_group(4242, identity):
    raise SystemExit("a recycled process group was treated as terminated")
if signals:
    raise SystemExit("a recycled process group was signaled")
print("recycled helper process group was not signaled")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "recycled helper process group was not signaled"
}

@test "lock helpers share a dedicated process group" {
    local cache_dir="${TEST_ROOT}/helper-group-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/helper-group"
    local output_file="${TEST_ROOT}/helper-group.out"
    local status_file
    local installer_pid
    local installer_status=0
    local installer_pgid
    local guardian_pgid
    local owner_pgid
    local sentinel_pgid
    local helper_pgid
    local helper_pid
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            printf "%s\n" "${RUNTIME_LOCK_PID}" > "$2/guardian.pid"
            printf "%s\n" "${RUNTIME_LOCK_HOLDER_PID}" > "$2/supervisor.pid"
            printf "%s\n" "${RUNTIME_LOCK_WORKER_PID}" > "$2/worker.pid"
            printf "%s\n" "${RUNTIME_LOCK_WATCHDOG_PID}" > "$2/watchdog.pid"
            printf "%s\n" "${RUNTIME_LOCK_OWNER_PID}" > "$2/owner.pid"
            printf "%s\n" "${RUNTIME_LOCK_SENTINEL_PID}" > "$2/sentinel.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    installer_pgid=$(ps -o pgid= -p "${installer_pid}" | tr -d '[:space:]')
    guardian_pgid=$(ps -o pgid= -p "$(cat "${pid_directory}/guardian.pid")" |
        tr -d '[:space:]')
    if [ "${guardian_pgid}" = "${installer_pgid}" ]; then
        return 1
    fi
    for helper_pid in \
        "$(cat "${pid_directory}/supervisor.pid")" \
        "$(cat "${pid_directory}/worker.pid")" \
        "$(cat "${pid_directory}/watchdog.pid")"; do
        helper_pgid=$(ps -o pgid= -p "${helper_pid}" | tr -d '[:space:]')
        assert_equal "${helper_pgid}" "${guardian_pgid}"
    done
    owner_pgid=$(ps -o pgid= -p "$(cat "${pid_directory}/owner.pid")" |
        tr -d '[:space:]')
    sentinel_pgid=$(ps -o pgid= -p "$(cat "${pid_directory}/sentinel.pid")" |
        tr -d '[:space:]')
    if [ "${owner_pgid}" = "${guardian_pgid}" ] ||
        [ "${sentinel_pgid}" = "${guardian_pgid}" ] ||
        [ "${owner_pgid}" = "${sentinel_pgid}" ] ||
        [ "${owner_pgid}" = "${installer_pgid}" ] ||
        [ "${sentinel_pgid}" = "${installer_pgid}" ]; then
        return 1
    fi

    kill -TERM "${installer_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "143"
}

@test "successful cleanup removes all lock support artifacts and releases both domains" {
    local cache_dir="${TEST_ROOT}/support-cleanup-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local output_file="${TEST_ROOT}/support-cleanup.out"
    local attempt
    local support_file

    mkdir -p "${cache_dir}"
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            exit 0
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1
    assert_success

    for ((attempt = 0; attempt < 100; attempt++)); do
        support_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            \( -name '.postinstall-lock-*.acquired' -o \
            -name '.postinstall-lock-*.owner' -o \
            -name '.postinstall-lock-*.sentinel' -o \
            -name '.postinstall-lock-*.sentinel-teardown' -o \
            -name '.postinstall-lock-*.owner-retiring' \) \
            -print -quit 2>/dev/null || true)
        if [ -z "${support_file}" ]; then
            break
        fi
        sleep 0.05
    done
    run find "${cache_dir}" -maxdepth 1 -type f \
        \( -name '.postinstall-lock-*.acquired' -o \
        -name '.postinstall-lock-*.owner' -o \
        -name '.postinstall-lock-*.sentinel' -o \
        -name '.postinstall-lock-*.sentinel-teardown' -o \
        -name '.postinstall-lock-*.owner-retiring' \) \
        -print
    assert_success
    assert_equal "${output}" ""

    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "sentinel readiness failure aborts acquisition and releases both domains" {
    local cache_dir="${TEST_ROOT}/sentinel-readiness-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/sentinel-readiness-bin"
    local marker_file="${TEST_ROOT}/sentinel-readiness.marker"
    local attempt
    local support_file

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "lock-sentinel" ]; then
    : > "${MOCK_SENTINEL_READINESS_MARKER}"
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    run env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_SENTINEL_READINESS_MARKER="${marker_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}"
    assert_equal "${status}" "73"
    assert_output_contains "unable to start the installation lock support processes"
    assert_output_contains "acquisition-status=73"
    run test -e "${marker_file}"
    assert_success

    for ((attempt = 0; attempt < 100; attempt++)); do
        support_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            \( -name '.postinstall-lock-*.acquired' -o \
            -name '.postinstall-lock-*.owner' -o \
            -name '.postinstall-lock-*.sentinel' -o \
            -name '.postinstall-lock-*.sentinel-teardown' -o \
            -name '.postinstall-lock-*.owner-retiring' \) \
            -print -quit 2>/dev/null || true)
        if [ -z "${support_file}" ]; then
            break
        fi
        sleep 0.05
    done
    run find "${cache_dir}" -maxdepth 1 -type f \
        \( -name '.postinstall-lock-*.acquired' -o \
        -name '.postinstall-lock-*.owner' -o \
        -name '.postinstall-lock-*.sentinel' -o \
        -name '.postinstall-lock-*.sentinel-teardown' -o \
        -name '.postinstall-lock-*.owner-retiring' \) \
        -print
    assert_success
    assert_equal "${output}" ""

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "cleanup retires the owner through the sentinel after helper teardown" {
    local cache_dir="${TEST_ROOT}/owner-retirement-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local marker_file="${TEST_ROOT}/owner-retirement.marker"
    local owner_pid_file="${TEST_ROOT}/owner-retirement.owner-pid"
    local owner_pid
    local sentinel_pid
    local attempt

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_test_owner_pid="${RUNTIME_LOCK_OWNER_PID}"
            runtime_test_marker_path="$3"
            printf "%s\n" "${runtime_test_owner_pid}" > "$2"

            runtime_signal_lock_helper() {
                local runtime_test_owner_alive=0
                local runtime_test_sentinel_alive=0
                local runtime_test_status_removed=0
                local runtime_test_helper_group_empty=0

                if [ -e "/proc/${runtime_test_owner_pid}/stat" ]; then
                    runtime_test_owner_alive=1
                fi
                if [ -e "/proc/${1}/stat" ]; then
                    runtime_test_sentinel_alive=1
                fi
                if [ ! -e "${RUNTIME_LOCK_STATUS_FILE}" ]; then
                    runtime_test_status_removed=1
                fi
                if python3 "${SCRIPT_PATH}/common/lock-holder.py" \
                    verify-group-empty "${RUNTIME_LOCK_PGID}" >/dev/null 2>&1; then
                    runtime_test_helper_group_empty=1
                fi
                printf "target=%s signal=%s owner_alive=%s sentinel_alive=%s status_removed=%s helper_group_empty=%s\n" \
                    "$1" "$3" "${runtime_test_owner_alive}" \
                    "${runtime_test_sentinel_alive}" \
                    "${runtime_test_status_removed}" \
                    "${runtime_test_helper_group_empty}" >> "${runtime_test_marker_path}"
                python3 "${SCRIPT_PATH}/common/lock-holder.py" \
                    signal-process "$@" >/dev/null 2>&1
            }
            exit 0
        ' _ "${SANDBOX_REPO}" "${owner_pid_file}" "${marker_file}"
    assert_success

    run cat "${owner_pid_file}"
    assert_success
    owner_pid="${output}"
    run cat "${marker_file}"
    assert_success
    assert_output_contains "signal=12"
    assert_output_contains "owner_alive=1"
    assert_output_contains "sentinel_alive=1"
    assert_output_contains "status_removed=1"
    assert_output_contains "helper_group_empty=1"
    sentinel_pid=$(printf '%s\n' "${output}" |
        sed -n 's/^target=\([0-9][0-9]*\) signal=.*/\1/p')

    run test -e "/proc/${owner_pid}/stat"
    assert_failure
    run test -e "/proc/${sentinel_pid}/stat"
    assert_failure

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "owner retirement acknowledgements are strictly bound to the armed sentinel" {
    local transaction_directory="${TEST_ROOT}/owner-retirement-transaction"
    local ack_file="${transaction_directory}/owner-retirement.ack"
    local marker_file="${transaction_directory}/owner-retiring"

    mkdir -p "${transaction_directory}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_RUN_ID="run-123"
            RUNTIME_LOCK_OWNER_PID="111"
            RUNTIME_LOCK_OWNER_IDENTITY="boot:222"
            RUNTIME_LOCK_SENTINEL_PID="333"
            RUNTIME_LOCK_SENTINEL_IDENTITY="boot:444"
            RUNTIME_LOCK_INSTALLER_PID="555"
            RUNTIME_LOCK_INSTALLER_IDENTITY="boot:666"
            ack_file="$2"
            marker_file="$3"
            request_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

            write_marker() {
                printf "%s\n" \
                    "schema=1" \
                    "run_id=${RUNTIME_RUN_ID}" \
                    "state=owner-retiring" \
                    "request_id=${request_id}" \
                    "owner_pid=${RUNTIME_LOCK_OWNER_PID}" \
                    "owner_identity=${RUNTIME_LOCK_OWNER_IDENTITY}" \
                    "sentinel_pid=${RUNTIME_LOCK_SENTINEL_PID}" \
                    "sentinel_identity=${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
                    "installer_pid=${RUNTIME_LOCK_INSTALLER_PID}" \
                    "installer_identity=${RUNTIME_LOCK_INSTALLER_IDENTITY}" > "${marker_file}"
            }

            write_acknowledgement() {
                printf "%s\n" \
                    "schema=1" \
                    "run_id=${RUNTIME_RUN_ID}" \
                    "state=owner-retired" \
                    "request_id=${request_id}" \
                    "owner_pid=${RUNTIME_LOCK_OWNER_PID}" \
                    "owner_identity=${RUNTIME_LOCK_OWNER_IDENTITY}" \
                    "sentinel_pid=${RUNTIME_LOCK_SENTINEL_PID}" \
                    "sentinel_identity=${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
                    "installer_pid=${RUNTIME_LOCK_INSTALLER_PID}" \
                    "installer_identity=${RUNTIME_LOCK_INSTALLER_IDENTITY}" > "${ack_file}"
            }

            write_marker
            write_acknowledgement
            runtime_validate_lock_retirement_ack \
                "${ack_file}" "${marker_file}" || exit 1

            request_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            write_acknowledgement
            if runtime_validate_lock_retirement_ack \
                "${ack_file}" "${marker_file}"; then
                exit 2
            fi

            request_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            printf "%s\n" \
                "schema=1" \
                "run_id=${RUNTIME_RUN_ID}" \
                "state=owner-retired" \
                "request_id=${request_id}" \
                "owner_pid=${RUNTIME_LOCK_OWNER_PID}" \
                "owner_identity=${RUNTIME_LOCK_OWNER_IDENTITY}" \
                "sentinel_pid=${RUNTIME_LOCK_SENTINEL_PID}" \
                "sentinel_identity=${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
                "installer_pid=${RUNTIME_LOCK_INSTALLER_PID}" \
                "installer_identity=${RUNTIME_LOCK_INSTALLER_IDENTITY}" \
                "extra=content" > "${ack_file}"
            if runtime_validate_lock_retirement_ack \
                "${ack_file}" "${marker_file}"; then
                exit 3
            fi

            write_acknowledgement
            printf "%s\n\n" "$(cat "${ack_file}")" > "${ack_file}"
            if runtime_validate_lock_retirement_ack \
                "${ack_file}" "${marker_file}"; then
                exit 4
            fi

            write_acknowledgement
            printf "%s" "$(cat "${ack_file}")" > "${ack_file}"
            if runtime_validate_lock_retirement_ack \
                "${ack_file}" "${marker_file}"; then
                exit 5
            fi

            printf "strict acknowledgement accepted\n"
        ' _ "${SANDBOX_REPO}" "${ack_file}" "${marker_file}"
    assert_success
    assert_output_contains "strict acknowledgement accepted"
}

@test "a stopped sentinel is resumed during cleanup and releases both domains" {
    local cache_dir="${TEST_ROOT}/stopped-sentinel-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/stopped-sentinel"
    local output_file="${TEST_ROOT}/stopped-sentinel.out"
    local owner_status_file
    local sentinel_status_file
    local owner_pid
    local sentinel_pid
    local owner_state
    local sentinel_state
    local installer_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        owner_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.owner' -print -quit 2>/dev/null || true)
        sentinel_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.sentinel' -print -quit 2>/dev/null || true)
        if [ -n "${owner_status_file}" ] &&
            [ -n "${sentinel_status_file}" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${owner_status_file}" ] ||
        [ -z "${sentinel_status_file}" ] ||
        [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    owner_pid=$(sed -n 's/^process_pid=//p' "${owner_status_file}")
    sentinel_pid=$(sed -n 's/^process_pid=//p' "${sentinel_status_file}")
    if ! [[ "${owner_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${sentinel_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    # Stop both mutually monitoring processes together. Each process resumes a
    # stopped peer, so separate stop operations would race with the peer's
    # recovery. Cleanup must still resume both identities before it can
    # complete the support retirement protocol.
    for ((attempt = 0; attempt < 20; attempt++)); do
        kill -STOP "${owner_pid}" "${sentinel_pid}" 2>/dev/null || true
        owner_state=$(ps -o stat= -p "${owner_pid}" 2>/dev/null || true)
        sentinel_state=$(ps -o stat= -p "${sentinel_pid}" 2>/dev/null || true)
        if [[ "${owner_state}" == T* ]] &&
            [[ "${sentinel_state}" == T* ]]; then
            break
        fi
    done
    if [[ "${owner_state}" != T* ]] ||
        [[ "${sentinel_state}" != T* ]]; then
        kill -KILL "${installer_pid}" "${owner_pid}" "${sentinel_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -TERM "${installer_pid}"
    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""

    assert_equal "${installer_status}" "143"
    run test -e "/proc/${owner_pid}/stat"
    assert_failure
    run test -e "/proc/${sentinel_pid}/stat"
    assert_failure

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "sentinel death reports support loss and releases the final owner descriptor" {
    local cache_dir="${TEST_ROOT}/sentinel-death-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/sentinel-death"
    local output_file="${TEST_ROOT}/sentinel-death.out"
    local owner_status_file
    local sentinel_status_file
    local owner_pid
    local sentinel_pid
    local installer_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        owner_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.owner' -print -quit 2>/dev/null || true)
        sentinel_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.sentinel' -print -quit 2>/dev/null || true)
        if [ -n "${owner_status_file}" ] &&
            [ -n "${sentinel_status_file}" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${owner_status_file}" ] ||
        [ -z "${sentinel_status_file}" ] ||
        [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    owner_pid=$(sed -n 's/^process_pid=//p' "${owner_status_file}")
    sentinel_pid=$(sed -n 's/^process_pid=//p' "${sentinel_status_file}")
    if ! [[ "${owner_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${sentinel_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -KILL "${sentinel_pid}"
    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""

    assert_equal "${installer_status}" "141"
    run test -e "/proc/${owner_pid}/stat"
    assert_failure
    run test -e "/proc/${sentinel_pid}/stat"
    assert_failure

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success

    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock support failed"
}

@test "the retirement fallback preserves an exact ordinary shutdown status" {
    local cache_dir="${TEST_ROOT}/retirement-fallback-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/retirement-fallback"
    local output_file="${TEST_ROOT}/retirement-fallback.out"
    local owner_status_file
    local sentinel_status_file
    local owner_pid
    local sentinel_pid
    local installer_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_signal_lock_helper() {
                return 0
            }
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        owner_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.owner' -print -quit 2>/dev/null || true)
        sentinel_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.sentinel' -print -quit 2>/dev/null || true)
        if [ -n "${owner_status_file}" ] &&
            [ -n "${sentinel_status_file}" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${owner_status_file}" ] ||
        [ -z "${sentinel_status_file}" ] ||
        [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    owner_pid=$(sed -n 's/^process_pid=//p' "${owner_status_file}")
    sentinel_pid=$(sed -n 's/^process_pid=//p' "${sentinel_status_file}")
    if ! [[ "${owner_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${sentinel_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -TERM "${installer_pid}"
    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""

    assert_equal "${installer_status}" "143"
    run test -e "/proc/${owner_pid}/stat"
    assert_failure
    run test -e "/proc/${sentinel_pid}/stat"
    assert_failure

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "the dedicated support processes retain lock ownership when every helper dies" {
    local cache_dir="${TEST_ROOT}/all-helper-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/all-helper-loss"
    local output_file="${TEST_ROOT}/all-helper-loss.out"
    local status_file
    local installer_pid
    local installer_status=0
    local installer_state
    local helper_pid
    local helper_state
    local all_stopped
    local attempt
    local -a helper_pids=()

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    helper_pids=(
        "$(sed -n '1p' "${status_file}")"
        "$(sed -n '2p' "${status_file}")"
        "$(sed -n '6p' "${status_file}")"
        "$(sed -n '9p' "${status_file}")"
    )
    kill -STOP "${helper_pids[@]}" 2>/dev/null || true
    for ((attempt = 0; attempt < 500; attempt++)); do
        all_stopped=1
        for helper_pid in "${helper_pids[@]}"; do
            helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
            if [[ "${helper_state}" != T* ]] &&
                [[ "${helper_state}" != t* ]]; then
                all_stopped=0
                break
            fi
        done
        if [ "${all_stopped}" -eq 1 ]; then
            break
        fi
        sleep 0.01
    done
    if [ "${all_stopped}" -ne 1 ]; then
        kill -KILL "${helper_pids[@]}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -KILL "${helper_pids[@]}" 2>/dev/null || true
    sleep 0.1
    run flock --exclusive --nonblock "${lock_file}" true
    assert_failure
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_failure

    # Deliver the definitive helper-loss notification only after every
    # helper has died. This removes the race with an ordinary shutdown signal:
    # a helper failure observed before teardown must retain status 141.
    kill -USR1 "${installer_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "141"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "owner loss keeps the scope locked and aborts the installer with status 141" {
    local loss_mode
    local case_root
    local cache_dir
    local lock_file
    local pid_directory
    local output_file
    local status_file
    local owner_status_file
    local sentinel_status_file
    local owner_pid
    local sentinel_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local attempt
    local -a helper_pids=()

    for loss_mode in simultaneous sequential; do
        case_root="${TEST_ROOT}/owner-loss-${loss_mode}"
        cache_dir="${case_root}/cache"
        lock_file="${cache_dir}/postinstall.lock"
        pid_directory="${case_root}/pids"
        output_file="${case_root}/output"
        installer_pid=""

        mkdir -p "${cache_dir}" "${pid_directory}"
        env \
            SCRIPT_PATH="${SANDBOX_REPO}" \
            HOME="${case_root}/home" \
            POSTINSTALL_CACHE_DIR="${cache_dir}" \
            POSTINSTALL_LOCK_FILE="${lock_file}" \
            POSTINSTALL_LOG_STDOUT="1" \
            bash -c '
                source "$1/common/runtime.sh"
                runtime_initialize || exit $?
                runtime_acquire_install_lock || exit $?
                printf "%s\n" "${RUNTIME_LOCK_OWNER_PID}" > "$2/owner.pid"
                printf "%s\n" "${RUNTIME_LOCK_SENTINEL_PID}" > "$2/sentinel.pid"
                : > "$2/ready"
                while :; do sleep 0.2; done
            ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
        installer_pid="${!}"

        for ((attempt = 0; attempt < 200; attempt++)); do
            status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
                -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
            owner_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
                -name '.postinstall-lock-*.owner' -print -quit 2>/dev/null || true)
            sentinel_status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
                -name '.postinstall-lock-*.sentinel' -print -quit 2>/dev/null || true)
            if [ -n "${status_file}" ] &&
                [ -n "${owner_status_file}" ] &&
                [ -n "${sentinel_status_file}" ] &&
                [ -e "${pid_directory}/ready" ]; then
                break
            fi
            sleep 0.05
        done
        if [ -z "${status_file}" ] ||
            [ -z "${owner_status_file}" ] ||
            [ -z "${sentinel_status_file}" ] ||
            [ ! -e "${pid_directory}/ready" ]; then
            kill -KILL "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
            return 1
        fi

        owner_pid=$(sed -n 's/^process_pid=//p' "${owner_status_file}")
        sentinel_pid=$(sed -n 's/^process_pid=//p' "${sentinel_status_file}")
        helper_pids=(
            "$(sed -n '1p' "${status_file}")"
            "$(sed -n '2p' "${status_file}")"
            "$(sed -n '6p' "${status_file}")"
            "$(sed -n '9p' "${status_file}")"
        )
        if ! [[ "${owner_pid}" =~ ^[0-9]+$ ]] ||
            ! [[ "${sentinel_pid}" =~ ^[0-9]+$ ]]; then
            kill -TERM "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
            return 1
        fi

        if [ "${loss_mode}" = "simultaneous" ]; then
            kill -KILL "${helper_pids[@]}" "${owner_pid}" 2>/dev/null || true
        else
            kill -KILL "${helper_pids[@]}" 2>/dev/null || true
            sleep 0.1
            kill -KILL "${owner_pid}" 2>/dev/null || true
        fi

        # The sentinel is outside the helper group and retains both exact
        # descriptors, so no second installer can enter the scope while the
        # first installer is still winding down.
        run flock --exclusive --nonblock "${lock_file}" true
        assert_failure
        run flock --exclusive --nonblock "${cache_dir}" true
        assert_failure

        for ((attempt = 0; attempt < 200; attempt++)); do
            installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
            if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
                break
            fi
            sleep 0.05
        done
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
            kill -KILL "${installer_pid}" "${sentinel_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
            return 1
        fi
        wait "${installer_pid}" || installer_status="${?}"
        installer_pid=""
        assert_equal "${installer_status}" "141"

        run cat "${output_file}"
        assert_success
        assert_output_contains "installation lock owner failed"

        for ((attempt = 0; attempt < 100; attempt++)); do
            if flock --exclusive --nonblock "${lock_file}" true; then
                break
            fi
            sleep 0.05
        done
        run flock --exclusive --nonblock "${lock_file}" true
        assert_success
        run flock --exclusive --nonblock "${cache_dir}" true
        assert_success
    done
}

@test "the parent scope lock rejects a second installer after public lock replacement" {
    local cache_dir="${TEST_ROOT}/scope-replacement-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local original_lock="${cache_dir}/postinstall.lock.original"
    local pid_directory="${TEST_ROOT}/scope-replacement"
    local output_file="${TEST_ROOT}/scope-replacement.out"
    local installer_pid
    local installer_status=0
    local original_inode
    local replacement_inode
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    original_inode=$(stat -c '%i' "${lock_file}")
    if ! mv "${lock_file}" "${original_lock}"; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    if ! (umask 077 && : > "${lock_file}"); then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    chmod 600 "${lock_file}"
    replacement_inode=$(stat -c '%i' "${lock_file}")
    if [ "${original_inode}" = "${replacement_inode}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock
        ' _ "${SANDBOX_REPO}"
    assert_equal "${status}" "75"
    assert_output_contains "lock scope"

    # The replacement public file has a different inode and is not itself
    # flocked. The parent directory scope lock is what prevents a second
    # installer from entering the same lock domain.
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${original_lock}" true
    assert_failure

    kill -TERM "${installer_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "143"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${original_lock}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${original_lock}" true
    assert_success
}

@test "acquisition failure without initialization terminates a stopped helper group" {
    local cache_dir="${TEST_ROOT}/standalone-acquisition-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/standalone-acquisition-bin"
    local output_file="${TEST_ROOT}/standalone-acquisition.out"
    local holder_pid_file="${TEST_ROOT}/standalone-acquisition.holder.pid"
    local status_file
    local supervisor_pid
    local worker_pid
    local watchdog_pid
    local guardian_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local helper_state
    local attempt
    local -a status_lines=()

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "hold" ]; then
    printf '%s\n' "$$" > "${MOCK_HOLDER_PID_FILE}"
    kill -STOP "${PPID}" 2>/dev/null || true
    for attempt in {1..200}; do
        state=$(ps -o stat= -p "${PPID}" 2>/dev/null || true)
        if [[ "${state}" == T* ]] || [[ "${state}" == t* ]]; then
            break
        fi
        sleep 0.01
    done
    exec /usr/bin/python3 "$@"
fi
if [ "${2:-}" = "validate-status" ]; then
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_HOLDER_PID_FILE="${holder_pid_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        if [ -s "${holder_pid_file}" ]; then
            kill -KILL "$(cat "${holder_pid_file}")" 2>/dev/null || true
        fi
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    worker_pid="${status_lines[1]}"
    guardian_pid="${status_lines[5]}"
    watchdog_pid="${status_lines[8]}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "73"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock acquisition was cancelled"

    for helper_pid in \
        "${guardian_pid}" \
        "${supervisor_pid}" \
        "${worker_pid}" \
        "${watchdog_pid}"; do
        helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
        if [ -n "${helper_state}" ] && [[ "${helper_state}" != Z* ]]; then
            return 1
        fi
    done

    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "failed helper teardown preserves validated lock identities" {
    local mock_bin="${TEST_ROOT}/failed-teardown-bin"

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
resume-process | terminate-group | terminate-process)
    exit 1
    ;;
esac
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    run env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_PID=4000001
            RUNTIME_LOCK_GUARDIAN_IDENTITY="boot-id:101"
            RUNTIME_LOCK_PGID=4000001
            RUNTIME_LOCK_HOLDER_PID=4000002
            RUNTIME_LOCK_HOLDER_IDENTITY="boot-id:102"
            RUNTIME_LOCK_WORKER_PID=4000003
            RUNTIME_LOCK_WORKER_IDENTITY="boot-id:103"
            RUNTIME_LOCK_WATCHDOG_PID=4000004
            RUNTIME_LOCK_WATCHDOG_IDENTITY="boot-id:104"
            runtime_release_install_lock
            release_status=$?
            printf "release-status=%s\n" "${release_status}"
            printf "guardian=%s:%s\n" "${RUNTIME_LOCK_PID}" "${RUNTIME_LOCK_GUARDIAN_IDENTITY}"
            printf "holder=%s:%s\n" "${RUNTIME_LOCK_HOLDER_PID}" "${RUNTIME_LOCK_HOLDER_IDENTITY}"
            printf "worker=%s:%s\n" "${RUNTIME_LOCK_WORKER_PID}" "${RUNTIME_LOCK_WORKER_IDENTITY}"
            printf "watchdog=%s:%s\n" "${RUNTIME_LOCK_WATCHDOG_PID}" "${RUNTIME_LOCK_WATCHDOG_IDENTITY}"
            printf "pgid=%s\n" "${RUNTIME_LOCK_PGID}"
            exit "${release_status}"
        ' _ "${SANDBOX_REPO}"
    assert_failure
    assert_equal "${status}" "1"
    assert_output_contains "release-status=1"
    assert_output_contains "guardian=4000001:boot-id:101"
    assert_output_contains "holder=4000002:boot-id:102"
    assert_output_contains "worker=4000003:boot-id:103"
    assert_output_contains "watchdog=4000004:boot-id:104"
    assert_output_contains "pgid=4000001"
}

@test "a transient helper teardown failure is retried" {
    local mock_bin="${TEST_ROOT}/retry-teardown-bin"
    local counter_file="${TEST_ROOT}/retry-teardown.count"
    local status_file="${TEST_ROOT}/retry-teardown.status"
    local decision_file="${TEST_ROOT}/retry-teardown.decision"

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
    terminate-group | verify-group-empty)
        count=0
        if [ -f "${MOCK_RETRY_COUNTER}" ]; then
            read -r count < "${MOCK_RETRY_COUNTER}" || count=0
        fi
        count=$((count + 1))
        printf '%s\n' "${count}" > "${MOCK_RETRY_COUNTER}"
        if [ "${count}" -eq 1 ]; then
            exit 1
        fi
        ;;
esac
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    : > "${status_file}"
    printf 'committed' > "${decision_file}"
    run env \
        PATH="${mock_bin}:${PATH}" \
        MOCK_RETRY_COUNTER="${counter_file}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_PID=4000001
            RUNTIME_LOCK_GUARDIAN_IDENTITY="boot-id:101"
            RUNTIME_LOCK_PGID=4000001
            RUNTIME_LOCK_HOLDER_PID=4000002
            RUNTIME_LOCK_HOLDER_IDENTITY="boot-id:102"
            RUNTIME_LOCK_WORKER_PID=4000003
            RUNTIME_LOCK_WORKER_IDENTITY="boot-id:103"
            RUNTIME_LOCK_WATCHDOG_PID=4000004
            RUNTIME_LOCK_WATCHDOG_IDENTITY="boot-id:104"
            RUNTIME_LOCK_STATUS_FILE="$2"
            RUNTIME_LOCK_DECISION_FILE="$3"
            runtime_release_install_lock
            release_status=$?
            printf "release-status=%s attempts=%s\\n" \
                "${release_status}" "$(cat "$4")"
            exit "${release_status}"
        ' _ "${SANDBOX_REPO}" "${status_file}" "${decision_file}" "${counter_file}"
    assert_success
    assert_output_contains "release-status=0"
    if ! [[ "${output}" =~ attempts=([2-9][0-9]*) ]]; then
        return 1
    fi
    assert_file_exists "${decision_file}"
}

@test "a lock status removal failure fails cleanup and preserves state" {
    local state_dir="${TEST_ROOT}/status-removal-cache"
    local status_file="${state_dir}/cleanup.status"
    local decision_file="${state_dir}/cleanup.decision"

    mkdir -p "${state_dir}"
    printf 'status\n' > "${status_file}"
    printf 'committed' > "${decision_file}"
    chmod 0500 "${state_dir}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_PID=4000001
            RUNTIME_LOCK_GUARDIAN_IDENTITY="boot-id:101"
            RUNTIME_LOCK_PGID=4000001
            RUNTIME_LOCK_HOLDER_PID=4000002
            RUNTIME_LOCK_HOLDER_IDENTITY="boot-id:102"
            RUNTIME_LOCK_WORKER_PID=4000003
            RUNTIME_LOCK_WORKER_IDENTITY="boot-id:103"
            RUNTIME_LOCK_WATCHDOG_PID=4000004
            RUNTIME_LOCK_WATCHDOG_IDENTITY="boot-id:104"
            RUNTIME_LOCK_STATUS_FILE="$2"
            RUNTIME_LOCK_DECISION_FILE="$3"
            runtime_release_install_lock
            release_status=$?
            printf "release-status=%s status=%s\\n" \
                "${release_status}" "${RUNTIME_LOCK_STATUS_FILE}"
            exit "${release_status}"
        ' _ "${SANDBOX_REPO}" "${status_file}" "${decision_file}"
    assert_failure
    assert_output_contains "release-status=1"
    assert_output_contains "status=${status_file}"
    assert_file_exists "${status_file}"
    chmod 0700 "${state_dir}"
}

@test "stopped guardian and supervisor processes are resumed without retaining the lock" {
    local cache_dir="${TEST_ROOT}/stopped-helpers-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/stopped-helpers"
    local output_file="${TEST_ROOT}/stopped-helpers.out"
    local status_file
    local supervisor_pid
    local worker_pid
    local watchdog_pid
    local guardian_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local helper_pid
    local helper_state
    local all_stopped
    local all_running
    local attempt
    local -a helper_pids=()

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "${RUNTIME_LOCK_HOLDER_PID}" > "$2/supervisor.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -s "${pid_directory}/supervisor.pid" ] &&
            [ -e "${pid_directory}/ready" ] &&
            [ -n "${status_file}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/supervisor.pid" ] ||
        [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    supervisor_pid=$(cat "${pid_directory}/supervisor.pid")
    worker_pid=$(sed -n '2p' "${status_file}")
    guardian_pid=$(sed -n '6p' "${status_file}")
    watchdog_pid=$(sed -n '9p' "${status_file}")
    if ! [[ "${supervisor_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${worker_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${guardian_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${watchdog_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    helper_pids=(
        "${guardian_pid}"
        "${supervisor_pid}"
        "${worker_pid}"
        "${watchdog_pid}"
    )
    kill -STOP "${helper_pids[@]}"
    for ((attempt = 0; attempt < 500; attempt++)); do
        all_stopped=1
        for helper_pid in "${helper_pids[@]}"; do
            helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
            if [[ "${helper_state}" != T* ]] &&
                [[ "${helper_state}" != t* ]]; then
                all_stopped=0
                break
            fi
        done
        if [ "${all_stopped}" -eq 1 ]; then
            break
        fi
        sleep 0.01
    done
    if [ "${all_stopped}" -ne 1 ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    run flock --exclusive --nonblock "${lock_file}" true
    assert_failure

    # Resume one member of the stopped helper tree. The remaining monitors
    # must resume the stopped supervisor and guardian before any descriptor
    # owner can be left behind.
    kill -CONT "${worker_pid}"
    for ((attempt = 0; attempt < 200; attempt++)); do
        all_running=1
        for helper_pid in "${helper_pids[@]}"; do
            helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
            if [ -z "${helper_state}" ] ||
                [[ "${helper_state}" == T* ]] ||
                [[ "${helper_state}" == t* ]] ||
                [[ "${helper_state}" == Z* ]]; then
                all_running=0
                break
            fi
        done
        if [ "${all_running}" -eq 1 ]; then
            break
        fi
        sleep 0.05
    done
    if [ "${all_running}" -ne 1 ]; then
        kill -KILL "${helper_pids[@]}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    local lock_was_held=1
    if flock --exclusive --nonblock "${lock_file}" true; then
        lock_was_held=0
    fi

    kill -TERM "${installer_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] ||
            [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] &&
        [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "143"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    assert_equal "${lock_was_held}" "1"
}

@test "a stopped final lock owner is terminated during installer cleanup" {
    local cache_dir="${TEST_ROOT}/stopped-final-owner-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/stopped-final-owner"
    local output_file="${TEST_ROOT}/stopped-final-owner.out"
    local status_file
    local supervisor_pid
    local worker_pid
    local watchdog_pid
    local guardian_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local guardian_state
    local helper_pid
    local helper_state
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    supervisor_pid=$(sed -n '1p' "${status_file}")
    worker_pid=$(sed -n '2p' "${status_file}")
    guardian_pid=$(sed -n '6p' "${status_file}")
    watchdog_pid=$(sed -n '9p' "${status_file}")
    if ! [[ "${supervisor_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${worker_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${guardian_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${watchdog_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    # Remove every other descriptor owner, then leave the guardian stopped as
    # the final owner. The installer's final cleanup must terminate it so it
    # cannot retain the flock after cleanup.
    kill -STOP "${guardian_pid}" 2>/dev/null || true
    kill -KILL "${supervisor_pid}" "${worker_pid}" "${watchdog_pid}" 2>/dev/null || true
    kill -STOP "${guardian_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        guardian_state=$(ps -o stat= -p "${guardian_pid}" 2>/dev/null || true)
        if [[ "${guardian_state}" == T* ]] ||
            [[ "${guardian_state}" == t* ]]; then
            break
        fi
        sleep 0.05
    done
    guardian_state=$(ps -o stat= -p "${guardian_pid}" 2>/dev/null || true)
    if [[ "${guardian_state}" != T* ]] &&
        [[ "${guardian_state}" != t* ]]; then
        kill -KILL "${guardian_pid}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    local lock_was_held=1
    if flock --exclusive --nonblock "${lock_file}" true; then
        lock_was_held=0
    fi

    kill -TERM "${installer_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] ||
            [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] &&
        [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${installer_pid}" "${guardian_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    wait "${installer_pid}" || installer_status="${?}"
    if [ "${installer_status}" -ne 141 ] &&
        [ "${installer_status}" -ne 143 ]; then
        return 1
    fi
    for helper_pid in \
        "${guardian_pid}" \
        "${supervisor_pid}" \
        "${worker_pid}" \
        "${watchdog_pid}"; do
        helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
        if [ -n "${helper_state}" ] &&
            [[ "${helper_state}" != Z* ]]; then
            return 1
        fi
    done

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    assert_equal "${lock_was_held}" "1"
}

@test "a stopped reparented supervisor is terminated during installer cleanup" {
    local cache_dir="${TEST_ROOT}/stopped-final-supervisor-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/stopped-final-supervisor"
    local output_file="${TEST_ROOT}/stopped-final-supervisor.out"
    local status_file
    local supervisor_pid
    local worker_pid
    local watchdog_pid
    local guardian_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local supervisor_state
    local helper_state
    local helper_pid
    local all_stopped
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            trap "" USR1
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    supervisor_pid=$(sed -n '1p' "${status_file}")
    worker_pid=$(sed -n '2p' "${status_file}")
    guardian_pid=$(sed -n '6p' "${status_file}")
    watchdog_pid=$(sed -n '9p' "${status_file}")
    if ! [[ "${supervisor_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${worker_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${guardian_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${watchdog_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    # Leave the stopped supervisor as the final descriptor owner after its
    # former parent and siblings have been removed. Wait until every helper
    # has actually entered the stopped state before removing the siblings;
    # otherwise the watchdog can resume the supervisor in the race window.
    kill -STOP \
        "${guardian_pid}" \
        "${supervisor_pid}" \
        "${worker_pid}" \
        "${watchdog_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 500; attempt++)); do
        all_stopped=1
        for helper_pid in \
            "${guardian_pid}" \
            "${supervisor_pid}" \
            "${worker_pid}" \
            "${watchdog_pid}"; do
            helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
            if [[ "${helper_state}" != T* ]] &&
                [[ "${helper_state}" != t* ]]; then
                all_stopped=0
                break
            fi
        done
        if [ "${all_stopped}" -eq 1 ]; then
            break
        fi
        sleep 0.01
    done
    if [ "${all_stopped}" -ne 1 ]; then
        kill -KILL \
            "${guardian_pid}" \
            "${supervisor_pid}" \
            "${worker_pid}" \
            "${watchdog_pid}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    kill -KILL \
        "${guardian_pid}" \
        "${worker_pid}" \
        "${watchdog_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 500; attempt++)); do
        supervisor_state=$(ps -o stat= -p "${supervisor_pid}" 2>/dev/null || true)
        if [ -n "${supervisor_state}" ] &&
            [[ "${supervisor_state}" != T* ]] &&
            [[ "${supervisor_state}" != t* ]] &&
            [[ "${supervisor_state}" != Z* ]]; then
            break
        fi
        sleep 0.01
    done
    kill -STOP "${supervisor_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 500; attempt++)); do
        supervisor_state=$(ps -o stat= -p "${supervisor_pid}" 2>/dev/null || true)
        if [[ "${supervisor_state}" == T* ]] ||
            [[ "${supervisor_state}" == t* ]]; then
            break
        fi
        sleep 0.01
    done
    supervisor_state=$(ps -o stat= -p "${supervisor_pid}" 2>/dev/null || true)
    if [[ "${supervisor_state}" != T* ]] &&
        [[ "${supervisor_state}" != t* ]]; then
        kill -KILL "${supervisor_pid}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    run flock --exclusive --nonblock "${lock_file}" true
    assert_failure

    kill -TERM "${installer_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] ||
            [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] &&
        [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${installer_pid}" "${supervisor_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    wait "${installer_pid}" || installer_status="${?}"
    if [ "${installer_status}" -ne 141 ] &&
        [ "${installer_status}" -ne 143 ]; then
        return 1
    fi

    supervisor_state=$(ps -o stat= -p "${supervisor_pid}" 2>/dev/null || true)
    if [ -n "${supervisor_state}" ] &&
        [[ "${supervisor_state}" != Z* ]]; then
        return 1
    fi
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "lock acquisition rejects helpers that die during startup" {
    local cache_dir="${TEST_ROOT}/startup-race-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/startup-race-bin"
    local output_file="${TEST_ROOT}/startup-race.out"
    local status_file
    local holder_pid
    local worker_pid
    local installer_pid
    local installer_status=0
    local attempt
    local -a status_lines=()

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/flock" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "${argument}" = "--conflict-exit-code" ]; then
        sleep 1
        break
    fi
done
exec /usr/bin/flock "$@"
EOF
    chmod +x "${mock_bin}/flock"

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock || exit $?
            : > "$2/acquired"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${TEST_ROOT}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    mapfile -t status_lines < "${status_file}"
    holder_pid="${status_lines[0]}"
    worker_pid="${status_lines[1]}"
    kill -KILL "${holder_pid}" "${worker_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"
    status="${installer_status}"
    output="$(cat "${output_file}")"

    assert_failure
    assert_file_absent "${TEST_ROOT}/acquired"
    run grep -E 'unable to lock file|installation lock was lost|installation lock acquisition was cancelled' "${output_file}"
    assert_success
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "runtime aborts when the lock holder exits unexpectedly" {
    local cache_dir="${TEST_ROOT}/holder-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/holder-loss"
    local output_file="${TEST_ROOT}/holder-loss.out"
    local installer_pid
    local holder_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/holder.pid" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        run cat "${output_file}"
        assert_success
        assert_output_contains "unable to lock file"
        return 1
    fi

    holder_pid=$(cat "${pid_directory}/holder.pid")
    kill -KILL "${holder_pid}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "lock loss is detected without relying on the status file" {
    local cache_dir="${TEST_ROOT}/status-independent-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/status-independent-loss"
    local output_file="${TEST_ROOT}/status-independent-loss.out"
    local installer_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/holder.pid" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    rm -f "${cache_dir}"/.postinstall-lock-*.acquired
    kill -KILL "$(cat "${pid_directory}/holder.pid")"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
}

@test "runtime aborts when the lock worker exits unexpectedly" {
    local cache_dir="${TEST_ROOT}/worker-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/worker-loss"
    local output_file="${TEST_ROOT}/worker-loss.out"
    local installer_pid
    local worker_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_WORKER_PID" > "$2/worker.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/worker.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/worker.pid" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        run cat "${output_file}"
        assert_success
        assert_output_contains "unable to lock file"
        return 1
    fi

    worker_pid=$(cat "${pid_directory}/worker.pid")
    kill -KILL "${worker_pid}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "runtime aborts when the lock wrapper exits unexpectedly" {
    local cache_dir="${TEST_ROOT}/wrapper-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/wrapper-loss"
    local output_file="${TEST_ROOT}/wrapper-loss.out"
    local decision_file
    local installer_pid
    local wrapper_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_PID" > "$2/wrapper.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/wrapper.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/wrapper.pid" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        run cat "${output_file}"
        assert_success
        assert_output_contains "unable to lock file"
        return 1
    fi

    decision_file=$(find "${cache_dir}" -maxdepth 1 -type f \
        -name '.postinstall-lock-*.decision' -print -quit 2>/dev/null || true)
    if [ -z "${decision_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wrapper_pid=$(cat "${pid_directory}/wrapper.pid")
    kill -KILL "${wrapper_pid}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "the lock remains held until foreground work finishes after helper loss" {
    local cache_dir="${TEST_ROOT}/foreground-lock-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/foreground-lock"
    local output_file="${TEST_ROOT}/foreground-lock.out"
    local installer_pid
    local holder_pid
    local wrapper_pid
    local worker_pid
    local child_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    cat > "${pid_directory}/foreground.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${BASHPID}" > "${1}"
exec sleep 30
EOF
    chmod +x "${pid_directory}/foreground.sh"

    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            printf "%s\n" "$RUNTIME_LOCK_WORKER_PID" > "$2/worker.pid"
            printf "%s\n" "$RUNTIME_LOCK_PID" > "$2/wrapper.pid"
            : > "$2/ready"
            "$2/foreground.sh" "$2/child.pid"
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] &&
            [ -s "${pid_directory}/worker.pid" ] &&
            [ -s "${pid_directory}/wrapper.pid" ] &&
            [ -s "${pid_directory}/child.pid" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/child.pid" ]; then
        kill "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        run cat "${output_file}"
        assert_success
        assert_output_contains "unable to lock file"
        return 1
    fi

    holder_pid=$(cat "${pid_directory}/holder.pid")
    wrapper_pid=$(cat "${pid_directory}/wrapper.pid")
    worker_pid=$(cat "${pid_directory}/worker.pid")
    child_pid=$(cat "${pid_directory}/child.pid")

    kill -KILL "${wrapper_pid}" "${holder_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        if ! kill -0 "${worker_pid}" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    # The worker still owns the inherited descriptor while Bash defers the
    # lock-loss trap until its foreground child returns.
    run flock --exclusive --nonblock "${lock_file}" true
    assert_failure

    kill -TERM "${child_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "losing both lock helpers preserves the lock and completes cleanup" {
    local cache_dir="${TEST_ROOT}/all-helpers-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/all-helpers-loss"
    local output_file="${TEST_ROOT}/all-helpers-loss.out"
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"

            function all_helpers_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                kill -KILL "$RUNTIME_LOCK_HOLDER_PID" "$RUNTIME_LOCK_WORKER_PID"
                for attempt in {1..40}; do
                    if ! flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
                        printf "held\n" > "${cleanup_directory}/lock-held"
                    fi
                    sleep 0.05
                done
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "all-helpers-cleanup" all_helpers_cleanup || exit $?
            exit 0
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_exists "${pid_directory}/lock-held"
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "a group-directed SIGTERM keeps the lock held throughout cleanup" {
    local cache_dir="${TEST_ROOT}/group-signal-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/group-signal"
    local output_file="${TEST_ROOT}/group-signal.out"
    local installer_pid
    local installer_status=0
    local process_group
    local attempt

    mkdir -p "${pid_directory}"
    setsid env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"

            function group_signal_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                for attempt in {1..40}; do
                    if flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
                        printf "released\n" > "${cleanup_directory}/lock-released"
                    else
                        printf "held\n" > "${cleanup_directory}/lock-held"
                    fi
                    sleep 0.05
                done
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "group-signal-cleanup" group_signal_cleanup || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    process_group=$(ps -o pgid= -p "${installer_pid}" | tr -d '[:space:]')
    if [ "${process_group}" != "${installer_pid}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        printf 'installer did not start in an isolated process group\n' >&2
        return 1
    fi

    kill -TERM -- "-${process_group}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "143"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_exists "${pid_directory}/lock-held"
    assert_file_absent "${pid_directory}/lock-released"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "a pre-commit SIGUSR2 cancels acquisition without releasing the lock early" {
    local cache_dir="${TEST_ROOT}/precommit-usr2-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/precommit-usr2"
    local output_file="${TEST_ROOT}/precommit-usr2.out"
    local mock_bin="${TEST_ROOT}/precommit-usr2-bin"
    local events_fifo="${pid_directory}/events.fifo"
    local probe_release_fifo="${pid_directory}/probe.release"
    local cleanup_release_fifo="${pid_directory}/cleanup.release"
    local watcher_output="${TEST_ROOT}/precommit-event-watcher.out"
    local watcher_pid=""
    local watcher_status=0
    local event_fd
    local probe_release_fd
    local cleanup_release_fd
    local test_lock_fd
    local installer_pid=""
    local installer_status=0
    local status_file
    local supervisor_pid
    local supervisor_identity
    local worker_pid
    local worker_identity
    local wrapper_pid
    local wrapper_identity
    local watchdog_pid
    local watchdog_identity
    local expected_lock_identity
    local -a status_lines=()

    mkdir -p "${cache_dir}" "${pid_directory}" "${mock_bin}"
    chmod 0700 "${cache_dir}"
    mkfifo \
        "${events_fifo}" \
        "${probe_release_fifo}" \
        "${cleanup_release_fifo}"
    exec {event_fd}<>"${events_fifo}"
    exec {probe_release_fd}<>"${probe_release_fifo}"
    exec {cleanup_release_fd}<>"${cleanup_release_fifo}"

    function abort_precommit_test {
        printf 'release-after-cancellation\n' >&"${probe_release_fd}" 2>/dev/null || true
        printf 'release-cleanup\n' >&"${cleanup_release_fd}" 2>/dev/null || true
        if [ -n "${installer_pid}" ]; then
            kill -TERM -- "-${installer_pid}" 2>/dev/null || true
            kill -TERM "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
        fi
        if [ -n "${watcher_pid}" ]; then
            kill "${watcher_pid}" 2>/dev/null || true
            wait "${watcher_pid}" 2>/dev/null || true
        fi
    }

    /usr/bin/python3 \
        "${REPO_ROOT}/tests/helpers/lock-event-watcher.py" \
        "${cache_dir}" \
        "${event_fd}" >"${watcher_output}" 2>&1 &
    watcher_pid="${!}"
    if ! expect_lock_event "W" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "ready" ]; then
        abort_precommit_test
        return 1
    fi

    cat > "${mock_bin}/flock" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "${argument}" != "true" ]; then
        continue
    fi
    status_file=$(
        find "${MOCK_CACHE_DIR}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' \
            -print -quit 2>/dev/null || true
    )
    if [ -z "${status_file}" ]; then
        exit 125
    fi
    printf 'P\t%s\n' "${status_file}" >&"${MOCK_EVENT_FD}"
    IFS= read -r release_token < "${MOCK_PROBE_RELEASE_FIFO}" || exit 125
    if [ "${release_token}" != "release-after-cancellation" ]; then
        exit 125
    fi
    if /usr/bin/flock "$@"; then
        probe_status=0
    else
        probe_status="${?}"
    fi
    printf 'P-done\t%s\n' "${probe_status}" >&"${MOCK_EVENT_FD}"
    exit "${probe_status}"
done
exec /usr/bin/flock "$@"
EOF
    chmod +x "${mock_bin}/flock"

    setsid env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_CACHE_DIR="${cache_dir}" \
        MOCK_EVENT_FD="${event_fd}" \
        MOCK_PROBE_RELEASE_FIFO="${probe_release_fifo}" \
        MOCK_CLEANUP_RELEASE_FIFO="${cleanup_release_fifo}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?

            function precommit_usr2_cleanup {
                local lock_status
                local lock_descriptor_path

                printf "C\tstarted\n" >&"${MOCK_EVENT_FD}"
                if [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ]; then
                    lock_descriptor_path="/proc/${RUNTIME_LOCK_OWNER_PID}/fd/${RUNTIME_LOCK_OWNER_FILE_FD}"
                else
                    lock_descriptor_path="/proc/self/fd/${RUNTIME_LOCK_FILE_FD}"
                fi
                if /usr/bin/flock \
                    --exclusive \
                    --nonblock \
                    --conflict-exit-code 75 \
                    "${lock_descriptor_path}" true; then
                    lock_status=0
                else
                    lock_status="${?}"
                fi
                if [ "${lock_status}" -ne 75 ]; then
                    printf "C\tlock-error:%s\n" "${lock_status}" >&"${MOCK_EVENT_FD}"
                    return 1
                fi
                printf "C\tlock-held\n" >&"${MOCK_EVENT_FD}"
                IFS= read -r release_token < "${MOCK_CLEANUP_RELEASE_FIFO}" || {
                    printf "C\trelease-failed\n" >&"${MOCK_EVENT_FD}"
                    return 1
                }
                if [ "${release_token}" != "release-cleanup" ]; then
                    printf "C\trelease-invalid\n" >&"${MOCK_EVENT_FD}"
                    return 1
                fi
                printf "C\tcomplete\n" >&"${MOCK_EVENT_FD}"
            }
            runtime_register_cleanup "precommit-usr2-cleanup" precommit_usr2_cleanup || exit $?
            if runtime_acquire_install_lock; then
                acquisition_status=0
            else
                acquisition_status="${?}"
            fi
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    if ! expect_lock_event "P" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    status_file="${LOCK_EVENT_VALUE}"
    if [ ! -s "${status_file}" ]; then
        abort_precommit_test
        return 1
    fi
    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    worker_pid="${status_lines[1]}"
    supervisor_identity="${status_lines[3]}"
    worker_identity="${status_lines[4]}"
    wrapper_pid="${status_lines[5]}"
    wrapper_identity="${status_lines[6]}"
    watchdog_pid="${status_lines[8]}"
    watchdog_identity="${status_lines[9]}"

    exec {test_lock_fd}<>"${lock_file}"
    expected_lock_identity=$(
        stat -Lc '%d:%i' "/proc/self/fd/${test_lock_fd}"
    )
    if [ -z "${expected_lock_identity}" ]; then
        abort_precommit_test
        return 1
    fi

    run /usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        signal-process \
        "${wrapper_pid}" \
        "${wrapper_identity}" \
        12
    if [ "${status}" -ne 0 ]; then
        abort_precommit_test
        return 1
    fi

    if ! expect_lock_event "D" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "cancelled" ]; then
        abort_precommit_test
        return 1
    fi

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "/proc/self/fd/${test_lock_fd}" true
    if [ "${status}" -ne 75 ]; then
        abort_precommit_test
        return 1
    fi

    printf 'release-after-cancellation\n' >&"${probe_release_fd}"
    if ! expect_lock_event "P-done" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "75" ]; then
        abort_precommit_test
        return 1
    fi

    if ! expect_lock_event "C" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "started" ]; then
        abort_precommit_test
        return 1
    fi
    if ! expect_lock_event "C" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "lock-held" ]; then
        abort_precommit_test
        return 1
    fi

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "/proc/self/fd/${test_lock_fd}" true
    if [ "${status}" -ne 75 ]; then
        abort_precommit_test
        return 1
    fi

    printf 'release-cleanup\n' >&"${cleanup_release_fd}"
    if ! expect_lock_event "C" "${event_fd}"; then
        abort_precommit_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "complete" ]; then
        abort_precommit_test
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""
    assert_equal "${installer_status}" "73"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock acquisition was cancelled"

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        "/proc/self/fd/${test_lock_fd}" true
    assert_success

    assert_lock_helper_gone "${supervisor_pid}" "${supervisor_identity}"
    assert_lock_helper_gone "${worker_pid}" "${worker_identity}"
    assert_lock_helper_gone "${wrapper_pid}" "${wrapper_identity}"
    assert_lock_helper_gone "${watchdog_pid}" "${watchdog_identity}"
    run /usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        verify-group-empty "${wrapper_pid}"
    assert_success

    wait "${watcher_pid}" || watcher_status="${?}"
    watcher_pid=""
    assert_equal "${watcher_status}" "0"
}

@test "watchdog SIGUSR2 cancels acquisition and retains the lock through cleanup" {
    local cache_dir="${TEST_ROOT}/watchdog-usr2-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/watchdog-usr2"
    local output_file="${TEST_ROOT}/watchdog-usr2.out"
    local mock_bin="${TEST_ROOT}/watchdog-usr2-bin"
    local events_fifo="${pid_directory}/events.fifo"
    local probe_release_fifo="${pid_directory}/probe.release"
    local cleanup_release_fifo="${pid_directory}/cleanup.release"
    local watcher_output="${TEST_ROOT}/watchdog-event-watcher.out"
    local watcher_pid=""
    local watcher_status=0
    local event_fd
    local probe_release_fd
    local cleanup_release_fd
    local test_lock_fd
    local installer_pid=""
    local installer_status=0
    local status_file
    local watchdog_pid
    local watchdog_identity
    local supervisor_pid
    local supervisor_identity
    local worker_pid
    local worker_identity
    local wrapper_pid
    local wrapper_identity
    local expected_lock_identity
    local -a status_lines=()

    mkdir -p "${cache_dir}" "${pid_directory}" "${mock_bin}"
    chmod 0700 "${cache_dir}"
    mkfifo \
        "${events_fifo}" \
        "${probe_release_fifo}" \
        "${cleanup_release_fifo}"
    exec {event_fd}<>"${events_fifo}"
    exec {probe_release_fd}<>"${probe_release_fifo}"
    exec {cleanup_release_fd}<>"${cleanup_release_fifo}"

    function abort_watchdog_test {
        printf 'release-after-cancellation\n' >&"${probe_release_fd}" 2>/dev/null || true
        printf 'release-cleanup\n' >&"${cleanup_release_fd}" 2>/dev/null || true
        if [ -n "${installer_pid}" ]; then
            kill -TERM -- "-${installer_pid}" 2>/dev/null || true
            kill -TERM "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
        fi
        if [ -n "${watcher_pid}" ]; then
            kill "${watcher_pid}" 2>/dev/null || true
            wait "${watcher_pid}" 2>/dev/null || true
        fi
    }

    /usr/bin/python3 \
        "${REPO_ROOT}/tests/helpers/lock-event-watcher.py" \
        "${cache_dir}" \
        "${event_fd}" >"${watcher_output}" 2>&1 &
    watcher_pid="${!}"
    if ! expect_lock_event "W" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "ready" ]; then
        abort_watchdog_test
        return 1
    fi

    cat > "${mock_bin}/flock" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "${argument}" != "true" ]; then
        continue
    fi
    status_file=$(
        find "${MOCK_CACHE_DIR}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' \
            -print -quit 2>/dev/null || true
    )
    if [ -z "${status_file}" ]; then
        exit 125
    fi
    printf 'P\t%s\n' "${status_file}" >&"${MOCK_EVENT_FD}"
    IFS= read -r release_token < "${MOCK_PROBE_RELEASE_FIFO}" || exit 125
    if [ "${release_token}" != "release-after-cancellation" ]; then
        exit 125
    fi
    if /usr/bin/flock "$@"; then
        probe_status=0
    else
        probe_status="${?}"
    fi
    printf 'P-done\t%s\n' "${probe_status}" >&"${MOCK_EVENT_FD}"
    exit "${probe_status}"
done
exec /usr/bin/flock "$@"
EOF
    chmod +x "${mock_bin}/flock"

    setsid env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_CACHE_DIR="${cache_dir}" \
        MOCK_EVENT_FD="${event_fd}" \
        MOCK_PROBE_RELEASE_FIFO="${probe_release_fifo}" \
        MOCK_CLEANUP_RELEASE_FIFO="${cleanup_release_fifo}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?

            function watchdog_usr2_cleanup {
                local exact_identity
                local lock_status
                local lock_descriptor_path

                printf "C\tstarted\n" >&"${MOCK_EVENT_FD}"
                if [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ]; then
                    lock_descriptor_path="/proc/${RUNTIME_LOCK_OWNER_PID}/fd/${RUNTIME_LOCK_OWNER_FILE_FD}"
                else
                    lock_descriptor_path="/proc/self/fd/${RUNTIME_LOCK_FILE_FD}"
                fi
                exact_identity=$(
                    stat -Lc "%d:%i" \
                        "${lock_descriptor_path}" 2>/dev/null
                ) || {
                    printf "C\tidentity-failed\n" >&"${MOCK_EVENT_FD}"
                    return 1
                }
                printf "C\tlock:%s\n" "${exact_identity}" >&"${MOCK_EVENT_FD}"
                if /usr/bin/flock \
                    --exclusive \
                    --nonblock \
                    --conflict-exit-code 75 \
                    "${lock_descriptor_path}" true; then
                    lock_status=0
                else
                    lock_status="${?}"
                fi
                if [ "${lock_status}" -eq 0 ]; then
                    printf "C\tlock-free\n" >&"${MOCK_EVENT_FD}"
                    return 1
                fi
                if [ "${lock_status}" -ne 75 ]; then
                    printf "C\tlock-error:%s\n" "${lock_status}" >&"${MOCK_EVENT_FD}"
                    return 1
                fi
                printf "C\tlock-held\n" >&"${MOCK_EVENT_FD}"
                IFS= read -r release_token < "${MOCK_CLEANUP_RELEASE_FIFO}" || {
                    printf "C\trelease-failed\n" >&"${MOCK_EVENT_FD}"
                    return 1
                }
                if [ "${release_token}" != "release-cleanup" ]; then
                    printf "C\trelease-invalid\n" >&"${MOCK_EVENT_FD}"
                    return 1
                fi
                printf "C\tcomplete\n" >&"${MOCK_EVENT_FD}"
            }
            runtime_register_cleanup "watchdog-usr2-cleanup" watchdog_usr2_cleanup || exit $?
            if runtime_acquire_install_lock; then
                acquisition_status=0
            else
                acquisition_status="${?}"
            fi
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    if ! expect_lock_event "P" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    status_file="${LOCK_EVENT_VALUE}"
    if [ ! -s "${status_file}" ]; then
        abort_watchdog_test
        return 1
    fi
    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    worker_pid="${status_lines[1]}"
    supervisor_identity="${status_lines[3]}"
    worker_identity="${status_lines[4]}"
    wrapper_pid="${status_lines[5]}"
    wrapper_identity="${status_lines[6]}"
    watchdog_pid="${status_lines[8]}"
    watchdog_identity="${status_lines[9]}"

    exec {test_lock_fd}<>"${lock_file}"
    expected_lock_identity=$(
        stat -Lc '%d:%i' "/proc/self/fd/${test_lock_fd}"
    )
    if [ -z "${expected_lock_identity}" ]; then
        abort_watchdog_test
        return 1
    fi

    run /usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        signal-process \
        "${watchdog_pid}" \
        "${watchdog_identity}" \
        12
    if [ "${status}" -ne 0 ]; then
        abort_watchdog_test
        return 1
    fi

    if ! expect_lock_event "D" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "cancelled" ]; then
        abort_watchdog_test
        return 1
    fi

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "/proc/self/fd/${test_lock_fd}" true
    if [ "${status}" -ne 75 ]; then
        abort_watchdog_test
        return 1
    fi

    printf 'release-after-cancellation\n' >&"${probe_release_fd}"
    if ! expect_lock_event "P-done" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "75" ]; then
        abort_watchdog_test
        return 1
    fi

    if ! expect_lock_event "C" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "started" ]; then
        abort_watchdog_test
        return 1
    fi
    if ! expect_lock_event "C" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "lock:${expected_lock_identity}" ]; then
        abort_watchdog_test
        return 1
    fi
    if ! expect_lock_event "C" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "lock-held" ]; then
        abort_watchdog_test
        return 1
    fi

    run /usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        identity "${watchdog_pid}"
    if [ "${status}" -ne 0 ] ||
        [ "${output}" != "${watchdog_identity}" ]; then
        abort_watchdog_test
        return 1
    fi

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "/proc/self/fd/${test_lock_fd}" true
    if [ "${status}" -ne 75 ]; then
        abort_watchdog_test
        return 1
    fi

    printf 'release-cleanup\n' >&"${cleanup_release_fd}"
    if ! expect_lock_event "C" "${event_fd}"; then
        abort_watchdog_test
        return 1
    fi
    if [ "${LOCK_EVENT_VALUE}" != "complete" ]; then
        abort_watchdog_test
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""
    assert_equal "${installer_status}" "73"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock acquisition was cancelled"

    run /usr/bin/flock \
        --exclusive \
        --nonblock \
        "/proc/self/fd/${test_lock_fd}" true
    assert_success

    assert_lock_helper_gone "${supervisor_pid}" "${supervisor_identity}"
    assert_lock_helper_gone "${worker_pid}" "${worker_identity}"
    assert_lock_helper_gone "${wrapper_pid}" "${wrapper_identity}"
    assert_lock_helper_gone "${watchdog_pid}" "${watchdog_identity}"
    run /usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        verify-group-empty "${wrapper_pid}"
    assert_success

    wait "${watcher_pid}" || watcher_status="${?}"
    watcher_pid=""
    assert_equal "${watcher_status}" "0"
}

@test "release retains decision state for cleanup loss classification" {
    local cache_dir="${TEST_ROOT}/decision-lifetime-cache"
    local cancelled_decision="${cache_dir}/cancelled.decision"
    local committed_decision="${cache_dir}/committed.decision"
    local status_file="${cache_dir}/cleanup.status"

    mkdir -p "${cache_dir}"
    chmod 0700 "${cache_dir}"
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" claim-decision \
        "${cancelled_decision}" cancelled
    assert_success
    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" claim-decision \
        "${committed_decision}" committed
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_PID=4000001
            RUNTIME_LOCK_GUARDIAN_IDENTITY="boot-id:101"
            RUNTIME_LOCK_PGID=4000001
            RUNTIME_LOCK_HOLDER_PID=4000002
            RUNTIME_LOCK_HOLDER_IDENTITY="boot-id:102"
            RUNTIME_LOCK_WORKER_PID=4000003
            RUNTIME_LOCK_WORKER_IDENTITY="boot-id:103"
            RUNTIME_LOCK_WATCHDOG_PID=4000004
            RUNTIME_LOCK_WATCHDOG_IDENTITY="boot-id:104"
            RUNTIME_LOCK_STATUS_FILE="$3"
            RUNTIME_LOCK_DECISION_FILE="$2"
            runtime_release_install_lock || exit $?
            RUNTIME_CRITICAL_DEPTH=1
            runtime_handle_lock_loss 141 lock-loss || exit $?
            printf "decision=%s acquired=%s held=%s pending=%s name=%s\n" \
                "$RUNTIME_LOCK_DECISION_FILE" \
                "$RUNTIME_LOCK_ACQUIRED" \
                "$RUNTIME_LOCK_HELD" \
                "$RUNTIME_PENDING_SIGNAL_STATUS" \
                "$RUNTIME_PENDING_SIGNAL_NAME"
            if [ -f "$2" ]; then
                printf 'decision-retained=1\n'
            else
                printf 'decision-retained=0\n'
            fi
            rm -f -- "$2"
            RUNTIME_PENDING_SIGNAL_STATUS=0
            RUNTIME_PENDING_SIGNAL_NAME=""
            runtime_handle_lock_loss 141 lock-loss || exit $?
            printf "cached-pending=%s cached-name=%s\n" \
                "$RUNTIME_PENDING_SIGNAL_STATUS" \
                "$RUNTIME_PENDING_SIGNAL_NAME"
        ' _ "${SANDBOX_REPO}" "${cancelled_decision}" "${status_file}"
    assert_success
    assert_output_contains "decision=${cancelled_decision} acquired=1 held=0 pending=73 name=lock-cancelled"
    assert_output_contains "decision-retained=1"
    assert_output_contains "cached-pending=73 cached-name=lock-cancelled"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_PID=4000001
            RUNTIME_LOCK_GUARDIAN_IDENTITY="boot-id:101"
            RUNTIME_LOCK_PGID=4000001
            RUNTIME_LOCK_HOLDER_PID=4000002
            RUNTIME_LOCK_HOLDER_IDENTITY="boot-id:102"
            RUNTIME_LOCK_WORKER_PID=4000003
            RUNTIME_LOCK_WORKER_IDENTITY="boot-id:103"
            RUNTIME_LOCK_WATCHDOG_PID=4000004
            RUNTIME_LOCK_WATCHDOG_IDENTITY="boot-id:104"
            RUNTIME_LOCK_STATUS_FILE="$3"
            RUNTIME_LOCK_DECISION_FILE="$2"
            runtime_release_install_lock || exit $?
            RUNTIME_CRITICAL_DEPTH=1
            runtime_handle_lock_loss 141 lock-loss || exit $?
            printf "decision=%s acquired=%s held=%s pending=%s name=%s\n" \
                "$RUNTIME_LOCK_DECISION_FILE" \
                "$RUNTIME_LOCK_ACQUIRED" \
                "$RUNTIME_LOCK_HELD" \
                "$RUNTIME_PENDING_SIGNAL_STATUS" \
                "$RUNTIME_PENDING_SIGNAL_NAME"
        ' _ "${SANDBOX_REPO}" "${committed_decision}" "${status_file}"
    assert_success
    assert_output_contains "decision=${committed_decision} acquired=1 held=0 pending=141 name=lock-loss"
    assert_file_exists "${committed_decision}"
}

@test "the final validated helper identity snapshot is retained" {
    local cache_dir="${TEST_ROOT}/final-validation-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/final-validation-bin"
    local counter_file="${TEST_ROOT}/final-validation.count"
    local output_file="${TEST_ROOT}/final-validation.out"
    local attempt

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "validate-status" ]; then
    count=0
    if [ -f "${MOCK_FINAL_VALIDATION_COUNTER}" ]; then
        read -r count < "${MOCK_FINAL_VALIDATION_COUNTER}" || count=0
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${MOCK_FINAL_VALIDATION_COUNTER}"
    if [ "${count}" -eq 1 ]; then
        printf '%s\n' \
            '4100001 4100002 4100003 boot-id:101 boot-id:102 boot-id:103 boot-id:104'
    else
        printf '%s\n' \
            '4200001 4200002 4200003 boot-id:201 boot-id:202 boot-id:203 boot-id:204'
    fi
    exit 0
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_FINAL_VALIDATION_COUNTER="${counter_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock || exit $?
            printf "holder=%s identity=%s worker=%s watchdog=%s\\n" \
                "${RUNTIME_LOCK_HOLDER_PID}" \
                "${RUNTIME_LOCK_HOLDER_IDENTITY}" \
                "${RUNTIME_LOCK_WORKER_PID}" \
                "${RUNTIME_LOCK_WATCHDOG_PID}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1

    run cat "${output_file}"
    assert_success
    assert_output_contains "holder=4200001 identity=boot-id:201 worker=4200002 watchdog=4200003"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "a helper death before owner handoff is caught by the final validation" {
    local cache_dir="${TEST_ROOT}/owner-handoff-validation-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/owner-handoff-validation-bin"
    local counter_file="${TEST_ROOT}/owner-handoff-validation.count"
    local validation_marker="${TEST_ROOT}/owner-handoff-validation.ready"
    local validation_release="${TEST_ROOT}/owner-handoff-validation.release"
    local output_file="${TEST_ROOT}/owner-handoff-validation.out"
    local status_file
    local installer_pid=""
    local installer_status=0
    local attempt
    local -a status_lines=()

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "validate-status" ]; then
    count=0
    if [ -f "${MOCK_OWNER_VALIDATION_COUNTER}" ]; then
        read -r count < "${MOCK_OWNER_VALIDATION_COUNTER}" || count=0
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${MOCK_OWNER_VALIDATION_COUNTER}"
    if [ "${count}" -eq 3 ]; then
        validation_output=$(/usr/bin/python3 "$@") || exit $?
        : > "${MOCK_OWNER_VALIDATION_MARKER}"
        while [ ! -e "${MOCK_OWNER_VALIDATION_RELEASE}" ]; do
            sleep 0.01
        done
        printf '%s\n' "${validation_output}"
        exit 0
    fi
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    function abort_owner_handoff_test {
        : > "${validation_release}"
        if [ -n "${installer_pid}" ]; then
            kill -TERM "${installer_pid}" 2>/dev/null || true
            wait "${installer_pid}" 2>/dev/null || true
        fi
    }

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_OWNER_VALIDATION_COUNTER="${counter_file}" \
        MOCK_OWNER_VALIDATION_MARKER="${validation_marker}" \
        MOCK_OWNER_VALIDATION_RELEASE="${validation_release}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 200; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
            -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -n "${status_file}" ] && [ -e "${validation_marker}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -z "${status_file}" ] || [ ! -e "${validation_marker}" ]; then
        abort_owner_handoff_test
        return 1
    fi

    mapfile -t status_lines < "${status_file}"
    kill -KILL \
        "${status_lines[0]}" \
        "${status_lines[1]}" \
        "${status_lines[5]}" \
        "${status_lines[8]}" 2>/dev/null || true
    : > "${validation_release}"

    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""
    assert_equal "${installer_status}" "73"
    run cat "${output_file}"
    assert_success
    assert_output_contains "lock acquisition failed after commit"
    run cat "${counter_file}"
    assert_success
    assert_equal "${output}" "4"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "an owner death before final support validation fails acquisition with status 73" {
    local cache_dir="${TEST_ROOT}/owner-final-validation-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/owner-final-validation-bin"
    local counter_file="${TEST_ROOT}/owner-final-validation.count"
    local output_file="${TEST_ROOT}/owner-final-validation.out"
    local installer_pid=""
    local installer_status=0
    local attempt

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "validate-support" ] && [ "${4:-}" = "owner" ]; then
    count=0
    if [ -f "${MOCK_OWNER_FINAL_COUNTER}" ]; then
        read -r count < "${MOCK_OWNER_FINAL_COUNTER}" || count=0
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${MOCK_OWNER_FINAL_COUNTER}"
    if [ "${count}" -eq 4 ]; then
        owner_pid=$(sed -n 's/^process_pid=//p' "${3}")
        if [[ "${owner_pid}" =~ ^[0-9]+$ ]]; then
            kill -KILL "${owner_pid}" 2>/dev/null || true
        fi
    fi
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_OWNER_FINAL_COUNTER="${counter_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s held=%s\n" \
                "${acquisition_status}" "${RUNTIME_LOCK_HELD}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    wait "${installer_pid}" || installer_status="${?}"
    installer_pid=""
    assert_equal "${installer_status}" "73"

    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock owner failed during acquisition"
    run cat "${counter_file}"
    assert_success
    assert_equal "${output}" "4"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    run flock --exclusive --nonblock "${cache_dir}" true
    assert_success
}

@test "a post-commit validation failure resumes stopped helpers and returns 73" {
    local cache_dir="${TEST_ROOT}/post-commit-validation-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/post-commit-validation-bin"
    local counter_file="${TEST_ROOT}/post-commit-validation.count"
    local status_snapshot="${TEST_ROOT}/post-commit-validation.status"
    local output_file="${TEST_ROOT}/post-commit-validation.out"
    local installer_pid
    local installer_status=0
    local installer_state
    local attempt

    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "validate-status" ]; then
    count=0
    if [ -f "${MOCK_VALIDATE_COUNTER}" ]; then
        read -r count < "${MOCK_VALIDATE_COUNTER}" || count=0
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${MOCK_VALIDATE_COUNTER}"
    if [ "${count}" -eq 3 ]; then
        cp -- "$3" "${MOCK_VALIDATE_STATUS_SNAPSHOT}"
        mapfile -t status_lines < "$3"
        kill -STOP \
            "${status_lines[0]}" \
            "${status_lines[1]}" \
            "${status_lines[5]}" \
            "${status_lines[8]}" 2>/dev/null || true
        exit 1
    fi
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "${mock_bin}/python3"

    env \
        PATH="${mock_bin}:${PATH}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        MOCK_VALIDATE_COUNTER="${counter_file}" \
        MOCK_VALIDATE_STATUS_SNAPSHOT="${status_snapshot}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        sleep 0.1
        kill -KILL "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "73"
    run cat "${output_file}"
    assert_success
    assert_output_contains "lock acquisition failed after commit"
    run cat "${counter_file}"
    assert_success
    assert_equal "${output}" "3"

    if [ -s "${status_snapshot}" ]; then
        mapfile -t status_lines < "${status_snapshot}"
        for helper_pid in \
            "${status_lines[0]}" \
            "${status_lines[1]}" \
            "${status_lines[5]}" \
            "${status_lines[8]}"; do
            helper_state=$(ps -o stat= -p "${helper_pid}" 2>/dev/null || true)
            if [[ "${helper_state}" == T* ]] ||
                [[ "${helper_state}" == t* ]]; then
                return 1
            fi
        done
    fi

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "losing the guardian supervisor and worker leaves the watchdog holding the lock" {
    local cache_dir="${TEST_ROOT}/simultaneous-helper-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/simultaneous-helper-loss"
    local output_file="${TEST_ROOT}/simultaneous-helper-loss.out"
    local lock_inode_link="${pid_directory}/lock.inode"
    local installer_pid
    local installer_status=0
    local installer_state
    local watchdog_state
    local status_file
    local guardian_pid
    local supervisor_pid
    local worker_pid
    local watchdog_pid
    local attempt
    local -a status_lines=()

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"

            function blocked_lock_cleanup {
                local cleanup_attempt=0
                : > "${cleanup_directory}/cleanup-started"
                while [ ! -e "${cleanup_directory}/cleanup-release" ] && [ "${cleanup_attempt}" -lt 600 ]; do
                    if /usr/bin/flock --exclusive --nonblock "${cleanup_directory}/lock.inode" true; then
                        : > "${cleanup_directory}/lock-released"
                    else
                        : > "${cleanup_directory}/lock-held"
                    fi
                    cleanup_attempt=$((cleanup_attempt + 1))
                    sleep 0.05
                done
                if [ ! -e "${cleanup_directory}/cleanup-release" ]; then
                    : > "${cleanup_directory}/cleanup-timeout"
                fi
                : > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "blocked-lock-cleanup" blocked_lock_cleanup || exit $?

            printf "%s\n" "$RUNTIME_LOCK_PID" > "$2/guardian.pid"
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/supervisor.pid"
            printf "%s\n" "$RUNTIME_LOCK_WORKER_PID" > "$2/worker.pid"
            printf "%s\n" "$RUNTIME_LOCK_WATCHDOG_PID" > "$2/watchdog.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
    if [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    worker_pid="${status_lines[1]}"
    guardian_pid="${status_lines[5]}"
    watchdog_pid="${status_lines[8]}"
    if ! [[ "${guardian_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${supervisor_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${worker_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${watchdog_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    # Keep a second name for the exact inode acquired by the helpers, then
    # replace the public lock path. The watchdog must continue to hold the
    # original inode even though the path now resolves to a different file.
    if ! ln "${lock_file}" "${lock_inode_link}" ||
        ! mv "${lock_file}" "${lock_file}.replaced"; then
        : > "${pid_directory}/cleanup-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    # Stop the helpers first so they cannot race one another during teardown;
    # then kill them together while leaving the watchdog running.
    kill -STOP "${guardian_pid}" "${supervisor_pid}" "${worker_pid}" 2>/dev/null || true
    sleep 0.1
    kill -KILL "${guardian_pid}" "${supervisor_pid}" "${worker_pid}" 2>/dev/null || true

    for ((attempt = 0; attempt < 200; attempt++)); do
        if [ -e "${pid_directory}/cleanup-started" ] &&
            [ -e "${pid_directory}/lock-held" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/cleanup-started" ] ||
        [ ! -e "${pid_directory}/lock-held" ]; then
        : > "${pid_directory}/cleanup-release"
        kill -KILL "${watchdog_pid}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    watchdog_state=$(ps -o stat= -p "${watchdog_pid}" 2>/dev/null || true)
    if [ -z "${watchdog_state}" ] || [[ "${watchdog_state}" == Z* ]]; then
        : > "${pid_directory}/cleanup-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    run flock --exclusive --nonblock "${lock_inode_link}" true
    assert_failure

    # The replacement path is a different inode and can be locked
    # independently; the original inode remains locked by the watchdog.
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success

    : > "${pid_directory}/cleanup-release"
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${watchdog_pid}" 2>/dev/null || true
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "141"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_absent "${pid_directory}/cleanup-timeout"
    assert_file_absent "${pid_directory}/lock-released"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"

    for ((attempt = 0; attempt < 100; attempt++)); do
        watchdog_state=$(ps -o stat= -p "${watchdog_pid}" 2>/dev/null || true)
        if [ -z "${watchdog_state}" ] || [[ "${watchdog_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    for ((attempt = 0; attempt < 200; attempt++)); do
        if flock --exclusive --nonblock "${lock_inode_link}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_inode_link}" true
    assert_success
}

@test "losing only the watchdog aborts the installer" {
    local cache_dir="${TEST_ROOT}/watchdog-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/watchdog-loss"
    local output_file="${TEST_ROOT}/watchdog-loss.out"
    local installer_pid
    local installer_status=0
    local installer_state
    local watchdog_pid
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            printf "%s\n" "$RUNTIME_LOCK_WATCHDOG_PID" > "$2/watchdog.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/watchdog.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/watchdog.pid" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    watchdog_pid=$(cat "${pid_directory}/watchdog.pid")
    kill -KILL "${watchdog_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
}

@test "a group-directed SIGUSR2 during cleanup keeps a committed lock held" {
    local cache_dir="${TEST_ROOT}/group-usr2-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/group-usr2"
    local output_file="${TEST_ROOT}/group-usr2.out"
    local installer_pid
    local installer_status=0
    local attempt

    mkdir -p "${pid_directory}"
    setsid env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            cleanup_directory="$2"
            installer_process_id="${BASHPID}"

            function group_usr2_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                process_group=$(ps -o pgid= -p "${installer_process_id}" | tr -d "[:space:]")
                if [ "${process_group}" != "${installer_process_id}" ]; then
                    printf "mismatch\n" > "${cleanup_directory}/group-mismatch"
                else
                    kill -USR2 -- "-${process_group}"
                fi
                for attempt in {1..40}; do
                    if flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
                        printf "released\n" > "${cleanup_directory}/lock-released"
                        break
                    fi
                    printf "held\n" > "${cleanup_directory}/lock-held"
                    sleep 0.05
                done
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "group-usr2-cleanup" group_usr2_cleanup || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    kill -TERM "${installer_pid}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "143"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_exists "${pid_directory}/lock-held"
    assert_file_absent "${pid_directory}/lock-released"
    assert_file_absent "${pid_directory}/group-mismatch"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "an unreadable committed decision fails generically rather than as cancellation" {
    local cache_dir="${TEST_ROOT}/unreadable-decision-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/unreadable-decision"
    local output_file="${TEST_ROOT}/unreadable-decision.out"
    local status_file
    local decision_file
    local supervisor_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local attempt
    local -a status_lines=()

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${pid_directory}/ready" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    status_file=$(find "${cache_dir}" -maxdepth 1 -type f \
        -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
    decision_file=$(find "${cache_dir}" -maxdepth 1 -type f \
        -name '.postinstall-lock-*.decision' -print -quit 2>/dev/null || true)
    if [ -z "${status_file}" ] || [ -z "${decision_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    if ! [[ "${supervisor_pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    chmod 0000 "${decision_file}"
    kill -USR2 "${supervisor_pid}"
    for ((attempt = 0; attempt < 200; attempt++)); do
        installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
        if [ -z "${installer_state}" ] || [[ "${installer_state}" == Z* ]]; then
            break
        fi
        sleep 0.05
    done
    installer_state=$(ps -o stat= -p "${installer_pid}" 2>/dev/null || true)
    if [ -n "${installer_state}" ] && [[ "${installer_state}" != Z* ]]; then
        kill -KILL "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "141"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
    refute_output_contains "acquisition was cancelled"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "both lock helpers dying with a deleted status preserves the lock through cleanup" {
    local cache_dir="${TEST_ROOT}/deleted-status-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/deleted-status-loss"
    local output_file="${TEST_ROOT}/deleted-status-loss.out"
    local installer_pid
    local installer_status=0
    local status_file
    local holder_pid
    local worker_pid
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"

            function deleted_status_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                for attempt in {1..40}; do
                    if ! flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
                        printf "held\n" > "${cleanup_directory}/lock-held"
                    fi
                    sleep 0.05
                done
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "deleted-status-cleanup" deleted_status_cleanup || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            printf "%s\n" "$RUNTIME_LOCK_WORKER_PID" > "$2/worker.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] &&
            [ -s "${pid_directory}/worker.pid" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/holder.pid" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
    rm -f -- "${status_file}"
    holder_pid=$(cat "${pid_directory}/holder.pid")
    worker_pid=$(cat "${pid_directory}/worker.pid")
    kill -KILL "${holder_pid}" "${worker_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_exists "${pid_directory}/lock-held"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "both lock helpers dying with a corrupted status preserves the lock through cleanup" {
    local cache_dir="${TEST_ROOT}/corrupted-status-loss-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/corrupted-status-loss"
    local output_file="${TEST_ROOT}/corrupted-status-loss.out"
    local installer_pid
    local installer_status=0
    local status_file
    local holder_pid
    local worker_pid
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"

            function corrupted_status_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                for attempt in {1..40}; do
                    if ! flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
                        printf "held\n" > "${cleanup_directory}/lock-held"
                    fi
                    sleep 0.05
                done
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "corrupted-status-cleanup" corrupted_status_cleanup || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            printf "%s\n" "$RUNTIME_LOCK_WORKER_PID" > "$2/worker.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] &&
            [ -s "${pid_directory}/worker.pid" ] &&
            [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/holder.pid" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
    printf 'corrupted\n' > "${status_file}"
    holder_pid=$(cat "${pid_directory}/holder.pid")
    worker_pid=$(cat "${pid_directory}/worker.pid")
    kill -KILL "${holder_pid}" "${worker_pid}" 2>/dev/null || true
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_exists "${pid_directory}/lock-held"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "an ordinary signal during lock-loss cleanup preserves status 141" {
    local cache_dir="${TEST_ROOT}/lock-loss-signal-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/lock-loss-signal"
    local output_file="${TEST_ROOT}/lock-loss-signal.out"
    local installer_pid
    local installer_status=0
    local holder_pid
    local attempt

    mkdir -p "${pid_directory}"
    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_initialize || exit $?
            runtime_acquire_install_lock || exit $?
            runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
            cleanup_directory="$2"
            cleanup_parent_pid="$BASHPID"

            function lock_loss_signal_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                kill -TERM "$cleanup_parent_pid"
                sleep 0.2
                printf "complete\n" > "${cleanup_directory}/cleanup-complete"
            }
            runtime_register_cleanup "lock-loss-signal-cleanup" lock_loss_signal_cleanup || exit $?
            printf "%s\n" "$RUNTIME_LOCK_HOLDER_PID" > "$2/holder.pid"
            : > "$2/ready"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -s "${pid_directory}/holder.pid" ] && [ -e "${pid_directory}/ready" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -s "${pid_directory}/holder.pid" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    holder_pid=$(cat "${pid_directory}/holder.pid")
    kill -KILL "${holder_pid}"
    wait "${installer_pid}" || installer_status="${?}"

    assert_equal "${installer_status}" "141"
    assert_file_exists "${pid_directory}/cleanup-started"
    assert_file_exists "${pid_directory}/cleanup-complete"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock was lost"
}

@test "lock monitoring handles a parent without pidfd support" {
    local test_script="${TEST_ROOT}/pidfd-fallback.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import subprocess
import sys
import threading

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

target = subprocess.Popen(["sleep", "5"])
other = subprocess.Popen(["sleep", "5"])
original_pidfd_open = module.os.pidfd_open


def monitored_pidfd_open(process_id):
    if process_id == target.pid:
        raise OSError(errno.EPERM, "pidfd monitoring is unavailable")
    return original_pidfd_open(process_id)


module.os.pidfd_open = monitored_pidfd_open
identity = module.capture_process_identity(other.pid)
if identity is None:
    raise SystemExit("unable to capture the monitored process identity")
replacement_identity = module.ProcessIdentity(identity.start_time + 1, identity.boot_id)
if module.process_matches_identity(other.pid, replacement_identity):
    raise SystemExit("a replacement process identity was accepted")
threading.Timer(0.2, target.kill).start()
try:
    exited_process = module.wait_for_parents([target.pid, other.pid])
finally:
    other.kill()
    target.wait()
    other.wait()

if exited_process != target.pid:
    raise SystemExit("the unmonitored parent exit was not detected")
print("unmonitored parent exit detected")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "unmonitored parent exit detected"
}

@test "lock monitoring fails closed when no process identity is available" {
    local test_script="${TEST_ROOT}/pidfd-identity-failure.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

child = subprocess.Popen(["sleep", "5"])


def unavailable_pidfd(_process_id):
    raise OSError(errno.EPERM, "pidfd monitoring is unavailable")


module.os.pidfd_open = unavailable_pidfd
module.capture_process_identity = lambda _process_id: None
try:
    module.ProcessMonitor([("child", child.pid)])
except module.MonitoringUnavailable:
    pass
else:
    child.kill()
    child.wait()
    raise SystemExit("monitoring failure was treated as process exit")

if child.poll() is not None:
    raise SystemExit("the monitored child exited unexpectedly")
child.kill()
child.wait()
print("monitoring failure was rejected")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "monitoring failure was rejected"
}

@test "watchdog fallback keeps unknown process state distinct from exit" {
    local test_script="${TEST_ROOT}/watchdog-unknown-state.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys
import threading
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
observations = [module.ProcessObservation.UNKNOWN] * 50
observations.append(module.ProcessObservation.EXITED)
module.watchdog_process_observation = lambda _process_id, _identity: observations.pop(0)
module.observe_process_identity_and_parent = lambda _process_id, _identity, _parent: module.ProcessObservation.UNKNOWN
module.capture_process_identity_and_parent_observation = lambda _process_id, _parent: (None, module.ProcessObservation.UNKNOWN)
module.observe_parent_relationship = lambda _process_id, _parent: module.ProcessObservation.UNKNOWN

if module.watchdog_helper_relationships_broken(
    11,
    12,
    identity,
    13,
    identity,
    14,
    identity,
):
    raise SystemExit("unknown helper state was treated as helper loss")

fake_status = module.LockStatus(
    installer_process_id=21,
    installer_identity=identity,
    wrapper_process_id=11,
    wrapper_identity=identity,
    supervisor_process_id=13,
    supervisor_identity=identity,
    worker_process_id=14,
    worker_identity=identity,
    watchdog_process_id=15,
    watchdog_identity=identity,
)
module.read_lock_status = lambda _path: fake_status
module.observe_process_identity = lambda _process_id, _identity: module.ProcessObservation.UNKNOWN
status, definitive_failure = module.inspect_lock_status(
    "unused",
    11,
    21,
    identity,
)
if status is not None or definitive_failure:
    raise SystemExit("unknown status observation was treated as definitive failure")

thread_error = []


def wait_for_exit():
    try:
        module.wait_for_watchdog_installer_exit(21, identity)
    except BaseException as error:
        thread_error.append(error)


thread = threading.Thread(target=wait_for_exit)
thread.start()
time.sleep(0.1)
if not thread.is_alive():
    raise SystemExit("unknown installer state was treated as installer exit")
thread.join(timeout=1)
if thread.is_alive():
    raise SystemExit("installer exit wait did not complete")
if thread_error:
    raise SystemExit(f"installer exit wait failed: {thread_error[0]}")
print("unknown process state retained")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "unknown process state retained"
}

@test "watchdog notification retries a transient signal failure" {
    local test_script="${TEST_ROOT}/watchdog-notification-retry.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.capture_process_identity(os.getpid())
if identity is None:
    raise SystemExit("unable to capture installer identity")
attempts = []


def flaky_pidfd_signal(_descriptor, signal_number):
    attempts.append(signal_number)
    if len(attempts) == 1:
        raise OSError(errno.EAGAIN, "transient signal failure")
    return None


def forbidden_raw_kill(_process_id, _signal_number):
    raise AssertionError("raw PID signaling was used without a pidfd")


module.open_verified_installer_pidfd = lambda _process_id, _identity: 42
module.signal.pidfd_send_signal = flaky_pidfd_signal
module.os.kill = forbidden_raw_kill
if not module.notify_watchdog_installer(None, os.getpid(), identity):
    raise SystemExit("watchdog notification did not succeed")
if len(attempts) < 2:
    raise SystemExit("watchdog notification was not retried")
print("watchdog notification retried")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "watchdog notification retried"
}

@test "watchdog fallback publishes readiness only after startup validation" {
    local test_script="${TEST_ROOT}/watchdog-readiness-fallback.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import select
import sys
import threading

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
validation_entered = threading.Event()
allow_validation = threading.Event()
installer_exited = threading.Event()
thread_errors = []


def validate_startup(*_arguments):
    validation_entered.set()
    if not allow_validation.wait(timeout=2):
        raise RuntimeError("startup validation was not released")
    return True, False


def observe_installer(_process_id, _identity):
    if installer_exited.is_set():
        return module.ProcessObservation.EXITED
    return module.ProcessObservation.ALIVE


module.configure_watchdog_signal_handlers = lambda: None
module.validate_watchdog_startup = validate_startup
module.watchdog_process_observation = observe_installer
module.watchdog_helper_relationships_broken = lambda *_arguments: False
module.watchdog_cancellation_observed = lambda: False

ready_read, ready_write = os.pipe()
os.set_blocking(ready_read, False)


def run_fallback():
    try:
        module.watchdog_fallback_loop(
            21,
            identity,
            22,
            identity,
            23,
            identity,
            24,
            identity,
            ready_write,
            False,
            False,
        )
    except BaseException as error:
        thread_errors.append(error)


thread = threading.Thread(target=run_fallback)
thread.start()
if not validation_entered.wait(timeout=1):
    raise SystemExit("watchdog fallback did not attempt startup validation")

try:
    early_readiness = os.read(ready_read, 1)
except BlockingIOError:
    early_readiness = b""
if early_readiness:
    raise SystemExit("watchdog fallback published readiness before validation")

allow_validation.set()
readable, _writable, _exceptional = select.select([ready_read], [], [], 1)
if not readable:
    raise SystemExit("watchdog fallback did not publish readiness")
if os.read(ready_read, 1) != b"1":
    raise SystemExit("watchdog fallback published invalid readiness")

installer_exited.set()
thread.join(timeout=1)
if thread.is_alive():
    raise SystemExit("watchdog fallback did not stop after installer exit")
if thread_errors:
    raise SystemExit(f"watchdog fallback failed: {thread_errors[0]}")
print("watchdog readiness deferred until validation")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "watchdog readiness deferred until validation"
}

@test "watchdog notification prefers pidfd signaling over a raw PID signal" {
    local test_script="${TEST_ROOT}/watchdog-notification-order.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.capture_process_identity(os.getpid())
if identity is None:
    raise SystemExit("unable to capture installer identity")
calls = []


class MonitorWithoutPidfd:
    def signal_via_pidfd(self, _label, _signal_number):
        calls.append("monitor-pidfd-unavailable")
        return None


def open_installer_pidfd(_process_id, _identity):
    calls.append("verified-installer-pidfd")
    return 42


def send_pidfd_signal(_descriptor, _signal_number):
    calls.append("verified-installer-pidfd-signal")


def raw_kill(_process_id, _signal_number):
    calls.append("raw-kill")
    raise AssertionError("raw PID signaling was used before pidfd signaling")


module.open_verified_installer_pidfd = open_installer_pidfd
module.signal.pidfd_send_signal = send_pidfd_signal
module.os.kill = raw_kill
if not module.notify_watchdog_installer(
    MonitorWithoutPidfd(),
    os.getpid(),
    identity,
):
    raise SystemExit("watchdog notification did not succeed")
if calls != [
    "monitor-pidfd-unavailable",
    "verified-installer-pidfd",
    "verified-installer-pidfd-signal",
]:
    raise SystemExit(f"unexpected watchdog notification order: {calls}")

calls.clear()


class MonitorWithPidfd:
    def signal_via_pidfd(self, _label, _signal_number):
        calls.append("monitor-pidfd-signal")
        return True


module.watchdog_process_observation = lambda _process_id, _identity: module.ProcessObservation.UNKNOWN
if not module.notify_watchdog_installer(
    MonitorWithPidfd(),
    os.getpid(),
    identity,
):
    raise SystemExit("monitor pidfd notification did not succeed")
if calls != ["monitor-pidfd-signal"]:
    raise SystemExit(f"monitor pidfd was not preferred: {calls}")
print("watchdog notification used pidfd signaling first")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${SANDBOX_REPO}/common/lock-holder.py"
    assert_success
    assert_output_contains "watchdog notification used pidfd signaling first"
}

@test "artifact publication stores only checksum-verified bytes" {
    local artifact_directory="${TEST_ROOT}/artifact-publication"
    local source_file="${artifact_directory}/source.bin"
    local destination_file="${artifact_directory}/destination.bin"
    local invalid_source="${artifact_directory}/invalid-source.bin"
    local invalid_destination="${artifact_directory}/invalid-destination.bin"
    local expected_checksum

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'verified bytes\n' > "${source_file}"
    printf 'old bytes\n' > "${destination_file}"
    printf 'invalid bytes\n' > "${invalid_source}"
    expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" publish \
        "${source_file}" "${destination_file}" "${expected_checksum}"
    assert_success
    assert_output_contains "${expected_checksum}"
    run cat "${destination_file}"
    assert_success
    assert_equal "${output}" "verified bytes"
    assert_file_absent "${source_file}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" publish \
        "${invalid_source}" "${invalid_destination}" "${expected_checksum}"
    assert_failure
    assert_output_contains "source checksum does not match"
    assert_file_exists "${invalid_source}"
    assert_file_absent "${invalid_destination}"
    run find "${artifact_directory}" -maxdepth 1 -name '.artifact-*.tmp' -print
    assert_success
    refute_output_contains ".artifact-"
}

@test "artifact publication rejects identical source and destination paths" {
    local artifact_directory="${TEST_ROOT}/artifact-identical-paths"
    local source_file="${artifact_directory}/artifact.bin"
    local expected_checksum

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'verified bytes\n' > "${source_file}"
    expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" publish \
        "${source_file}" "${source_file}" "${expected_checksum}"
    assert_failure
    assert_output_contains "must be different paths"
    run cat "${source_file}"
    assert_success
    assert_equal "${output}" "verified bytes"
}

@test "artifact publication preserves a source replaced during publication" {
    local artifact_directory="${TEST_ROOT}/artifact-source-race"
    local source_file="${artifact_directory}/source.bin"
    local destination_file="${artifact_directory}/destination.bin"
    local test_script="${TEST_ROOT}/source-race.py"
    local expected_checksum

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'verified bytes\n' > "${source_file}"
    expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_file", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

original_replace = module.os.replace


def replace_and_swap_source(source, destination, **keywords):
    original_replace(source, destination, **keywords)
    if os.path.basename(destination) == "destination.bin":
        os.unlink(sys.argv[2])
        descriptor = os.open(
            sys.argv[2],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            os.write(descriptor, b"replacement bytes\n")
        finally:
            os.close(descriptor)


module.os.replace = replace_and_swap_source
module.publish_file(sys.argv[2], sys.argv[3], sys.argv[4])
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/runtime-file.py" \
        "${source_file}" \
        "${destination_file}" \
        "${expected_checksum}"
    assert_success
    run cat "${destination_file}"
    assert_success
    assert_equal "${output}" "verified bytes"
    run cat "${source_file}"
    assert_success
    assert_equal "${output}" "replacement bytes"
}

@test "artifact publication preserves the verified source when replacement fails" {
    local artifact_directory="${TEST_ROOT}/artifact-replacement-failure"
    local source_file="${artifact_directory}/source.bin"
    local destination_file="${artifact_directory}/destination.bin"
    local test_script="${TEST_ROOT}/force-replace-failure.py"
    local expected_checksum

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'verified bytes\n' > "${source_file}"
    printf 'old bytes\n' > "${destination_file}"
    expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_file", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fail_replace(*_arguments, **_keywords):
    raise OSError(errno.EIO, "forced replacement failure")


module.os.replace = fail_replace
try:
    module.publish_file(sys.argv[2], sys.argv[3], sys.argv[4])
except OSError:
    pass
else:
    raise SystemExit("forced replacement failure was not reported")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/runtime-file.py" \
        "${source_file}" \
        "${destination_file}" \
        "${expected_checksum}"
    assert_success
    run cat "${source_file}"
    assert_success
    assert_equal "${output}" "verified bytes"
    run cat "${destination_file}"
    assert_success
    assert_equal "${output}" "old bytes"
    run find "${artifact_directory}" -maxdepth 1 -name '.artifact-*.tmp' -print
    assert_success
    refute_output_contains ".artifact-"
}

@test "a failed private copy does not remove an existing destination" {
    local artifact_directory="${TEST_ROOT}/copy-existing-destination"
    local source_file="${artifact_directory}/source.bin"
    local destination_file="${artifact_directory}/destination.bin"

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'source bytes\n' > "${source_file}"
    printf 'destination bytes\n' > "${destination_file}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" copy \
        "${source_file}" "${destination_file}"
    assert_failure
    run cat "${destination_file}"
    assert_success
    assert_equal "${output}" "destination bytes"
}

@test "rollback does not overwrite a concurrent destination replacement" {
    local artifact_directory="${TEST_ROOT}/rollback-concurrent-replacement"
    local destination_file="${artifact_directory}/fd"
    local backup_file="${artifact_directory}/backup/fd"
    local test_script="${TEST_ROOT}/rollback-race.py"
    local original_identity backup_identity staged_identity

    mkdir -p "${artifact_directory}/backup"
    chmod 0700 "${artifact_directory}" "${artifact_directory}/backup"
    printf 'staged bytes\n' > "${destination_file}"
    printf 'original bytes\n' > "${backup_file}"
    original_identity=$(stat -c '%d:%i' -- "${backup_file}")
    backup_identity="${original_identity}"
    staged_identity=$(stat -c '%d:%i' -- "${destination_file}")

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_file", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

original_rename_noreplace = module.rename_noreplace
injected = False


def racing_rename(source_parent, source_name, destination_parent, destination_name):
    global injected
    if source_name == "fd" and destination_name.startswith(".fd.rollback.") and not injected:
        injected = True
        os.unlink("fd", dir_fd=destination_parent)
        descriptor = os.open(
            "fd",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=destination_parent,
        )
        try:
            os.write(descriptor, b"concurrent bytes\n")
        finally:
            os.close(descriptor)
    return original_rename_noreplace(
        source_parent,
        source_name,
        destination_parent,
        destination_name,
    )


module.rename_noreplace = racing_rename
status = module.rollback_destination(
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
    sys.argv[6],
    True,
)
print(f"rollback-status={status}")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" \
        "${SANDBOX_REPO}/common/runtime-file.py" \
        "${destination_file}" \
        "${backup_file}" \
        "${original_identity}" \
        "${staged_identity}" \
        "${backup_identity}"
    assert_success
    assert_output_contains "rollback-status=3"
    run cat "${destination_file}"
    assert_success
    assert_equal "${output}" "concurrent bytes"
    run cat "${backup_file}"
    assert_success
    assert_equal "${output}" "original bytes"
}

@test "cache pruning removes stale interrupted artifact files" {
    local artifact_directory="${TEST_ROOT}/artifact-pruning"
    local stale_file="${artifact_directory}/.artifact-stale.tmp"
    local recent_file="${artifact_directory}/.artifact-recent.tmp"
    local cached_file="${artifact_directory}/artifact.tar.gz"

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'stale\n' > "${stale_file}"
    printf 'recent\n' > "${recent_file}"
    printf 'cached\n' > "${cached_file}"
    touch -d '2 hours ago' "${stale_file}"

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SANDBOX_REPO}/common/runtime-file.py" prune \
        "${artifact_directory}" "artifact.tar.gz"
    assert_success
    assert_file_absent "${stale_file}"
    assert_file_exists "${recent_file}"
    assert_file_exists "${cached_file}"
}

@test "runtime writes structured log entries" {
    run_runtime "runtime_log 'INFO' 'test message'"
    assert_success

    run grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] INFO  test message$' "${LOG_FILE}"
    assert_success
}
