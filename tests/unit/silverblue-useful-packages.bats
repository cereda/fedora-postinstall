#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    source "${REPO_ROOT}/common/runtime.sh"
    source "${REPO_ROOT}/common/ui.sh"
    source "${REPO_ROOT}/common/ui-prompts.sh"
    TEST_ROOT="${BATS_TEST_TMPDIR}/silverblue-useful-packages"
    mkdir -p "${TEST_ROOT}/scripts"

    cat > "${TEST_ROOT}/scripts/aliases.sh" <<'EOF'
local PACKAGE_LIST="TOOLBOX_INSTALLATION_LIST"
EOF

    cat > "${TEST_ROOT}/gum" <<'EOF'
#!/usr/bin/env bash
if [ "${1}" = "choose" ]; then
    printf '%s\n' "ack"
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_ROOT}/gum"

    GUM="${TEST_ROOT}/gum"
    TOOLBOX_NAME="f42-dev"
    ROOT_DIRECTORY_STRUCTURE="${TEST_ROOT}"
    PACKAGES_TO_INSTALL=("ack" "bat")
    TOOLBOX_CALLS="${TEST_ROOT}/toolbox-calls"

    toolbox() { printf '%s\n' "$*" >> "${TOOLBOX_CALLS}"; }
}

run_useful_packages() {
    local install_now="${1}"

    ui_confirm() {
        return 0
    }

    ui_choose_many() {
        printf '%s\n' "ack" "bat"
    }

    ui_choose_one() {
        if [ "${install_now}" = "yes" ]; then
            printf '%s\n' "Install now"
        else
            printf '%s\n' "Save for later"
        fi
    }

    (
        cd "${REPO_ROOT}" || exit 1
        source "silverblue/useful-packages.sh"
    )
}

@test "declining install now does not install packages" {
    run run_useful_packages "no"
    assert_success

    if [ -f "${TOOLBOX_CALLS}" ]; then
        run cat "${TOOLBOX_CALLS}"
        refute_output_contains "run sudo dnf install"
    fi

    run grep -F 'PACKAGE_LIST="ack bat"' "${TEST_ROOT}/scripts/aliases.sh"
    assert_success
}

@test "accepting install now installs selected packages in the toolbox" {
    run run_useful_packages "yes"
    assert_success

    assert_file_exists "${TOOLBOX_CALLS}"
    run cat "${TOOLBOX_CALLS}"
    assert_output_contains "run sudo dnf install ack"
}
