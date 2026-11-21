#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/gum"
    MOCK_BIN="${TEST_ROOT}/bin"
    FIXTURE_ROOT="${TEST_ROOT}/fixture"
    TMP_ROOT="${TEST_ROOT}/tmp"
    SANDBOX_REPO="${TEST_ROOT}/repo"

    mkdir -p \
        "${MOCK_BIN}" \
        "${FIXTURE_ROOT}/gum_2.0.2_Linux_x86_64" \
        "${FIXTURE_ROOT}/gum_2.0.2_Linux_arm64" \
        "${TMP_ROOT}" \
        "${SANDBOX_REPO}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"

    for architecture in x86_64 arm64; do
        cat > "${FIXTURE_ROOT}/gum_2.0.2_Linux_${architecture}/gum" <<'EOF'
#!/usr/bin/env bash
printf 'bootstrap gum\n'
EOF
        chmod +x "${FIXTURE_ROOT}/gum_2.0.2_Linux_${architecture}/gum"
        tar -czf "${FIXTURE_ROOT}/gum-${architecture}.tar.gz" \
            -C "${FIXTURE_ROOT}" "gum_2.0.2_Linux_${architecture}"
    done

    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
cp "${MOCK_CURL_SOURCE}" "${output}"
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_ARCHITECTURE}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    chmod +x "${MOCK_BIN}/curl" "${MOCK_BIN}/uname"
}

set_manifest_checksum() {
    local architecture="${1}"
    local archive="${2}"
    local checksum
    local manifest="${SANDBOX_REPO}/extras/tools-manifest.json"

    checksum="$(sha256sum "${archive}" | cut -d' ' -f1)"
    jq --arg architecture "${architecture}" \
        --arg checksum "${checksum}" \
        '.tools.gum.assets[$architecture].sha256 = $checksum' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"
}

run_bootstrap() {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        MOCK_CURL_SOURCE="${MOCK_CURL_SOURCE}" \
        MOCK_ARCHITECTURE="${MOCK_ARCHITECTURE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh' || exit \$?; runtime_initialize || exit \$?; source '${SANDBOX_REPO}/common/gum-setup.sh' || exit \$?; test -x \"\${GUM}\" || exit \$?; \"\${GUM}\" || exit \$?; exit 0"
}

@test "gum bootstrap verifies a pinned checksum and cleans its workspace" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"

    run_bootstrap
    assert_success
    assert_output_contains "bootstrap gum"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap supports AArch64" {
    export MOCK_ARCHITECTURE="aarch64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-arm64.tar.gz"
    set_manifest_checksum "aarch64" "${MOCK_CURL_SOURCE}"

    run_bootstrap
    assert_success
    assert_output_contains "bootstrap gum"
}

@test "gum bootstrap rejects a checksum mismatch" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    local manifest="${SANDBOX_REPO}/extras/tools-manifest.json"
    jq '.tools.gum.assets.x86_64.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_bootstrap
    assert_failure
    assert_output_contains "Checksum verification failed for gum"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}
