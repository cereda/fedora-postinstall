#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

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

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        POSTINSTALL_CACHE_DIR="${cache_dir}" \
        POSTINSTALL_LOCK_FILE="${lock_file}" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock || exit $?
            sleep 2 &
            printf "%s\n" "$!" > "$2"
        ' _ "${SANDBOX_REPO}" "${child_pid_file}"
    assert_success

    local child_pid
    child_pid=$(cat "${child_pid_file}")
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
    kill "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
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
    run grep -E 'unable to lock file|installation lock was lost' "${output_file}"
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
    assert_file_absent "${decision_file}"
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
    local probe_marker="${pid_directory}/probe"
    local status_file
    local supervisor_pid
    local wrapper_pid
    local installer_pid
    local installer_status=0
    local lock_status=0
    local final_lock_status=0
    local decision_file
    local decision_state=""
    local attempt
    local -a status_lines=()

    mkdir -p "${pid_directory}" "${mock_bin}"
    cat > "${mock_bin}/flock" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "${argument}" = "true" ]; then
        : > "${MOCK_FLOCK_PROBE_MARKER}"
        for attempt in {1..200}; do
            if [ -e "${MOCK_FLOCK_RELEASE}" ]; then
                break
            fi
            sleep 0.05
        done
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
        MOCK_FLOCK_PROBE_MARKER="${probe_marker}" \
        MOCK_FLOCK_RELEASE="${pid_directory}/release" \
        bash -c '
            source "$1/common/runtime.sh"
            runtime_acquire_install_lock
            acquisition_status=$?
            if [ "${acquisition_status}" -eq 0 ]; then
                printf "held=1\n" > "$2/held"
            fi
            while [ ! -e "$2/release" ]; do sleep 0.05; done
            exit "${acquisition_status}"
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -e "${probe_marker}" ] && [ -n "${status_file}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${probe_marker}" ] || [ -z "${status_file}" ]; then
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    mapfile -t status_lines < "${status_file}"
    supervisor_pid="${status_lines[0]}"
    wrapper_pid="${status_lines[5]}"
    kill -USR2 "${wrapper_pid}" 2>/dev/null || true
    kill -USR2 "${supervisor_pid}" 2>/dev/null || true

    decision_file=""
    for ((attempt = 0; attempt < 100; attempt++)); do
        decision_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.decision' -print -quit 2>/dev/null || true)
        if [ -n "${decision_file}" ]; then
            decision_state=$(cat "${decision_file}")
            if [ "${decision_state}" = "cancelled" ]; then
                break
            fi
        fi
        sleep 0.05
    done

    /usr/bin/flock --exclusive --nonblock "${lock_file}" true ||
        lock_status="${?}"
    : > "${pid_directory}/release"
    wait "${installer_pid}" || installer_status="${?}"
    for ((attempt = 0; attempt < 100; attempt++)); do
        if /usr/bin/flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    /usr/bin/flock --exclusive --nonblock "${lock_file}" true ||
        final_lock_status="${?}"

    assert_equal "${installer_status}" "73"
    assert_file_absent "${pid_directory}/held"
    assert_equal "${decision_state}" "cancelled"
    assert_equal "${lock_status}" "1"
    assert_equal "${final_lock_status}" "0"
    assert_file_absent "${decision_file}"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock acquisition was cancelled"
}

@test "watchdog SIGUSR2 cancels acquisition and retains the lock through cleanup" {
    local cache_dir="${TEST_ROOT}/watchdog-usr2-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local pid_directory="${TEST_ROOT}/watchdog-usr2"
    local output_file="${TEST_ROOT}/watchdog-usr2.out"
    local mock_bin="${TEST_ROOT}/watchdog-usr2-bin"
    local probe_marker="${pid_directory}/probe"
    local status_file
    local decision_file
    local decision_state=""
    local watchdog_pid
    local installer_pid
    local installer_status=0
    local installer_state
    local watchdog_state
    local attempt

    mkdir -p "${pid_directory}" "${mock_bin}"
    cat > "${mock_bin}/flock" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "${argument}" = "true" ]; then
        : > "${MOCK_FLOCK_PROBE_MARKER}"
        for attempt in {1..200}; do
            if [ -e "${MOCK_FLOCK_RELEASE}" ]; then
                break
            fi
            sleep 0.05
        done
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
        MOCK_FLOCK_PROBE_MARKER="${probe_marker}" \
        MOCK_FLOCK_RELEASE="${pid_directory}/probe-release" \
        bash -c '
            source "$1/common/runtime.sh"
            cleanup_directory="$2"
            runtime_initialize || exit $?

            function watchdog_usr2_cleanup {
                local cleanup_attempt=0
                : > "${cleanup_directory}/cleanup-started"
                while [ ! -e "${cleanup_directory}/cleanup-release" ] && [ "${cleanup_attempt}" -lt 200 ]; do
                    if /usr/bin/flock --exclusive --nonblock "$POSTINSTALL_LOCK_FILE" true; then
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
            runtime_register_cleanup "watchdog-usr2-cleanup" watchdog_usr2_cleanup || exit $?
            runtime_acquire_install_lock
            acquisition_status=$?
            printf "acquisition-status=%s\n" "${acquisition_status}"
            while :; do sleep 0.2; done
        ' _ "${SANDBOX_REPO}" "${pid_directory}" >"${output_file}" 2>&1 &
    installer_pid="${!}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        status_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.acquired' -print -quit 2>/dev/null || true)
        if [ -e "${probe_marker}" ] && [ -n "${status_file}" ]; then
            break
        fi
        sleep 0.05
    done
    if [ ! -e "${probe_marker}" ] || [ -z "${status_file}" ]; then
        : > "${pid_directory}/probe-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    watchdog_pid=$(sed -n '9p' "${status_file}")
    if ! [[ "${watchdog_pid}" =~ ^[0-9]+$ ]]; then
        : > "${pid_directory}/probe-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    kill -USR2 "${watchdog_pid}" 2>/dev/null || true

    for ((attempt = 0; attempt < 200; attempt++)); do
        decision_file=$(find "${cache_dir}" -maxdepth 1 -type f -name '.postinstall-lock-*.decision' -print -quit 2>/dev/null || true)
        if [ -n "${decision_file}" ] &&
            [ -e "${pid_directory}/cleanup-started" ] &&
            [ -e "${pid_directory}/lock-held" ]; then
            decision_state=$(cat "${decision_file}" 2>/dev/null || true)
            if [ "${decision_state}" = "cancelled" ]; then
                break
            fi
        fi
        sleep 0.05
    done
    if [ "${decision_state}" != "cancelled" ] ||
        [ ! -e "${pid_directory}/cleanup-started" ] ||
        [ ! -e "${pid_directory}/lock-held" ]; then
        : > "${pid_directory}/probe-release"
        : > "${pid_directory}/cleanup-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    watchdog_state=$(ps -o stat= -p "${watchdog_pid}" 2>/dev/null || true)
    if [ -z "${watchdog_state}" ] || [[ "${watchdog_state}" == Z* ]]; then
        : > "${pid_directory}/probe-release"
        : > "${pid_directory}/cleanup-release"
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi
    run flock --exclusive --nonblock "${lock_file}" true
    assert_failure

    : > "${pid_directory}/probe-release"
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
        kill -TERM "${installer_pid}" 2>/dev/null || true
        wait "${installer_pid}" 2>/dev/null || true
        return 1
    fi

    wait "${installer_pid}" || installer_status="${?}"
    assert_equal "${installer_status}" "73"
    assert_file_exists "${pid_directory}/cleanup-complete"
    assert_file_absent "${pid_directory}/cleanup-timeout"
    assert_file_absent "${pid_directory}/lock-released"
    run cat "${output_file}"
    assert_success
    assert_output_contains "installation lock acquisition was cancelled"

    for ((attempt = 0; attempt < 200; attempt++)); do
        if flock --exclusive --nonblock "${lock_file}" true; then
            break
        fi
        sleep 0.05
    done
    run flock --exclusive --nonblock "${lock_file}" true
    assert_success
}

@test "release retains decision state for cleanup loss classification" {
    local cache_dir="${TEST_ROOT}/decision-lifetime-cache"
    local cancelled_decision="${cache_dir}/cancelled.decision"
    local committed_decision="${cache_dir}/committed.decision"

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
        ' _ "${SANDBOX_REPO}" "${cancelled_decision}"
    assert_success
    assert_output_contains "decision=${cancelled_decision} acquired=1 held=0 pending=73 name=lock-cancelled"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_ROOT}/home" \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_HELD=1
            RUNTIME_LOCK_ACQUIRED=1
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
        ' _ "${SANDBOX_REPO}" "${committed_decision}"
    assert_success
    assert_output_contains "decision=${committed_decision} acquired=1 held=0 pending=141 name=lock-loss"
}

@test "a post-commit validation failure returns 73 without waiting for the guardian" {
    local cache_dir="${TEST_ROOT}/post-commit-validation-cache"
    local lock_file="${cache_dir}/postinstall.lock"
    local mock_bin="${TEST_ROOT}/post-commit-validation-bin"
    local counter_file="${TEST_ROOT}/post-commit-validation.count"
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
                while [ ! -e "${cleanup_directory}/cleanup-release" ] && [ "${cleanup_attempt}" -lt 200 ]; do
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
            trap ":" USR2
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

            function lock_loss_signal_cleanup {
                printf "started\n" > "${cleanup_directory}/cleanup-started"
                kill -TERM "$BASHPID"
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


def flaky_kill(process_id, signal_number):
    attempts.append((process_id, signal_number))
    if len(attempts) == 1:
        raise OSError(errno.EAGAIN, "transient signal failure")
    return None


module.open_verified_installer_pidfd = lambda _process_id, _identity: -1
module.os.kill = flaky_kill
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
