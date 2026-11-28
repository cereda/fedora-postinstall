#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/rolling-install"
    MOCK_BIN="${TEST_ROOT}/bin"
    TMP_ROOT="${TEST_ROOT}/tmp"

    mkdir -p "${MOCK_BIN}" "${TMP_ROOT}"
}

write_curl_mock() {
    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        --tlsv1.2)
            shift
            ;;
        *)
            shift
            ;;
    esac
done
if [ "${MOCK_CURL_STATUS:-0}" -ne 0 ]; then
    exit "${MOCK_CURL_STATUS}"
fi
if [ "${MOCK_CURL_EMPTY:-0}" -eq 1 ]; then
    : > "${output}"
else
    cat > "${output}" <<'INSTALLER'
#!/usr/bin/env bash
if [ -n "${MOCK_INSTALLER_ARGS_FILE:-}" ]; then
    printf '%s\n' "$@" > "${MOCK_INSTALLER_ARGS_FILE}"
fi
for mock_installer_argument in "$@"; do
    if [ "${mock_installer_argument}" = "--" ]; then
        exit 64
    fi
done
exit "${MOCK_INSTALLER_STATUS:-0}"
INSTALLER
fi
EOF
    chmod +x "${MOCK_BIN}/curl"
}

run_rolling_installer() {
    run env \
        MOCK_CURL_EMPTY="${MOCK_CURL_EMPTY:-0}" \
        MOCK_CURL_STATUS="${MOCK_CURL_STATUS:-0}" \
        MOCK_INSTALLER_STATUS="${MOCK_INSTALLER_STATUS:-0}" \
        MOCK_INSTALLER_ARGS_FILE="${TEST_ROOT}/installer-arguments" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        bash -c '
            source "$1/common/rolling-install.sh"
            rolling_installer_run "https://example.test/install" sh --prefix "$2"
        ' _ "${REPO_ROOT}" "${TEST_ROOT}/prefix"
}

run_rolling_installer_with_err_trap() {
    run env \
        MOCK_CURL_EMPTY="${MOCK_CURL_EMPTY:-0}" \
        MOCK_CURL_STATUS="${MOCK_CURL_STATUS:-0}" \
        MOCK_INSTALLER_STATUS="${MOCK_INSTALLER_STATUS:-0}" \
        MOCK_INSTALLER_ARGS_FILE="${TEST_ROOT}/installer-arguments" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        bash -c '
            set -E
            trap '\''status=$?; printf "err trap: %s\\n" "${status}" >&2; exit "${status}"'\'' ERR
            source "$1/common/rolling-install.sh"
            rolling_installer_run "https://example.test/install" sh --prefix "$2" || exit $?
        ' _ "${REPO_ROOT}" "${TEST_ROOT}/prefix"
}

@test "rolling installer forwards options without an argument separator" {
    write_curl_mock

    run_rolling_installer
    assert_success
    run head -n 1 "${TEST_ROOT}/installer-arguments"
    assert_success
    assert_equal "${output}" "--prefix"
}

@test "the Starship caller forwards installer options without a separator" {
    local home_directory="${TEST_ROOT}/home"

    mkdir -p "${home_directory}"
    write_curl_mock

    run env \
        HOME="${home_directory}" \
        MOCK_INSTALLER_ARGS_FILE="${TEST_ROOT}/installer-arguments" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        ROOT_DIRECTORY_STRUCTURE="${TEST_ROOT}/managed" \
        SCRIPT_PATH="${REPO_ROOT}" \
        bash -c '
            ui_section() { :; }
            ui_description() { :; }
            ui_step() { :; }
            ui_success() { :; }
            ui_confirm() { return 0; }
            source "$1/common/starship-installation.sh"
        ' _ "${REPO_ROOT}"
    assert_success
    run cat "${TEST_ROOT}/installer-arguments"
    assert_success
    assert_output_contains "-b"
    assert_output_contains "-y"
    run bash -c '! grep -Fx -- "--" "$1"' _ "${TEST_ROOT}/installer-arguments"
    assert_success
}

@test "the Distrobox caller forwards installer options without a separator" {
    local home_directory="${TEST_ROOT}/home"

    mkdir -p "${home_directory}"
    write_curl_mock

    run env \
        HOME="${home_directory}" \
        MOCK_INSTALLER_ARGS_FILE="${TEST_ROOT}/installer-arguments" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        SCRIPT_PATH="${REPO_ROOT}" \
        bash -c '
            ui_section() { :; }
            ui_description() { :; }
            ui_warning() { :; }
            ui_step() { :; }
            ui_success() { :; }
            ui_confirm() { return 0; }
            source "$1/common/distrobox-installation.sh"
        ' _ "${REPO_ROOT}"
    assert_success
    run cat "${TEST_ROOT}/installer-arguments"
    assert_success
    assert_output_contains "--prefix"
    run bash -c '! grep -Fx -- "--" "$1"' _ "${TEST_ROOT}/installer-arguments"
    assert_success
}

@test "rolling installer failures preserve the downloaded script status" {
    write_curl_mock

    export MOCK_INSTALLER_STATUS=7
    run_rolling_installer
    unset MOCK_INSTALLER_STATUS

    assert_equal "${status}" "7"
    assert_output_contains "failed with status 7"
    run find "${TMP_ROOT}" -maxdepth 1 -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "rolling installer download failures preserve the curl status" {
    write_curl_mock

    export MOCK_CURL_STATUS=22
    run_rolling_installer
    unset MOCK_CURL_STATUS

    assert_equal "${status}" "22"
    assert_output_contains "Unable to download the rolling installer"
    run find "${TMP_ROOT}" -maxdepth 1 -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "rolling installers reject an empty response" {
    write_curl_mock

    export MOCK_CURL_EMPTY=1
    run_rolling_installer
    unset MOCK_CURL_EMPTY

    assert_equal "${status}" "1"
    assert_output_contains "was empty"
}

@test "rolling installer failures clean temporary files before the ERR trap observes them" {
    write_curl_mock

    export MOCK_CURL_STATUS=22
    run_rolling_installer_with_err_trap
    unset MOCK_CURL_STATUS

    assert_equal "${status}" "22"
    assert_output_contains "Unable to download the rolling installer"
    refute_output_contains "err trap:"
    run find "${TMP_ROOT}" -maxdepth 1 -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "rolling temporary cleanup retains retry state after a removal failure" {
    local temporary_file="${TEST_ROOT}/rolling-temporary"
    local removal_log="${TEST_ROOT}/rolling-removal-log"

    printf '%s\n' "temporary" > "${temporary_file}"
    run bash -c '
        source "$1/common/rolling-install.sh"
        REMOVAL_LOG="$2"
        runtime_unregister_cleanup() {
            printf "unregistered\n" >> "${REMOVAL_LOG}"
            return 0
        }
        rm() {
            count=0
            [ ! -f "${REMOVAL_LOG}" ] ||
                count=$(cat "${REMOVAL_LOG}")
            count=$((count + 1))
            printf "%s\n" "${count}" > "${REMOVAL_LOG}"
            if [ "${count}" -eq 1 ]; then
                return 9
            fi
            /usr/bin/rm "$@"
        }
        ROLLING_INSTALLER_TEMPORARY_PATH="$3"
        ROLLING_INSTALLER_CLEANUP_REGISTERED=1
        first_status=0
        rolling_installer_remove_temporary || first_status="${?}"
        printf "first=%s path=%s registered=%s\n" \
            "${first_status}" "${ROLLING_INSTALLER_TEMPORARY_PATH}" \
            "${ROLLING_INSTALLER_CLEANUP_REGISTERED}"
        second_status=0
        rolling_installer_remove_temporary || second_status="${?}"
        printf "second=%s path=%s registered=%s\n" \
            "${second_status}" "${ROLLING_INSTALLER_TEMPORARY_PATH}" \
            "${ROLLING_INSTALLER_CLEANUP_REGISTERED}"
    ' _ "${REPO_ROOT}" "${removal_log}" "${temporary_file}"
    assert_success
    assert_output_contains "first=9 path=${temporary_file} registered=1"
    assert_output_contains "second=0 path= registered=0"
    assert_file_absent "${temporary_file}"
}

@test "downloaded rolling installer failures clean temporary files before the ERR trap observes them" {
    write_curl_mock

    export MOCK_INSTALLER_STATUS=7
    run_rolling_installer_with_err_trap
    unset MOCK_INSTALLER_STATUS

    assert_equal "${status}" "7"
    assert_output_contains "failed with status 7"
    refute_output_contains "err trap:"
    run find "${TMP_ROOT}" -maxdepth 1 -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "rolling installer downloads reject a non-HTTPS URL before invoking curl" {
    local curl_marker="${TEST_ROOT}/curl-called"
    local destination="${TEST_ROOT}/downloaded-installer"

    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CURL_MARKER}"
exit 0
EOF
    chmod +x "${MOCK_BIN}/curl"

    run env \
        MOCK_CURL_MARKER="${curl_marker}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c '
            source "$1/common/rolling-install.sh"
            rolling_installer_download "http://example.test/install" "$2"
        ' _ "${REPO_ROOT}" "${destination}"
    assert_equal "${status}" "64"
    assert_output_contains "HTTPS"
    assert_file_absent "${curl_marker}"
    assert_file_absent "${destination}"
}

@test "rolling installers wait for the stable per-tool update lock" {
    local curl_marker="${TEST_ROOT}/curl-called"
    local runtime_directory="${TEST_ROOT}/runtime"
    local lock_path="${runtime_directory}/rolling-install-starship.lock"
    local ready_marker="${TEST_ROOT}/lock-ready"

    mkdir -p "${runtime_directory}"
    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CURL_MARKER}"
exit 0
EOF
    chmod +x "${MOCK_BIN}/curl"

    flock -x "${lock_path}" bash -c '
        : > "$1"
        sleep 5
    ' _ "${ready_marker}" &
    local lock_holder="${!}"
    for _ in {1..50}; do
        [ -f "${ready_marker}" ] && break
        sleep 0.1
    done
    assert_file_exists "${ready_marker}"

    run env \
        MOCK_CURL_MARKER="${curl_marker}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        ROLLING_INSTALLER_LOCK_TIMEOUT_SECONDS=1 \
        TMPDIR="${TMP_ROOT}" \
        XDG_RUNTIME_DIR="${runtime_directory}" \
        bash -c '
            source "$1/common/rolling-install.sh"
            rolling_installer_run "https://starship.rs/install.sh" sh
        ' _ "${REPO_ROOT}"
    kill "${lock_holder}" 2>/dev/null || true
    wait "${lock_holder}" 2>/dev/null || true

    assert_failure
    assert_output_contains "update lock"
    assert_file_absent "${curl_marker}"
}

@test "rolling installer execution has a bounded timeout" {
    write_curl_mock

    run env \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        ROLLING_INSTALLER_KILL_GRACE_SECONDS=1 \
        ROLLING_INSTALLER_TIMEOUT_SECONDS=1 \
        TMPDIR="${TMP_ROOT}" \
        bash -c '
            source "$1/common/rolling-install.sh"
            cat > "$2" <<"INSTALLER"
#!/usr/bin/env bash
sleep 30
INSTALLER
            rolling_installer_execute bash "$2"
        ' _ "${REPO_ROOT}" "${TMP_ROOT}/timeout-installer"
    assert_equal "${status}" "124"
    assert_output_contains "timed out"
}

@test "rolling installer forwards HUP INT and TERM without masking installer status" {
    local signal
    local expected_status
    local ready_marker="${TEST_ROOT}/signal-ready"

    for signal in HUP INT TERM; do
        case "${signal}" in
        HUP) expected_status=7 ;;
        INT) expected_status=8 ;;
        TERM) expected_status=9 ;;
        esac
        rm -f "${ready_marker}"
        cat > "${MOCK_BIN}/curl" <<EOF
#!/usr/bin/env bash
output=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --output)
            output="\${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "\${output}" <<'INSTALLER'
#!/usr/bin/env bash
trap 'exit ${expected_status}' ${signal}
: > "\${READY_MARKER}"
while :; do sleep 1; done
INSTALLER
EOF
        chmod +x "${MOCK_BIN}/curl"

        run env \
            PATH="${MOCK_BIN}:/usr/bin:/bin" \
            READY_MARKER="${ready_marker}" \
            ROLLING_INSTALLER_TIMEOUT_SECONDS=10 \
            TMPDIR="${TMP_ROOT}" \
            python3 "${REPO_ROOT}/tests/helpers/run-until-ready.py" \
            --signal "${signal}" \
            --ready "${ready_marker}" \
            --timeout 10 \
            -- \
            bash -c '
                source "$1/common/rolling-install.sh"
                rolling_installer_run "https://example.test/install" bash
            ' _ "${REPO_ROOT}"

        assert_equal "${status}" "${expected_status}"
        assert_output_contains "failed with status ${expected_status}"
    done
}
