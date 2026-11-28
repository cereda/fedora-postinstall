#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/resume-context"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    STATE_FILE="${TEST_ROOT}/state.tsv"

    mkdir -p \
        "${SANDBOX_REPO}/common" \
        "${SANDBOX_REPO}/extras" \
        "${SANDBOX_REPO}/modules" \
        "${SANDBOX_REPO}/workstation" \
        "${SANDBOX_REPO}/silverblue" \
        "${TEST_HOME}" \
        "${MOCK_BIN}"

    cp "${REPO_ROOT}/common/runtime.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/runtime-file.py" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/module-inventory.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/home-helpers.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/validation.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/flatpaks-installation.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/flatpaks-to-install.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/common/hostname-configuration.sh" "${SANDBOX_REPO}/common/"
    cp "${REPO_ROOT}/workstation/home-configuration.sh" \
        "${SANDBOX_REPO}/workstation/"
    cp "${REPO_ROOT}/silverblue/home-configuration.sh" \
        "${SANDBOX_REPO}/silverblue/"
    cp "${REPO_ROOT}/extras/tools-list.sh" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/tools-download.sh" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/tools-unpacking.sh" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/tools-deployment.sh" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/archive-extract.py" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/manifest_url.py" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/tar_guard.py" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/tools-manifest.json" "${SANDBOX_REPO}/extras/"
    cp "${REPO_ROOT}/extras/additional-tools.sh" "${SANDBOX_REPO}/extras/"
    for wrapper in "${REPO_ROOT}/extras/"*-download.sh; do
        cp "${wrapper}" "${SANDBOX_REPO}/extras/"
    done

    printf 'printf "module ran\\n"\n' > "${SANDBOX_REPO}/modules/context.sh"
    cat > "${SANDBOX_REPO}/modules/shared-context.sh" <<'EOF'
MACHINE_NAME="test-host"
ROOT_DIRECTORY_STRUCTURE="/tmp/test-root"
COMMAND_NAME="host_test_host"
TOOLBOX_NAME="f45-test"
EOF
}

checksum_for() {
    local module="${1:-modules/context.sh}"
    shift || true

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        "$@" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; source '${SANDBOX_REPO}/common/module-inventory.sh'; runtime_module_checksum '${module}' '${SANDBOX_REPO}/${module}'"
    assert_success
    printf '%s\n' "${output}"
}

@test "architecture changes invalidate a module fingerprint" {
    local before after
    before=$(checksum_for modules/context.sh POSTINSTALL_ARCHITECTURE=x86_64)
    after=$(checksum_for modules/context.sh POSTINSTALL_ARCHITECTURE=aarch64)
    if [ "${before}" = "${after}" ]; then
        printf 'architecture did not change the module fingerprint\n' >&2
        return 1
    fi
}

@test "flavor changes invalidate a module fingerprint" {
    local before after
    before=$(checksum_for modules/context.sh POSTINSTALL_FLAVOR=workstation)
    after=$(checksum_for modules/context.sh POSTINSTALL_FLAVOR=silverblue)
    if [ "${before}" = "${after}" ]; then
        printf 'flavor did not change the module fingerprint\n' >&2
        return 1
    fi
}

@test "profile content changes invalidate a module fingerprint" {
    local profile="${TEST_ROOT}/profile.json"
    printf '{"schema_version":1}\n' > "${profile}"
    local before after
    before=$(checksum_for modules/context.sh POSTINSTALL_PROFILE_FILE="${profile}")
    printf '{"schema_version":1,"name":"changed"}\n' > "${profile}"
    after=$(checksum_for modules/context.sh POSTINSTALL_PROFILE_FILE="${profile}")
    if [ "${before}" = "${after}" ]; then
        printf 'profile did not change the module fingerprint\n' >&2
        return 1
    fi
}

@test "logging options do not invalidate a module fingerprint" {
    local before after
    before=$(checksum_for modules/context.sh POSTINSTALL_LOG_FORMAT=plain POSTINSTALL_LOG_LEVEL=info)
    after=$(checksum_for modules/context.sh POSTINSTALL_LOG_FORMAT=json POSTINSTALL_LOG_LEVEL=debug)
    if [ "${before}" != "${after}" ]; then
        printf 'logging options unexpectedly changed the module fingerprint\n' >&2
        return 1
    fi
}

@test "changing the explicit extras selection invalidates the extras fingerprint" {
    local before after
    before=$(checksum_for extras/additional-tools.sh \
        POSTINSTALL_SELECTED_TOOLS=fd POSTINSTALL_TOOL_SELECTION_MODE=explicit)
    after=$(checksum_for extras/additional-tools.sh \
        POSTINSTALL_SELECTED_TOOLS=ripgrep POSTINSTALL_TOOL_SELECTION_MODE=explicit)
    if [ "${before}" = "${after}" ]; then
        printf 'extras selection did not change the module fingerprint\n' >&2
        return 1
    fi
}

@test "runtime skips modules outside the effective profile selection" {
    local marker="${TEST_ROOT}/module-marker"
    printf 'printf "ran\\n" > "%s"\n' "${marker}" > \
        "${SANDBOX_REPO}/modules/profile-skipped.sh"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_LOG_STDOUT=1 \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; RUNTIME_PROFILE_ENABLED=1; RUNTIME_PROFILE_MODULES=('modules/other.sh'); runtime_run_module 'modules/profile-skipped.sh'"
    assert_success
    assert_file_absent "${marker}"
    assert_output_contains "not selected by the active profile"
}

@test "resume captures and restores the shared installation context" {
    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; runtime_run_module 'modules/shared-context.sh' mutating MACHINE_NAME ROOT_DIRECTORY_STRUCTURE COMMAND_NAME TOOLBOX_NAME"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_RESUME=1 \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; MACHINE_NAME=''; ROOT_DIRECTORY_STRUCTURE=''; COMMAND_NAME=''; TOOLBOX_NAME=''; runtime_run_module 'modules/shared-context.sh' mutating MACHINE_NAME ROOT_DIRECTORY_STRUCTURE COMMAND_NAME TOOLBOX_NAME; printf '%s\\n%s\\n%s\\n%s\\n' \"\${MACHINE_NAME}\" \"\${ROOT_DIRECTORY_STRUCTURE}\" \"\${COMMAND_NAME}\" \"\${TOOLBOX_NAME}\""
    assert_success
    assert_output_contains "Module 1: modules/shared-context.sh (already completed)"
    assert_output_contains "test-host"
    assert_output_contains "/tmp/test-root"
    assert_output_contains "host_test_host"
    assert_output_contains "f45-test"
}

@test "resume restores retained Flatpak application IDs from a skipped provider" {
    cat > "${SANDBOX_REPO}/common/flatpaks-installation.sh" <<'EOF'
FLATPAKS_KEEP_CACHE_IDS_JSON='["com.example.Retained"]'
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; runtime_run_module 'common/flatpaks-installation.sh' mutating FLATPAKS_KEEP_CACHE_IDS_JSON"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_RESUME=1 \
        POSTINSTALL_LOG_STDOUT=1 \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; FLATPAKS_KEEP_CACHE_IDS_JSON=''; runtime_run_module 'common/flatpaks-installation.sh' mutating FLATPAKS_KEEP_CACHE_IDS_JSON; printf '%s\\n' \"\${FLATPAKS_KEEP_CACHE_IDS_JSON}\""
    assert_success
    assert_output_contains "Resume: skipping completed module"
    assert_output_contains '["com.example.Retained"]'
}

@test "resume restores an empty Flatpak cache-retention selection" {
    cat > "${SANDBOX_REPO}/common/flatpaks-installation.sh" <<'EOF'
FLATPAKS_KEEP_CACHE_IDS_JSON='[]'
EOF

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; runtime_run_module 'common/flatpaks-installation.sh' mutating FLATPAKS_KEEP_CACHE_IDS_JSON"
    assert_success

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        POSTINSTALL_RESUME=1 \
        POSTINSTALL_LOG_STDOUT=1 \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_initialize; FLATPAKS_KEEP_CACHE_IDS_JSON='unset'; runtime_run_module 'common/flatpaks-installation.sh' mutating FLATPAKS_KEEP_CACHE_IDS_JSON; printf '%s\\n' \"\${FLATPAKS_KEEP_CACHE_IDS_JSON}\""
    assert_success
    assert_output_contains "Resume: skipping completed module"
    assert_output_contains "[]"
}

@test "home configuration depends on resumable Flatpak retention state" {
    local before after

    before=$(checksum_for workstation/home-configuration.sh \
        POSTINSTALL_FLAVOR=workstation)
    printf '\n# provider change\n' >> \
        "${SANDBOX_REPO}/common/flatpaks-installation.sh"
    after=$(checksum_for workstation/home-configuration.sh \
        POSTINSTALL_FLAVOR=workstation)
    if [ "${before}" = "${after}" ]; then
        printf 'Flatpak retention provider did not change the consumer fingerprint\n' >&2
        return 1
    fi

    run grep -Fx \
        'common/flatpaks-installation.sh|mutating|FLATPAKS_KEEP_CACHE_IDS_JSON' \
        "${REPO_ROOT}/common/workstation-modules.psv"
    assert_success

    run grep -Fx \
        'common/flatpaks-installation.sh|mutating|FLATPAKS_KEEP_CACHE_IDS_JSON' \
        "${REPO_ROOT}/common/silverblue-modules.psv"
    assert_success
}

@test "home configuration depends on the Flatpak suggestion data" {
    local before after

    before=$(checksum_for workstation/home-configuration.sh \
        POSTINSTALL_FLAVOR=workstation)
    printf '\n# suggestion change\n' >> \
        "${SANDBOX_REPO}/common/flatpaks-to-install.sh"
    after=$(checksum_for workstation/home-configuration.sh \
        POSTINSTALL_FLAVOR=workstation)
    if [ "${before}" = "${after}" ]; then
        printf 'Flatpak suggestion data did not change the consumer fingerprint\n' >&2
        return 1
    fi
}

@test "home configuration fingerprints include helper and validation dependencies" {
    local module dependency flavor before after

    for module in \
        workstation/home-configuration.sh \
        silverblue/home-configuration.sh; do
        case "${module}" in
        workstation/*) flavor="workstation" ;;
        silverblue/*) flavor="silverblue" ;;
        esac

        for dependency in \
            common/home-helpers.sh \
            common/validation.sh; do
            cp "${REPO_ROOT}/${dependency}" "${SANDBOX_REPO}/${dependency}"
            before=$(checksum_for "${module}" \
                "POSTINSTALL_FLAVOR=${flavor}")
            printf '\n# dependency change\n' >> \
                "${SANDBOX_REPO}/${dependency}"
            after=$(checksum_for "${module}" \
                "POSTINSTALL_FLAVOR=${flavor}")

            if [ "${before}" = "${after}" ]; then
                printf '%s did not change the %s fingerprint\n' \
                    "${dependency}" "${module}" >&2
                return 1
            fi
        done
    done
}

@test "malformed resume records do not mark a module complete" {
    local checksum
    checksum=$(checksum_for modules/context.sh)
    printf 'module\tdefault:modules/context.sh\t%s\n' "${checksum}" > "${STATE_FILE}"

    run env \
        SCRIPT_PATH="${SANDBOX_REPO}" \
        HOME="${TEST_HOME}" \
        POSTINSTALL_STATE_FILE="${STATE_FILE}" \
        bash -c "source '${SANDBOX_REPO}/common/runtime.sh'; runtime_state_is_complete 'modules/context.sh' '${checksum}'"
    assert_equal "${status}" 2
    assert_output_contains "malformed record"
}

@test "a changed dependency provider invalidates the consumer fingerprint" {
    local before after
    before=$(checksum_for workstation/home-configuration.sh POSTINSTALL_FLAVOR=workstation)
    printf '\n# provider change\n' >> \
        "${SANDBOX_REPO}/common/hostname-configuration.sh"
    after=$(checksum_for workstation/home-configuration.sh POSTINSTALL_FLAVOR=workstation)
    if [ "${before}" = "${after}" ]; then
        printf 'dependency provider did not change the consumer fingerprint\n' >&2
        return 1
    fi
}

@test "interactive extras selections are part of the resume fingerprint" {
    local before after
    before=$(checksum_for extras/additional-tools.sh \
        POSTINSTALL_TOOL_SELECTION_MODE=interactive CLI_TOOLS_SELECTION=fd)
    after=$(checksum_for extras/additional-tools.sh \
        POSTINSTALL_TOOL_SELECTION_MODE=interactive CLI_TOOLS_SELECTION=ripgrep)
    if [ "${before}" = "${after}" ]; then
        printf 'interactive extras selection did not change the module fingerprint\n' >&2
        return 1
    fi
}
