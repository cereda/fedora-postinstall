#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/extras"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    FIXTURE_ROOT="${TEST_ROOT}/fixture"
    TMP_ROOT="${TEST_ROOT}/tmp"
    MANIFEST_FILE="${TEST_ROOT}/manifest.json"
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
if [ -n "${output}" ]; then
    cp "${MOCK_CURL_SOURCE}" "${output}"
fi
EOF

    cat > "${MOCK_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
if [ -n "${MOCK_MV_FAIL_TARGET:-}" ] && [[ "${destination}" == */"${MOCK_MV_FAIL_TARGET}" ]]; then
    exit 1
fi
exec /usr/bin/mv "$@"
EOF

    chmod +x "${MOCK_BIN}/gum" "${MOCK_BIN}/rpm" "${MOCK_BIN}/curl" "${MOCK_BIN}/mv"
    export MOCK_SELECTED_TOOL="fd"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/fd.tar.gz"
    export MOCK_CURL_LOG="${CURL_LOG}"
    export MOCK_MV_FAIL_TARGET=""

    write_manifest "$(sha256sum "${FIXTURE_ROOT}/fd.tar.gz" | cut -d' ' -f1)"
}

write_manifest() {
    local checksum="${1}"

    cat > "${MANIFEST_FILE}" <<EOF
{
  "schema_version": 1,
  "tools": {
    "fd": {
      "version": "test-1",
      "source": "example/fd",
      "assets": {
        "x86_64": {
          "url": "https://example.test/fd-v1.tar.gz",
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
    local architecture="${1:-}"

    if [ -n "${architecture}" ]; then
        run env \
            PATH="${MOCK_BIN}:${PATH}" \
            HOME="${TEST_HOME}" \
            TMPDIR="${TMP_ROOT}" \
            CLI_TOOLS_ONLY=1 \
            EXTRAS_MANIFEST_FILE="${MANIFEST_FILE}" \
            EXTRAS_ARCHITECTURE="${architecture}" \
            bash "${SANDBOX_REPO}/fedora-postinstall.sh"
    else
        run env \
            PATH="${MOCK_BIN}:${PATH}" \
            HOME="${TEST_HOME}" \
            TMPDIR="${TMP_ROOT}" \
            CLI_TOOLS_ONLY=1 \
            EXTRAS_MANIFEST_FILE="${MANIFEST_FILE}" \
            bash "${SANDBOX_REPO}/fedora-postinstall.sh"
    fi
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

@test "standalone artifacts are checksum-verified and deployed" {
    printf '#!/usr/bin/env bash\nprintf "raw fixture\\n"\n' > "${FIXTURE_ROOT}/fd-raw"
    chmod +x "${FIXTURE_ROOT}/fd-raw"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/fd-raw"
    write_manifest "$(sha256sum "${FIXTURE_ROOT}/fd-raw" | cut -d' ' -f1)"
    jq '.tools.fd.assets.x86_64.url = "https://example.test/fd-raw" |
        .tools.fd.assets.x86_64.type = "none" |
        .tools.fd.assets.x86_64.files = {"fd-raw": "fd"}' \
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
        .url = "https://example.test/fd-v1-aarch64.tar.gz")' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_installer "arm64"
    assert_success
    run grep -Fx 'https://example.test/fd-v1-aarch64.tar.gz' "${CURL_LOG}"
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
    (cd "${FIXTURE_ROOT}" && zip -q fd.zip zip-package/fd)
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
        "source": "example/f2",
        "assets": {
            "x86_64": {
                "url": "https://example.test/f2-v1.tar.gz",
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
        "source": "example/f2",
        "assets": {
            "x86_64": {
                "url": "https://example.test/f2-v1.tar.gz",
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
