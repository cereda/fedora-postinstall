#!/usr/bin/env bats

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
    write_module "declined-question.sh" "source '${SANDBOX_REPO}/common/gum-functions.sh'; question 'Continue?'; if [ \$? -eq 0 ]; then printf 'accepted\\n'; else printf 'declined\\n'; fi"

    run_runtime "runtime_run_module 'modules/declined-question.sh'"
    assert_success
    assert_output_contains "declined"
    refute_output_contains "Command 'return 1' failed"
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

@test "runtime writes structured log entries" {
    run_runtime "runtime_log 'INFO' 'test message'"
    assert_success

    run grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] INFO  test message$' "${LOG_FILE}"
    assert_success
}
