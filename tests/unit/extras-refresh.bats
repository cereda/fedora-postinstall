#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/extras-refresh"
    SANDBOX="${TEST_ROOT}/repository"
    MOCK_BIN="${TEST_ROOT}/bin"
    FIXTURES="${TEST_ROOT}/fixtures"
    MANIFEST_FILE="${SANDBOX}/extras/tools-manifest.json"
    CONFIG_FILE="${SANDBOX}/tools/extras-refresh-config.json"

    mkdir -p \
        "${SANDBOX}/extras" \
        "${SANDBOX}/tools" \
        "${SANDBOX}/tests/unit" \
        "${MOCK_BIN}" \
        "${FIXTURES}/package"

    cat > "${SANDBOX}/extras/tools-list.sh" <<'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
declare -g -t CLI_TOOLS_LIST=(
    "fd"
    "ncdu"
    "unimatrix"
)
if [ -n "${MOCK_TOKEN_PROBE:-}" ]; then
    if [ "${GITHUB_TOKEN+x}" = "x" ]; then
        printf 'present\n' > "${MOCK_TOKEN_PROBE}"
    else
        printf 'absent\n' > "${MOCK_TOKEN_PROBE}"
    fi
fi
if [ -n "${MOCK_TOKEN_PROC_PROBE:-}" ]; then
    if parent_environment="$(tr '\0' '\n' < "/proc/${PPID}/environ" 2>/dev/null)"; then
        if ! printf '%s\n' "${parent_environment}" | grep -q '^MOCK_PARENT_ENV_MARKER='; then
            printf 'blocked\n' >> "${MOCK_TOKEN_PROC_PROBE}"
        elif printf '%s\n' "${parent_environment}" | grep -q '^GITHUB_TOKEN='; then
            printf 'leaked\n' >> "${MOCK_TOKEN_PROC_PROBE}"
        else
            printf 'absent\n' >> "${MOCK_TOKEN_PROC_PROBE}"
        fi
    else
        printf 'blocked\n' >> "${MOCK_TOKEN_PROC_PROBE}"
    fi
fi
EOF

    mkdir -p \
        "${FIXTURES}/package/fd-v2.0.0-x86_64-unknown-linux-gnu" \
        "${FIXTURES}/package/fd-v2.0.0-aarch64-unknown-linux-gnu" \
        "${FIXTURES}/package/ncdu"
    printf '%s\n' 'fd-x86_64' > \
        "${FIXTURES}/package/fd-v2.0.0-x86_64-unknown-linux-gnu/fd"
    printf '%s\n' 'fd-aarch64' > \
        "${FIXTURES}/package/fd-v2.0.0-aarch64-unknown-linux-gnu/fd"
    printf '%s\n' 'ncdu-binary' > "${FIXTURES}/package/ncdu/ncdu"
    tar -czf "${FIXTURES}/fd-x86_64.tar.gz" -C "${FIXTURES}/package" \
        fd-v2.0.0-x86_64-unknown-linux-gnu
    tar -czf "${FIXTURES}/fd-aarch64.tar.gz" -C "${FIXTURES}/package" \
        fd-v2.0.0-aarch64-unknown-linux-gnu
    tar -czf "${FIXTURES}/ncdu-x86_64.tar.gz" -C "${FIXTURES}/package" ncdu
    tar -czf "${FIXTURES}/ncdu-aarch64.tar.gz" -C "${FIXTURES}/package" ncdu
    printf '%s\n' '#!/usr/bin/env python3' 'print("unimatrix")' > \
        "${FIXTURES}/unimatrix.py"

    local fd_x86_checksum fd_aarch_checksum ncdu_x86_checksum ncdu_aarch_checksum
    local fd_x86_size fd_aarch_size
    fd_x86_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    fd_aarch_checksum="$(sha256sum "${FIXTURES}/fd-aarch64.tar.gz" | cut -d' ' -f1)"
    ncdu_x86_checksum="$(sha256sum "${FIXTURES}/ncdu-x86_64.tar.gz" | cut -d' ' -f1)"
    ncdu_aarch_checksum="$(sha256sum "${FIXTURES}/ncdu-aarch64.tar.gz" | cut -d' ' -f1)"
    fd_x86_size="$(stat -c '%s' "${FIXTURES}/fd-x86_64.tar.gz")"
    fd_aarch_size="$(stat -c '%s' "${FIXTURES}/fd-aarch64.tar.gz")"
    printf '%s  fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz\n' \
        "${fd_x86_checksum}" > "${FIXTURES}/fd.sha256"
    printf '%s  fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz\n' \
        "${fd_aarch_checksum}" > "${FIXTURES}/fd-aarch64.sha256"

    cat > "${FIXTURES}/releases.json" <<EOF
[
  {
    "tag_name": "v3.0.0-alpha.1",
    "published_at": "2026-03-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v3.0.0-alpha.1-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v3.0.0-alpha.1/fd-v3.0.0-alpha.1-x86_64-unknown-linux-gnu.tar.gz"
      },
      {
        "name": "fd-v3.0.0-alpha.1-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v3.0.0-alpha.1/fd-v3.0.0-alpha.1-aarch64-unknown-linux-gnu.tar.gz"
      }
    ]
  },
  {
    "tag_name": "v2.0.0",
    "published_at": "2026-01-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "size": ${fd_x86_size},
        "digest": "sha256:${fd_x86_checksum}"
      },
      {
        "name": "fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "size": ${fd_aarch_size},
        "digest": "sha256:${fd_aarch_checksum}"
      }
    ]
  }
]
EOF

    cat > "${FIXTURES}/releases-sidecar.json" <<EOF
[
  {
    "tag_name": "v2.0.0",
    "published_at": "2026-01-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "size": ${fd_x86_size}
      },
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
      },
      {
        "name": "fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "size": ${fd_aarch_size},
        "digest": "sha256:${fd_aarch_checksum}"
      }
    ]
  }
]
EOF

    cat > "${FIXTURES}/releases-calculated.json" <<EOF
[
  {
    "tag_name": "v2.0.0",
    "published_at": "2026-01-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "size": ${fd_x86_size}
      },
      {
        "name": "fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "size": ${fd_aarch_size}
      }
    ]
  }
]
EOF

    cat > "${FIXTURES}/releases-ambiguous.json" <<EOF
[
  {
    "tag_name": "v2.0.0",
    "published_at": "2026-01-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz"
      },
      {
        "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu-copy.tar.gz"
      },
      {
        "name": "fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz"
      }
    ]
  }
]
EOF

    cat > "${FIXTURES}/releases-missing.json" <<EOF
[
  {
    "tag_name": "v2.0.0",
    "published_at": "2026-01-02T00:00:00Z",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz",
        "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-aarch64-unknown-linux-gnu.tar.gz"
      }
    ]
  }
]
EOF

    cat > "${FIXTURES}/commit.json" <<'EOF'
{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
EOF

    cat > "${FIXTURES}/commit-compare.json" <<'EOF'
{
  "status": "ahead",
  "ahead_by": 1,
  "behind_by": 0,
  "total_commits": 1,
  "base_commit": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  "merge_base_commit": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  "head_commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
}
EOF

    cat > "${FIXTURES}/ncdu.html" <<EOF
<dt><a id="ncdu-3.0.0-linux-x86_64.tar.gz" href="/download/ncdu-3.0.0-linux-x86_64.tar.gz">ncdu-3.0.0-linux-x86_64.tar.gz</a></dt>
<dd><table><tr><td>SHA256</td><td>${ncdu_x86_checksum}</td></tr></table></dd>
<dt><a id="ncdu-3.0.0-linux-aarch64.tar.gz" href="/download/ncdu-3.0.0-linux-aarch64.tar.gz">ncdu-3.0.0-linux-aarch64.tar.gz</a></dt>
<dd><table><tr><td>SHA256</td><td>${ncdu_aarch_checksum}</td></tr></table></dd>
EOF

    cat > "${CONFIG_FILE}" <<'EOF'
{
  "schema_version": 2,
  "excluded_rolling_tools": ["distrobox", "direnv", "starship"],
  "unstable_tag_patterns": [
    "(?i)(?:alpha|beta|rc|nightly|dev(?:elopment)?)(?:[-_.]|$)"
  ],
  "tools": {
    "fd": {
      "mode": "release",
      "source": "example/fd",
      "assets": {
        "x86_64": {
          "pattern": "^fd-v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?-x86_64-unknown-linux-gnu\\.tar\\.gz$",
          "type": "tar.gz",
          "files": {"fd": "fd"}
        },
        "aarch64": {
          "pattern": "^fd-v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?-aarch64-unknown-linux-gnu\\.tar\\.gz$",
          "type": "tar.gz",
          "files": {"fd": "fd"}
        }
      }
    },
    "ncdu": {
      "mode": "ncdu",
      "source": "yorhel/ncdu",
      "assets": {
        "x86_64": {
          "pattern": "^ncdu-[0-9]+(?:\\.[0-9]+)+-linux-x86_64\\.tar\\.gz$",
          "type": "tar.gz",
          "files": {"ncdu": "ncdu"}
        },
        "aarch64": {
          "pattern": "^ncdu-[0-9]+(?:\\.[0-9]+)+-linux-aarch64\\.tar\\.gz$",
          "type": "tar.gz",
          "files": {"ncdu": "ncdu"}
        }
      }
    },
    "unimatrix": {
      "mode": "commit",
      "source": "example/unimatrix",
      "ref": "master",
      "path": "unimatrix.py",
      "assets": {
        "any": {
          "pattern": null,
          "type": "none",
          "files": {"unimatrix.py": "unimatrix"}
        }
      }
    }
  }
}
EOF

    cat > "${MANIFEST_FILE}" <<EOF
{
  "schema_version": 1,
  "tools": {
    "fd": {
      "version": "v1.0.0",
      "description": "Find files by name or pattern.",
      "source": "example/fd",
      "assets": {
        "x86_64": {
          "url": "https://github.com/example/fd/releases/download/v1.0.0/fd-v1.0.0-x86_64-unknown-linux-gnu.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "type": "tar.gz",
          "files": {"fd": "fd"}
        },
        "aarch64": {
          "url": "https://github.com/example/fd/releases/download/v1.0.0/fd-v1.0.0-aarch64-unknown-linux-gnu.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "type": "tar.gz",
          "files": {"fd": "fd"}
        }
      }
    },
    "ncdu": {
      "version": "2.0.0",
      "description": "Browse disk usage interactively.",
      "source": "yorhel/ncdu",
      "assets": {
        "x86_64": {
          "url": "https://dev.yorhel.nl/download/ncdu-2.0.0-linux-x86_64.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "type": "tar.gz",
          "files": {"ncdu": "ncdu"}
        },
        "aarch64": {
          "url": "https://dev.yorhel.nl/download/ncdu-2.0.0-linux-aarch64.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "type": "tar.gz",
          "files": {"ncdu": "ncdu"}
        }
      }
    },
    "unimatrix": {
      "version": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "description": "Display terminal matrices.",
      "source": "example/unimatrix",
      "assets": {
        "any": {
          "url": "https://raw.githubusercontent.com/example/unimatrix/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/unimatrix.py",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "type": "none",
          "files": {"unimatrix.py": "unimatrix"}
        }
      }
    }
  }
}
EOF

    cat > "${SANDBOX}/tests/unit/extras.bats" <<'EOF'
#!/usr/bin/env bats
@test "sandbox extras validation" {
    true
}
EOF

    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
url=""
config=""
max_redirs=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="${2:-}"
            shift 2
            ;;
        --config)
            config="${2:-}"
            shift 2
            ;;
        --max-redirs)
            max_redirs="${2:-}"
            shift 2
            ;;
        --write-out | --user-agent | --header)
            shift 2
            ;;
        --connect-timeout | --max-time | --max-filesize | --proto)
            shift 2
            ;;
        --disable | --location | --silent | --show-error | --fail | --tlsv1.2)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

if [ -n "${config}" ]; then
    if [ "${max_redirs}" != "0" ]; then
        printf '%s\n' 'mock curl: authenticated API redirects must be disabled' >&2
        exit 92
    fi
    if [ "$(stat -c '%a' "${config}")" != "600" ]; then
        printf '%s\n' 'mock curl: token configuration must be private' >&2
        exit 92
    fi
    if ! grep -Eq \
        '^header = "Authorization: Bearer [A-Za-z0-9_-]+"$' "${config}"; then
        printf '%s\n' 'mock curl: token configuration is invalid' >&2
        exit 92
    fi
fi

if [ -n "${MOCK_REFRESH_DELAY:-}" ] &&
    [[ "${url}" == *api.github.com*/releases* ]]; then
    if [ -n "${MOCK_REFRESH_DELAY_MARKER:-}" ]; then
        touch "${MOCK_REFRESH_DELAY_MARKER}"
    fi
    sleep "${MOCK_REFRESH_DELAY}"
fi

emit_metadata() {
    local source="$1"
    local status="$2"
    if [ -n "${output}" ]; then
        cp "${source}" "${output}"
        return
    fi
    cat "${source}"
    printf '\n__fedora_postinstall_http_status__:%s' "${status}"
}

case "${url}" in
    *api.github.com*/releases*)
        if [[ "${url}" == *"page=2"* ]] &&
            [ -n "${MOCK_REFRESH_RELEASES_PAGE_2:-}" ]; then
            emit_metadata "${MOCK_REFRESH_RELEASES_PAGE_2}" 200
        else
            emit_metadata "${MOCK_REFRESH_RELEASES}" 200
        fi
        ;;
    *api.github.com*/compare/*)
        comparison_base="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        comparison_head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        if [[ "${url}" != *"/compare/${comparison_base}...${comparison_head}?"* ]]; then
            printf '%s\n' 'mock curl: commit comparison direction is invalid' >&2
            exit 92
        fi
        emit_metadata "${MOCK_REFRESH_COMPARE}" 200
        ;;
    *api.github.com*/commits/*)
        emit_metadata "${MOCK_REFRESH_COMMIT}" 200
        ;;
    https://dev.yorhel.nl/download)
        emit_metadata "${MOCK_REFRESH_NCDU_PAGE}" 200
        ;;
    *github.com/*checksum*)
        sidecar="${MOCK_REFRESH_SIDECAR}"
        if [ -n "${sidecar}" ] && [ -f "${sidecar}" ]; then
            emit_metadata "${sidecar}" 200
        else
            printf '\n__fedora_postinstall_http_status__:404'
        fi
        ;;
    *github.com/*sha256*)
        sidecar="${MOCK_REFRESH_SIDECAR}"
        if [[ "${url}" == *aarch64* ]] &&
            [ -f "${MOCK_REFRESH_AARCH64_SIDECAR}" ]; then
            sidecar="${MOCK_REFRESH_AARCH64_SIDECAR}"
        fi
        if [ -n "${sidecar}" ] && [ -f "${sidecar}" ]; then
            emit_metadata "${sidecar}" 200
        else
            printf '\n__fedora_postinstall_http_status__:404'
        fi
        ;;
    *github.com/*fd-v2.0.0-aarch64*)
        emit_metadata "${MOCK_REFRESH_FD_AARCH64}" 200
        ;;
    *github.com/*fd-v2.0.0-x86_64*)
        emit_metadata "${MOCK_REFRESH_FD_X86}" 200
        if [ -n "${MOCK_REFRESH_CONCURRENT_FILE:-}" ]; then
            printf '\n' >> "${MOCK_REFRESH_CONCURRENT_FILE}"
        fi
        ;;
    *dev.yorhel.nl/download/ncdu-3.0.0-linux-aarch64*)
        emit_metadata "${MOCK_REFRESH_NCDU_AARCH64}" 200
        ;;
    *dev.yorhel.nl/download/ncdu-3.0.0-linux-x86_64*)
        emit_metadata "${MOCK_REFRESH_NCDU_X86}" 200
        ;;
    *raw.githubusercontent.com*)
        emit_metadata "${MOCK_REFRESH_COMMIT_FILE}" 200
        ;;
    *)
        printf '\n__fedora_postinstall_http_status__:404'
        ;;
esac
EOF
    chmod +x "${MOCK_BIN}/curl"

    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases.json"
    export MOCK_REFRESH_COMMIT="${FIXTURES}/commit.json"
    export MOCK_REFRESH_COMPARE="${FIXTURES}/commit-compare.json"
    export MOCK_REFRESH_COMMIT_FILE="${FIXTURES}/unimatrix.py"
    export MOCK_REFRESH_NCDU_PAGE="${FIXTURES}/ncdu.html"
    export MOCK_REFRESH_FD_X86="${FIXTURES}/fd-x86_64.tar.gz"
    export MOCK_REFRESH_FD_AARCH64="${FIXTURES}/fd-aarch64.tar.gz"
    export MOCK_REFRESH_NCDU_X86="${FIXTURES}/ncdu-x86_64.tar.gz"
    export MOCK_REFRESH_NCDU_AARCH64="${FIXTURES}/ncdu-aarch64.tar.gz"
    export MOCK_REFRESH_SIDECAR=""
    export MOCK_REFRESH_AARCH64_SIDECAR="${FIXTURES}/fd-aarch64.sha256"
    export MOCK_REFRESH_RELEASES_PAGE_2=""
}

run_refresh() {
    run env \
        MOCK_REFRESH_RELEASES="${MOCK_REFRESH_RELEASES}" \
        MOCK_REFRESH_RELEASES_PAGE_2="${MOCK_REFRESH_RELEASES_PAGE_2:-}" \
        MOCK_REFRESH_COMMIT="${MOCK_REFRESH_COMMIT}" \
        MOCK_REFRESH_COMPARE="${MOCK_REFRESH_COMPARE}" \
        MOCK_REFRESH_COMMIT_FILE="${MOCK_REFRESH_COMMIT_FILE}" \
        MOCK_REFRESH_NCDU_PAGE="${MOCK_REFRESH_NCDU_PAGE}" \
        MOCK_REFRESH_FD_X86="${MOCK_REFRESH_FD_X86}" \
        MOCK_REFRESH_FD_AARCH64="${MOCK_REFRESH_FD_AARCH64}" \
        MOCK_REFRESH_NCDU_X86="${MOCK_REFRESH_NCDU_X86}" \
        MOCK_REFRESH_NCDU_AARCH64="${MOCK_REFRESH_NCDU_AARCH64}" \
        MOCK_REFRESH_SIDECAR="${MOCK_REFRESH_SIDECAR}" \
        MOCK_REFRESH_AARCH64_SIDECAR="${MOCK_REFRESH_AARCH64_SIDECAR}" \
        MOCK_REFRESH_CONCURRENT_FILE="${MOCK_REFRESH_CONCURRENT_FILE:-}" \
        MOCK_REFRESH_DELAY="${MOCK_REFRESH_DELAY:-}" \
        MOCK_REFRESH_DELAY_MARKER="${MOCK_REFRESH_DELAY_MARKER:-}" \
        MOCK_TOKEN_PROBE="${MOCK_TOKEN_PROBE:-}" \
        MOCK_TOKEN_PROC_PROBE="${MOCK_TOKEN_PROC_PROBE:-}" \
        MOCK_PARENT_ENV_MARKER="parent-marker" \
        GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        POSTINSTALL_REFRESH_TEST_MODE="${POSTINSTALL_REFRESH_TEST_MODE:-}" \
        POSTINSTALL_REFRESH_TEST_FAILPOINT="${POSTINSTALL_REFRESH_TEST_FAILPOINT:-}" \
        POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET="${POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET:-}" \
        POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT="${POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT:-}" \
        HOME="${REFRESH_HOME:-${HOME}}" \
        TMPDIR="${REFRESH_TMPDIR:-${TMPDIR:-/tmp}}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 "${REPO_ROOT}/tools/refresh-extras-manifest.py" \
        --repository "${SANDBOX}" "$@"
}

@test "the refresher default mode is read-only and shows its proposed diff" {
    local before
    before="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"

    run_refresh --tool fd
    assert_success
    assert_output_contains "Proposed manifest diff:"
    assert_output_contains '"version": "v2.0.0"'
    assert_output_contains "No changes were written"

    local after
    after="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"
    assert_equal "${after}" "${before}"
}

@test "the refresher check mode reports drift without changing the manifest" {
    local before
    before="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"

    run_refresh --tool fd --check
    assert_equal "${status}" "1"
    assert_output_contains "out of date"

    local after
    after="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"
    assert_equal "${after}" "${before}"
}

@test "the refresher writes a selected tool only with the explicit write option" {
    run_refresh --tool fd --write
    assert_success
    assert_output_contains "Updated"

    run jq -e '
        .tools.fd.version == "v2.0.0" and
        .tools.fd.assets.x86_64.url ==
            "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz"
    ' "${MANIFEST_FILE}"
    assert_success

    local expected_checksum
    expected_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    run jq -e --arg checksum "${expected_checksum}" \
        '.tools.fd.assets.x86_64.sha256 == $checksum' "${MANIFEST_FILE}"
    assert_success
}

@test "the refresher rejects rolling tools and invalid selections" {
    local tool
    for tool in distrobox direnv starship; do
        run_refresh --tool "${tool}"
        assert_equal "${status}" "69"
        assert_output_contains "rolling tools"
    done

    run_refresh --tool unknown
    assert_equal "${status}" "69"
    assert_output_contains "unknown tool"

    run_refresh --all --tool fd
    assert_equal "${status}" "64"
    assert_output_contains "cannot be used together"

    run_refresh --tool ,
    assert_equal "${status}" "64"
    assert_output_contains "select --tool NAME or --all"

    run_refresh --tool fd --check --write
    assert_equal "${status}" "64"
    assert_output_contains "cannot be used together"
}

@test "the refresher rejects ambiguous and incomplete architecture selections" {
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-ambiguous.json"
    run_refresh --tool fd
    assert_equal "${status}" "1"
    assert_output_contains "multiple x86_64 assets"

    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-missing.json"
    run_refresh --tool fd
    assert_equal "${status}" "69"
    assert_output_contains "missing x86_64 asset"
}

@test "the refresher rejects one release asset selected for both architectures" {
    local fixture="${FIXTURES}/releases-shared-architecture.json"

    jq '.tools.fd.assets.aarch64.pattern =
        "^fd-v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?-x86_64-unknown-linux-gnu\\.tar\\.gz$"' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets |= map(select(.name | contains("aarch64") | not))
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "same release asset is selected for multiple architectures"
}

@test "manifest validation rejects duplicate architecture assets" {
    jq '.tools.fd.assets.aarch64.url =
        .tools.fd.assets.x86_64.url' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_refresh --validate
    assert_failure
    assert_output_contains "architecture assets are not distinct"
}

@test "the refresher verifies an upstream checksum sidecar" {
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-sidecar.json"
    export MOCK_REFRESH_SIDECAR="${FIXTURES}/fd.sha256"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "upstream checksum asset"

    local expected_checksum
    expected_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    run jq -e --arg checksum "${expected_checksum}" \
        '.tools.fd.assets.x86_64.sha256 == $checksum' "${MANIFEST_FILE}"
    assert_success
}

@test "the refresher calculates a checksum when upstream does not publish one" {
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-calculated.json"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"

    local expected_checksum
    expected_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    run jq -e --arg checksum "${expected_checksum}" \
        '.tools.fd.assets.x86_64.sha256 == $checksum' "${MANIFEST_FILE}"
    assert_success
}

@test "the refresher rejects an upstream checksum mismatch" {
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-sidecar.json"
    printf '%s  %s\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${FIXTURES}/wrong.sha256"
    export MOCK_REFRESH_SIDECAR="${FIXTURES}/wrong.sha256"

    run_refresh --tool fd --write
    assert_equal "${status}" "1"
    assert_output_contains "checksum mismatch"
}

@test "a release API digest cannot hide a conflicting sidecar digest" {
    local fixture="${FIXTURES}/releases-conflicting-sidecar.json"
    local conflicting="${FIXTURES}/conflicting.sha256"

    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
            }]
        else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    printf '%s  %s\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${conflicting}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${conflicting}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "conflicting digests"
}

@test "GNU and BSD checksum sidecars require an exact filename match" {
    local fixture="${FIXTURES}/releases-gnu-sidecar.json"
    local sidecar="${FIXTURES}/gnu.sha256"
    local expected_checksum

    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    expected_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    printf 'SHA256 (fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz) = %s\n' \
        "${expected_checksum}" > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "upstream checksum asset"
    run jq -e --arg checksum "${expected_checksum}" \
        '.tools.fd.assets.x86_64.sha256 == $checksum' "${MANIFEST_FILE}"
    assert_success
}

@test "an unrelated GNU checksum entry cannot supply the candidate digest" {
    local sidecar="${FIXTURES}/unrelated-gnu.sha256"

    printf 'SHA256 (another-file.tar.gz) = %s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-calculated.json"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"
}

@test "GNU checksum sidecars support the binary filename marker" {
    local fixture="${FIXTURES}/releases-gnu-standard-sidecar.json"
    local sidecar="${FIXTURES}/gnu-standard.sha256"
    local expected_checksum

    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    expected_checksum="$(sha256sum "${FIXTURES}/fd-x86_64.tar.gz" | cut -d' ' -f1)"
    printf '%s *%s\n' \
        "${expected_checksum}" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "upstream checksum asset"
}

@test "a GNU checksum prefix collision cannot supply the candidate digest" {
    local sidecar="${FIXTURES}/gnu-prefix-collision.sha256"

    printf '%s  %s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.extra" > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-calculated.json"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"
}

@test "checksum filename matching is case-sensitive" {
    local sidecar="${FIXTURES}/case-mismatch.sha256"

    printf '%s  %s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "FD-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-calculated.json"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"
}

@test "a direct sidecar cannot conflict with a release API digest" {
    local conflicting="${FIXTURES}/direct-conflicting.sha256"

    printf '%s  %s\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${conflicting}"
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases.json"
    export MOCK_REFRESH_SIDECAR="${conflicting}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "conflicting digests"
}

@test "duplicate checksum entries for one filename are rejected" {
    local fixture="${FIXTURES}/releases-duplicate-sidecar.json"
    local sidecar="${FIXTURES}/duplicate.sha256"

    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    printf '%s  %s\n%s  %s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" > "${sidecar}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${sidecar}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "conflicting digests"
}

@test "a generic checksum manifest requires an exact filename" {
    local fixture="${FIXTURES}/releases-bare-generic-checksum.json"
    local checksum_file="${FIXTURES}/bare-generic-checksums.txt"

    printf '%s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${checksum_file}"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "checksums.txt",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/checksums.txt"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${checksum_file}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "upstream checksum asset does not contain"
}

@test "a candidate-specific bare checksum is calculated locally" {
    local fixture="${FIXTURES}/releases-bare-candidate-checksum.json"
    local checksum_file="${FIXTURES}/bare-candidate.sha256"

    printf '%s\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${checksum_file}"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz.sha256"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${checksum_file}"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"
}

@test "the refresher refreshes ncdu from the official page and checksum" {
    run_refresh --tool ncdu --write
    assert_success
    assert_output_contains "official ncdu page checksum"

    run jq -e '
        .tools.ncdu.version == "3.0.0" and
        .tools.ncdu.assets.x86_64.url ==
            "https://dev.yorhel.nl/download/ncdu-3.0.0-linux-x86_64.tar.gz"
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "the refresher pins commit-based tools to a full commit SHA" {
    run_refresh --tool unimatrix --write
    assert_success

    run jq -e '
        .tools.unimatrix.version ==
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
        .tools.unimatrix.assets.any.url ==
            "https://raw.githubusercontent.com/example/unimatrix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/unimatrix.py"
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "the refresher rejects a commit that is older than the current pin" {
    local fixture="${FIXTURES}/commit-compare-behind.json"

    cat > "${fixture}" <<'EOF'
{
  "status": "behind",
  "ahead_by": 0,
  "behind_by": 1,
  "total_commits": 1,
  "base_commit": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  "merge_base_commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  "head_commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
}
EOF
    export MOCK_REFRESH_COMPARE="${fixture}"

    run_refresh --tool unimatrix
    assert_equal "${status}" "69"
    assert_output_contains "not newer than the current pin"
    run jq -e '.tools.unimatrix.version ==
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "${MANIFEST_FILE}"
    assert_success
}

@test "an unchanged commit does not request an ancestry comparison" {
    local fixture="${FIXTURES}/commit-identical.json"

    cat > "${fixture}" <<'EOF'
{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
EOF
    export MOCK_REFRESH_COMMIT="${fixture}"
    export MOCK_REFRESH_COMPARE="/dev/null"

    run_refresh --tool unimatrix --write
    assert_success
}

@test "the refresher rejects a divergent commit history" {
    local fixture="${FIXTURES}/commit-compare-diverged.json"

    cat > "${fixture}" <<'EOF'
{
  "status": "diverged",
  "ahead_by": 1,
  "behind_by": 1,
  "total_commits": 2,
  "base_commit": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  "merge_base_commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  "head_commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
}
EOF
    export MOCK_REFRESH_COMPARE="${fixture}"

    run_refresh --tool unimatrix
    assert_equal "${status}" "69"
    assert_output_contains "not newer than the current pin"
}

@test "the refresher all mode updates every registered tool" {
    run_refresh --all --write
    assert_success

    run jq -e '
        .tools.fd.version == "v2.0.0" and
        .tools.ncdu.version == "3.0.0" and
        .tools.unimatrix.version == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "a failed local validation leaves the original manifest unchanged" {
    local before
    before="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"
    cat > "${SANDBOX}/tests/unit/extras.bats" <<'EOF'
#!/usr/bin/env bats
@test "intentional validation failure" {
    false
}
EOF

    run_refresh --tool fd --write
    assert_equal "${status}" "1"
    assert_output_contains "extras validation tests failed"

    local after
    after="$(sha256sum "${MANIFEST_FILE}" | cut -d' ' -f1)"
    assert_equal "${after}" "${before}"
}

@test "a concurrent manifest modification aborts the write" {
    export MOCK_REFRESH_CONCURRENT_FILE="${MANIFEST_FILE}"

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "changed while the refresh was running"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "a manifest replacement at the exchange boundary preserves concurrent content" {
    export POSTINSTALL_REFRESH_TEST_MODE=1
    export POSTINSTALL_REFRESH_TEST_FAILPOINT=before_exchange
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET="${MANIFEST_FILE}"
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT='{"concurrent":true}
'

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "extras manifest changed"
    run cat "${MANIFEST_FILE}"
    assert_output_contains '"concurrent":true'
}

@test "a manifest displaced after the exchange is not overwritten" {
    export POSTINSTALL_REFRESH_TEST_MODE=1
    export POSTINSTALL_REFRESH_TEST_FAILPOINT=after_exchange
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET="${MANIFEST_FILE}"
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT='{"concurrent":true}
'

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "candidate extras manifest was displaced"
    run cat "${MANIFEST_FILE}"
    assert_output_contains '"concurrent":true'

    run bash -c '
        set -eu
        found=0
        for candidate in "$1"/.tools-manifest.json.refresh-*; do
            [ -f "${candidate}" ] || continue
            grep -Fq '"'"'"version": "v1.0.0"'"'"' "${candidate}"
            found=1
        done
        [ "${found}" -eq 1 ]
    ' _ "${SANDBOX}/extras"
    assert_success
}

@test "rollback never installs a modified recovery manifest" {
    run python3 - \
        "${REPO_ROOT}/tools/refresh-extras-manifest.py" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("refresh_extras_manifest", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    recovery = root / "recovery"
    manifest = root / "manifest"
    manifest.write_bytes(b"original manifest\n")
    expected = module.read_source_snapshot(manifest, "recovery manifest")
    recovery.write_bytes(b"candidate manifest\n")
    if not module.rename_exchange(recovery, manifest):
        raise SystemExit(2)

    candidate = manifest.read_bytes()
    candidate_identity = module.source_identity(manifest.lstat())
    recovery.write_bytes(b"tampered recovery\n")

    rolled_back, detail = module.rollback_manifest_exchange(
        recovery,
        manifest,
        candidate,
        candidate_identity,
        expected,
    )
    if rolled_back:
        raise SystemExit(3)
    if "recovery data changed" not in detail:
        raise SystemExit(4)
    if manifest.read_bytes() != candidate:
        raise SystemExit(5)
    if recovery.read_bytes() != b"tampered recovery\n":
        raise SystemExit(6)
PY
    assert_success
}

@test "rollback rechecks recovery data before exchanging it" {
    run python3 - \
        "${REPO_ROOT}/tools/refresh-extras-manifest.py" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("refresh_extras_manifest", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    recovery = root / "recovery"
    manifest = root / "manifest"
    manifest.write_bytes(b"original manifest\n")
    expected = module.read_source_snapshot(manifest, "recovery manifest")
    recovery.write_bytes(b"candidate manifest\n")
    if not module.rename_exchange(recovery, manifest):
        raise SystemExit(2)

    candidate = manifest.read_bytes()
    candidate_identity = module.source_identity(manifest.lstat())
    exchange_calls = []
    real_exchange = module.rename_exchange

    def mutate_recovery(name):
        if name == "before_rollback_exchange":
            recovery.write_bytes(b"tampered recovery\n")

    def tracked_exchange(first, second):
        exchange_calls.append((first, second))
        return real_exchange(first, second)

    module.refresh_test_failpoint = mutate_recovery
    module.rename_exchange = tracked_exchange
    rolled_back, detail = module.rollback_manifest_exchange(
        recovery,
        manifest,
        candidate,
        candidate_identity,
        expected,
    )
    if rolled_back:
        raise SystemExit(3)
    if "recovery data changed" not in detail:
        raise SystemExit(4)
    if exchange_calls:
        raise SystemExit(5)
    if manifest.read_bytes() != candidate:
        raise SystemExit(6)
    if recovery.read_bytes() != b"tampered recovery\n":
        raise SystemExit(7)
PY
    assert_success
}

@test "a refresh input changed before rollback restores the original manifest" {
    export POSTINSTALL_REFRESH_TEST_MODE=1
    export POSTINSTALL_REFRESH_TEST_FAILPOINT=after_exchange,before_rollback
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET="${CONFIG_FILE}"
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT='{"concurrent":true}
'

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "refresh input changed"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "a concurrent manifest replacement during rollback is preserved" {
    export POSTINSTALL_REFRESH_TEST_MODE=1
    export POSTINSTALL_REFRESH_TEST_FAILPOINT=after_exchange,before_rollback_exchange
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET_AFTER_EXCHANGE="${CONFIG_FILE}"
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT_AFTER_EXCHANGE='{"concurrent":true}
'
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET_BEFORE_ROLLBACK_EXCHANGE="${MANIFEST_FILE}"
    export POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT_BEFORE_ROLLBACK_EXCHANGE='{"concurrent":true}
'

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "candidate manifest changed before it could be rolled back"
    run cat "${MANIFEST_FILE}"
    assert_output_contains '"concurrent":true'

    run bash -c '
        set -eu
        found=0
        for candidate in "$1"/.tools-manifest.json.refresh-*; do
            [ -f "${candidate}" ] || continue
            grep -Fq '"'"'"version": "v1.0.0"'"'"' "${candidate}"
            found=1
        done
        [ "${found}" -eq 1 ]
    ' _ "${SANDBOX}/extras"
    assert_success
}

@test "a selected refresh repairs an architecture-policy mismatch" {
    jq 'del(.tools.fd.assets.aarch64)' "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_refresh --tool fd --write
    assert_success
    run jq -e '
        .tools.fd.assets.x86_64.type == "tar.gz" and
        .tools.fd.assets.aarch64.type == "tar.gz"
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "the authoritative registry configuration and manifest are consistent" {
    run env \
        PATH="/usr/bin:/bin" \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 "${REPO_ROOT}/tools/refresh-extras-manifest.py" \
        --repository "${REPO_ROOT}" --validate
    assert_success
    assert_output_contains "are consistent"
}

@test "draft prerelease and unknown release states are rejected" {
    local fixture

    fixture="${FIXTURES}/releases-draft.json"
    jq 'map(if .tag_name == "v2.0.0" then .draft = true else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    run_refresh --tool fd
    assert_equal "${status}" "69"
    assert_output_contains "no stable release"

    fixture="${FIXTURES}/releases-prerelease.json"
    jq 'map(if .tag_name == "v2.0.0" then .prerelease = true else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    run_refresh --tool fd
    assert_equal "${status}" "69"

    fixture="${FIXTURES}/releases-unknown-flags.json"
    jq 'map(if .tag_name == "v2.0.0" then del(.draft, .prerelease) else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    run_refresh --tool fd
    assert_equal "${status}" "69"
}

@test "rolling release tags are rejected" {
    local fixture="${FIXTURES}/releases-rolling.json"
    jq 'map(if .tag_name == "v2.0.0" then .tag_name = "master" else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_equal "${status}" "69"
    assert_output_contains "rolling tag"
}

@test "malformed upstream digest metadata is fatal" {
    local fixture="${FIXTURES}/releases-malformed-digest.json"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .name | contains("x86_64") then
                .digest = "sha256:not-a-digest"
            else . end)
        else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "invalid checksum digest"
}

@test "oversized release metadata is rejected before download" {
    local fixture="${FIXTURES}/releases-oversized.json"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .name | contains("x86_64") then
                .size = 300000000
            else . end)
        else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "release asset is too large"
}

@test "a direct checksum sidecar is verified" {
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-calculated.json"
    export MOCK_REFRESH_SIDECAR="${FIXTURES}/fd.sha256"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "upstream sidecar .sha256"
}

@test "the refresher isolates its GitHub token and disables API redirects" {
    local probe="${TEST_ROOT}/token-probe"

    GITHUB_TOKEN="test-token-value" \
        MOCK_TOKEN_PROBE="${probe}" \
        run_refresh --tool fd
    assert_success

    run cat "${probe}"
    assert_success
    assert_equal "${output}" "absent"
}

@test "the refresher blocks child access to the parent token environment" {
    local probe="${TEST_ROOT}/token-proc-probe"

    GITHUB_TOKEN="test-token-value" \
        MOCK_TOKEN_PROC_PROBE="${probe}" \
        run_refresh --tool fd
    assert_success

    run cat "${probe}"
    assert_success
    assert_output_contains "blocked"
    run bash -c '! grep -Fq leaked "$1"' _ "${probe}"
    assert_success
}

@test "manifest URLs must match the configured source" {
    local manifest="${MANIFEST_FILE}"

    jq '.tools.fd.assets.x86_64.url =
        "https://evil.example/example/fd/releases/download/v1.0.0/fd-v1.0.0-x86_64-unknown-linux-gnu.tar.gz"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_refresh --validate
    assert_failure
    assert_output_contains "configured release source"

    jq '.tools.fd.assets.x86_64.url =
        "https:///example/fd/releases/download/v1.0.0/fd-v1.0.0-x86_64-unknown-linux-gnu.tar.gz"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_refresh --validate
    assert_failure
    assert_output_contains "URL is invalid"
}

@test "a hexadecimal release tag is not mistaken for a commit" {
    local fixture="${FIXTURES}/releases-hex-tag.json"
    local version="1234567890abcdef1234567890abcdef12345678"

    jq --arg version "${version}" '
        map(if .tag_name == "v2.0.0" then
            .tag_name = $version |
            .assets |= map(
                .browser_download_url |= sub("/v2.0.0/"; "/" + $version + "/")
            )
        else . end)
    ' "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd --write
    assert_success
    run jq -e --arg version "${version}" '
        .tools.fd.version == $version and
        .tools.fd.assets.x86_64.url ==
            ("https://github.com/example/fd/releases/download/" + $version + "/fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz")
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "encoded release URL separators are rejected" {
    jq '.tools.fd.assets.x86_64.url =
        "https://github.com/example/fd/releases/download/v1.0.0/fd%2F..%2Fother.tar.gz"' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_refresh --validate
    assert_failure
    assert_output_contains "not canonically encoded"
}

@test "downloaded release assets must match the declared metadata size" {
    local fixture="${FIXTURES}/releases-size-mismatch.json"

    jq 'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .name == "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" then
                .size += 1
            else . end)
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "size does not match release metadata"
}

@test "an incomplete upstream checksum manifest is rejected" {
    local fixture="${FIXTURES}/releases-generic-checksum.json"
    local checksum_file="${FIXTURES}/incomplete-checksums.txt"

    printf '%s  another-file.tar.gz\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${checksum_file}"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "checksums.txt",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/checksums.txt"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${checksum_file}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "upstream checksum asset does not contain"
}

@test "unrelated checksum sidecars do not block a valid release" {
    local fixture="${FIXTURES}/releases-unrelated-checksum.json"

    jq 'map(if .tag_name == "v2.0.0" then
            .assets += [{
                "name": "checksums-other-tool.txt",
                "browser_download_url": "https://github.com/example/fd/releases/download/v2.0.0/checksums-other-tool.txt"
            }]
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"
    export MOCK_REFRESH_SIDECAR="${FIXTURES}/unrelated-checksums.txt"

    printf '%s  another-file.tar.gz\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${FIXTURES}/unrelated-checksums.txt"

    run_refresh --tool fd --write
    assert_success
    assert_output_contains "calculated locally"
}

@test "the refresher bounds TAR extended metadata" {
    local archive="${FIXTURES}/oversized-pax.tar.gz"

    run python3 "${REPO_ROOT}/tests/helpers/make-tar-fixture.py" \
        "${archive}" pax-oversized
    assert_success
    run python3 - \
        "${REPO_ROOT}/tools/refresh-extras-manifest.py" "${archive}" <<'PY'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("refresh_extras_manifest", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
try:
    module.archive_regular_members(pathlib.Path(sys.argv[2]), "tar.gz")
except module.RefreshError as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
PY
    assert_failure
    assert_output_contains "extended metadata exceeds the permitted size"
}

@test "the refresher rejects sparse TAR metadata" {
    local archive="${FIXTURES}/sparse-pax.tar.gz"

    run python3 "${REPO_ROOT}/tests/helpers/make-tar-fixture.py" \
        "${archive}" pax-sparse
    assert_success
    run python3 - \
        "${REPO_ROOT}/tools/refresh-extras-manifest.py" "${archive}" <<'PY'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("refresh_extras_manifest", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
try:
    module.archive_regular_members(pathlib.Path(sys.argv[2]), "tar.gz")
except module.RefreshError as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
PY
    assert_failure
    assert_output_contains "sparse metadata is not permitted"
}

@test "configured archive member wildcards resolve without pinning an upstream version" {
    jq '.tools.fd.assets.x86_64.files = {"fd*": "fd"} |
        .tools.fd.assets.aarch64.files = {"fd*": "fd"}' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

    run_refresh --tool fd --write
    assert_success
    run jq -e '
        .tools.fd.assets.x86_64.files | to_entries | length == 1
    ' "${MANIFEST_FILE}"
    assert_success
}

@test "a wildcard selector must resolve to exactly one archive member" {
    local archive="${FIXTURES}/fd-ambiguous-wildcard.tar.gz"
    local release_fixture="${FIXTURES}/releases-ambiguous-wildcard.json"
    local archive_size

    printf '%s\n' 'fd-extra' > \
        "${FIXTURES}/package/fd-v2.0.0-x86_64-unknown-linux-gnu/fd-extra"
    tar -czf "${archive}" -C "${FIXTURES}/package" \
        fd-v2.0.0-x86_64-unknown-linux-gnu
    jq '.tools.fd.assets.x86_64.files = {"fd*": "fd"} |
        .tools.fd.assets.aarch64.files = {"fd*": "fd"}' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

    archive_size="$(stat -c '%s' "${archive}")"
    jq --argjson size "${archive_size}" \
        'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .name == "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" then
                .size = $size
            else . end)
        else . end)' \
        "${FIXTURES}/releases-calculated.json" > "${release_fixture}"
    export MOCK_REFRESH_FD_X86="${archive}"
    export MOCK_REFRESH_RELEASES="${release_fixture}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "multiple candidates for fd*"
}

@test "the refresh configuration is authoritative for release sources" {
    local fixture="${FIXTURES}/releases-authoritative.json"

    jq '.tools.fd.source = "example/fd-authoritative"' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"
    jq 'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .browser_download_url then
                .browser_download_url |= sub("/example/fd/"; "/example/fd-authoritative/")
            else . end)
        else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd --write
    assert_success
    run jq -e '.tools.fd.source == "example/fd-authoritative"' \
        "${MANIFEST_FILE}"
    assert_success
}

@test "registry configuration and manifest set mismatches are rejected" {
    local registry="${SANDBOX}/extras/tools-list.sh"
    cp "${registry}" "${registry}.new"
    sed -i '/"fd"/d' "${registry}.new"
    mv "${registry}.new" "${registry}"

    run_refresh --tool ncdu
    assert_failure
    assert_output_contains "manifest and registry differ"
}

@test "a concurrent configuration modification aborts the refresh" {
    export MOCK_REFRESH_CONCURRENT_FILE="${CONFIG_FILE}"

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "refresh input changed"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "a concurrent refresher is rejected by the refresh lock" {
    local marker="${TEST_ROOT}/refresh-lock-marker"
    local first_status_file="${TEST_ROOT}/refresh-lock-first-status"

    local lock_home="${TEST_ROOT}/refresh-lock-home"
    local first_tmp="${TEST_ROOT}/refresh-lock-tmp-first"
    local second_tmp="${TEST_ROOT}/refresh-lock-tmp-second"
    mkdir -p "${lock_home}" "${first_tmp}" "${second_tmp}"

    env \
        HOME="${lock_home}" \
        TMPDIR="${first_tmp}" \
        MOCK_REFRESH_RELEASES="${MOCK_REFRESH_RELEASES}" \
        MOCK_REFRESH_RELEASES_PAGE_2="${MOCK_REFRESH_RELEASES_PAGE_2:-}" \
        MOCK_REFRESH_COMMIT="${MOCK_REFRESH_COMMIT}" \
        MOCK_REFRESH_COMPARE="${MOCK_REFRESH_COMPARE}" \
        MOCK_REFRESH_COMMIT_FILE="${MOCK_REFRESH_COMMIT_FILE}" \
        MOCK_REFRESH_NCDU_PAGE="${MOCK_REFRESH_NCDU_PAGE}" \
        MOCK_REFRESH_FD_X86="${MOCK_REFRESH_FD_X86}" \
        MOCK_REFRESH_FD_AARCH64="${MOCK_REFRESH_FD_AARCH64}" \
        MOCK_REFRESH_NCDU_X86="${MOCK_REFRESH_NCDU_X86}" \
        MOCK_REFRESH_NCDU_AARCH64="${MOCK_REFRESH_NCDU_AARCH64}" \
        MOCK_REFRESH_SIDECAR="${MOCK_REFRESH_SIDECAR}" \
        MOCK_REFRESH_AARCH64_SIDECAR="${MOCK_REFRESH_AARCH64_SIDECAR}" \
        MOCK_REFRESH_DELAY="2" \
        MOCK_REFRESH_DELAY_MARKER="${marker}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 "${REPO_ROOT}/tools/refresh-extras-manifest.py" \
        --repository "${SANDBOX}" --tool fd --write \
        >"${TEST_ROOT}/refresh-lock-first.out" 2>&1 &
    local holder="${!}"

    for _ in {1..100}; do
        [ -e "${marker}" ] && break
        sleep 0.05
    done
    if [ ! -e "${marker}" ]; then
        kill "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
        return 1
    fi

    local second_home="${TEST_ROOT}/refresh-lock-home-second"
    mkdir -p "${second_home}"
    REFRESH_HOME="${second_home}" \
        REFRESH_TMPDIR="${second_tmp}" \
        run_refresh --tool fd --write
    assert_equal "${status}" "75"
    assert_output_contains "another extras manifest refresher"

    wait "${holder}" 2>/dev/null || true
    printf '%s\n' "${?}" > "${first_status_file}"
    run cat "${first_status_file}"
    assert_success
    assert_equal "${output}" "0"
}

@test "release pagination reaches newer releases on later pages" {
    local first_page="${FIXTURES}/releases-page-1.json"
    python3 - "${first_page}" <<'PY'
import json
import sys

releases = []
for index in range(1, 101):
    releases.append(
        {
            "tag_name": f"v0.0.{index}",
            "published_at": "2020-01-01T00:00:00Z",
            "draft": False,
            "prerelease": False,
            "assets": [],
        }
    )
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(releases, stream)
PY
    export MOCK_REFRESH_RELEASES="${first_page}"
    export MOCK_REFRESH_RELEASES_PAGE_2="${FIXTURES}/releases.json"

    run_refresh --tool fd --write
    assert_success
    run jq -e '.tools.fd.version == "v2.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "a release older than the current pin is rejected" {
    local fixture="${FIXTURES}/releases-downgrade.json"
    jq 'map(if .tag_name == "v2.0.0" then .tag_name = "v0.9.0" else . end)' \
        "${FIXTURES}/releases.json" > "${fixture}"
    export MOCK_REFRESH_RELEASES="${fixture}"

    run_refresh --tool fd
    assert_equal "${status}" "69"
    assert_output_contains "older than the current pin"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "the configured archive type is authoritative" {
    jq '.tools.fd.assets.x86_64.type = "zip"' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "not a zip file"
    run jq -e '.tools.fd.assets.x86_64.type == "tar.gz"' "${MANIFEST_FILE}"
    assert_success
}

@test "the configured file mapping is authoritative" {
    jq '.tools.fd.assets.x86_64.files = {"missing": "fd"}' \
        "${CONFIG_FILE}" > "${CONFIG_FILE}.new"
    mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "configured executable: missing"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "manifest archive policy drift is rejected by validation" {
    jq '.tools.fd.assets.x86_64.type = "zip"' \
        "${MANIFEST_FILE}" > "${MANIFEST_FILE}.new"
    mv "${MANIFEST_FILE}.new" "${MANIFEST_FILE}"

    run_refresh --validate
    assert_failure
    assert_output_contains "archive type does not match"
}

@test "a concurrent registry modification aborts the refresh" {
    export MOCK_REFRESH_CONCURRENT_FILE="${SANDBOX}/extras/tools-list.sh"

    run_refresh --tool fd --write
    assert_equal "${status}" "69"
    assert_output_contains "refresh input changed"
    run jq -e '.tools.fd.version == "v1.0.0"' "${MANIFEST_FILE}"
    assert_success
}

@test "ZIP central-directory metadata is bounded before extraction" {
    local archive="${FIXTURES}/bounded-metadata.zip"
    python3 - "${archive}" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("fd", "fd")
PY

    run python3 - \
        "${REPO_ROOT}/tools/refresh-extras-manifest.py" \
        "${archive}" <<'PY'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("refresh_extras_manifest", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.MAXIMUM_ZIP_METADATA_SIZE = 1
try:
    module.zip_central_directory_count(archive_path)
except module.RefreshError as error:
    if "ZIP metadata" in str(error):
        raise SystemExit(0)
    raise
raise SystemExit(1)
PY
    assert_success
}

@test "release archives with duplicate paths are rejected" {
    local duplicate="${FIXTURES}/fd-duplicate.tar.gz"
    local duplicate_size
    tar -czf "${duplicate}" \
        -C "${FIXTURES}/package" \
        fd-v2.0.0-x86_64-unknown-linux-gnu/fd \
        fd-v2.0.0-x86_64-unknown-linux-gnu/fd
    export MOCK_REFRESH_FD_X86="${duplicate}"
    export MOCK_REFRESH_RELEASES="${FIXTURES}/releases-duplicate.json"
    duplicate_size="$(stat -c '%s' "${duplicate}")"
    jq --argjson size "${duplicate_size}" \
        'map(if .tag_name == "v2.0.0" then
            .assets |= map(if .name == "fd-v2.0.0-x86_64-unknown-linux-gnu.tar.gz" then
                .size = $size
            else . end)
        else . end)' \
        "${FIXTURES}/releases-calculated.json" \
        > "${MOCK_REFRESH_RELEASES}"

    run_refresh --tool fd
    assert_failure
    assert_output_contains "duplicate path"
}
