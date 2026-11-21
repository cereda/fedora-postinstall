#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

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
style)
    printf '%s\n' "$*"
    ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/gum"
}

run_question() {
    local confirm_status="${1}"

    run env \
        GUM="${MOCK_BIN}/gum" \
        MOCK_CONFIRM_STATUS="${confirm_status}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/gum-functions.sh"
            if question "Continue?"; then
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

    run env \
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
            source "$1/common/gum-functions.sh"
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

@test "question accepts the affirmative response" {
    run_question 0

    assert_success
    assert_output_contains "accepted"
    refute_output_contains "declined"
}

@test "question preserves the normal decline response" {
    run_question 1

    assert_success
    assert_output_contains "declined"
    refute_output_contains "Prompt failed"
}

@test "question aborts on an operational Gum failure" {
    run_question 7

    assert_equal "${status}" 7
    assert_output_contains "Prompt failed with status 7"
    refute_output_contains "accepted"
    refute_output_contains "declined"
}

@test "home configuration aborts when the hidden-directory prompt fails" {
    local flavor

    for flavor in workstation silverblue; do
        rm -f "${FILE_COUNTER}"
        run_home_configuration "${flavor}" 7 selected 0

        assert_equal "${status}" 7
        assert_output_contains "Prompt failed with status 7"
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
        assert_output_contains "Directory selection was cancelled"
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
        assert_output_contains "No directory was selected"
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
        assert_output_contains "Unable to select a directory (status 7)"
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
        assert_output_contains "after 3 attempts"
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
