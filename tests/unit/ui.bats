#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/ui"
    STDOUT_FILE="${TEST_ROOT}/stdout"
    STDERR_FILE="${TEST_ROOT}/stderr"
    GUM_MARKER="${TEST_ROOT}/gum-called"
    GUM_LOG="${TEST_ROOT}/gum-arguments"

    mkdir -p "${TEST_ROOT}"
}

@test "static messages do not invoke gum" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"${MOCK_GUM_MARKER}"
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_GUM_MARKER="${GUM_MARKER}" \
        PATH="${TEST_ROOT}:${PATH}" \
        bash -c '
            source "$1/common/ui.sh"
            ui_title "Fedora post-installer"
            ui_section "Useful packages"
            ui_step "Installing packages."
            ui_success "Packages installed."
            ui_warning "A warning."
            ui_error "An error."
        ' _ "${REPO_ROOT}"

    assert_success
    assert_file_absent "${GUM_MARKER}"
}

@test "modules do not invoke Gum directly" {
    run bash -c '
        cd "$1" || exit 1
        grep -RIl -w --include="*.sh" GUM \
            common extras workstation silverblue fedora-postinstall.sh | sort
    ' _ "${REPO_ROOT}"

    assert_success
    assert_equal "${output}" $'common/gum-setup.sh\ncommon/ui-prompts.sh'

    run bash -c '
        cd "$1" || exit 1
        grep -RInE --include="*.sh" \
            "(^|[[:space:];|&()])gum[[:space:]]+(choose|confirm|input|file)([[:space:]]|$)" \
            common extras workstation silverblue fedora-postinstall.sh
    ' _ "${REPO_ROOT}"

    assert_failure
    assert_equal "${output}" ""
}

@test "normal messages use stdout while warnings and errors use stderr" {
    run bash -c '
        source "$1/common/ui.sh"
        exec >"$2" 2>"$3"
        ui_step "Installing packages."
        ui_success "Packages installed."
        ui_warning "A prerequisite is missing."
        ui_error "Could not install packages."
    ' _ "${REPO_ROOT}" "${STDOUT_FILE}" "${STDERR_FILE}"

    assert_success
    run cat "${STDOUT_FILE}"
    assert_success
    assert_output_contains "info: Installing packages."
    assert_output_contains "done: Packages installed."
    refute_output_contains "warning:"
    refute_output_contains "error:"

    run cat "${STDERR_FILE}"
    assert_success
    assert_output_contains "warning: A prerequisite is missing."
    assert_output_contains "error: Could not install packages."
    refute_output_contains "Installing packages."
}

@test "plain output has labels and no ANSI escape sequences" {
    run env \
        NO_COLOR=1 \
        TERM=dumb \
        UI_COLOR_OVERRIDE=auto \
        bash -c '
            source "$1/common/ui.sh"
            exec >"$2" 2>"$3"
            ui_step "Installing packages."
            ui_success "Packages installed."
            ui_warning "A prerequisite is missing."
            ui_error "Could not install packages."
        ' _ "${REPO_ROOT}" "${STDOUT_FILE}" "${STDERR_FILE}"

    assert_success
    run cat "${STDOUT_FILE}" "${STDERR_FILE}"
    assert_success
    refute_output_contains $'\033'
    assert_output_contains "info: Installing packages."
    assert_output_contains "done: Packages installed."
    assert_output_contains "warning: A prerequisite is missing."
    assert_output_contains "error: Could not install packages."
}

@test "forced color output uses semantic status markers" {
    run env \
        -u NO_COLOR \
        TERM=xterm \
        UI_COLOR_OVERRIDE=always \
        bash -c '
            source "$1/common/ui.sh"
            exec >"$2" 2>"$3"
            ui_step "Installing packages."
            ui_success "Packages installed."
            ui_warning "A prerequisite is missing."
            ui_error "Could not install packages."
        ' _ "${REPO_ROOT}" "${STDOUT_FILE}" "${STDERR_FILE}"

    assert_success
    run cat "${STDOUT_FILE}" "${STDERR_FILE}"
    assert_success
    assert_output_contains "• Installing packages."
    assert_output_contains "✓ Packages installed."
    assert_output_contains "! A prerequisite is missing."
    assert_output_contains "✗ Could not install packages."
    assert_output_contains $'\033'
}

@test "directory selection is directory-only and starts at the requested path" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${MOCK_GUM_LOG}"
printf '%s\n' "${MOCK_GUM_RESULT}"
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/gum" \
        HOME="${TEST_ROOT}/home" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        MOCK_GUM_RESULT="${TEST_ROOT}/home/selected" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_select_directory "${HOME}"
        ' _ "${REPO_ROOT}"

    assert_success
    assert_output_contains "${TEST_ROOT}/home/selected"

    run cat "${GUM_LOG}"
    assert_success
    assert_equal "${output}" $'file\n--all\n--permissions\n--file=false\n--directory\n'"${TEST_ROOT}"'/home'
}

@test "confirmation adapter distinguishes a decline from a status-one failure" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${MOCK_GUM_LOG}"
if [ "${MOCK_CONFIRM_OUTPUT:-1}" -eq 1 ]; then
    printf '%s\n' "${MOCK_CONFIRM_OUTPUT_VALUE:-Continue? Skip}"
fi
exit "${MOCK_CONFIRM_STATUS:-1}"
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_CONFIRM_STATUS=1 \
        MOCK_CONFIRM_OUTPUT=1 \
        MOCK_GUM_LOG="${GUM_LOG}" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_confirm "Continue?" "Install" "Skip"
        ' _ "${REPO_ROOT}"

    assert_equal "${status}" 1
    refute_output_contains "Prompt failed"

    run cat "${GUM_LOG}"
    assert_success
    assert_equal "${output}" $'confirm\n--show-output\n--prompt.foreground=6\n--selected.background=6\n--affirmative=Install\n--negative=Skip\nContinue?'

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_CONFIRM_STATUS=1 \
        MOCK_CONFIRM_OUTPUT=0 \
        MOCK_GUM_LOG="${GUM_LOG}" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_confirm "Continue?" "Install" "Skip"
        ' _ "${REPO_ROOT}"

    assert_equal "${status}" 1
    assert_output_contains "Prompt failed with status 1"

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_CONFIRM_STATUS=1 \
        MOCK_CONFIRM_OUTPUT=1 \
        MOCK_CONFIRM_OUTPUT_VALUE="backend diagnostic on stdout" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_confirm "Continue?" "Install" "Skip"
        ' _ "${REPO_ROOT}"

    assert_equal "${status}" 1
    assert_output_contains "Prompt failed with status 1"
}

@test "a piped status-one response without selection output is an operational failure" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
read -r _response || true
exit 1
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/gum" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_confirm "Continue?" "Install" "Skip"
        ' _ "${REPO_ROOT}" <<<"n"

    assert_equal "${status}" 1
    assert_output_contains "error: Prompt failed with status 1"
    refute_output_contains "declined"
}

@test "extras progress helpers preserve UI output failures" {
    run bash -c '
        source "$1/extras/tools-download.sh"
        ui_step() { return 7; }
        extras_report_step "Progress failed."
    ' _ "${REPO_ROOT}"

    assert_equal "${status}" 7
}

@test "an invalid configured prompt backend is not silently replaced" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"${MOCK_GUM_MARKER}"
printf '%s\n' selected
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/missing-gum" \
        MOCK_GUM_MARKER="${GUM_MARKER}" \
        PATH="${TEST_ROOT}:${PATH}" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            prompt_status=0
            ui_choose_one "Select one" "selected" || prompt_status="${?}"
            printf "status=%s\n" "${prompt_status}"
            test "${prompt_status}" -eq 127
        ' _ "${REPO_ROOT}"

    assert_success
    assert_output_contains "status=127"
    assert_output_contains "configured interactive prompt backend is unavailable"
    assert_file_absent "${GUM_MARKER}"
}

@test "choice and input adapters preserve status and exact arguments" {
    cat >"${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${MOCK_GUM_LOG}"
case "${1:-}" in
choose)
    printf '%s\n' "${MOCK_GUM_RESULT:-selected}"
    ;;
input)
    printf '%s\n' "${MOCK_GUM_RESULT:-value}"
    ;;
esac
exit "${MOCK_GUM_STATUS:-0}"
EOF
    chmod +x "${TEST_ROOT}/gum"

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        MOCK_GUM_RESULT="selected" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_choose_one "Select one" "first" "second"
        ' _ "${REPO_ROOT}"

    assert_success
    assert_output_contains "selected"
    run cat "${GUM_LOG}"
    assert_success
    assert_equal "${output}" $'choose\n--header=Select one\nfirst\nsecond'

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        MOCK_GUM_RESULT="first" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_choose_many "Select many" "*" "first" "second"
        ' _ "${REPO_ROOT}"

    assert_success
    run cat "${GUM_LOG}"
    assert_success
    assert_equal "${output}" $'choose\n--no-limit\n--height=15\n--header=Select many\n--selected=*\nfirst\nsecond'

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        MOCK_GUM_RESULT="typed" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_input "Name: " "default"
        ' _ "${REPO_ROOT}"

    assert_success
    assert_output_contains "typed"
    run cat "${GUM_LOG}"
    assert_success
    assert_equal "${output}" $'input\n--prompt=Name: \n--value=default'

    run env \
        GUM="${TEST_ROOT}/gum" \
        MOCK_GUM_LOG="${GUM_LOG}" \
        MOCK_GUM_STATUS=7 \
        bash -c '
            source "$1/common/ui-prompts.sh"
            ui_choose_one "Select one" "first"
        ' _ "${REPO_ROOT}"

    assert_equal "${status}" 7
}
