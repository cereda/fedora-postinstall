#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/profiles"
    SANDBOX_REPO="${TEST_ROOT}/repo"
    TEST_HOME="${TEST_ROOT}/home"
    MOCK_BIN="${TEST_ROOT}/bin"
    TMP_ROOT="${TEST_ROOT}/tmp"
    OS_RELEASE_FILE="${TEST_ROOT}/os-release"

    mkdir -p \
        "${SANDBOX_REPO}" \
        "${TEST_HOME}" \
        "${MOCK_BIN}" \
        "${TMP_ROOT}"

    cp -R "${REPO_ROOT}/common" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/extras" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/profiles" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/workstation" "${SANDBOX_REPO}/"
    cp -R "${REPO_ROOT}/silverblue" "${SANDBOX_REPO}/"
    cp "${REPO_ROOT}/fedora-postinstall.sh" "${SANDBOX_REPO}/"

    cat > "${OS_RELEASE_FILE}" <<'EOF'
NAME="Fedora Workstation"
ID=fedora
VERSION_ID=45
VARIANT_ID=workstation
EOF

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
    printf '%s\n' "x86_64"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

    cat > "${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-E" ]; then
    printf '%s\n' "45"
    exit 0
fi
printf '%s\n' "package ${2} is not installed"
exit 1
EOF

    chmod +x "${MOCK_BIN}/uname" "${MOCK_BIN}/rpm"
    export POSTINSTALL_OS_RELEASE_FILE="${OS_RELEASE_FILE}"
}

run_plan() {
    run env \
        HOME="${TEST_HOME}" \
        XDG_CONFIG_HOME="${TEST_ROOT}/config" \
        XDG_STATE_HOME="${TEST_ROOT}/state" \
        TMPDIR="${TMP_ROOT}" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        bash "${SANDBOX_REPO}/fedora-postinstall.sh" plan --json "$@"
}

write_profile() {
    local path="${1:-${TEST_ROOT}/profile.json}"
    cat > "${path}"
    printf '%s\n' "${path}"
}

@test "a valid profile selects modules in canonical inventory order" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "tiny",
  "description": "A tiny profile",
  "modules": {
    "include": ["common/zoxide-installation.sh"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_success
    run jq -r '.modules[] | select(.selected) | .path' <<<"${output}"
    assert_success
    assert_equal "${output}" $'common/hostname-configuration.sh\nworkstation/home-configuration.sh\ncommon/zoxide-installation.sh'
}

@test "profile module order cannot override canonical execution order" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "ordered",
  "description": "An ordered profile",
  "modules": {
    "include": ["common/zoxide-installation.sh", "common/hostname-configuration.sh"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_success
    run jq -r '.modules[] | select(.selected) | .path' <<<"${output}"
    assert_success
    assert_equal "${output}" $'common/hostname-configuration.sh\nworkstation/home-configuration.sh\ncommon/zoxide-installation.sh'
}

@test "excluding a required dependency is rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "broken",
  "description": "A broken profile",
  "modules": {
    "include": ["common/zoxide-installation.sh"],
    "exclude": ["workstation/home-configuration.sh"]
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "requires excluded module"
}

@test "an unknown module pattern is rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "unknown",
  "description": "An unknown profile",
  "modules": {
    "include": ["does/not/exist.sh"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "does not match any supported inventory"
}

@test "a profile can restrict supported Fedora flavors" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "workstation-only",
  "description": "A Workstation profile",
  "flavors": ["workstation"],
  "modules": {"include": [], "exclude": []}
}
EOF
)

    run_plan --profile-file "${profile}" --flavor silverblue
    assert_equal "${status}" 65
    assert_output_contains "does not support Fedora silverblue"
}

@test "unknown profile tools are rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "bad-tool",
  "description": "A profile with an unknown tool",
  "extras": {"tools": ["not-a-tool"]}
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "unknown tool identifier"
}

@test "duplicate JSON keys are rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "duplicate",
  "description": "A duplicate profile",
  "modules": {"include": [], "exclude": []},
  "modules": {"include": ["*"], "exclude": []}
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "duplicate JSON key"
}

@test "unknown profile fields are rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "unknown-field",
  "description": "An unknown profile field",
  "commands": ["rm -rf /"]
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "unknown profile field"
}

@test "symbolic-link profiles are rejected" {
    local profile="${TEST_ROOT}/target.json"
    local link="${TEST_ROOT}/link.json"
    cat > "${profile}" <<'EOF'
{"schema_version":1,"name":"linked","description":"A linked profile"}
EOF
    ln -s "${profile}" "${link}"

    run_plan --profile-file "${link}"
    assert_equal "${status}" 65
    assert_output_contains "must not be a symbolic link"
}

@test "a user profile takes precedence over a bundled profile name" {
    local user_profile="${TEST_ROOT}/config/fedora-postinstall/profiles/default.json"
    mkdir -p "$(dirname "${user_profile}")"
    cat > "${user_profile}" <<'EOF'
{
  "schema_version": 1,
  "name": "default",
  "description": "A user override",
  "modules": {
    "include": ["common/hostname-configuration.sh"],
    "exclude": []
  }
}
EOF

    run_plan --profile default
    assert_success
    local plan_output="${output}"
    run jq -r '.profile.name' <<<"${plan_output}"
    assert_success
    assert_equal "${output}" "default"
    run jq -r '.modules[] | select(.selected) | .path' <<<"${plan_output}"
    assert_success
    assert_equal "${output}" "common/hostname-configuration.sh"
}

@test "array-valued state dependencies are included in the closure" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "flatpaks",
  "description": "Install Flatpaks",
  "modules": {
    "include": ["common/flatpaks-installation.sh"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_success
    run jq -r '.modules[] | select(.selected) | .path' <<<"${output}"
    assert_success
    assert_equal "${output}" $'common/flatpaks-to-install.sh\ncommon/flatpaks-installation.sh'
}

@test "excluding an array-valued state provider is rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "broken-flatpaks",
  "description": "Exclude a required Flatpak provider",
  "modules": {
    "include": ["common/flatpaks-installation.sh"],
    "exclude": ["common/flatpaks-to-install.sh"]
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "requires excluded module"
}

@test "indirectly expanded array dependencies are included in the closure" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "fonts",
  "description": "Install Nerd Fonts",
  "modules": {
    "include": ["common/fonts-installation.sh"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_success
    run jq -r '.modules[] | select(.selected) | .path' <<<"${output}"
    assert_success
    assert_equal "${output}" $'common/fonts-to-install.sh\ncommon/fonts-installation.sh'
}

@test "excluding an indirectly expanded array provider is rejected" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "broken-fonts",
  "description": "Exclude a required Nerd Fonts provider",
  "modules": {
    "include": ["common/fonts-installation.sh"],
    "exclude": ["common/fonts-to-install.sh"]
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_equal "${status}" 65
    assert_output_contains "requires excluded module"
}

@test "the extras module can be selected with a wildcard pattern" {
    local profile
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "extras-only",
  "description": "Select only the extras module",
  "modules": {
    "include": ["extras/*"],
    "exclude": []
  }
}
EOF
)

    run_plan --profile-file "${profile}"
    assert_success
    run jq -r '.modules[] | select(.selected) | .path' <<<"${output}"
    assert_success
    assert_equal "${output}" "extras/additional-tools.sh"
}

@test "JSON logs report the effective profile name" {
    local profile
    local log_file="${TEST_ROOT}/profile.log"
    profile=$(write_profile <<'EOF'
{
  "schema_version": 1,
  "name": "effective-name",
  "description": "A profile with an effective name"
}
EOF
)

    run_plan --profile-file "${profile}" --log-file "${log_file}" --log-format json
    assert_success
    assert_file_exists "${log_file}"
    run jq -s -e 'all(.[]; .context.profile == "effective-name")' "${log_file}"
    assert_success
}
