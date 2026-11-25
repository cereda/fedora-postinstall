#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    source "${REPO_ROOT}/common/validation.sh"
}

@test "valid hostnames are accepted" {
    run is_valid_hostname "workstation-42"
    assert_success

    run is_valid_hostname "a"
    assert_success
}

@test "unsafe hostnames are rejected" {
    for name in "" "-workstation" "workstation-" "two words" "../escape" "workstation/child"; do
        run is_valid_hostname "${name}"
        assert_failure
    done
}

@test "valid container names are accepted" {
    run is_valid_container_name "f42-dev"
    assert_success

    run is_valid_container_name "tool_box.local"
    assert_success
}

@test "unsafe container names are rejected" {
    for name in "" "-toolbox" "two words" "../escape" "toolbox/child"; do
        run is_valid_container_name "${name}"
        assert_failure
    done
}

@test "Git identities reject control characters and malformed addresses" {
    run is_valid_git_name "Paula Cereda"
    assert_success

    run is_valid_git_name $'Paula\nCereda'
    assert_failure

    run is_valid_git_email "paula@example.com"
    assert_success

    run is_valid_git_email "not-an-address"
    assert_failure
}

@test "Flatpak cache-retention state round-trips populated and empty selections" {
    run flatpaks_keep_cache_state_from_ids \
        "com.example.Retained" "org.gnome.TextEditor"
    assert_success
    assert_equal "${output}" \
        '["com.example.Retained","org.gnome.TextEditor"]'

    flatpaks_keep_cache_filter_from_state "${output}"
    assert_equal "${FLATPAKS_KEEP_CACHE_LIST}" \
        " -not -name com.example.Retained -not -name org.gnome.TextEditor"

    run flatpaks_keep_cache_state_from_ids
    assert_success
    assert_equal "${output}" "[]"

    flatpaks_keep_cache_filter_from_state "${output}"
    assert_equal "${FLATPAKS_KEEP_CACHE_LIST}" ""
}

@test "Flatpak cache-retention state rejects invalid identifiers" {
    run flatpaks_keep_cache_state_from_ids "../escape"
    assert_failure
    assert_output_contains "Invalid Flatpak application identifier"

    run flatpaks_keep_cache_filter_from_state '["../escape"]'
    assert_failure
    assert_output_contains "saved Flatpak cache-retention state is invalid"
}
