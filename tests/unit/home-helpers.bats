#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/home-helpers"
    MANAGED_ROOT="${TEST_ROOT}/managed"
    SCRIPT_ROOT="${MANAGED_ROOT}/scripts"

    mkdir -p "${SCRIPT_ROOT}"
}

@test "generated Flatpak retention filters retain every selected identifier" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local filter_count

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content \
            "$2" workstation host_test 1 \
            $'"'"'org.example.First\norg.example.Second'"'"'
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_success

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content \
            "$2" workstation host_test 1 \
            $'"'"'org.example.First\norg.example.Second'"'"' > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run bash -c '
        source "$1"
        printf "%s\n" "${#HOME_CONFIGURATION_FLATPAKS_KEEP_FILTER[@]}"
        printf "%s\n" "${HOME_CONFIGURATION_FLATPAKS_KEEP_FILTER[@]}"
    ' _ "${aliases_file}"
    assert_success
    filter_count="$(printf '%s\n' "${output}" | sed -n '1p')"
    assert_equal "${filter_count}" "6"
    assert_output_contains "org.example.First"
    assert_output_contains "org.example.Second"
}

@test "generated helper command names reject shell syntax" {
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation "bad;name" 1 ""
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_completion_content "bad;name" "system"
    ' _ "${REPO_ROOT}"
    assert_failure
}

@test "generated-file writes are atomic and preserve the previous file on failure" {
    local target="${SCRIPT_ROOT}/atomic.txt"

    printf '%s\n' "original" > "${target}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        failing_renderer() { return 7; }
        home_helpers_write_file "$2" 0644 failing_renderer
    ' _ "${REPO_ROOT}" "${target}"
    assert_equal "${status}" "7"

    run cat "${target}"
    assert_success
    assert_equal "${output}" "original"
    run find "${SCRIPT_ROOT}" -maxdepth 1 -name 'atomic.txt.tmp.*' -print
    assert_success
    assert_equal "${output}" ""
}

@test "generated-file writes reject a directory target" {
    local target="${SCRIPT_ROOT}/directory-target"

    mkdir -p "${target}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        renderer() { printf "%s\n" "unexpected"; }
        home_helpers_write_file "$2" 0644 renderer
    ' _ "${REPO_ROOT}" "${target}"
    assert_failure
    assert_output_contains "target is not a regular file"

    run test -d "${target}"
    assert_success
    run find "${SCRIPT_ROOT}" -maxdepth 1 -name 'directory-target.tmp.*' -print
    assert_success
    assert_equal "${output}" ""
}

@test "temporary cleanup retains retry state after a removal failure" {
    local temporary_file="${TEST_ROOT}/temporary-file"
    local removal_log="${TEST_ROOT}/removal-log"

    printf '%s\n' "temporary" > "${temporary_file}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        REMOVAL_LOG="$2"
        runtime_register_cleanup() { return 0; }
        runtime_unregister_cleanup() {
            printf "unregistered\n" >> "${REMOVAL_LOG}"
            return 0
        }
        rm() {
            count=0
            [ ! -f "${REMOVAL_LOG}" ] ||
                count=$(cat "${REMOVAL_LOG}")
            count=$((count + 1))
            printf "%s\n" "${count}" > "${REMOVAL_LOG}"
            if [ "${count}" -eq 1 ]; then
                return 9
            fi
            /usr/bin/rm "$@"
        }
        home_helpers_track_temporary "$3"
        first_status=0
        home_helpers_remove_temporary || first_status="${?}"
        printf "first=%s path=%s registered=%s\n" \
            "${first_status}" "${HOME_HELPERS_TEMPORARY_PATH}" \
            "${HOME_HELPERS_CLEANUP_REGISTERED}"
        second_status=0
        home_helpers_remove_temporary || second_status="${?}"
        printf "second=%s path=%s registered=%s\n" \
            "${second_status}" "${HOME_HELPERS_TEMPORARY_PATH}" \
            "${HOME_HELPERS_CLEANUP_REGISTERED}"
    ' _ "${REPO_ROOT}" "${removal_log}" "${temporary_file}"
    assert_success
    assert_output_contains "first=9 path=${temporary_file} registered=1"
    assert_output_contains "second=0 path= registered=0"
    assert_file_absent "${temporary_file}"
}

@test "the managed Bash entry-point block is idempotent" {
    local bashrc="${TEST_ROOT}/.bashrc"

    printf '%s\n' "before" > "${bashrc}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_success

    run grep -c '^# BEGIN fedora-postinstall managed home configuration$' "${bashrc}"
    assert_success
    assert_equal "${output}" "1"
    run grep -c '^# END fedora-postinstall managed home configuration$' "${bashrc}"
    assert_success
    assert_equal "${output}" "1"
    run grep -F "source ${MANAGED_ROOT}/scripts/bash.sh" "${bashrc}"
    assert_success
}

@test "an unmatched managed Bash block is rejected without changing the entry point" {
    local bashrc="${TEST_ROOT}/.bashrc"

    printf '%s\n' \
        "before" \
        "# BEGIN fedora-postinstall managed home configuration" > "${bashrc}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "unmatched managed block"

    run cat "${bashrc}"
    assert_success
    assert_equal "${output}" $'before\n# BEGIN fedora-postinstall managed home configuration'
}

@test "an unmatched managed end marker is rejected without changing the entry point" {
    local bashrc="${TEST_ROOT}/.bashrc"

    printf '%s\n' \
        "before" \
        "# END fedora-postinstall managed home configuration" > "${bashrc}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "unmatched managed block"

    run cat "${bashrc}"
    assert_success
    assert_equal "${output}" $'before\n# END fedora-postinstall managed home configuration'
}

@test "generated-file writes reject a symlinked ancestor outside the managed root" {
    local outside_root="${TEST_ROOT}/outside"
    local target="${MANAGED_ROOT}/linked/sub/generated.txt"

    mkdir -p "${outside_root}/sub"
    ln -s "${outside_root}" "${MANAGED_ROOT}/linked"

    run bash -c '
        source "$1/common/home-helpers.sh"
        HOME_HELPERS_MANAGED_ROOT="$2"
        renderer() { printf "%s\n" "unexpected" > "$3"; }
        home_helpers_write_file "$3" 0644 renderer "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${target}"
    assert_failure
    assert_output_contains "symbolic-link component"
    assert_file_absent "${outside_root}/sub/generated.txt"
}

@test "generated-file writes reject a symlinked ancestor inside the managed root" {
    local target="${MANAGED_ROOT}/linked/generated.txt"

    mkdir -p "${MANAGED_ROOT}/real"
    ln -s "${MANAGED_ROOT}/real" "${MANAGED_ROOT}/linked"

    run bash -c '
        source "$1/common/home-helpers.sh"
        HOME_HELPERS_MANAGED_ROOT="$2"
        renderer() { printf "%s\n" "unexpected" > "$3"; }
        home_helpers_write_file "$3" 0644 renderer "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${target}"
    assert_failure
    assert_output_contains "symbolic-link component"
    assert_file_absent "${MANAGED_ROOT}/real/generated.txt"
}

@test "the generated file server prefers python3 and falls back to python" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local marker="${TEST_ROOT}/server-command"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env MOCK_SERVER_MARKER="${marker}" bash -c '
        command() {
            if [ "${1:-}" = "-v" ]; then
                case "${2:-}" in
                    python3 | python) return 0 ;;
                    *) return 1 ;;
                esac
            fi
            builtin command "$@"
        }
        python3() { printf "%s\n" "python3" > "${MOCK_SERVER_MARKER}"; }
        python() { printf "%s\n" "python" > "${MOCK_SERVER_MARKER}"; }
        source "$1"
        _host_serve_directory "$2"
    ' _ "${aliases_file}" "${TEST_ROOT}"
    assert_success
    run cat "${marker}"
    assert_success
    assert_equal "${output}" "python3"

    run env MOCK_SERVER_MARKER="${marker}" bash -c '
        command() {
            if [ "${1:-}" = "-v" ]; then
                [ "${2:-}" = "python" ]
                return $?
            fi
            builtin command "$@"
        }
        python() { printf "%s\n" "python" > "${MOCK_SERVER_MARKER}"; }
        source "$1"
        _host_serve_directory "$2"
    ' _ "${aliases_file}" "${TEST_ROOT}"
    assert_success
    run cat "${marker}"
    assert_success
    assert_equal "${output}" "python"

    run -127 bash -c '
        command() {
            if [ "${1:-}" = "-v" ]; then
                return 1
            fi
            builtin command "$@"
        }
        source "$1"
        _host_serve_directory "$2"
    ' _ "${aliases_file}" "${TEST_ROOT}"
    assert_equal "${status}" "127"
}

@test "generated media helpers use explicit directories and safe yt-dlp options" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/media-bin"
    local output_directory="${TEST_ROOT}/media-output"
    local ytdlp_log="${TEST_ROOT}/yt-dlp.log"
    local ffmpeg_marker="${TEST_ROOT}/ffmpeg-called"

    mkdir -p "${mock_bin}" "${output_directory}"
    cat > "${mock_bin}/yt-dlp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${MOCK_YTDLP_LOG}"
exit 0
EOF
    cat > "${mock_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_FFMPEG_MARKER}"
exit 0
EOF
    chmod +x "${mock_bin}/yt-dlp" "${mock_bin}/ffmpeg"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env \
        MOCK_YTDLP_LOG="${ytdlp_log}" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        bash -c '
            source "$1"
            video-downloader "$2" "https://example.invalid/video"
        ' _ "${aliases_file}" "${output_directory}"
    assert_success
    run grep -Fx -- '--no-playlist' "${ytdlp_log}"
    assert_success
    run grep -Fx -- '--no-overwrites' "${ytdlp_log}"
    assert_success
    run grep -F -- "https://example.invalid/video" "${ytdlp_log}"
    assert_success

    run env \
        MOCK_YTDLP_LOG="${ytdlp_log}" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        bash -c '
            source "$1"
            playlist "https://example.invalid/list" "$2"
        ' _ "${aliases_file}" "${output_directory}"
    assert_success
    run grep -Fx -- '--yes-playlist' "${ytdlp_log}"
    assert_success

    printf '%s\n' 'audio' > "${TEST_ROOT}/source.mp3"
    printf '%s\n' 'existing' > "${output_directory}/source.ogg"
    run env \
        MOCK_FFMPEG_MARKER="${ffmpeg_marker}" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        bash -c '
            source "$1"
            audio-to-ogg "$2" "$3"
        ' _ "${aliases_file}" "${TEST_ROOT}/source.mp3" "${output_directory}"
    assert_equal "${status}" "1"
    assert_output_contains "output file already exists"
    assert_file_absent "${ffmpeg_marker}"
}

@test "generated rolling-tool updates preserve installer failures" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/bin"
    local runtime_directory="${TEST_ROOT}/runtime"

    mkdir -p "${mock_bin}" "${runtime_directory}"
    cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "${output}" <<'INSTALLER'
#!/usr/bin/env bash
exit "${MOCK_INSTALLER_STATUS:-0}"
INSTALLER
EOF
    chmod +x "${mock_bin}/curl"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test_machine 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env \
        MOCK_INSTALLER_STATUS=7 \
        PATH="${mock_bin}:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="${runtime_directory}" \
        bash -c '
            source "$1"
            host_test_machine upgrade starship
        ' _ "${aliases_file}"
    assert_equal "${status}" "7"
    assert_output_contains "failed with status 7"
}

@test "generated rolling-tool cleanup retries a failed temporary removal" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/rolling-retry-bin"
    local temporary_root="${TEST_ROOT}/rolling-retry-tmp"
    local removal_log="${TEST_ROOT}/rolling-removal-log"
    local runtime_directory="${TEST_ROOT}/runtime"

    mkdir -p "${mock_bin}" "${temporary_root}" "${runtime_directory}"
    cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${output}"
EOF
    chmod +x "${mock_bin}/curl"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test_machine 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env \
        MOCK_REMOVAL_LOG="${removal_log}" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        TMPDIR="${temporary_root}" \
        XDG_RUNTIME_DIR="${runtime_directory}" \
        bash -c '
            rm() {
                count=0
                [ ! -f "${MOCK_REMOVAL_LOG}" ] ||
                    count=$(tail -n 1 "${MOCK_REMOVAL_LOG}")
                count=$((count + 1))
                printf "%s\n" "${count}" >> "${MOCK_REMOVAL_LOG}"
                if [ "${count}" -eq 1 ]; then
                    return 9
                fi
                /usr/bin/rm "$@"
            }
            source "$1"
            _host_run_rolling_installer "https://example.test/install" sh
        ' _ "${aliases_file}"
    assert_equal "${status}" "9"
    assert_output_contains "temporary file could not be removed"

    run cat "${removal_log}"
    assert_success
    assert_equal "${output}" $'1\n2'
    run find "${temporary_root}" -maxdepth 1 -type f -print
    assert_success
    assert_equal "${output}" ""
}

@test "helper rendering validates every argument before writing a partial set" {
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_all "$2" workstation "bad;name" 1 ""
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "invalid helper command name"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_all "$2" workstation host_test 2 ""
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "invalid Flatpak retention state"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_all "$2" workstation host_test 1 "not a valid id"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "invalid Flatpak application identifier"

    local generated_file
    for generated_file in bash.sh aliases.sh completion.sh toolbox.sh; do
        assert_file_absent "${SCRIPT_ROOT}/${generated_file}"
    done
}

@test "a legacy unmarked managed Bash block is migrated to the marked block" {
    local bashrc="${TEST_ROOT}/.bashrc"

    printf '%s\n' \
        "before" \
        "# managed home configuration" \
        "if [ -e \"/legacy/root/scripts/bash.sh\" ]; then" \
        "    source \"/legacy/root/scripts/bash.sh\"" \
        "fi" \
        "after" > "${bashrc}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_success

    run grep -c '^# managed home configuration$' "${bashrc}"
    assert_failure
    run grep -c '^# BEGIN fedora-postinstall managed home configuration$' "${bashrc}"
    assert_success
    assert_equal "${output}" "1"
    run grep -c '^# END fedora-postinstall managed home configuration$' "${bashrc}"
    assert_success
    assert_equal "${output}" "1"
    run grep -F "source ${MANAGED_ROOT}/scripts/bash.sh" "${bashrc}"
    assert_success
    run grep -F "/legacy/root/scripts/bash.sh" "${bashrc}"
    assert_failure
}

@test "a malformed legacy managed Bash block is rejected without changing the entry point" {
    local bashrc="${TEST_ROOT}/.bashrc"
    local original="${TEST_ROOT}/bashrc.original"

    printf '%s\n' \
        "# managed home configuration" \
        "if [ -e \"/legacy/root/scripts/bash.sh\" ]; then" \
        "    source \"/different/root/scripts/bash.sh\"" \
        "fi" > "${bashrc}"
    cp "${bashrc}" "${original}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "malformed legacy managed block"

    run cmp -s "${original}" "${bashrc}"
    assert_success
}

@test "ambiguous legacy managed Bash blocks are rejected without changing the entry point" {
    local bashrc="${TEST_ROOT}/.bashrc"
    local original="${TEST_ROOT}/bashrc.original"

    printf '%s\n' \
        "# managed home configuration" \
        "if [ -e \"/legacy/root/scripts/bash.sh\" ]; then" \
        "    source \"/legacy/root/scripts/bash.sh\"" \
        "fi" \
        "# managed home configuration" \
        "if [ -e \"/other/root/scripts/bash.sh\" ]; then" \
        "    source \"/other/root/scripts/bash.sh\"" \
        "fi" > "${bashrc}"
    cp "${bashrc}" "${original}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_update_bashrc "$2" "$3"
    ' _ "${REPO_ROOT}" "${bashrc}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "ambiguous managed block"

    run cmp -s "${original}" "${bashrc}"
    assert_success
}

@test "the common and generated rolling installers share a stable per-tool lock path" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local runtime_directory="${TEST_ROOT}/runtime"

    mkdir -p "${runtime_directory}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env XDG_RUNTIME_DIR="${runtime_directory}" bash -c '
        source "$1/common/rolling-install.sh"
        source "$2"
        common_path=$(rolling_installer_lock_path "https://starship.rs/install.sh")
        generated_path=$(_host_rolling_lock_path "https://starship.rs/install.sh")
        direnv_path=$(_host_rolling_lock_path "https://direnv.net/install.sh")
        printf "%s\n%s\n%s\n" "${common_path}" "${generated_path}" "${direnv_path}"
    ' _ "${REPO_ROOT}" "${aliases_file}"
    assert_success
    assert_output_contains "${runtime_directory}/rolling-install-starship.lock"
    assert_output_contains "${runtime_directory}/rolling-install-direnv.lock"
    assert_equal "$(printf '%s\n' "${output}" | sed -n '1p')" \
        "$(printf '%s\n' "${output}" | sed -n '2p')"
}

@test "the common and generated rolling installers contend on the same tool lock" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/lock-contention-bin"
    local runtime_directory="${TEST_ROOT}/runtime"
    local lock_holder
    local lock_path
    local ready_marker="${TEST_ROOT}/lock-holder-ready"

    mkdir -p "${mock_bin}" "${runtime_directory}"
    cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
: > "${MOCK_CURL_MARKER}"
exit 0
EOF
    chmod +x "${mock_bin}/curl"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env XDG_RUNTIME_DIR="${runtime_directory}" bash -c '
        source "$1/common/rolling-install.sh"
        rolling_installer_lock_path "https://starship.rs/install.sh"
    ' _ "${REPO_ROOT}"
    assert_success
    lock_path="${output}"

    MOCK_READY_MARKER="${ready_marker}" setsid flock -x "${lock_path}" -c \
        'touch "$MOCK_READY_MARKER"; sleep 30' &
    lock_holder="${!}"
    for _ in {1..50}; do
        [ -f "${ready_marker}" ] && break
        sleep 0.1
    done
    if [ ! -f "${ready_marker}" ]; then
        kill -TERM -- "-${lock_holder}" 2>/dev/null ||
            kill -TERM "${lock_holder}" 2>/dev/null || true
        wait "${lock_holder}" 2>/dev/null || true
    fi
    assert_file_exists "${ready_marker}"

    run env \
        MOCK_CURL_MARKER="${TEST_ROOT}/curl-called" \
        PATH="${mock_bin}:/usr/bin:/bin" \
        ROLLING_INSTALLER_LOCK_TIMEOUT_SECONDS=1 \
        XDG_RUNTIME_DIR="${runtime_directory}" \
        bash -c '
            source "$1"
            _host_run_rolling_installer "https://starship.rs/install.sh" bash
        ' _ "${aliases_file}"

    kill -TERM -- "-${lock_holder}" 2>/dev/null || kill -TERM "${lock_holder}" 2>/dev/null || true
    wait "${lock_holder}" 2>/dev/null || true

    assert_failure
    assert_output_contains "update lock"
    assert_file_absent "${TEST_ROOT}/curl-called"
}

@test "individual helper renderers reject invalid arguments" {
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "not a valid id"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "invalid Flatpak application identifier"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_bash_content "$2" unsupported
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "unsupported helper flavor"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_toolbox_content "$2" unsupported
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}"
    assert_failure
    assert_output_contains "unsupported helper flavor"
}

@test "generated rolling installers have a bounded execution timeout" {
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/generated-timeout-bin"
    local temporary_root="${TEST_ROOT}/generated-timeout-tmp"
    local runtime_directory="${TEST_ROOT}/runtime"

    mkdir -p "${mock_bin}" "${temporary_root}" "${runtime_directory}"
    cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "${output}" <<'INSTALLER'
#!/usr/bin/env bash
sleep 30
INSTALLER
EOF
    chmod +x "${mock_bin}/curl"

    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success

    run env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        ROLLING_INSTALLER_KILL_GRACE_SECONDS=1 \
        ROLLING_INSTALLER_TIMEOUT_SECONDS=1 \
        TMPDIR="${temporary_root}" \
        XDG_RUNTIME_DIR="${runtime_directory}" \
        bash -c '
            source "$1"
            _host_run_rolling_installer "https://example.test/install" bash
        ' _ "${aliases_file}"
    assert_equal "${status}" "124"
    assert_output_contains "timed out"
    run find "${temporary_root}" -mindepth 1 -print
    assert_success
    assert_equal "${output}" ""
}

@test "generated rolling installers forward signals and preserve installer status" {
    local signal
    local expected_status
    local aliases_file="${SCRIPT_ROOT}/aliases.sh"
    local mock_bin="${TEST_ROOT}/generated-signal-bin"
    local temporary_root="${TEST_ROOT}/generated-signal-tmp"
    local ready_marker="${TEST_ROOT}/generated-signal-ready"
    local runtime_directory="${TEST_ROOT}/runtime"

    mkdir -p "${mock_bin}" "${temporary_root}" "${runtime_directory}"
    run bash -c '
        source "$1/common/home-helpers.sh"
        home_helpers_render_aliases_content "$2" workstation host_test 1 "" > "$3"
    ' _ "${REPO_ROOT}" "${MANAGED_ROOT}" "${aliases_file}"
    assert_success
    for signal in HUP INT TERM; do
        case "${signal}" in
        HUP) expected_status=7 ;;
        INT) expected_status=8 ;;
        TERM) expected_status=9 ;;
        esac
        rm -f "${ready_marker}"
        cat > "${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
output=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --output)
            output="\${2:-}"
            shift 2
            ;;
        --retry | --retry-delay | --connect-timeout | --max-time | --proto)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "\${output}" <<'INSTALLER'
#!/usr/bin/env bash
trap 'exit ${expected_status}' ${signal}
: > "\${READY_MARKER}"
while :; do sleep 1; done
INSTALLER
EOF
        chmod +x "${mock_bin}/curl"

        run env \
            PATH="${mock_bin}:/usr/bin:/bin" \
            READY_MARKER="${ready_marker}" \
            ROLLING_INSTALLER_TIMEOUT_SECONDS=10 \
            TMPDIR="${temporary_root}" \
            XDG_RUNTIME_DIR="${runtime_directory}" \
            python3 "${REPO_ROOT}/tests/helpers/run-until-ready.py" \
            --signal "${signal}" \
            --ready "${ready_marker}" \
            --timeout 10 \
            -- \
            bash -c '
                source "$1"
                _host_run_rolling_installer "https://example.test/install" bash
            ' _ "${aliases_file}"

        assert_equal "${status}" "${expected_status}"
        assert_output_contains "failed with status ${expected_status}"
    done
}
