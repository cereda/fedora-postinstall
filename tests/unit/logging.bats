#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/logging"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    LOG_FILE="${TEST_ROOT}/runtime.log"
    STATE_FILE="${TEST_ROOT}/state.tsv"

    mkdir -p "${SANDBOX_REPO}/common" "${TEST_HOME}"
    cp "${REPO_ROOT}/common/runtime.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/runtime-file.py" "${SANDBOX_REPO}/common/"
}

run_runtime() {
    local log_format="${1:-json}"
    local log_level="${2:-info}"
    local command="${3:-}"
    local stdout_file="${TEST_ROOT}/stdout"
    local stderr_file="${TEST_ROOT}/stderr"

    env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_LOG_FILE="${LOG_FILE}" \
        POSTINSTALL_LOG_FORMAT="${log_format}" \
        POSTINSTALL_LOG_LEVEL="${log_level}" \
        POSTINSTALL_LOG_STDOUT=1 \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; ${command}" \
        >"${stdout_file}" 2>"${stderr_file}"
}

@test "JSON logs are valid JSON Lines with stable event metadata" {
    run_runtime json info
    assert_file_exists "${LOG_FILE}"
    run jq -e '
        .schema_version == 1 and
        .event == "runtime.initialized" and
        .level == "INFO" and
        (.run_id | length > 0) and
        (.timestamp | test("^[0-9]{4}-")) and
        has("namespace") and
        has("module")
    ' "${LOG_FILE}"
    assert_success
}

@test "JSON log stdout is routed to stderr" {
    run_runtime json info
    if [ -s "${TEST_ROOT}/stdout" ]; then
        printf 'expected JSON logs on stderr, but stdout was not empty\n' >&2
        return 1
    fi
    run grep -F '"event":"runtime.initialized"' "${TEST_ROOT}/stderr"
    assert_success
}

@test "log levels filter lower-priority records" {
    run_runtime json error 'runtime_log "ERROR" "expected error"'
    assert_file_exists "${LOG_FILE}"
    run jq -e 'all(.level; . == "ERROR")' "${LOG_FILE}"
    assert_success
}

@test "log files append rather than truncate" {
    run_runtime plain info
    local first_size
    first_size=$(wc -c < "${LOG_FILE}")
    run_runtime plain info
    local second_size
    second_size=$(wc -c < "${LOG_FILE}")
    if [ "${second_size}" -le "${first_size}" ]; then
        printf 'expected the log file to grow after a second run\n' >&2
        return 1
    fi
}

@test "separate runs receive different run identifiers" {
    run_runtime json info
    local first_run_id
    first_run_id=$(jq -r '.run_id' "${LOG_FILE}")
    run_runtime json info
    local second_run_id
    second_run_id=$(jq -r '.run_id' "${LOG_FILE}" | tail -n 1)
    if [ "${first_run_id}" = "${second_run_id}" ]; then
        printf 'expected different run identifiers\n' >&2
        return 1
    fi
}
