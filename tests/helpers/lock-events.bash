#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

expect_lock_event() {
    local expected_kind="${1}"
    local event_fd="${2}"
    local timeout_seconds="${3:-30}"
    local kind
    local value
    local path
    local extra

    if ! IFS=$'\t' read -r -t "${timeout_seconds}" \
        kind value path extra <&"${event_fd}"; then
        printf 'timed out waiting for lock event <%s>\n' \
            "${expected_kind}" >&2
        return 1
    fi
    if [ "${kind}" != "${expected_kind}" ]; then
        printf 'expected lock event <%s>, got <%s>\n' \
            "${expected_kind}" "${kind}" >&2
        return 1
    fi

    LOCK_EVENT_KIND="${kind}"
    LOCK_EVENT_VALUE="${value}"
    LOCK_EVENT_PATH="${path}"
    return 0
}

assert_lock_helper_gone() {
    local helper_pid="${1}"
    local expected_identity="${2}"
    local current_identity=""

    if current_identity=$(/usr/bin/python3 \
        "${SANDBOX_REPO}/common/lock-holder.py" \
        identity "${helper_pid}" 2>/dev/null); then
        if [ "${current_identity}" = "${expected_identity}" ]; then
            printf 'lock helper leaked: pid=%s identity=%s\n' \
                "${helper_pid}" "${expected_identity}" >&2
            return 1
        fi
    fi
    return 0
}
