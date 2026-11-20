#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/architecture-assets"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    MOCK_BIN="${TEST_ROOT}/bin"

    mkdir -p "${SANDBOX_REPO}" "${MOCK_BIN}"
    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_HOST_ARCHITECTURE:-x86_64}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF
    chmod +x "${MOCK_BIN}/uname"
}

@test "runtime architecture aliases normalize to canonical manifest keys" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_normalize_architecture amd64"
    assert_success
    assert_equal "${output}" "x86_64"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_normalize_architecture arm64"
    assert_success
    assert_equal "${output}" "aarch64"
}

@test "an explicit architecture override selects the requested canonical key" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        POSTINSTALL_ARCHITECTURE="aarch64" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_selected_architecture"
    assert_success
    assert_equal "${output}" "aarch64"
}

@test "release asset selection requires exactly one matching asset" {
    cat > "${TEST_ROOT}/assets.json" <<'EOF'
{
  "assets": [
    {"name": "tool-linux-x86_64.tar.gz", "browser_download_url": "https://example.test/tool-x86_64.tar.gz"},
    {"name": "tool-linux-aarch64.tar.gz", "browser_download_url": "https://example.test/tool-aarch64.tar.gz"}
  ]
}
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_select_github_asset_by_suffix '${TEST_ROOT}/assets.json' 'linux-x86_64.tar.gz'"
    assert_success
    assert_equal "${output}" "https://example.test/tool-x86_64.tar.gz"
}

@test "release asset selection rejects zero matches" {
    cat > "${TEST_ROOT}/assets.json" <<'EOF'
{"assets": [{"name": "tool-linux-x86_64.tar.gz", "browser_download_url": "https://example.test/tool.tar.gz"}]}
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_select_github_asset_by_suffix '${TEST_ROOT}/assets.json' 'linux-aarch64.tar.gz'"
    assert_failure
    assert_output_contains "expected exactly one release asset"
}

@test "release asset selection rejects ambiguous matches" {
    cat > "${TEST_ROOT}/assets.json" <<'EOF'
{
  "assets": [
    {"name": "tool-linux-x86_64.tar.gz", "browser_download_url": "https://example.test/one.tar.gz"},
    {"name": "extra-linux-x86_64.tar.gz", "browser_download_url": "https://example.test/two.tar.gz"}
  ]
}
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_select_github_asset_by_suffix '${TEST_ROOT}/assets.json' 'linux-x86_64.tar.gz'"
    assert_failure
    assert_output_contains "expected exactly one release asset"
}

@test "manifest lookup never falls back between native architectures" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${SANDBOX_REPO}/extras/tools-manifest.json'; extras_manifest_entry fd x86_64"
    assert_success
    run jq -e '.url | test("x86_64|amd64")' <<<"${output}"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${SANDBOX_REPO}/extras/tools-manifest.json'; extras_manifest_entry fd aarch64"
    assert_success
    run jq -e '.url | test("aarch64|arm64")' <<<"${output}"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${SANDBOX_REPO}/extras/tools-manifest.json'; extras_manifest_entry jless aarch64"
    assert_failure
}

@test "architecture-sensitive common modules use the shared selector" {
    local module
    for module in \
        common/carapace-installation.sh \
        common/go-installation.sh \
        common/helix-installation.sh \
        common/miniconda-installation.sh \
        common/mise-installation.sh \
        common/zed-installation.sh \
        common/zoxide-installation.sh; do
        run grep -F 'runtime_selected_architecture' "${REPO_ROOT}/${module}"
        assert_success
    done
}

@test "zoxide selects the current musl release assets" {
    run grep -F 'x86_64-unknown-linux-musl.tar.gz' \
        "${REPO_ROOT}/common/zoxide-installation.sh"
    assert_success
    run grep -F 'aarch64-unknown-linux-musl.tar.gz' \
        "${REPO_ROOT}/common/zoxide-installation.sh"
    assert_success
    run grep -F 'unknown-linux-gnu.tar.gz' \
        "${REPO_ROOT}/common/zoxide-installation.sh"
    assert_failure
}

@test "Go release selection chooses the highest stable version" {
    run bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; printf '%s\\n' \
        'go1.9.7.linux-amd64.tar.gz' \
        'go1.27.4.linux-amd64.tar.gz' \
        'go1.28rc1.linux-amd64.tar.gz' \
        'go1.10.1.linux-amd64.tar.gz' | \
        runtime_select_latest_go_release linux-amd64"
    assert_success
    assert_equal "${output}" "dl/go1.27.4.linux-amd64.tar.gz"
}

@test "manifest lookup rejects noncanonical architecture aliases" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${SANDBOX_REPO}/extras/tools-manifest.json'; extras_manifest_entry fd amd64"
    assert_failure
    assert_output_contains "unsupported canonical architecture key"
}

@test "manifest validation rejects noncanonical asset keys" {
    local invalid_manifest="${TEST_ROOT}/invalid-manifest.json"
    jq '.tools.fd.assets.amd64 = .tools.fd.assets.x86_64 |
        del(.tools.fd.assets.x86_64)' \
        "${SANDBOX_REPO}/extras/tools-manifest.json" > "${invalid_manifest}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${invalid_manifest}'; extras_validate_manifest_file"
    assert_failure
    assert_output_contains "invalid command line tool manifest"
}

@test "universal assets are selected only through the explicit any key" {
    run jq -e '.tools.unimatrix.assets | has("any")' \
        "${SANDBOX_REPO}/extras/tools-manifest.json"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        bash -c "source '${SANDBOX_REPO}/extras/tools-download.sh'; EXTRAS_MANIFEST_FILE='${SANDBOX_REPO}/extras/tools-manifest.json'; extras_manifest_entry unimatrix x86_64"
    assert_success
    run jq -e '.url and .sha256 and .type and .files' <<<"${output}"
    assert_success
}

@test "the interactive extras chooser omits tools unavailable on AArch64" {
    local gum_log="${TEST_ROOT}/gum-arguments"
    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${MOCK_GUM_ARGUMENTS}"
exit 0
EOF
    chmod +x "${MOCK_BIN}/gum"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        POSTINSTALL_ARCHITECTURE=aarch64 \
        POSTINSTALL_TOOL_SELECTION_MODE=interactive \
        GUM="${MOCK_BIN}/gum" \
        MOCK_GUM_ARGUMENTS="${gum_log}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; section(){ :; }; description(){ :; }; text(){ :; }; info(){ :; }; source '${SANDBOX_REPO}/extras/additional-tools.sh'"
    assert_success

    run grep -Fx 'fd' "${gum_log}"
    assert_success
    run grep -Fx 'jless' "${gum_log}"
    assert_failure
}
