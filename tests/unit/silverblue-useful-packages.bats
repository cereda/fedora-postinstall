#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
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

    section() { :; }
    description() { :; }
    text() { :; }
    info() { :; }
    warning() { :; }
    toolbox() { printf '%s\n' "$*" >> "${TOOLBOX_CALLS}"; }
}

run_useful_packages() {
    local install_now="${1}"

    question() {
        case "${1}" in
            "Do you want to install some useful packages?") return 0 ;;
            "Should I install them now? It's advisable to do this later.") [ "${install_now}" = "yes" ] ;;
            *) return 1 ;;
        esac
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
}

@test "accepting install now installs selected packages in the toolbox" {
    run run_useful_packages "yes"
    assert_success

    assert_file_exists "${TOOLBOX_CALLS}"
    run cat "${TOOLBOX_CALLS}"
    assert_output_contains "run sudo dnf install ack"
}
