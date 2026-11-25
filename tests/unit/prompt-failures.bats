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
    VALID_DIRECTORY="${HOME_DIR}/selected"
    INVALID_DIRECTORY="${TEST_ROOT}/outside-home"

    mkdir -p \
        "${HOME_DIR}" \
        "${MOCK_BIN}" \
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

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        GUM="${MOCK_BIN}/gum" \
        FLATPAKS_KEEP_CACHE_IDS_JSON="[]" \
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

    run --separate-stderr env \
        HOME="${HOME_DIR}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" "${action}" "${target}" <<<"${input}"
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
        bash -c '
            read() { return "${MOCK_READ_STATUS}"; }
            source "$1"
            shift
            "$@"
        ' _ "${helper_file}" "host_test_machine" "${action}" "${target}" < /dev/null
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

@test "generated Firefox cleanup aborts when confirmation input fails" {
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
        assert_equal "${status}" 1
        assert_stderr_contains "Unable to read the Firefox confirmation"
        assert_file_absent "${cleanup_marker}"
    done
}

@test "generated Flatpak permission cleanup passes only the first two columns" {
    local flavor
    local permission_log="${TEST_ROOT}/flatpak-permission-removals"

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        printf 'com.example.First\tfiles\tthird\tfourth\n'
        printf 'com.example.Second\tdbus\tother\n'
        printf 'com.example.EmptySecond\t\tthird\n'
        printf 'com.example.NoSecond\n'
        ;;
    permission-remove)
        if [ "$#" -ne 3 ]; then
            printf 'unexpected argument count: %s\n' "$#" >&2
            exit 9
        fi
        printf '%s\t%s\n' "${2:-}" "${3:-}" >> "${MOCK_PERMISSION_LOG}"
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

        run_generated_helper clean permissions
        assert_success
        run cat "${permission_log}"
        assert_success
        assert_equal "${output}" $'com.example.First\tfiles\ncom.example.Second\tdbus'
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

@test "generated Flatpak permission cleanup preserves operational statuses" {
    local flavor

    cat > "${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    permissions)
        if [ "${MOCK_FLATPAK_PERMISSIONS_STATUS:-0}" -ne 0 ]; then
            exit "${MOCK_FLATPAK_PERMISSIONS_STATUS}"
        fi
        printf 'com.example.First\tfiles\n'
        ;;
    permission-remove)
        exit "${MOCK_FLATPAK_REMOVE_STATUS:-0}"
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
        run_generated_helper clean permissions
        assert_equal "${status}" 7
        assert_stderr_contains "Unable to read the Flatpak permissions"

        unset MOCK_FLATPAK_PERMISSIONS_STATUS
        export MOCK_FLATPAK_REMOVE_STATUS=9
        run_generated_helper clean permissions
        assert_equal "${status}" 9
        assert_stderr_contains "unable to reset the Flatpak permission"
        unset MOCK_FLATPAK_REMOVE_STATUS
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
