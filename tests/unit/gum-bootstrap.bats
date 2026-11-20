#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/gum"
    MOCK_BIN="${TEST_ROOT}/bin"
    FIXTURE_ROOT="${TEST_ROOT}/fixture"
    TMP_ROOT="${TEST_ROOT}/tmp"

    mkdir -p \
        "${MOCK_BIN}" \
        "${FIXTURE_ROOT}/gum_2.0.2_Linux_x86_64" \
        "${FIXTURE_ROOT}/gum_2.0.2_Linux_arm64" \
        "${TMP_ROOT}"

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

    cat > "${MOCK_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '%s  %s\n' "${MOCK_EXPECTED_HASH}" "${2}"
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "${MOCK_ARCHITECTURE}"
else
    /usr/bin/uname "$@"
fi
EOF

    chmod +x \
        "${MOCK_BIN}/curl" \
        "${MOCK_BIN}/sha256sum" \
        "${MOCK_BIN}/uname"
}

@test "gum bootstrap verifies a pinned checksum and cleans its workspace" {
    export MOCK_ARCHITECTURE="x86_64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-x86_64.tar.gz"
    export MOCK_EXPECTED_HASH="d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2"

    run bash -c \
        "command() { if [ \"\${1:-}\" = '-v' ] && [ \"\${2:-}\" = 'gum' ]; then return 1; fi; builtin command \"\$@\"; }; PATH='${MOCK_BIN}:/usr/bin:/bin'; TMPDIR='${TMP_ROOT}'; source '${REPO_ROOT}/common/gum-setup.sh'; test -x \"\${GUM}\"; \"\${GUM}\""
    assert_success
    assert_output_contains "bootstrap gum"

    run find "${TMP_ROOT}" -mindepth 1 -print
    assert_success
    refute_output_contains "fedora-postinstall-gum."
}

@test "gum bootstrap supports AArch64" {
    export MOCK_ARCHITECTURE="aarch64"
    export MOCK_CURL_SOURCE="${FIXTURE_ROOT}/gum-arm64.tar.gz"
    export MOCK_EXPECTED_HASH="8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5"

    run bash -c \
        "command() { if [ \"\${1:-}\" = '-v' ] && [ \"\${2:-}\" = 'gum' ]; then return 1; fi; builtin command \"\$@\"; }; PATH='${MOCK_BIN}:/usr/bin:/bin'; TMPDIR='${TMP_ROOT}'; source '${REPO_ROOT}/common/gum-setup.sh'; test -x \"\${GUM}\"; \"\${GUM}\""
    assert_success
    assert_output_contains "bootstrap gum"
}
