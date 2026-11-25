
# SPDX-License-Identifier: MIT
assert_success() {
    if [ "${status}" -ne 0 ]; then
        printf 'expected success, got status %s\noutput:\n%s\n' "${status}" "${output}" >&2
        return 1
    fi
}

assert_failure() {
    if [ "${status}" -eq 0 ]; then
        printf 'expected failure, got status 0\noutput:\n%s\n' "${output}" >&2
        return 1
    fi
}

assert_output_contains() {
    case "${output}" in
        *"${1}"*) return 0 ;;
        *)
            printf 'expected output to contain <%s>\noutput:\n%s\n' "${1}" "${output}" >&2
            return 1
            ;;
    esac
}

refute_output_contains() {
    case "${output}" in
        *"${1}"*)
            printf 'expected output not to contain <%s>\noutput:\n%s\n' "${1}" "${output}" >&2
            return 1
            ;;
        *) return 0 ;;
    esac
}

assert_stderr_contains() {
    case "${stderr:-}" in
        *"${1}"*) return 0 ;;
        *)
            printf 'expected stderr to contain <%s>\nstderr:\n%s\n' "${1}" "${stderr:-}" >&2
            return 1
            ;;
    esac
}

refute_stderr_contains() {
    case "${stderr:-}" in
        *"${1}"*)
            printf 'expected stderr not to contain <%s>\nstderr:\n%s\n' "${1}" "${stderr:-}" >&2
            return 1
            ;;
        *) return 0 ;;
    esac
}

assert_file_exists() {
    if [ ! -e "${1}" ]; then
        printf 'expected file to exist: %s\n' "${1}" >&2
        return 1
    fi
}

assert_file_absent() {
    if [ -e "${1}" ]; then
        printf 'expected file to be absent: %s\n' "${1}" >&2
        return 1
    fi
}

assert_equal() {
    if [ "${1}" != "${2}" ]; then
        printf 'expected <%s>, got <%s>\n' "${2}" "${1}" >&2
        return 1
    fi
}
