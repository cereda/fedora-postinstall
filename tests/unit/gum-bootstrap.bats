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
case "${1:-}" in
--version)
    printf '%s\n' 'gum version v2.0.2'
    ;;
choose)
    printf '%s\n' '--no-limit' '--header' '--height' '--selected'
    ;;
confirm)
    printf '%s\n' '--show-output' '--affirmative' '--negative' \
        '--prompt.foreground' '--selected.background'
    ;;
input)
    printf '%s\n' '--value' '--prompt'
    ;;
file)
    printf '%s\n' '--file' '--directory' '--all' '--[no-]permissions'
    ;;
*)
    printf 'bootstrap gum\n'
    ;;
esac
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
exit "${MOCK_CURL_STATUS:-0}"
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
    local -a environment=(
        -u GUM
        -u POSTINSTALL_ARCHITECTURE
    )

    if [ "$#" -gt 0 ]; then
        environment+=("GUM=$1")
    fi

    run env \
        "${environment[@]}" \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        TMPDIR="${TMP_ROOT}" \
        MOCK_CURL_SOURCE="${MOCK_CURL_SOURCE}" \
        MOCK_CURL_STATUS="${MOCK_CURL_STATUS:-0}" \
        MOCK_ARCHITECTURE="${MOCK_ARCHITECTURE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh' || exit \$?; runtime_initialize || exit \$?; source '${SANDBOX_REPO}/common/gum-setup.sh' || exit \$?; test -x \"\${GUM}\" || exit \$?; \"\${GUM}\" || exit \$?; exit 0"
}

write_gum_v2() {
    local version="${1}"

    cat > "${MOCK_BIN}/gum" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    printf '%s\\n' 'gum version ${version}'
    exit 0
fi
case "\${1:-}" in
choose)
    printf '%s\\n' '--no-limit' '--header' '--height' '--selected'
    ;;
confirm)
    printf '%s\\n' '--show-output' '--affirmative' '--negative' \
        '--prompt.foreground' '--selected.background'
    ;;
input)
    printf '%s\\n' '--value' '--prompt'
    ;;
file)
    printf '%s\\n' '--file' '--directory' '--all' '--[no-]permissions'
    ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/gum"
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
    assert_output_contains "Checksum verification failed for Gum"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap preserves the download failure status and cleans its workspace" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    export MOCK_CURL_STATUS=28
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"

    run_bootstrap
    assert_equal "${status}" 28
    assert_output_contains "Unable to download Gum v2.0.2"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap rejects a malformed manifest entry before downloading" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    local manifest="${SANDBOX_REPO}/extras/tools-manifest.json"
    jq '.tools.gum.assets.x86_64.files["gum_2.0.2_Linux_x86_64/not-gum"] = "gum"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_bootstrap
    assert_equal "${status}" 1
    assert_output_contains "authoritative Gum manifest entry is invalid"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap rejects an archive larger than the configured limit" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/oversize-gum.tar.gz"
    truncate -s 67108865 "${MOCK_CURL_SOURCE}"
    local manifest="${SANDBOX_REPO}/extras/tools-manifest.json"
    jq '.tools.gum.assets.x86_64.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
        "${manifest}" > "${manifest}.new"
    mv "${manifest}.new" "${manifest}"

    run_bootstrap
    assert_equal "${status}" 1
    assert_output_contains "downloaded Gum archive exceeds the allowed size"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap rejects an archive without the declared executable" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-without-member.tar.gz"
    mkdir -p "${FIXTURE_ROOT}/gum-without-member"
    printf 'not an executable\n' > "${FIXTURE_ROOT}/gum-without-member/README"
    tar -czf "${MOCK_CURL_SOURCE}" -C "${FIXTURE_ROOT}" gum-without-member
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"

    run_bootstrap
    assert_equal "${status}" 1
    assert_output_contains "Unable to extract Gum v2.0.2"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap rejects a staged executable with an unexpected version" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-wrong-version.tar.gz"
    cat > "${FIXTURE_ROOT}/gum_2.0.2_Linux_x86_64/gum" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'gum version v9.1.0'
    exit 0
fi
exit 1
EOF
    chmod +x "${FIXTURE_ROOT}/gum_2.0.2_Linux_x86_64/gum"
    tar -czf "${MOCK_CURL_SOURCE}" \
        -C "${FIXTURE_ROOT}" gum_2.0.2_Linux_x86_64
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"

    run_bootstrap
    assert_equal "${status}" 1
    assert_output_contains "staged Gum executable has an unexpected version"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap cleanup failure retains its status" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"
    cat > "${MOCK_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
for rm_argument in "$@"; do
    case "${rm_argument}" in
        */fedora-postinstall-gum.*) exit 7 ;;
    esac
done
exec /usr/bin/rm "$@"
EOF
    chmod +x "${MOCK_BIN}/rm"

    run_bootstrap
    assert_equal "${status}" 7

    rm -rf "${TMP_ROOT}"/fedora-postinstall-gum.*
}

@test "gum bootstrap reuses an installed v2 release directly" {
    write_gum_v2 "v2.0.2"
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"

    run_bootstrap
    assert_success
    refute_output_contains "Fetching Gum"
}

@test "gum bootstrap replaces unsupported installed releases with the pinned release" {
    local version

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    set_manifest_checksum "x86_64" "${MOCK_CURL_SOURCE}"

    for version in v0.17.0 v1.2.3 v2 v2.0 v2.00.02 v2.01.0 \
        v2.0.2-beta v2.0.2foo v9.1.0; do
        cat > "${MOCK_BIN}/gum" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    printf '%s\n' 'gum version ${version}'
    exit 0
fi
exit 1
EOF
        chmod +x "${MOCK_BIN}/gum"

        run_bootstrap
        assert_success
        assert_output_contains "Fetching Gum v2.0.2"
    done
}

@test "gum bootstrap honors a valid explicit executable override" {
    cat > "${FIXTURE_ROOT}/explicit-gum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--version)
    printf '%s\n' 'gum version v2.0.2'
    ;;
choose)
    printf '%s\n' '--no-limit' '--header' '--height' '--selected'
    ;;
confirm)
    printf '%s\n' '--show-output' '--affirmative' '--negative' \
        '--prompt.foreground' '--selected.background'
    ;;
input)
    printf '%s\n' '--value' '--prompt'
    ;;
file)
    printf '%s\n' '--file' '--directory' '--all' '--[no-]permissions'
    ;;
*)
    printf '%s\n' 'explicit gum'
    ;;
esac
EOF
    chmod +x "${FIXTURE_ROOT}/explicit-gum"

    cat > "${MOCK_BIN}/gum" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${MOCK_BIN}/gum"

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"

    run_bootstrap "${FIXTURE_ROOT}/explicit-gum"
    assert_success
    assert_output_contains "explicit gum"
    refute_output_contains "Fetching Gum"
}

@test "gum bootstrap rejects an unsupported explicit executable override" {
    cat > "${FIXTURE_ROOT}/explicit-gum" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'gum version v9.1.0'
    exit 0
fi
exit 1
EOF
    chmod +x "${FIXTURE_ROOT}/explicit-gum"

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"

    run_bootstrap "${FIXTURE_ROOT}/explicit-gum"
    assert_equal "${status}" 1
    assert_output_contains "configured Gum executable is unavailable or unsupported"
    refute_output_contains "Fetching Gum"
}

@test "gum bootstrap rejects an explicit v2 executable without required controls" {
    cat > "${FIXTURE_ROOT}/explicit-gum" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'gum version v2.0.2'
    exit 0
fi
exit 1
EOF
    chmod +x "${FIXTURE_ROOT}/explicit-gum"

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"

    run_bootstrap "${FIXTURE_ROOT}/explicit-gum"
    assert_equal "${status}" 1
    assert_output_contains "configured Gum executable is unavailable or unsupported"
    refute_output_contains "Fetching Gum"
}

@test "gum bootstrap rejects an invalid explicit executable override" {
    write_gum_v2 "v2.0.2"

    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"

    run_bootstrap "${FIXTURE_ROOT}/missing-gum"
    assert_equal "${status}" 1
    assert_output_contains "configured Gum executable is unavailable or unsupported"
    refute_output_contains "Fetching Gum"
}
