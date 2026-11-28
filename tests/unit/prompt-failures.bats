#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/prompt-failures"
    HOME_DIR="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    FILE_COUNTER="${TEST_ROOT}/file-chooser-calls"
    TMP_ROOT="${TEST_ROOT}/tmp"
    VALID_DIRECTORY="${HOME_DIR}/selected"
    INVALID_DIRECTORY="${TEST_ROOT}/outside-home"

    mkdir -p \
        "${HOME_DIR}" \
        "${MOCK_BIN}" \
        "${TMP_ROOT}" \
        "${VALID_DIRECTORY}" \
        "${INVALID_DIRECTORY}"
    : >"${HOME_DIR}/.bashrc"

    cat >"${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
confirm)
    if [ "${MOCK_CONFIRM_STATUS:-0}" -eq 1 ] &&
        [ "${MOCK_CONFIRM_NO_OUTPUT:-0}" -ne 1 ]; then
        confirm_prompt="${!#}"
        confirm_negative="No"
        for confirm_argument in "$@"; do
            case "${confirm_argument}" in
            --negative=*) confirm_negative="${confirm_argument#--negative=}" ;;
            esac
        done
        printf '%s %s\n' "${confirm_prompt}" "${confirm_negative}"
    fi
    exit "${MOCK_CONFIRM_STATUS:-0}"
    ;;
file)
    count=0
    if [ -f "${MOCK_FILE_COUNTER}" ]; then
        count="$(wc -l <"${MOCK_FILE_COUNTER}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" >>"${MOCK_FILE_COUNTER}"

    case "${MOCK_FILE_MODE:-selected}" in
    selected)
        printf '%s\n' "${MOCK_FILE_PATH:-${MOCK_FILE_FALLBACK_PATH}}"
        ;;
    cancel)
        if [ "${count}" -eq 1 ]; then
            exit 1
        fi
        printf '%s\n' "${MOCK_FILE_FALLBACK_PATH}"
        ;;
    empty)
        if [ "${count}" -eq 1 ]; then
            exit 0
        fi
        printf '%s\n' "${MOCK_FILE_FALLBACK_PATH}"
        ;;
    fail)
        if [ "${count}" -eq 1 ]; then
            exit "${MOCK_FILE_STATUS:-7}"
        fi
        printf '%s\n' "${MOCK_FILE_FALLBACK_PATH}"
        ;;
    invalid)
        if [ "${count}" -le 3 ]; then
            printf '%s\n' "${MOCK_FILE_INVALID_PATH}"
        else
            printf '%s\n' "${MOCK_FILE_FALLBACK_PATH}"
        fi
        ;;
    esac
    ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/gum"
}

run_confirmation() {
    local confirm_status="${1}"
    local confirm_no_output="${2:-0}"

    run --separate-stderr env \
        GUM="${MOCK_BIN}/gum" \
        MOCK_CONFIRM_STATUS="${confirm_status}" \
        MOCK_CONFIRM_NO_OUTPUT="${confirm_no_output}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/ui-prompts.sh"
            if ui_confirm "Continue?"; then
                printf "accepted\n"
            else
                printf "declined\n"
            fi
        ' _ "${REPO_ROOT}"
}

run_home_configuration() {
    local flavor="${1}"
    local confirm_status="${2}"
    local file_mode="${3}"
    local file_status="${4}"
    local selected_directory="${5:-${VALID_DIRECTORY}}"

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        GUM="${MOCK_BIN}/gum" \
        FLATPAKS_KEEP_CACHE_IDS_JSON="[]" \
        MACHINE_NAME="test-machine" \
        MOCK_CONFIRM_STATUS="${confirm_status}" \
        MOCK_FILE_COUNTER="${FILE_COUNTER}" \
        MOCK_FILE_FALLBACK_PATH="${selected_directory}" \
        MOCK_FILE_INVALID_PATH="${INVALID_DIRECTORY}" \
        MOCK_FILE_MODE="${file_mode}" \
        MOCK_FILE_PATH="${selected_directory}" \
        MOCK_FILE_STATUS="${file_status}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/ui.sh"
            source "$1/common/ui-prompts.sh"
            source "$1/common/validation.sh"
            source "$2"
        ' _ "${REPO_ROOT}" "${REPO_ROOT}/${flavor}/home-configuration.sh"
}

run_home_configuration_without_retention() {
    local flavor="${1}"
    local confirm_status="${2}"
    local file_mode="${3}"
    local file_status="${4}"

    run --separate-stderr env \
        -u FLATPAKS_KEEP_CACHE_IDS_JSON \
        HOME="${HOME_DIR}" \
        GUM="${MOCK_BIN}/gum" \
        MACHINE_NAME="test-machine" \
        MOCK_CONFIRM_STATUS="${confirm_status}" \
        MOCK_FILE_COUNTER="${FILE_COUNTER}" \
        MOCK_FILE_FALLBACK_PATH="${VALID_DIRECTORY}" \
        MOCK_FILE_INVALID_PATH="${INVALID_DIRECTORY}" \
        MOCK_FILE_MODE="${file_mode}" \
        MOCK_FILE_PATH="${VALID_DIRECTORY}" \
        MOCK_FILE_STATUS="${file_status}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/ui.sh"
            source "$1/common/ui-prompts.sh"
            source "$1/common/validation.sh"
            source "$2"
        ' _ "${REPO_ROOT}" "${REPO_ROOT}/${flavor}/home-configuration.sh"
}

run_home_configuration_with_retention() {
    local flavor="${1}"
    local retention_state="${2}"
    local confirm_status="${3}"
    local file_mode="${4}"
    local file_status="${5}"

    run --separate-stderr env \
        FLATPAKS_KEEP_CACHE_IDS_JSON="${retention_state}" \
        HOME="${HOME_DIR}" \
        GUM="${MOCK_BIN}/gum" \
        MACHINE_NAME="test-machine" \
        MOCK_CONFIRM_STATUS="${confirm_status}" \
        MOCK_FILE_COUNTER="${FILE_COUNTER}" \
        MOCK_FILE_FALLBACK_PATH="${VALID_DIRECTORY}" \
        MOCK_FILE_INVALID_PATH="${INVALID_DIRECTORY}" \
        MOCK_FILE_MODE="${file_mode}" \
        MOCK_FILE_PATH="${VALID_DIRECTORY}" \
        MOCK_FILE_STATUS="${file_status}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/ui.sh"
            source "$1/common/ui-prompts.sh"
            source "$1/common/validation.sh"
            source "$2"
        ' _ "${REPO_ROOT}" "${REPO_ROOT}/${flavor}/home-configuration.sh"
}

assert_file_call_count() {
    local expected="${1}"

    run bash -c 'wc -l <"$1" | tr -d "[:space:]"' _ "${FILE_COUNTER}"
    assert_success
    assert_equal "${output}" "${expected}"
}

run_generated_helper() {
    local action="${1}"
    local target="${2}"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        bash -c '
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" "${action}" "${target}" < /dev/null
}

run_generated_helper_with_input() {
    local action="${1}"
    local target="${2}"
    local input="${3:-}"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    shift 3
    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        python3 "${REPO_ROOT}/tests/helpers/run-with-pty.py" \
        --stdin-only \
        --stderr-tty \
        --input "${input}" \
        -- \
        bash -c '
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" "${action}" "${target}" "$@"
}

run_generated_helper_with_read_status() {
    local read_status="${1}"
    local action="${2}"
    local target="${3}"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        MOCK_READ_STATUS="${read_status}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        python3 "${REPO_ROOT}/tests/helpers/run-with-pty.py" \
        --stdin-only \
        --stderr-tty \
        -- \
        bash -c '
            read() { return "${MOCK_READ_STATUS}"; }
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" "${action}" "${target}"
}

@test "confirmation accepts the affirmative response" {
    run_confirmation 0

    assert_success
    assert_output_contains "accepted"
    refute_output_contains "declined"
}

@test "confirmation preserves the normal decline response" {
    run_confirmation 1

    assert_success
    assert_output_contains "declined"
    refute_output_contains "Prompt failed"
}

@test "confirmation aborts on an operational Gum failure" {
    run_confirmation 7

    assert_equal "${status}" 7
    assert_stderr_contains "Prompt failed with status 7"
    refute_output_contains "accepted"
    refute_output_contains "declined"
}

@test "confirmation does not mistake a status-one backend failure for a decline" {
    run_confirmation 1 1

    assert_equal "${status}" 1
    assert_stderr_contains "Prompt failed with status 1"
    refute_output_contains "declined"
}

@test "home configuration aborts when the hidden-directory prompt fails" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 7 selected 0

        assert_equal "${status}" 7
        assert_stderr_contains "Prompt failed with status 7"
        assert_file_absent "${FILE_COUNTER}"
        assert_file_absent "${HOME_DIR}/.test-machine"
    done
}

@test "home configuration aborts when directory selection is cancelled" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 cancel 0

        assert_equal "${status}" 1
        assert_stderr_contains "Directory selection was cancelled"
        assert_file_call_count 1
        assert_file_absent "${HOME_DIR}/.test-machine"
    done
}

@test "home configuration aborts when the directory chooser returns no path" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 empty 0

        assert_equal "${status}" 1
        assert_stderr_contains "No directory was selected"
        assert_file_call_count 1
        assert_file_absent "${HOME_DIR}/.test-machine"
    done
}

@test "home configuration aborts on an operational directory chooser failure" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 fail 7

        assert_equal "${status}" 7
        assert_stderr_contains "Unable to select a directory (status 7)"
        assert_file_call_count 1
        assert_file_absent "${HOME_DIR}/.test-machine"
    done
}

@test "home configuration bounds retries for unsafe directory selections" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 invalid 0

        assert_equal "${status}" 1
        assert_stderr_contains "after 3 attempts"
        assert_file_call_count 3
        assert_file_absent "${HOME_DIR}/.test-machine"
    done
}

@test "home configuration preserves runtime toolbox path expressions" {
    local flavor
    local expected_path
    local toolbox_file="${VALID_DIRECTORY}/scripts/toolbox.sh"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run cat "${toolbox_file}"
        assert_success
        assert_output_contains 'echo $PATH'
        assert_output_contains '(^|:)$1($|:)'
        assert_output_contains 'if [ "$2" = "after" ]'
        assert_output_contains 'PATH=$PATH:$1'
        assert_output_contains 'PATH=$1:$PATH'
        refute_output_contains '\$PATH'
        refute_output_contains '\$1'
        refute_output_contains '\$2'
        refute_output_contains '${ROOT_DIRECTORY_STRUCTURE}'

        case "${flavor}" in
        workstation)
            expected_path="/var/run/host/opt/texbin"
            ;;
        silverblue)
            expected_path="${VALID_DIRECTORY}/applications/texlive/current"
            ;;
        esac
        run grep -F "pathmunge ${expected_path} after" "${toolbox_file}"
        assert_success
    done
}

@test "home configuration accepts a valid directory selection" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0

        assert_success
        assert_file_call_count 1
        assert_file_exists "${VALID_DIRECTORY}/scripts/bash.sh"
    done
}

@test "home configuration rejects a symbolic-link managed root" {
    local flavor
    local selected_link="${HOME_DIR}/selected-link"

    ln -s "${VALID_DIRECTORY}" "${selected_link}"
    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        rm -rf "${VALID_DIRECTORY}/scripts"

        run_home_configuration "${flavor}" 1 selected 0 "${selected_link}"

        assert_equal "${status}" "1"
        assert_stderr_contains "non-symbolic-link"
        assert_file_call_count 3
        assert_file_absent "${VALID_DIRECTORY}/scripts/bash.sh"
    done
}

@test "home configuration rejects a symbolic-link managed child" {
    local flavor
    local selected_directory="${HOME_DIR}/selected-with-linked-child"
    local outside_directory="${TEST_ROOT}/outside-child"

    mkdir -p "${selected_directory}" "${outside_directory}"
    ln -s "${outside_directory}" "${selected_directory}/scripts"
    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"

        run_home_configuration "${flavor}" 1 selected 0 "${selected_directory}"

        assert_equal "${status}" "1"
        assert_stderr_contains "symbolic links"
        assert_file_call_count 3
        assert_file_absent "${outside_directory}/bash.sh"
    done
}

@test "home configuration accepts a symbolic-link home and updates the canonical Bash entry point" {
    local flavor
    local home_link="${TEST_ROOT}/home-link"

    ln -s "${HOME_DIR}" "${home_link}"
    for flavor in workstation silverblue; do
        run --separate-stderr env \
            HOME="${home_link}" \
            GUM="${MOCK_BIN}/gum" \
            FLATPAKS_KEEP_CACHE_IDS_JSON="[]" \
            MACHINE_NAME="test-machine" \
            MOCK_CONFIRM_STATUS=0 \
            PATH="${MOCK_BIN}:/usr/bin:/bin" \
            bash -c '
                source "$1/common/ui.sh"
                source "$1/common/ui-prompts.sh"
                source "$1/common/validation.sh"
                source "$2"
            ' _ "${REPO_ROOT}" "${REPO_ROOT}/${flavor}/home-configuration.sh"
        assert_success

        run grep -F "source ${HOME_DIR}/.test-machine/scripts/bash.sh" \
            "${HOME_DIR}/.bashrc"
        assert_success
    done
}

@test "generated Firefox cleanup requires a terminal before cleanup" {
    local flavor
    local cleanup_marker="${TEST_ROOT}/firefox-cleanup-called"

    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "firefox" ]; then
    exit 0
fi
exit 1
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
    run)
        : > "${MOCK_CLEANUP_MARKER}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/pidof" "${MOCK_BIN}/bleachbit" "${MOCK_BIN}/flatpak"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${cleanup_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper clean cache
        assert_equal "${status}" 64
        assert_stderr_contains "terminal is required"
        assert_file_absent "${cleanup_marker}"
    done
}

@test "generated application-grid reset restores the GNOME schema default" {
    local gsettings_log="${TEST_ROOT}/gsettings-calls"

    cat > "${MOCK_BIN}/gsettings" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_GSETTINGS_LOG}"
exit "${MOCK_GSETTINGS_STATUS:-0}"
EOF
    chmod +x "${MOCK_BIN}/gsettings"
    export MOCK_GSETTINGS_LOG="${gsettings_log}"

    run_home_configuration workstation 1 selected 0
    assert_success

    run_generated_helper_with_input config reset "" app-grid
    assert_success
    run cat "${gsettings_log}"
    assert_success
    assert_equal "${output}" "reset org.gnome.shell app-picker-layout"
}

@test "generated application-grid reset preserves the schema reset failure" {
    cat > "${MOCK_BIN}/gsettings" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
    chmod +x "${MOCK_BIN}/gsettings"

    run_home_configuration workstation 1 selected 0
    assert_success

    run_generated_helper_with_input config reset "" app-grid
    assert_equal "${status}" "9"
}

@test "generated Flatpak permission reset exports the real table before resetting each application" {
    local flavor
    local permission_log="${TEST_ROOT}/flatpak-permission-resets"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        printf 'notifications\tnotification\tcom.example.First\tyes\t0x00\n'
        printf 'notifications\tshared\tcom.example.First\tyes\t0x01\n'
        printf 'notifications\tnotification\tcom.example.Second\tyes\t0x00\n'
        printf 'notifications\tglobal\t\tyes\t0x00\n'
        printf 'notifications\tglobal\t\tyes\t0x00\n'
        ;;
    permission-reset)
        if [ "$#" -ne 2 ]; then
            printf 'unexpected argument count: %s\n' "$#" >&2
            exit 9
        fi
        printf '%s\n' "${2:-}" >> "${MOCK_PERMISSION_LOG}"
        ;;
    permission-remove)
        if [ "$#" -ne 3 ]; then
            printf 'unexpected argument count: %s\n' "$#" >&2
            exit 9
        fi
        printf '%s:%s\n' "${2:-}" "${3:-}" >> "${MOCK_PERMISSION_LOG}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_PERMISSION_LOG="${permission_log}"

    for flavor in workstation silverblue; do
        : > "${permission_log}"
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper_with_input clean permissions "RESET" reset
        assert_success
        run cat "${permission_log}"
        assert_success
        assert_equal "${output}" $'com.example.First\ncom.example.Second\nnotifications:global'

        run stat -c '%a' "${HOME_DIR}/.host/backups/flatpak-permissions"
        assert_success
        assert_equal "${output}" "700"
        run bash -c '
            find "$1" -type f -name "flatpak-permissions-*.txt" \
                -exec stat -c "%a" {} \; |
                awk "BEGIN { found = 0 } { found = 1; if (\$1 != \"600\") exit 1 } END { exit(found ? 0 : 1) }"
        ' _ "${HOME_DIR}/.host/backups/flatpak-permissions"
        assert_success
    done
}

@test "generated destructive confirmation requires the prompt destination to be a terminal" {
    local permission_log="${TEST_ROOT}/flatpak-permission-redirected-stderr"
    local stderr_file="${TEST_ROOT}/generated-helper-stderr"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        printf 'notifications\tnotification\tcom.example.First\tyes\t0x00\n'
        ;;
    permission-reset)
        printf '%s\n' "${2:-}" >> "${MOCK_PERMISSION_LOG}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_PERMISSION_LOG="${permission_log}"

    run_home_configuration workstation 1 selected 0
    assert_success

    run env \
        HOME="${HOME_DIR}" \
        MOCK_STDERR_FILE="${stderr_file}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        python3 "${REPO_ROOT}/tests/helpers/run-with-pty.py" \
        --stdin-only \
        --input "RESET" \
        -- \
        bash -c '
            exec 2>"${MOCK_STDERR_FILE}"
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" clean permissions reset
    assert_equal "${status}" "64"
    assert_file_absent "${permission_log}"
    run cat "${stderr_file}"
    assert_success
    assert_output_contains "terminal is required"
}

@test "generated Flatpak permission export rejects a symlinked backup root" {
    local outside_root="${TEST_ROOT}/permission-backups-outside"

    mkdir -p "${outside_root}"
    run_home_configuration workstation 1 selected 0
    assert_success

    rm -rf "${HOME_DIR}/.host"
    ln -s "${outside_root}" "${HOME_DIR}/.host"
    run_generated_helper_with_input clean permissions "RESET" reset
    assert_equal "${status}" "1"
    assert_stderr_contains "symbolic link"
    run find "${outside_root}" -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "generated Flatpak export cleanup does not remove an unrelated filtered file" {
    local working_directory="${TEST_ROOT}/permission-export-working"
    local filtered_file="${working_directory}/.filtered"

    run_home_configuration workstation 1 selected 0
    assert_success
    mkdir -p "${working_directory}"
    printf '%s\n' "unrelated" > "${filtered_file}"
    cat > "${MOCK_BIN}/mktemp" <<'EOF'
#!/usr/bin/env bash
for mock_mktemp_argument in "$@"; do
    case "${mock_mktemp_argument}" in
        */.flatpak-permissions.*) exit 9 ;;
    esac
done
exec /usr/bin/mktemp "$@"
EOF
    chmod +x "${MOCK_BIN}/mktemp"

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        bash -c '
            cd "$2" || exit 1
            source "$1"
            shift 2
            "$@"
        ' _ "${VALID_DIRECTORY}/scripts/aliases.sh" "${working_directory}" \
        "host_test_machine" "clean" "permissions" "reset"
    assert_equal "${status}" "9"
    run cat "${filtered_file}"
    assert_success
    assert_equal "${output}" "unrelated"
}

@test "generated Flatpak reset discloses grants changed before a failure" {
    local permission_log="${TEST_ROOT}/flatpak-partial-reset"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        printf 'notifications\tnotification\tcom.example.First\tyes\t0x00\n'
        printf 'notifications\tnotification\tcom.example.Second\tyes\t0x00\n'
        ;;
    permission-reset)
        printf '%s\n' "${2:-}" >> "${MOCK_PERMISSION_LOG}"
        if [ "${2:-}" = "com.example.Second" ]; then
            exit 9
        fi
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_PERMISSION_LOG="${permission_log}"

    run_home_configuration workstation 1 selected 0
    assert_success
    run_generated_helper_with_input clean permissions "RESET" reset
    assert_equal "${status}" "9"
    assert_stderr_contains "may already be reset"
    assert_stderr_contains "private export was retained"
    run cat "${permission_log}"
    assert_success
    assert_equal "${output}" $'com.example.First\ncom.example.Second'
}

@test "generated per-application Flatpak permission reset exports before confirmation" {
    local flavor
    local permission_log="${TEST_ROOT}/flatpak-permission-actions"
    local permission_export

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        printf 'permissions\n' >> "${MOCK_PERMISSION_LOG}"
        printf 'notifications\tnotification\tcom.example.First\tyes\t0x00\n'
        printf 'notifications\tnotification\tcom.example.Second\tyes\t0x00\n'
        ;;
    permission-reset)
        printf 'reset:%s\n' "${2:-}" >> "${MOCK_PERMISSION_LOG}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_PERMISSION_LOG="${permission_log}"

    for flavor in workstation silverblue; do
        : > "${permission_log}"
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper_with_input clean permissions "NO" app com.example.First
        assert_equal "${status}" "1"
        run cat "${permission_log}"
        assert_success
        assert_equal "${output}" "permissions"

        run_generated_helper_with_input clean permissions "RESET" app com.example.First
        assert_success
        run cat "${permission_log}"
        assert_success
        assert_equal "${output}" $'permissions\npermissions\nreset:com.example.First'

        run find "${HOME_DIR}/.host/backups/flatpak-permissions" \
            -type f -name 'flatpak-permissions-com.example.First-*.txt' \
            -print -quit
        assert_success
        permission_export="${output}"
        run cat "${permission_export}"
        assert_success
        assert_output_contains "com.example.First"
        refute_output_contains "com.example.Second"
    done
}

@test "generated Firefox cleanup preserves an operational read failure" {
    local flavor

    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "firefox" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "${MOCK_BIN}/pidof"
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper_with_read_status 7 clean cache
        assert_equal "${status}" 7
        assert_stderr_contains "Unable to read the Firefox confirmation"
    done
}

@test "generated Firefox cleanup aborts when stopping Firefox fails" {
    local flavor
    local cleanup_marker="${TEST_ROOT}/firefox-cleanup-called"

    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "firefox" ]; then
    exit 0
fi
exit 1
EOF
    cat > "${MOCK_BIN}/killall" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
    run)
        : > "${MOCK_CLEANUP_MARKER}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/pidof" "${MOCK_BIN}/killall" \
        "${MOCK_BIN}/bleachbit" "${MOCK_BIN}/flatpak"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${cleanup_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper_with_input clean cache "y"
        assert_equal "${status}" 7
        assert_stderr_contains "Unable to stop Firefox"
        assert_file_absent "${cleanup_marker}"
    done
}

@test "generated cache cleanup preserves a BleachBit failure" {
    local gio_marker="${TEST_ROOT}/gio-called"

    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    cat > "${MOCK_BIN}/gio" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_GIO_MARKER}"
EOF
    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${MOCK_BIN}/bleachbit" "${MOCK_BIN}/gio" \
        "${MOCK_BIN}/pidof"
    export MOCK_GIO_MARKER="${gio_marker}"

    run_home_configuration workstation 1 selected 0
    assert_success

    run_generated_helper clean cache
    assert_equal "${status}" 7
    assert_stderr_contains "Unable to clean cached data with BleachBit"
    assert_file_absent "${gio_marker}"
}

@test "generated Silverblue cache cleanup preserves Flatpak list and run failures" {
    local gio_marker="${TEST_ROOT}/gio-called"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        if [ "${MOCK_FLATPAK_LIST_STATUS:-0}" -ne 0 ]; then
            exit "${MOCK_FLATPAK_LIST_STATUS}"
        fi
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
    run)
        exit "${MOCK_FLATPAK_RUN_STATUS:-0}"
        ;;
esac
exit 0
EOF
    cat > "${MOCK_BIN}/gio" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_GIO_MARKER}"
EOF
    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${MOCK_BIN}/flatpak" "${MOCK_BIN}/gio" \
        "${MOCK_BIN}/pidof"
    export MOCK_GIO_MARKER="${gio_marker}"

    run_home_configuration silverblue 1 selected 0
    assert_success

    export MOCK_FLATPAK_LIST_STATUS=7
    run_generated_helper clean cache
    assert_equal "${status}" 7
    assert_stderr_contains "Unable to list Flatpak applications"
    assert_file_absent "${gio_marker}"

    unset MOCK_FLATPAK_LIST_STATUS
    export MOCK_FLATPAK_RUN_STATUS=9
    run_generated_helper clean cache
    assert_equal "${status}" 9
    assert_stderr_contains "Unable to clean cached data with BleachBit"
    assert_file_absent "${gio_marker}"
}

@test "generated Flatpak permission reset preserves operational statuses" {
    local flavor

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        if [ "${MOCK_FLATPAK_PERMISSIONS_STATUS:-0}" -ne 0 ]; then
            exit "${MOCK_FLATPAK_PERMISSIONS_STATUS}"
        fi
        printf 'notifications\tnotification\tcom.example.First\tyes\t0x00\n'
        ;;
    permission-reset)
        exit "${MOCK_FLATPAK_RESET_STATUS:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/flatpak"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        export MOCK_FLATPAK_PERMISSIONS_STATUS=7
        run_generated_helper_with_input clean permissions "RESET" reset
        assert_equal "${status}" 7
        assert_stderr_contains "Unable to export the Flatpak permissions"

        unset MOCK_FLATPAK_PERMISSIONS_STATUS
        export MOCK_FLATPAK_RESET_STATUS=9
        run_generated_helper_with_input clean permissions "RESET" reset
        assert_equal "${status}" 9
        assert_stderr_contains "Unable to reset the Flatpak permission"
        unset MOCK_FLATPAK_RESET_STATUS
    done
}

@test "Flatpak installation failures are not recorded as successful selections" {
    local capture_count="${TEST_ROOT}/flatpak-selection-captures"
    local flatpak_log="${TEST_ROOT}/flatpak-install-calls"
    local state_file="${TEST_ROOT}/flatpak-state.tsv"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_FLATPAK_LOG}"
exit 7
EOF
    chmod +x "${MOCK_BIN}/flatpak"

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        MOCK_CAPTURE_COUNT="${capture_count}" \
        MOCK_FLATPAK_LOG="${flatpak_log}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_FLAVOR="workstation" \
        POSTINSTALL_STATE_FILE="${state_file}" \
        SCRIPT_PATH="${REPO_ROOT}" \
        bash -c '
            source "$1/common/runtime.sh"
            source "$1/common/module-inventory.sh"
            source "$1/common/ui.sh"
            source "$1/common/validation.sh"
            runtime_initialize
            ui_choose_many() {
                printf "call\n" >> "${MOCK_CAPTURE_COUNT}"
                printf "%s\n" "com.example.App"
            }
            runtime_run_module "common/flatpaks-installation.sh" mutating \
                FLATPAKS_KEEP_CACHE_IDS_JSON
        ' _ "${REPO_ROOT}"

    assert_equal "${status}" 7
    assert_stderr_contains "Unable to install Flatpak application com.example.App"
    run wc -l < "${capture_count}"
    assert_success
    assert_equal "${output}" "1"
    run cat "${flatpak_log}"
    assert_success
    assert_output_contains "install flathub com.example.App -y"
    run grep -F $'module\tdefault:common/flatpaks-installation.sh\t-\t' \
        "${state_file}"
    assert_success
    run grep -F \
        "default:common/flatpaks-installation.sh:FLATPAKS_KEEP_CACHE_IDS_JSON" \
        "${state_file}"
    assert_failure
}

@test "home configuration distinguishes absent, empty, and explicit Flatpak retention state" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration_without_retention "${flavor}" 1 selected 0
        assert_success
        assert_stderr_contains "Flatpak cache-retention state is unavailable"
        refute_output_contains "Flatpak cache-retention state is unavailable"

        rm -f "${FILE_COUNTER}"
        run_home_configuration_with_retention "${flavor}" "[]" 1 selected 0
        assert_success
        refute_stderr_contains "Flatpak cache-retention state is unavailable"
        refute_output_contains "Flatpak cache-retention state is unavailable"

        rm -f "${FILE_COUNTER}"
        run_home_configuration_with_retention "${flavor}" "" 1 selected 0
        assert_equal "${status}" 1
        assert_stderr_contains "The Flatpak cache-retention state is missing"
        refute_output_contains "The Flatpak cache-retention state is missing"
    done
}

@test "generated Flatpak cleanup refuses to delete data without retention state" {
    local flavor
    local flatpak_marker="${TEST_ROOT}/flatpak-cleanup-called"
    local retained_data="${HOME_DIR}/.var/app/com.example.Retained/data"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FLATPAK_MARKER}"
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_FLATPAK_MARKER="${flatpak_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${flatpak_marker}"
        run_home_configuration_without_retention "${flavor}" 1 selected 0
        assert_success
        assert_stderr_contains "Flatpak cache-retention state is unavailable"

        mkdir -p "$(dirname -- "${retained_data}")"
        printf 'retained\n' > "${retained_data}"
        run_generated_helper clean flatpak
        assert_equal "${status}" 1
        assert_stderr_contains "Flatpak cache-retention state is unavailable"
        assert_file_absent "${flatpak_marker}"
        assert_file_exists "${retained_data}"
    done
}

@test "generated cache cleanup preserves an operational pidof failure" {
    local flavor
    local cleanup_marker="${TEST_ROOT}/cache-cleanup-called"
    local gio_marker="${TEST_ROOT}/gio-called"

    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
    run)
        : > "${MOCK_CLEANUP_MARKER}"
        ;;
esac
exit 0
EOF
    cat > "${MOCK_BIN}/gio" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_GIO_MARKER}"
EOF
    chmod +x "${MOCK_BIN}/pidof" "${MOCK_BIN}/bleachbit" \
        "${MOCK_BIN}/flatpak" "${MOCK_BIN}/gio"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"
    export MOCK_GIO_MARKER="${gio_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${cleanup_marker}" "${gio_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper clean cache
        assert_equal "${status}" 7
        assert_stderr_contains "Unable to determine whether Firefox is running"
        assert_file_absent "${cleanup_marker}"
        assert_file_absent "${gio_marker}"
    done
}

@test "generated Firefox detection fails closed when no detector is available" {
    local cleanup_marker="${TEST_ROOT}/cache-cleanup-called"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    chmod +x "${MOCK_BIN}/bleachbit"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"

    run_home_configuration workstation 1 selected 0
    assert_success

    run -127 --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            command() {
                if [ "${1:-}" = "-v" ]; then
                    case "${2:-}" in
                        pidof | pgrep) return 1 ;;
                    esac
                fi
                builtin command "$@"
            }
            source "$1"
            host_test_machine clean cache
        ' _ "${helper_file}"
    assert_equal "${status}" "127"
    assert_stderr_contains "Unable to determine whether Firefox is running"
    assert_file_absent "${cleanup_marker}"
}

@test "generated Firefox detection preserves an operational pgrep failure" {
    local cleanup_marker="${TEST_ROOT}/cache-cleanup-called"
    local helper_file="${VALID_DIRECTORY}/scripts/aliases.sh"

    cat > "${MOCK_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    chmod +x "${MOCK_BIN}/pgrep" "${MOCK_BIN}/bleachbit"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"

    run_home_configuration workstation 1 selected 0
    assert_success

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            command() {
                if [ "${1:-}" = "-v" ] && [ "${2:-}" = "pidof" ]; then
                    return 1
                fi
                builtin command "$@"
            }
            source "$1"
            host_test_machine clean cache
        ' _ "${helper_file}"
    assert_equal "${status}" "7"
    assert_stderr_contains "Unable to determine whether Firefox is running"
    assert_file_absent "${cleanup_marker}"
}

@test "an empty Firefox confirmation does not terminate Firefox" {
    local flavor
    local kill_marker="${TEST_ROOT}/killall-called"
    local cleanup_marker="${TEST_ROOT}/cache-cleanup-called"

    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "${MOCK_BIN}/killall" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_KILL_MARKER}"
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CLEANUP_MARKER}"
EOF
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '%s\n' 'org.bleachbit.BleachBit'
        ;;
    run)
        : > "${MOCK_CLEANUP_MARKER}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/pidof" "${MOCK_BIN}/killall" \
        "${MOCK_BIN}/bleachbit" "${MOCK_BIN}/flatpak"
    export MOCK_KILL_MARKER="${kill_marker}"
    export MOCK_CLEANUP_MARKER="${cleanup_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${kill_marker}" "${cleanup_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper_with_input clean cache ""
        assert_equal "${status}" 1
        assert_stderr_contains "Firefox was not stopped"
        assert_file_absent "${kill_marker}"
        assert_file_absent "${cleanup_marker}"
    done
}

@test "generated system cleanup does not shut down after a cache failure" {
    local flavor
    local shutdown_marker="${TEST_ROOT}/shutdown-called"

    cat > "${MOCK_BIN}/shutdown" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_SHUTDOWN_MARKER}"
EOF
    cat > "${MOCK_BIN}/bleachbit" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
    exit 7
fi
exit 0
EOF
    cat > "${MOCK_BIN}/pidof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${MOCK_BIN}/shutdown" "${MOCK_BIN}/bleachbit" \
        "${MOCK_BIN}/flatpak" "${MOCK_BIN}/pidof"
    export MOCK_SHUTDOWN_MARKER="${shutdown_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${shutdown_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        run_generated_helper clean system
        assert_equal "${status}" 7
        assert_stderr_contains "Cache cleanup failed; shutdown was canceled"
        assert_file_absent "${shutdown_marker}"
    done
}

@test "generated Flatpak cleanup preserves an enumeration failure" {
    local flavor
    local removable_data="${HOME_DIR}/.var/app/com.example.Removable/data"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "${MOCK_BIN}/find" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    chmod +x "${MOCK_BIN}/flatpak" "${MOCK_BIN}/find"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        mkdir -p "$(dirname -- "${removable_data}")"
        printf 'removable\n' > "${removable_data}"
        run_generated_helper clean flatpak
        assert_equal "${status}" 7
        assert_stderr_contains "unable to enumerate Flatpak application data"
        refute_output_contains "unable to enumerate Flatpak application data"
        assert_file_exists "${removable_data}"
        run find "${TMP_ROOT}" -maxdepth 1 \
            -type f -name 'fedora-postinstall-flatpak-cleanup.*' -print
        assert_success
        assert_equal "${output}" ""
    done
}

@test "generated Flatpak cleanup preserves an application-data removal failure" {
    local flavor
    local removable_data="${HOME_DIR}/.var/app/com.example.Removable/data"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "${MOCK_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
for rm_argument in "$@"; do
    case "${rm_argument}" in
    */com.example.Removable)
        exit 7
        ;;
    esac
done
exec /usr/bin/rm "$@"
EOF
    chmod +x "${MOCK_BIN}/flatpak" "${MOCK_BIN}/rm"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        mkdir -p "$(dirname -- "${removable_data}")"
        printf 'removable\n' > "${removable_data}"
        run_generated_helper clean flatpak
        assert_equal "${status}" 7
        assert_stderr_contains "unable to reset Flatpak application data"
        refute_output_contains "unable to reset Flatpak application data"
        assert_file_exists "${removable_data}"
    done
}

@test "generated Flatpak cleanup preserves an unused-application removal failure" {
    local flavor
    local flatpak_marker="${TEST_ROOT}/flatpak-cleanup-called"
    local retained_data="${HOME_DIR}/.var/app/com.example.Retained/data"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FLATPAK_MARKER}"
exit 7
EOF
    chmod +x "${MOCK_BIN}/flatpak"
    export MOCK_FLATPAK_MARKER="${flatpak_marker}"

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}" "${flatpak_marker}"
        run_home_configuration "${flavor}" 1 selected 0
        assert_success

        mkdir -p "$(dirname -- "${retained_data}")"
        printf 'retained\n' > "${retained_data}"
        run_generated_helper clean flatpak
        assert_equal "${status}" 7
        assert_stderr_contains "unable to remove unused Flatpak applications"
        assert_file_exists "${flatpak_marker}"
        assert_file_exists "${retained_data}"
    done
}

@test "generated mise failures preserve their operational statuses" {
    cat > "${MOCK_BIN}/mise" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    self-update)
        exit "${MOCK_MISE_SELF_UPDATE_STATUS:-0}"
        ;;
    upgrade)
        exit "${MOCK_MISE_UPGRADE_STATUS:-0}"
        ;;
    activate)
        exit "${MOCK_MISE_ACTIVATE_STATUS:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/mise"

    run_home_configuration workstation 1 selected 0
    assert_success

    export MOCK_MISE_SELF_UPDATE_STATUS=7
    run_generated_helper upgrade mise
    assert_equal "${status}" "7"
    unset MOCK_MISE_SELF_UPDATE_STATUS

    export MOCK_MISE_UPGRADE_STATUS=8
    run_generated_helper upgrade mise
    assert_equal "${status}" "8"
    unset MOCK_MISE_UPGRADE_STATUS

    export MOCK_MISE_ACTIVATE_STATUS=9
    run_generated_helper use mise
    assert_equal "${status}" "9"
    unset MOCK_MISE_ACTIVATE_STATUS
}
