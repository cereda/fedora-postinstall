#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/git-configuration"
    MOCK_BIN="${TEST_ROOT}/bin"
    GIT_LOG="${TEST_ROOT}/git.log"

    mkdir -p \
        "${MOCK_BIN}" \
        "${TEST_ROOT}/home" \
        "${TEST_ROOT}/xdg-config" \
        "${TEST_ROOT}/managed/config/git/hooks"

    cat > "${MOCK_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_GIT_LOG}"
EOF
    chmod +x "${MOCK_BIN}/git"

    export MOCK_GIT_LOG="${GIT_LOG}"
    export PATH="${MOCK_BIN}:/usr/bin:/bin"
}

run_git_configuration() {
    run env \
        HOME="${TEST_ROOT}/home" \
        XDG_CONFIG_HOME="${1:-}" \
        ROOT_DIRECTORY_STRUCTURE="${TEST_ROOT}/managed" \
        bash -c '
            section() { :; }
            description() { :; }
            warning() { :; }
            info() { :; }
            prompt_valid_git_name() { printf "%s\n" "Test User"; }
            prompt_valid_git_email() { printf "%s\n" "test@example.com"; }
            source "$1/common/git-configuration.sh"
        ' _ "${REPO_ROOT}"
}

@test "git configuration uses an absolute XDG_CONFIG_HOME" {
    run_git_configuration "${TEST_ROOT}/xdg-config"
    assert_success

    run grep -F -- "--file ${TEST_ROOT}/xdg-config/git/config" "${GIT_LOG}"
    assert_success
}

@test "git configuration ignores a relative XDG_CONFIG_HOME" {
    run_git_configuration "relative/config"
    assert_success

    run grep -F -- "--file ${TEST_ROOT}/home/.config/git/config" "${GIT_LOG}"
    assert_success
}
