#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/extras"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    FIXTURE_ROOT="${TEST_ROOT}/fixture"
    TMP_ROOT="${TEST_ROOT}/tmp"
    MANIFEST_FILE="${SANDBOX_REPO}/extras/tools-manifest.json"
    CURL_LOG="${TEST_ROOT}/curl.log"

    mkdir -p \
        "${SANDBOX_REPO}" \
        "${TEST_HOME}" \
        "${MOCK_BIN}" \
        "${FIXTURE_ROOT}/package" \
        "${TMP_ROOT}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/silverblue" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/workstation" "${SANDBOX_REPO}/"
    cp "${REPO_ROOT}/fedora-postinstall.sh" "${SANDBOX_REPO}/"

    cat > "${FIXTURE_ROOT}/package/fd" <<'EOF'
#!/usr/bin/env bash
printf 'fixture fd\n'
EOF
    chmod +x "${FIXTURE_ROOT}/package/fd"
    tar -czf "${FIXTURE_ROOT}/fd.tar.gz" -C "${FIXTURE_ROOT}/package" fd

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
    choose)
        : > "${MOCK_CHOOSE_MARKER}"
        if [ "${MOCK_CHOOSE_FAIL:-0}" = "1" ]; then
            exit 7
        fi
        if [ -n "${MOCK_SELECTED_TOOLS:-}" ]; then
            printf '%s\n' "${MOCK_SELECTED_TOOLS}"
        elif [ -n "${MOCK_SELECTED_TOOL:-}" ]; then
            printf '%s\n' "${MOCK_SELECTED_TOOL}"
        fi
        ;;
    style)
        for argument in "$@"; do
            last_argument="${argument}"
        done
        printf '%s\n' "${last_argument}"
        ;;
    *) exit 0 ;;
esac
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-E" ]; then
    printf '42\n'
fi
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_ARCHITECTURE:-x86_64}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output=''
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
printf '%s\n' "${url}" >> "${MOCK_CURL_LOG}"
if [ "${MOCK_CURL_FAIL_AFTER_OUTPUT:-0}" = "1" ]; then
    if [ "${output}" = "-" ]; then
        cat "${MOCK_CURL_SOURCE}"
    elif [ -n "${output}" ]; then
        cp "${MOCK_CURL_SOURCE}" "${output}"
    fi
    exit 22
fi
if [ "${MOCK_CURL_FAIL:-0}" = "1" ]; then
    exit 22
fi
if [ "${output}" = "-" ]; then
    cat "${MOCK_CURL_SOURCE}"
elif [ -n "${output}" ]; then
    cp "${MOCK_CURL_SOURCE}" "${output}"
fi
EOF

    cat > "${MOCK_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
if [ -n "${MOCK_MV_FAIL_TARGET:-}" ] &&
    [[ "${destination}" == */"${MOCK_MV_FAIL_TARGET}" ]] &&
    [ ! -e "${MOCK_MV_FAILURE_MARKER:-}" ]; then
    if [ -n "${MOCK_MV_CONCURRENT_TARGET:-}" ] &&
        [[ "${destination}" == */"${MOCK_MV_CONCURRENT_TARGET}" ]]; then
        printf 'concurrent content\n' > "${destination}"
    fi
    : > "${MOCK_MV_FAILURE_MARKER}"
    exit 1
fi
if [ -n "${MOCK_ROLLBACK_FAIL_TARGET:-}" ] &&
    [[ "$*" == *".rollback."* ]] &&
    [[ "${destination}" == */"${MOCK_ROLLBACK_FAIL_TARGET}" ]]; then
    if [ "${MOCK_ROLLBACK_FAIL_ONCE:-0}" != "1" ] ||
        [ ! -e "${MOCK_ROLLBACK_FAILURE_MARKER:-}" ]; then
        : > "${MOCK_ROLLBACK_FAILURE_MARKER}"
        exit 1
    fi
fi
/usr/bin/mv "$@"
status="${?}"
if [ -n "${MOCK_INTERRUPT_AFTER_TARGET:-}" ] &&
    [[ "${destination}" == */"${MOCK_INTERRUPT_AFTER_TARGET}" ]] &&
    [ ! -e "${MOCK_INTERRUPT_MARKER:-}" ]; then
    : > "${MOCK_INTERRUPT_MARKER}"
    kill -"${MOCK_INTERRUPT_SIGNAL:-TERM}" "${PPID}"
fi
exit "${status}"
EOF

    cat > "${MOCK_BIN}/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "replace-destination" ]; then
    destination="${4}"
    target="${destination##*/}"
    if [ -n "${MOCK_MV_FAIL_TARGET:-}" ] &&
        [ "${target}" = "${MOCK_MV_FAIL_TARGET}" ] &&
        [ ! -e "${MOCK_MV_FAILURE_MARKER:-}" ]; then
        if [ -n "${MOCK_MV_CONCURRENT_TARGET:-}" ] &&
            [ "${target}" = "${MOCK_MV_CONCURRENT_TARGET}" ]; then
            printf 'concurrent content\n' > "${destination}"
        fi
        : > "${MOCK_MV_FAILURE_MARKER}"
        exit 1
    fi
fi

if [ "${2:-}" = "backup-destination" ]; then
    destination="${3}"
    target="${destination##*/}"
    if [ -n "${MOCK_BACKUP_SIGNAL_TARGET:-}" ] &&
        [ "${target}" = "${MOCK_BACKUP_SIGNAL_TARGET}" ] &&
        [ ! -e "${MOCK_BACKUP_SIGNAL_MARKER:-}" ]; then
        # Let the real helper move the original, but discard its identity
        # report before signalling the caller. This reproduces a signal in the
        # window between the namespace change and caller-side bookkeeping.
        /usr/bin/python3 "$@" >/dev/null
        status="${?}"
        if [ "${status}" -eq 0 ]; then
            : > "${MOCK_BACKUP_SIGNAL_MARKER}"
            pid_file="${MOCK_INSTALLER_PID_FILE:-}"
            for _ in {1..100}; do
                [ -s "${pid_file}" ] && break
                sleep 0.01
            done
            if [ -s "${pid_file}" ]; then
                installer_pid="$(< "${pid_file}")"
                kill -TERM "${installer_pid}" 2>/dev/null || true
            fi
        fi
        exit "${status}"
    fi
fi

if [ "${2:-}" != "replace-destination" ]; then
    exec /usr/bin/python3 "$@"
fi

/usr/bin/python3 "$@"
status="${?}"
if [ "${2:-}" = "replace-destination" ] && [ "${status}" -eq 0 ] &&
    [ -n "${MOCK_INTERRUPT_AFTER_TARGET:-}" ]; then
    destination="${4}"
    target="${destination##*/}"
    if [ "${target}" = "${MOCK_INTERRUPT_AFTER_TARGET}" ] &&
        [ ! -e "${MOCK_INTERRUPT_MARKER:-}" ]; then
        : > "${MOCK_INTERRUPT_MARKER}"
        kill -"${MOCK_INTERRUPT_SIGNAL:-TERM}" "${PPID}"
    fi
fi
exit "${status}"
EOF

    cat > "${MOCK_BIN}/install" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_INTERRUPT_DURING_INSTALL:-0}" = "1" ] &&
    [ ! -e "${MOCK_INTERRUPT_INSTALL_MARKER:-}" ]; then
    : > "${MOCK_INTERRUPT_INSTALL_MARKER}"
    kill -TERM "${PPID}"
    exit 1
fi
exec /usr/bin/install "$@"
EOF

    chmod +x \
        "${MOCK_BIN}/gum" \
        "${MOCK_BIN}/rpm" \
        "${MOCK_BIN}/uname" \
        "${MOCK_BIN}/curl" \
        "${MOCK_BIN}/install" \
        "${MOCK_BIN}/mv" \
        "${MOCK_BIN}/python3"
    export MOCK_SELECTED_TOOL="fd"
    export MOCK_CHOOSE_MARKER="${TEST_ROOT}/gum-choose-called"
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CHOOSE_FAIL=0
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/fd.tar.gz"
    export MOCK_CURL_LOG="${CURL_LOG}"
    export MOCK_CURL_FAIL=0
    export MOCK_CURL_FAIL_AFTER_OUTPUT=0
    export MOCK_MV_FAIL_TARGET=""
    export MOCK_MV_CONCURRENT_TARGET=""
    export MOCK_MV_FAILURE_MARKER="${TEST_ROOT}/mv-failure-marker"
    export MOCK_ROLLBACK_FAIL_TARGET=""
    export MOCK_ROLLBACK_FAIL_ONCE=0
    export MOCK_ROLLBACK_FAILURE_MARKER="${TEST_ROOT}/rollback-failure-marker"
    export MOCK_INTERRUPT_AFTER_TARGET=""
    export MOCK_INTERRUPT_SIGNAL="TERM"
    export MOCK_INTERRUPT_MARKER="${TEST_ROOT}/interrupt-marker"
    export MOCK_INTERRUPT_DURING_INSTALL=0
    export MOCK_INTERRUPT_INSTALL_MARKER="${TEST_ROOT}/interrupt-install-marker"
    export MOCK_BACKUP_SIGNAL_TARGET=""
    export MOCK_BACKUP_SIGNAL_MARKER="${TEST_ROOT}/backup-signal-marker"
    export MOCK_INSTALLER_PID_FILE="${TEST_ROOT}/installer.pid"

    write_manifest "$(sha256sum "${FIXTURE_ROOT}/fd.tar.gz" | cut -d' ' -f1)"
}

mock_rollback_failure() {
    local target="${1}"
    local fail_once="${2}"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local real_helper="${SANDBOX_REPO}/common/runtime-file-real.py"

    mv "${helper}" "${real_helper}"
    cat > "${helper}" <<'PY'
import os
import sys

real_helper = os.path.join(os.path.dirname(__file__), "runtime-file-real.py")
if (
    len(sys.argv) > 1
    and sys.argv[1] == "rollback"
    and sys.argv[2].endswith("/" + os.environ["MOCK_ROLLBACK_HELPER_TARGET"])
):
    marker = os.environ["MOCK_ROLLBACK_HELPER_MARKER"]
    fail_once = os.environ["MOCK_ROLLBACK_HELPER_FAIL_ONCE"] == "1"
    if not fail_once or not os.path.exists(marker):
        try:
            descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(descriptor)
        raise SystemExit(1)
os.execv(sys.executable, [sys.executable, real_helper, *sys.argv[1:]])
PY
    export MOCK_ROLLBACK_HELPER_TARGET="${target}"
    export MOCK_ROLLBACK_HELPER_FAIL_ONCE="${fail_once}"
    export MOCK_ROLLBACK_HELPER_MARKER="${TEST_ROOT}/rollback-helper-failure-marker"
}

write_manifest() {
    local checksum="${1}"

    cat > "${MANIFEST_FILE}" <<EOF
{
  "schema_version": 1,
  "tools": {
    "fd": {
      "version": "test-1",
      "description": "Find files by name or pattern.",
      "source": "example/fd",
      "assets": {
        "x86_64": {
          "url": "https://example.test/fd-test-1.tar.gz",
          "sha256": "${checksum}",
          "type": "tar.gz",
          "files": {"fd": "fd"}
        }
      }
    }
  }
}
EOF
}

run_installer() {
    local architecture="${1:-x86_64}"

    export MOCK_ARCHITECTURE="${architecture}"
    run env \
        PATH="${MOCK_BIN}:${PATH}" \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        CLI_TOOLS_ONLY=1 \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh"
}

run_installer_with_pid() {
    rm -f -- "${MOCK_INSTALLER_PID_FILE}"

    run env \
        PATH="${MOCK_BIN}:${PATH}" \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        CLI_TOOLS_ONLY=1 \
        bash -c \
            'printf "%s\n" "$$" > "$1"; exec bash "$2"' \
            _ "${MOCK_INSTALLER_PID_FILE}" \
            "${SANDBOX_REPO}/fedora-postinstall.sh"
}

run_extras_command() {
    run env \
        PATH="${MOCK_BIN}:${PATH}" \
        HOME="${TEST_HOME}" \
        XDG_CACHE_HOME="${TEST_ROOT}/cache" \
        TMPDIR="${TMP_ROOT}" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" extras "$@"
}

@test "extras manifest covers the authoritative tool registry" {
    run jq -e '.schema_version == 1' "${REPO_ROOT}/extras/tools-manifest.json"
    assert_success

    run bash -c \
        "source '${REPO_ROOT}/extras/tools-list.sh'; printf '%s\\n' \"\${CLI_TOOLS_LIST[@]}\" | sort > '${TEST_ROOT}/registry.txt'; jq -r '.tools | keys[]' '${REPO_ROOT}/extras/tools-manifest.json' | sort > '${TEST_ROOT}/manifest.txt'; diff -u '${TEST_ROOT}/registry.txt' '${TEST_ROOT}/manifest.txt'"
    assert_success
}

@test "every registered tool has a manifest-backed download wrapper" {
    run bash -c \
        "source '${REPO_ROOT}/extras/tools-list.sh'; for tool in \"\${CLI_TOOLS_LIST[@]}\"; do test -f '${REPO_ROOT}/extras/'\"\${tool}\"'-download.sh' || exit 1; grep -q \"^download_extras_tool \" '${REPO_ROOT}/extras/'\"\${tool}\"'-download.sh' || exit 1; done"
    assert_success
}

@test "extras descriptions are concise manifest metadata" {
    run jq -e '
        all(.tools[];
            (.description | type == "string") and
            (.description | length > 0) and
            (.description | length <= 100) and
            (.description | contains("\n") | not)
        )
    ' "${REPO_ROOT}/extras/tools-manifest.json"
    assert_success

    run bash -c \
        "source '${REPO_ROOT}/extras/tools-list.sh'; for tool in \"\${CLI_TOOLS_LIST[@]}\"; do grep -Fq \"extras_describe_tool \\\"\${tool}\\\"\" '${REPO_ROOT}/extras/'\"\${tool}\"'-download.sh' || exit 1; done"
    assert_success
}

@test "the README tool table matches manifest descriptions" {
    run bash -c \
        "jq -r '.tools | to_entries[] | [.key, .value.description] | @tsv' '${REPO_ROOT}/extras/tools-manifest.json' | while IFS=\$'\\t' read -r tool description; do printf '| \\x60%s\\x60 | %s |\\n' \"\${tool}\" \"\${description}\"; done > '${TEST_ROOT}/expected-tools.md'; sed -n '/^| .*binsider.* |/,/^| .*zellij.* |/p' '${REPO_ROOT}/README.md' > '${TEST_ROOT}/actual-tools.md'; diff -u '${TEST_ROOT}/expected-tools.md' '${TEST_ROOT}/actual-tools.md'"
    assert_success
}

@test "the extras manifest rejects missing tool descriptions" {
    jq 'del(.tools.fd.description)' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer
    assert_failure
    assert_output_contains "invalid command line tool manifest"
    assert_file_absent "${CURL_LOG}"
}

@test "extras manifest pins versions, URLs, and SHA-256 checksums" {
    run jq -e '
        .schema_version == 1 and
        ([.tools[] |
            .version | select(. == "" or . == "latest")
        ] | length == 0) and
        ([.tools[].assets[] |
            .sha256 | select(test("^[0-9a-f]{64}$") | not)
        ] | length == 0) and
        ([.tools[].assets[] |
            .url | select((test("^https://") | not) or contains("/releases/latest/"))
        ] | length == 0) and
        ([.tools[].assets[] |
            .files | to_entries[] |
            select((.key | startswith("/")) or
                (.key | contains("../")) or
                (.key | contains("..\\")) or
                (.value | test("^[^/]+$") | not))
        ] | length == 0)
    ' "${REPO_ROOT}/extras/tools-manifest.json"
    assert_success
}

@test "a real extras run creates and releases its installation lock" {
    run_extras_command --tools fd
    assert_success

    local cache_dir="${TEST_ROOT}/cache/fedora-postinstall"
    local lock_file="${cache_dir}/postinstall.lock"
    assert_file_exists "${lock_file}"
    run stat -c '%a' "${cache_dir}"
    assert_success
    assert_equal "${output}" "700"

    run stat -c '%a' "${lock_file}"
    assert_success
    assert_equal "${output}" "600"

    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    run stat -c '%a' "${artifact}"
    assert_success
    assert_equal "${output}" "600"

    run_extras_command --tools fd
    assert_success
    assert_output_contains "Using cached artifact for fd"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"
}

@test "extras artifacts are stored in the selected cache directory" {
    local cache_dir="${TEST_ROOT}/custom-cache"

    run_extras_command --tools fd --cache-dir "${cache_dir}"
    assert_success
    assert_file_exists \
        "${cache_dir}/extras/x86_64/fd/fd-test-1.tar.gz"
    assert_file_exists "${cache_dir}/postinstall.lock"
}

@test "a corrupt cached artifact is downloaded and verified again" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"

    run_extras_command --tools fd
    assert_success
    printf 'corrupt\n' > "${artifact}"
    rm -f "${CURL_LOG}"

    run_extras_command --tools fd
    assert_success
    assert_output_contains "Downloading fd test-1 (x86_64)"
    assert_output_contains "Verified SHA-256 checksum for fd"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"
}

@test "an unreadable cached artifact is downloaded and verified again" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"

    run_extras_command --tools fd
    assert_success
    chmod 0000 "${artifact}"
    rm -f "${CURL_LOG}"

    run_extras_command --tools fd
    assert_success
    assert_output_contains "Downloading fd test-1 (x86_64)"
    assert_output_contains "Verified SHA-256 checksum for fd"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"
}

@test "a failed download still reclaims stale interrupted artifacts" {
    local artifact_directory="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd"
    local stale_file="${artifact_directory}/.artifact-stale.tmp"

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'stale\n' > "${stale_file}"
    touch -d '2 hours ago' "${stale_file}"
    export MOCK_CURL_FAIL=1

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "download failed"
    assert_file_absent "${stale_file}"
}

@test "a failed update preserves the previous valid cached artifact" {
    local artifact_directory="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd"
    local previous_artifact="${artifact_directory}/fd-test-0.tar.gz"
    local source_namespace="${artifact_directory}/.fd-test-0.tar.gz.source.quarantine"
    local previous_identity

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    cp "${FIXTURE_ROOT}/fd.tar.gz" "${previous_artifact}"
    printf 'quarantine state\n' > "${source_namespace}"
    previous_identity=$(stat -c '%d:%i' -- "${previous_artifact}")
    export MOCK_CURL_FAIL=1

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "download failed"
    assert_file_exists "${previous_artifact}"
    run stat -c '%d:%i' -- "${previous_artifact}"
    assert_success
    assert_equal "${output}" "${previous_identity}"
    run sha256sum "${previous_artifact}"
    assert_success
    assert_output_contains "$(sha256sum "${FIXTURE_ROOT}/fd.tar.gz" | cut -d' ' -f1)"
    assert_file_exists "${source_namespace}"
}

@test "a cached artifact survives an unrelated snapshot copy failure" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    local expected_checksum
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local real_helper="${SANDBOX_REPO}/common/runtime-file-real.py"

    run_extras_command --tools fd
    assert_success
    expected_checksum=$(sha256sum "${artifact}" | cut -d' ' -f1)

    mv "${helper}" "${real_helper}"
    cat > "${helper}" <<'PY'
import os
import sys

real_helper = os.path.join(os.path.dirname(__file__), "runtime-file-real.py")
if len(sys.argv) > 1 and sys.argv[1] == "copy" and "/cache/fedora-postinstall/extras/" in sys.argv[2]:
    marker = os.environ["MOCK_CACHE_COPY_FAILURE_MARKER"]
    try:
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(descriptor)
        raise SystemExit(1)
os.execv(sys.executable, [sys.executable, real_helper, *sys.argv[1:]])
PY
    export MOCK_CACHE_COPY_FAILURE_MARKER="${TEST_ROOT}/cache-copy-failure"
    export MOCK_CURL_FAIL=1

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "download failed"
    assert_file_exists "${artifact}"
    run sha256sum "${artifact}"
    assert_success
    assert_output_contains "${expected_checksum}"
}

@test "a verified partial download is recovered without downloading it again" {
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local real_helper="${SANDBOX_REPO}/common/runtime-file-real.py"
    local failure_marker="${TEST_ROOT}/publish-failure-marker"

    mv "${helper}" "${real_helper}"
    cat > "${helper}" <<'PY'
import os
import sys

real_helper = os.path.join(os.path.dirname(__file__), "runtime-file-real.py")
if len(sys.argv) > 1 and sys.argv[1] == "publish":
    marker = os.environ["MOCK_PUBLISH_FAILURE_MARKER"]
    if not os.path.exists(marker):
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        raise SystemExit(1)
os.execv(sys.executable, [sys.executable, real_helper, *sys.argv[1:]])
PY
    export MOCK_PUBLISH_FAILURE_MARKER="${failure_marker}"

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "verified download was retained for retry"

    mv "${real_helper}" "${helper}"
    run_extras_command --tools fd
    assert_success
    assert_output_contains "Recovering a verified interrupted download"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"
}

@test "a checksum-valid partial survives a failed transfer" {
    local download_directory="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd"
    local partial

    export MOCK_CURL_FAIL_AFTER_OUTPUT=1
    run_extras_command --tools fd
    assert_failure
    assert_output_contains "verified download was retained for retry"

    partial=$(find "${download_directory}" -maxdepth 1 -type f -name '.artifact-*.tmp' -print -quit)
    assert_file_exists "${partial}"
    run sha256sum "${partial}"
    assert_success
    assert_output_contains "$(sha256sum "${FIXTURE_ROOT}/fd.tar.gz" | cut -d' ' -f1)"

    export MOCK_CURL_FAIL_AFTER_OUTPUT=0
    run_extras_command --tools fd
    assert_success
    assert_output_contains "Recovering a verified interrupted download"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"
}

@test "an older verified partial is recovered before stale pruning" {
    local download_directory="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd"
    local partial="${download_directory}/.artifact-interrupted.tmp"

    mkdir -p "${download_directory}"
    cp "${FIXTURE_ROOT}/fd.tar.gz" "${partial}"
    touch -d '2 hours ago' "${partial}"

    run_extras_command --tools fd
    assert_success
    assert_output_contains "Recovering a verified interrupted download"
    assert_file_absent "${CURL_LOG}"
}

@test "a symbolic-link cached artifact is rejected" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    local outside="${TEST_ROOT}/outside-artifact"

    run_extras_command --tools fd
    assert_success
    printf 'outside\n' > "${outside}"
    rm -f "${artifact}"
    ln -s "${outside}" "${artifact}"
    rm -f "${CURL_LOG}"

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "unsafe cached artifact"
    assert_file_absent "${CURL_LOG}"
    run cat "${outside}"
    assert_success
    assert_equal "${output}" "outside"
}

@test "a hard-linked cached artifact is rejected without changing the linked file" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    local outside="${TEST_ROOT}/outside-artifact"

    run_extras_command --tools fd
    assert_success
    cp "${artifact}" "${outside}"
    rm -f "${artifact}"
    ln "${outside}" "${artifact}"
    chmod 0644 "${outside}"
    rm -f "${CURL_LOG}"

    run_extras_command --tools fd
    assert_failure
    assert_output_contains "multiple hard links"
    assert_file_absent "${CURL_LOG}"
    run stat -c '%a' "${outside}"
    assert_success
    assert_equal "${output}" "644"
}

@test "a predictable partial-file symlink is not followed" {
    local artifact="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    local partial="${artifact}.part"
    local victim="${TEST_ROOT}/partial-victim"

    run_extras_command --tools fd
    assert_success
    rm -f "${artifact}"
    printf 'victim\n' > "${victim}"
    ln -s "${victim}" "${partial}"
    rm -f "${CURL_LOG}"

    run_extras_command --tools fd
    assert_success
    run cat "${victim}"
    assert_success
    assert_equal "${output}" "victim"
}

@test "a concurrent extras run exits with the lock contention status" {
    local lock_file="${TEST_ROOT}/contended.lock"
    local marker_file="${TEST_ROOT}/lock-holder-ready"
    local release_file="${TEST_ROOT}/release-lock-holder"
    local holder

    flock "${lock_file}" bash -c \
        'touch "$1"; while [ ! -e "$2" ]; do sleep 0.05; done' \
        _ "${marker_file}" "${release_file}" &
    holder="${!}"
    for _ in {1..100}; do
        [ -e "${marker_file}" ] && break
        sleep 0.05
    done
    if [ ! -e "${marker_file}" ]; then
        kill "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
        return 1
    fi

    run_extras_command --tools fd --lock-file "${lock_file}"
    touch "${release_file}"
    wait "${holder}" 2>/dev/null || true

    assert_equal "${status}" 75
    assert_output_contains "another installer is already running"
    assert_file_absent "${CURL_LOG}"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
}

@test "verified tools deploy atomically without leaving repository artifacts" {
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"

    run_installer
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    run grep -F 'fixture fd' "${TEST_HOME}/.local/bin/fd"
    assert_success

    assert_file_absent "${SANDBOX_REPO}/archives"
    assert_file_absent "${SANDBOX_REPO}/deploys"
    assert_file_absent "${SANDBOX_REPO}/fd.json"
    run find "${TMP_ROOT}" -maxdepth 1 -name 'fedora-postinstall-extras.*' -print
    assert_success
    refute_output_contains "fedora-postinstall-extras."
}

@test "an explicit tool selection bypasses the interactive chooser" {
    mkdir -p "${TEST_HOME}/.local/bin"

    run_extras_command --tools fd
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${MOCK_CHOOSE_MARKER}"
    run grep -Fx 'https://example.test/fd-test-1.tar.gz' "${CURL_LOG}"
    assert_success
}

@test "an unknown explicit tool fails before downloading" {
    run_extras_command --tools not-a-tool
    assert_failure
    assert_output_contains "unknown tool identifier"
    assert_file_absent "${CURL_LOG}"
    assert_file_absent "${MOCK_CHOOSE_MARKER}"
}

@test "resume invalidates extras when the manifest changes" {
    export POSTINSTALL_RESUME=1
    export POSTINSTALL_STATE_FILE="${TEST_ROOT}/resume-state.tsv"
    export POSTINSTALL_LOG_STDOUT=1

    run_installer
    assert_success
    run grep -Fx 'https://example.test/fd-test-1.tar.gz' "${CURL_LOG}"
    assert_success

    run_installer
    assert_success
    assert_output_contains "Resume: skipping completed module 'extras/additional-tools.sh'"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "1"

    jq '.tools.fd.version = "test-2" |
        .tools.fd.assets.x86_64.url = "https://example.test/fd-test-2.tar.gz"' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    local source_namespace="${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/.fd-test-1.tar.gz.source.quarantine"
    printf 'retained recovery state\n' > "${source_namespace}"

    run_installer
    assert_success
    refute_output_contains "Resume: skipping completed module 'extras/additional-tools.sh'"
    run grep -c '^https://' "${CURL_LOG}"
    assert_success
    assert_equal "${output}" "2"
    assert_file_absent \
        "${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-1.tar.gz"
    assert_file_exists \
        "${TEST_ROOT}/cache/fedora-postinstall/extras/x86_64/fd/fd-test-2.tar.gz"
    assert_file_exists "${source_namespace}"
}

@test "a checksum mismatch aborts before deployment" {
    write_manifest "0000000000000000000000000000000000000000000000000000000000000000"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"

    run_installer
    assert_failure
    assert_output_contains "checksum verification failed"
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    assert_file_absent "${SANDBOX_REPO}/archives"
    assert_file_absent "${SANDBOX_REPO}/deploys"
}

@test "only the tracked downloaded artifact is unpacked and deployed" {
    mkdir -p "${SANDBOX_REPO}/unrelated"
    printf '#!/usr/bin/env bash\nprintf "unrelated\\n"\n' > "${SANDBOX_REPO}/unrelated/tool"
    chmod +x "${SANDBOX_REPO}/unrelated/tool"
    tar -czf "${SANDBOX_REPO}/unrelated.tar.gz" -C "${SANDBOX_REPO}/unrelated" tool

    run_installer
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${TEST_HOME}/.local/bin/tool"
    assert_file_exists "${SANDBOX_REPO}/unrelated.tar.gz"
}

@test "unsafe archive paths are rejected before deployment" {
    mkdir -p "${FIXTURE_ROOT}/unsafe"
    printf 'escaped\n' > "${FIXTURE_ROOT}/unsafe/escape"
    tar -czf "${FIXTURE_ROOT}/unsafe.tar.gz" \
        --transform='s,^escape$,../escape,' \
        -C "${FIXTURE_ROOT}/unsafe" escape
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/unsafe.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/unsafe.tar.gz" | cut -d' ' -f1)"

    run_installer
    assert_failure
    assert_output_contains "archive contains an unsafe path"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${TEST_ROOT}/escape"
}

@test "an unsupported architecture is rejected before any download" {
    run_installer "aarch64"
    assert_failure
    assert_output_contains "not available for architecture aarch64"
    assert_file_absent "${CURL_LOG}"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
}

@test "a failed atomic replacement preserves the existing executable" {
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_MV_FAIL_TARGET="fd"

    run_installer
    assert_failure
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 -name '.fd.tmp.*' -print
    assert_success
    refute_output_contains ".fd.tmp."
}

@test "deployment replacement preserves a target changed between backup and replacement" {
    local deployment_directory="${TEST_ROOT}/deployment-target-race"
    local destination="${deployment_directory}/tool"
    local backup_directory="${deployment_directory}/backups"
    local backup="${backup_directory}/tool"
    local staged="${deployment_directory}/.tool.tmp"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local original_identity backup_identity staged_identity concurrent_identity

    mkdir -p "${deployment_directory}" "${backup_directory}"
    chmod 0700 "${deployment_directory}" "${backup_directory}"
    printf 'original content\n' > "${destination}"
    original_identity=$(stat -c '%d:%i' -- "${destination}")

    run python3 "${helper}" backup-destination \
        "${destination}" "${backup}" "${original_identity}"
    assert_success
    backup_identity=$(stat -c '%d:%i' -- "${backup}")
    assert_equal "${backup_identity}" "${original_identity}"

    printf 'staged content\n' > "${staged}"
    staged_identity=$(stat -c '%d:%i' -- "${staged}")
    printf 'concurrent content\n' > "${destination}"
    concurrent_identity=$(stat -c '%d:%i' -- "${destination}")

    run python3 "${helper}" replace-destination \
        "${staged}" "${destination}" "${staged_identity}"
    assert_failure
    run stat -c '%d:%i' -- "${destination}"
    assert_success
    assert_equal "${output}" "${concurrent_identity}"
    run grep -Fx 'concurrent content' "${destination}"
    assert_success
    run stat -c '%d:%i' -- "${backup}"
    assert_success
    assert_equal "${output}" "${original_identity}"
}

@test "rollback does not accept equal contents with a different inode" {
    local deployment_directory="${TEST_ROOT}/rollback-equal-content"
    local destination="${deployment_directory}/tool"
    local backup_directory="${deployment_directory}/backups"
    local backup="${backup_directory}/tool"
    local staged="${deployment_directory}/.tool.staged"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local original_identity backup_identity staged_identity concurrent_identity

    mkdir -p "${deployment_directory}" "${backup_directory}"
    chmod 0700 "${deployment_directory}" "${backup_directory}"
    printf 'identical content\n' > "${destination}"
    original_identity=$(stat -c '%d:%i' -- "${destination}")

    run python3 "${helper}" backup-destination \
        "${destination}" "${backup}" "${original_identity}"
    assert_success
    backup_identity=$(stat -c '%d:%i' -- "${backup}")
    printf 'identical content\n' > "${staged}"
    staged_identity=$(stat -c '%d:%i' -- "${staged}")
    printf 'identical content\n' > "${destination}"
    concurrent_identity=$(stat -c '%d:%i' -- "${destination}")
    if [ "${concurrent_identity}" = "${staged_identity}" ]; then
        printf 'expected the concurrent file to have a distinct inode\n' >&2
        return 1
    fi

    run python3 "${helper}" rollback \
        "${destination}" "${backup}" "${original_identity}" "${staged_identity}" \
        "${backup_identity}" 1
    assert_equal "${status}" 3
    run stat -c '%d:%i' -- "${destination}"
    assert_success
    assert_equal "${output}" "${concurrent_identity}"
    assert_file_exists "${backup}"
    run stat -c '%d:%i' -- "${backup}"
    assert_success
    assert_equal "${output}" "${backup_identity}"
}

@test "publication restores a source replaced by a directory or special file" {
    local test_script="${TEST_ROOT}/replace-source-type.py"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local case_name source_file destination_file expected_checksum

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_file", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

original_replace = module.os.replace


def replace_and_replace_source(source, destination, **keywords):
    original_replace(source, destination, **keywords)
    if os.path.basename(destination) == "destination.bin":
        os.unlink(sys.argv[3])
        if sys.argv[5] == "directory":
            os.mkdir(sys.argv[3], 0o700)
        else:
            os.mkfifo(sys.argv[3], 0o600)


module.os.replace = replace_and_replace_source
module.publish_file(sys.argv[3], sys.argv[4], sys.argv[6])
PY

    for case_name in directory fifo; do
        local case_directory="${TEST_ROOT}/source-replacement-${case_name}"
        source_file="${case_directory}/source.bin"
        destination_file="${case_directory}/destination.bin"
        mkdir -p "${case_directory}"
        chmod 0700 "${case_directory}"
        printf 'verified bytes\n' > "${source_file}"
        expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

        run python3 "${test_script}" \
            "${helper}" "${case_directory}" "${source_file}" \
            "${destination_file}" "${case_name}" "${expected_checksum}"
        assert_success
        assert_output_contains "replacement source was preserved"
        run grep -Fx 'verified bytes' "${destination_file}"
        assert_success
        if [ "${case_name}" = "directory" ]; then
            if [ ! -d "${source_file}" ]; then
                printf 'expected the replacement source directory to be restored\n' >&2
                return 1
            fi
        elif [ ! -p "${source_file}" ]; then
            printf 'expected the replacement source FIFO to be restored\n' >&2
            return 1
        fi
        run find "${case_directory}" -maxdepth 1 -name '.source.bin.source.*' -print
        assert_success
        refute_output_contains ".source.bin.source."
    done
}

@test "post-publication cleanup failure does not report publication failure" {
    local test_script="${TEST_ROOT}/publication-cleanup-failure.py"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local artifact_directory="${TEST_ROOT}/publication-cleanup-failure"
    local source_file="${artifact_directory}/source.bin"
    local destination_file="${artifact_directory}/destination.bin"
    local expected_checksum

    mkdir -p "${artifact_directory}"
    chmod 0700 "${artifact_directory}"
    printf 'verified bytes\n' > "${source_file}"
    expected_checksum=$(sha256sum "${source_file}" | cut -d' ' -f1)

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_file", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fail_cleanup(*_arguments, **_keywords):
    raise RuntimeError("forced cleanup failure")


module.remove_verified_source = fail_cleanup
module.publish_file(sys.argv[2], sys.argv[3], sys.argv[4])
PY

    run python3 "${test_script}" "${helper}" \
        "${source_file}" "${destination_file}" "${expected_checksum}"
    assert_success
    assert_output_contains "source cleanup failed"
    run grep -Fx 'verified bytes' "${destination_file}"
    assert_success
    assert_file_exists "${source_file}"
}

@test "successful rollback restores the original inode with one hard link" {
    local deployment_directory="${TEST_ROOT}/rollback-link-count"
    local destination="${deployment_directory}/tool"
    local backup_directory="${deployment_directory}/backups"
    local backup="${backup_directory}/tool"
    local staged="${deployment_directory}/.tool.tmp"
    local helper="${SANDBOX_REPO}/common/runtime-file.py"
    local original_identity backup_identity staged_identity

    mkdir -p "${deployment_directory}" "${backup_directory}"
    chmod 0700 "${deployment_directory}" "${backup_directory}"
    printf 'original content\n' > "${destination}"
    original_identity=$(stat -c '%d:%i' -- "${destination}")

    run python3 "${helper}" backup-destination \
        "${destination}" "${backup}" "${original_identity}"
    assert_success
    backup_identity=$(stat -c '%d:%i' -- "${backup}")
    printf 'staged content\n' > "${staged}"
    staged_identity=$(stat -c '%d:%i' -- "${staged}")
    run python3 "${helper}" replace-destination \
        "${staged}" "${destination}" "${staged_identity}"
    assert_success

    run python3 "${helper}" rollback \
        "${destination}" "${backup}" "${original_identity}" "${staged_identity}" \
        "${backup_identity}" 1
    assert_success
    run stat -c '%d:%i' -- "${destination}"
    assert_success
    assert_equal "${output}" "${original_identity}"
    run stat -c '%h' -- "${destination}"
    assert_success
    assert_equal "${output}" "1"
    run grep -Fx 'original content' "${destination}"
    assert_success
}

@test "rollback preserves a concurrent replacement and its recovery backup" {
    printf '#!/usr/bin/env bash\nprintf "second fixture\\n"\n' \
        > "${FIXTURE_ROOT}/package/fd2"
    chmod +x "${FIXTURE_ROOT}/package/fd2"
    tar -czf "${FIXTURE_ROOT}/concurrent.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd fd2
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/concurrent.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/concurrent.tar.gz" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.files = {"fd": "fd", "fd2": "fd2"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old fd\n' > "${TEST_HOME}/.local/bin/fd"
    printf 'old fd2\n' > "${TEST_HOME}/.local/bin/fd2"
    export MOCK_MV_FAIL_TARGET="fd2"
    export MOCK_MV_CONCURRENT_TARGET="fd2"

    run_installer
    assert_failure
    run grep -Fx 'old fd' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run grep -Fx 'concurrent content' "${TEST_HOME}/.local/bin/fd2"
    assert_success
    run grep -Fx 'old fd2' "${TEST_HOME}/.local/bin/fd2"
    assert_failure
    local recovered_fd2
    recovered_fd2=$(find "${TEST_HOME}/.local/bin" -maxdepth 2 -type f \
        -path '*/.fedora-postinstall-backups.*/fd2' -print -quit)
    if [ -z "${recovered_fd2}" ]; then
        printf 'expected the original fd2 recovery backup to remain\n' >&2
        return 1
    fi
    run grep -Fx 'old fd2' "${recovered_fd2}"
    assert_success
}

@test "standalone artifacts are checksum-verified and deployed" {
    printf '#!/usr/bin/env bash\nprintf "raw fixture\\n"\n' > "${FIXTURE_ROOT}/fd-raw"
    chmod +x "${FIXTURE_ROOT}/fd-raw"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/fd-raw"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/fd-raw" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.url = "https://example.test/test-1/fd" |
        .tools.fd.assets.x86_64.type = "none" |
        .tools.fd.assets.x86_64.files = {"fd": "fd"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    run grep -F 'raw fixture' "${TEST_HOME}/.local/bin/fd"
    assert_success
}

@test "a symbolic-link destination is replaced without following the link" {
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'outside content\n' > "${TEST_ROOT}/outside"
    ln -s "${TEST_ROOT}/outside" "${TEST_HOME}/.local/bin/fd"

    run_installer
    assert_success
    if [ -L "${TEST_HOME}/.local/bin/fd" ]; then
        printf 'expected deployed command not to remain a symbolic link\n' >&2
        return 1
    fi
    run grep -F 'fixture fd' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run grep -Fx 'outside content' "${TEST_ROOT}/outside"
    assert_success
}

@test "a hard-linked destination is rejected before replacement" {
    local destination="${TEST_HOME}/.local/bin/fd"
    local external="${TEST_ROOT}/external-fd"

    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'external content\n' > "${external}"
    ln "${external}" "${destination}"

    run_installer
    assert_failure
    assert_output_contains "multiple hard links"
    run grep -Fx 'external content' "${external}"
    assert_success
}

@test "a directory destination is rejected before replacement" {
    mkdir -p "${TEST_HOME}/.local/bin/fd"

    run_installer
    assert_failure
    assert_output_contains "deployment target is a directory"
    if [ ! -d "${TEST_HOME}/.local/bin/fd" ]; then
        printf 'expected destination directory to remain intact\n' >&2
        return 1
    fi
}

@test "an interruption during file staging removes temporary files" {
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_INTERRUPT_DURING_INSTALL=1

    run_installer
    assert_equal "${status}" 143
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 -name '.*.tmp.*' -print
    assert_success
    refute_output_contains ".tmp."
}

@test "an interrupted deployment is rolled back during cleanup" {
    printf '#!/usr/bin/env bash\nprintf "second fixture\\n"\n' \
        > "${FIXTURE_ROOT}/package/fd2"
    chmod +x "${FIXTURE_ROOT}/package/fd2"
    tar -czf "${FIXTURE_ROOT}/interrupt.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd fd2
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/interrupt.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/interrupt.tar.gz" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.files = {"fd": "fd", "fd2": "fd2"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_INTERRUPT_AFTER_TARGET="fd"

    run_installer
    assert_equal "${status}" 143
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 \
        -type d -name '.fedora-postinstall-backups.*' -print
    assert_success
    refute_output_contains ".fedora-postinstall-backups."
}

@test "a signal after backup move restores the original by exact identity" {
    local destination="${TEST_HOME}/.local/bin/fd"
    local original_identity

    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${destination}"
    original_identity=$(stat -c '%d:%i' -- "${destination}")
    export MOCK_BACKUP_SIGNAL_TARGET="fd"

    run_installer_with_pid
    assert_equal "${status}" 143
    assert_file_exists "${MOCK_BACKUP_SIGNAL_MARKER}"
    run stat -c '%d:%i' -- "${destination}"
    assert_success
    assert_equal "${output}" "${original_identity}"
    run grep -Fx 'old content' "${destination}"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 \
        -type d -name '.fedora-postinstall-backups.*' -print
    assert_success
    refute_output_contains ".fedora-postinstall-backups."
}

@test "lock loss immediately after a deployment rename rolls back the replacement" {
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_INTERRUPT_AFTER_TARGET="fd"
    export MOCK_INTERRUPT_SIGNAL="USR1"

    run_installer
    assert_equal "${status}" "141"
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 \
        -type d -name '.fedora-postinstall-backups.*' -print
    assert_success
    refute_output_contains ".fedora-postinstall-backups."
}

@test "rollback retries idempotently after a transient restoration failure" {
    printf '#!/usr/bin/env bash\nprintf "second fixture\\n"\n' \
        > "${FIXTURE_ROOT}/package/fd2"
    chmod +x "${FIXTURE_ROOT}/package/fd2"
    tar -czf "${FIXTURE_ROOT}/retry.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd fd2
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/retry.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/retry.tar.gz" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.files = {"fd": "fd", "fd2": "fd2"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_MV_FAIL_TARGET="fd2"
    mock_rollback_failure "fd" 1

    run_installer
    assert_failure
    assert_output_contains "rollback was incomplete"
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 \
        -type d -name '.fedora-postinstall-backups.*' -print
    assert_success
    refute_output_contains ".fedora-postinstall-backups."
}

@test "a failed rollback preserves recovery backups" {
    printf '#!/usr/bin/env bash\nprintf "second fixture\\n"\n' \
        > "${FIXTURE_ROOT}/package/fd2"
    chmod +x "${FIXTURE_ROOT}/package/fd2"
    tar -czf "${FIXTURE_ROOT}/rollback.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd fd2
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/rollback.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/rollback.tar.gz" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.files = {"fd": "fd", "fd2": "fd2"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_MV_FAIL_TARGET="fd2"
    mock_rollback_failure "fd" 0

    run_installer
    assert_failure
    assert_output_contains "rollback was incomplete"
    run grep -F 'fixture fd' "${TEST_HOME}/.local/bin/fd"
    assert_success
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 \
        -type d -name '.fedora-postinstall-backups.*' -print
    assert_success
    assert_output_contains ".fedora-postinstall-backups."
}

@test "a failed tool selection aborts without downloading" {
    export MOCK_CHOOSE_FAIL=1

    run_installer
    assert_failure
    assert_output_contains "Unable to read the command line tool selection"
    assert_file_absent "${CURL_LOG}"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
}

@test "unknown selections cannot become arbitrary sourced files" {
    export MOCK_SELECTED_TOOL="../../tmp/evil"

    run_installer
    assert_success
    assert_output_contains "Ignoring unknown command line tool"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${CURL_LOG}"
}

@test "architecture aliases select the declared native asset" {
    jq '.tools.fd.assets.aarch64 = (.tools.fd.assets.x86_64 |
        .url = "https://example.test/fd-test-1-aarch64.tar.gz")' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer "arm64"
    assert_success
    run grep -Fx 'https://example.test/fd-test-1-aarch64.tar.gz' "${CURL_LOG}"
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
}

@test "undeclared executables in a selected archive are not deployed" {
    printf '#!/usr/bin/env bash\nprintf "extra\\n"\n' > "${FIXTURE_ROOT}/package/extra"
    chmod +x "${FIXTURE_ROOT}/package/extra"
    tar -czf "${FIXTURE_ROOT}/with-extra.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd extra
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/with-extra.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/with-extra.tar.gz" | cut -d' ' -f1)"

    run_installer
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${TEST_HOME}/.local/bin/extra"
}

@test "ZIP archives extract only their declared member" {
    mkdir -p "${FIXTURE_ROOT}/zip-package"
    printf '#!/usr/bin/env bash\nprintf "zip fixture\\n"\n' \
        > "${FIXTURE_ROOT}/zip-package/fd"
    chmod +x "${FIXTURE_ROOT}/zip-package/fd"
    python3 - "${FIXTURE_ROOT}/fd.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.write(sys.argv[1].replace("fd.zip", "zip-package/fd"), "zip-package/fd")
PY
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/fd.zip"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/fd.zip" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.type = "zip" |
        .tools.fd.assets.x86_64.files = {"zip-package/fd": "fd"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer
    assert_success
    assert_file_exists "${TEST_HOME}/.local/bin/fd"
    run grep -F 'zip fixture' "${TEST_HOME}/.local/bin/fd"
    assert_success
}

@test "archive symbolic and hard links are rejected" {
    mkdir -p "${FIXTURE_ROOT}/links"
    printf 'payload\n' > "${FIXTURE_ROOT}/links/target"
    ln -s target "${FIXTURE_ROOT}/links/symlink"
    ln "${FIXTURE_ROOT}/links/target" "${FIXTURE_ROOT}/links/hardlink"
    tar -czf "${FIXTURE_ROOT}/links.tar.gz" \
        -C "${FIXTURE_ROOT}/links" target symlink hardlink
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/links.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/links.tar.gz" | cut -d' ' -f1)"

    run_installer
    assert_failure
    assert_output_contains "link or special file"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
}

@test "ZIP traversal is rejected before deployment" {
    python3 - "${FIXTURE_ROOT}/unsafe.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("../escape", "escaped\n")
PY
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/unsafe.zip"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/unsafe.zip" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.type = "zip"' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer
    assert_failure
    assert_output_contains "archive contains an unsafe path"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
    assert_file_absent "${TEST_ROOT}/escape"
}

@test "selected tools with duplicate command targets are rejected before download" {
    jq '.tools.f2 = {
        "version": "test-2",
        "description": "Rename files and directories in batches.",
        "source": "example/f2",
        "assets": {
            "x86_64": {
                "url": "https://example.test/f2-test-2.tar.gz",
                "sha256": .tools.fd.assets.x86_64.sha256,
                "type": "tar.gz",
                "files": {"fd": "fd"}
            }
        }
    }' "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    export MOCK_SELECTED_TOOLS=$'fd\nf2'

    run_installer
    assert_failure
    assert_output_contains "deploy the same command"
    assert_file_absent "${CURL_LOG}"
    assert_file_absent "${TEST_HOME}/.local/bin/fd"
}

@test "a failed download prevents every selected tool from being deployed" {
    jq '.tools.f2 = {
        "version": "test-2",
        "description": "Rename files and directories in batches.",
        "source": "example/f2",
        "assets": {
            "x86_64": {
                "url": "https://example.test/f2-test-2.tar.gz",
                "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
                "type": "tar.gz",
                "files": {"f2": "f2"}
            }
        }
    }' "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    export MOCK_SELECTED_TOOLS=$'fd\nf2'
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"

    run_installer
    assert_failure
    assert_output_contains "checksum verification failed"
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
}

@test "a failed multi-file replacement rolls back the original file" {
    printf '#!/usr/bin/env bash\nprintf "second fixture\\n"\n' \
        > "${FIXTURE_ROOT}/package/fd2"
    chmod +x "${FIXTURE_ROOT}/package/fd2"
    tar -czf "${FIXTURE_ROOT}/two.tar.gz" \
        -C "${FIXTURE_ROOT}/package" fd fd2
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/two.tar.gz"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/two.tar.gz" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.files = {"fd": "fd", "fd2": "fd2"}' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"
    mkdir -p "${TEST_HOME}/.local/bin"
    printf 'old content\n' > "${TEST_HOME}/.local/bin/fd"
    export MOCK_MV_FAIL_TARGET="fd2"

    run_installer
    assert_failure
    run grep -Fx 'old content' "${TEST_HOME}/.local/bin/fd"
    assert_success
    assert_file_absent "${TEST_HOME}/.local/bin/fd2"
    run find "${TEST_HOME}/.local/bin" -maxdepth 1 -name '.*.tmp.*' -print
    assert_success
    refute_output_contains ".tmp."
}
