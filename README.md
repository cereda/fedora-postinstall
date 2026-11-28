<!-- SPDX-License-Identifier: MIT -->

# Fedora post installation guide

This repository is my personal guide to the tasks I perform after a clean Fedora installation. It combines ideas from the Fedora community with my own experience and preferences. Review the script before running it and use it at your own risk.

## Requirements

The project targets Fedora Workstation and Fedora Silverblue. It requires `rpm` and the following commands: `bash`, `coreutils` (including `install`, `mktemp`, and `sha256sum`), `curl`, `findutils`, `git`, `jq`, `python3`, `realpath`, `tar`, `unzip`, `wget`, and `flock` from `util-linux`. On Fedora, install the missing tools with:

```bash
sudo dnf install coreutils curl findutils git jq python3 realpath tar unzip util-linux wget
```

An interactive installation also requires standard input and standard error to be connected to terminals, along with a working `sudo` session. The `detect`, `plan`, and `--dry-run` commands do not prompt, download files, create the cache or lock, or mutate installed packages or configuration. An explicitly requested `--log-file` is still written. The `doctor` command is read-only and Gum-independent. Snapshot listing and comparison are also Gum-independent and serialize with the installer lock, while snapshot creation and restoration use the normal mutation lifecycle. A command is required for every invocation; running the entry point without one is a usage error with status `64`. Invalid command usage exits with status `64`; an unknown or colliding explicit tool selection exits with status `69`.

Running the mocked test suite additionally requires Bats (`bats` on Fedora). The tests do not contact the network or use the real host home directory.

## Interaction and output

Static installer messages are rendered with native Bash so routine progress remains fast and readable. [Gum](https://github.com/charmbracelet/gum) is used only for interactive confirmations, selections, text input, and directory selection. It remains the primary interaction backend because it supplies consistent, feature-complete terminal controls without mixing several UI implementations. Routine sections are compact headings rather than full-width boxes.

Interactive installer progress and successful results are written to standard output, while interactive warnings and errors are written to standard error. The stable plain `detect`, `plan`, and dry-run reports retain their existing output format. Color is enabled only for an interactive terminal; `NO_COLOR` and `TERM=dumb` always disable it. `UI_COLOR_OVERRIDE=always` or `UI_COLOR_OVERRIDE=never` can force the color policy for a specific run.

For interactive commands, the installer reuses an installed Gum v2 release directly. If Gum v2 is not installed, the installer downloads the checksum-pinned Gum `v2.0.2` asset declared in `extras/tools-manifest.json`, verifies its SHA-256 checksum, enforces a download-size limit, extracts only the declared executable, verifies the staged version and required controls, and removes the temporary workspace when the run ends. This temporary prompt backend is not installed into `${HOME}/.local/bin`; the optional `gum` extra is a separate, persistent installation.

Set `GUM` to an explicit Gum executable path when an advanced installation needs to override normal executable lookup. If that override is missing or unsupported, the interactive command stops instead of silently using another Gum binary. The `help`, `detect`, `plan`, `doctor`, and `--dry-run` paths remain independent of Gum and never bootstrap or invoke it.

## Command-line workflow

Clone the repository and run the entry point from its root:

```bash
git clone --depth 1 https://github.com/cereda/fedora-postinstall
cd fedora-postinstall
bash fedora-postinstall.sh help
```

The available commands are:

| Command | Purpose |
|---------|---------|
| `install` | Run the selected Fedora flavor's post-installation modules. |
| `extras` | Install only the additional command-line tools. |
| `detect` | Report the detected operating system, flavor, and architecture. |
| `plan` | Render the effective module and tool plan without running it. |
| `doctor` | Run read-only host diagnostics. |
| `snapshot` | Create, list, compare, and restore managed-home snapshots. |
| `help` | Show command and option help. |

The `install` command requires a Fedora flavor. Use `--flavor workstation` or `--flavor silverblue` to select one explicitly, set `POSTINSTALL_FLAVOR`, or rely on reliable automatic detection. Command-line flavor selection takes precedence over the environment. If the flavor is unknown or detection is ambiguous, the command stops with status `69` before changing the system and asks for `--flavor`; there is no interactive flavor chooser. Architecture selection accepts `auto`, `x86_64`, or `aarch64`. Detection never falls back between native architectures: x86-64 and AArch64 use their own manifest assets, with universal assets selected only through an explicit `assets.any` entry.

Useful non-mutating examples are:

```bash
bash fedora-postinstall.sh detect
bash fedora-postinstall.sh detect --json
bash fedora-postinstall.sh doctor
bash fedora-postinstall.sh doctor --json
bash fedora-postinstall.sh plan
bash fedora-postinstall.sh plan --json --profile developer
bash fedora-postinstall.sh install --dry-run --json
```

`--dry-run` is non-interactive and routes through the same plan engine used by `plan`; it does not bootstrap Gum, download release assets, or execute installation modules.

## Diagnostics and snapshots

The `doctor` command performs read-only checks for the Fedora system, available firmware updates, the `fstrim.timer` state, a pending Workstation restart, whether `~/.local/bin` is present in `PATH`, and whether a snapshot transaction needs recovery. It never changes the host and never bootstraps Gum. Plain output is intended for people; `--json` emits a versioned object for automation. Warnings are reported without failing the command, while an unreadable or failed required check returns status `1`. Runtime logging options are rejected for `doctor` because creating a log file would violate its read-only contract. Host checks always use the detected host flavor; an explicit `--flavor` is reported separately as the selected flavor and never suppresses a host-specific check.

Snapshots capture the managed home directory selected during home configuration. Their metadata, manifests, and archives are stored privately under `~/.host/backups/snapshots/` with mode `0700` for directories and `0600` for files. Snapshot identifiers and labels are accepted in place of the generated timestamp identifier:

```bash
bash fedora-postinstall.sh snapshot create before-upgrade
bash fedora-postinstall.sh snapshot list
bash fedora-postinstall.sh snapshot diff before-upgrade after-change
bash fedora-postinstall.sh snapshot restore before-upgrade
bash fedora-postinstall.sh snapshot restore before-upgrade --path config/starship
```

`--path` is repeatable. Every restore requires an interactive terminal and explicit confirmation. A selective restore replaces exactly the requested snapshot subtrees transactionally; it does not merge unrelated files from the current directory. A whole-directory restore replaces the managed directory transactionally and retains the previous directory as a private rollback sibling. Snapshot creation is non-interactive and also uses the installer lock so it cannot race another post-installation run. Listing and comparison do not depend on the current runtime state; listing reports every valid snapshot, while comparison requires both snapshots to describe the same managed root.

Snapshot metadata never selects the restore destination independently: creation and restoration rediscover the managed root from the saved `ROOT_DIRECTORY_STRUCTURE` runtime state (using the effective `--state-file` selection) and fail with an operational error when that state is unavailable or invalid. Relative state-file paths resolve from the directory where the installer is invoked. If the state contains distinct Workstation and Silverblue roots, `--flavor` scopes discovery to that flavor; without it, the ambiguous roots are rejected. The latest valid saved root for a flavor is authoritative. Managed-root paths are canonicalized so a symbolic-link `HOME` remains usable. The runtime state, cache, and lock paths must remain outside the managed root so a restore cannot replace active installer control files. Archive, manifest, checksum, path, and symbolic-link checks are applied before restoration, and symlinked snapshot-storage components are rejected rather than followed.

Interrupted restores retain a private, versioned recovery journal in `${HOME}`. Run `bash fedora-postinstall.sh snapshot recover` to roll back an uncommitted transaction or finalize cleanup for a transaction that already reached its commit point; recovery never rolls committed content back. Recovery journals are bound to the authoritative managed root, and their generated artifact names and state fields are validated before any recovery action. Unsupported journal schemas, malformed records, and cleanup that could not finish remain visible as pending work instead of being ignored. The `doctor` command reports pending journals and their recovery artifacts without modifying them.

## Additional command-line tools

Select tools explicitly, or select every tool available for the target architecture:

```bash
bash fedora-postinstall.sh extras --tool fd --tool ripgrep
bash fedora-postinstall.sh extras --tools fd,ripgrep,yq
bash fedora-postinstall.sh extras --all-extras
bash fedora-postinstall.sh extras --dry-run --all-extras
```

The authoritative tool registry is `extras/tools-list.sh`. `extras/tools-manifest.json` records each resolved release URL, version, checksum, architecture asset, archive type, and archive member. The schema-v2 maintainer policy in `tools/extras-refresh-config.json` is authoritative for release sources, archive types, asset patterns, and archive-to-command mappings; profiles and command-line options can select registered tool identifiers but cannot replace those values.

## Profiles

Profiles are selection-only JSON documents. They can select canonical module names or patterns and registered extra-tool identifiers; they cannot define commands, URLs, checksums, scripts, or arbitrary paths. Bundled profiles are available as `default`, `minimal`, and `developer`:

```bash
bash fedora-postinstall.sh plan --profile minimal
bash fedora-postinstall.sh install --profile developer
bash fedora-postinstall.sh install --profile-file /path/to/profile.json
```

A user profile under `${XDG_CONFIG_HOME:-$HOME/.config}/fedora-postinstall/profiles/` takes precedence over the bundled profile with the same name. Explicit profile paths and user profiles are resolved before bundled profiles. Module order in a profile is ignored; modules always run in the canonical flavor inventory order. Required providers are included automatically, and excluding one is an error.

See [`docs/profiles.md`](docs/profiles.md) for the profile format and [`docs/profile.schema.json`](docs/profile.schema.json) for the JSON Schema.

## Managed home helper

The home-configuration module generates a `host_<machine-name>` command inside the managed `scripts/` directory and loads it from `~/.bashrc`. The generated files are replaced atomically on each run, and the managed Bash entry-point block is idempotent. Generated destructive confirmations require both standard input and standard error to be terminals, so redirected or background invocations fail closed instead of silently continuing. The helper provides explicit maintenance actions instead of an interactive configuration menu:

- `clean permissions reset` exports the current dynamic Flatpak permission-store grants and then resets every grant after confirmation.
- `clean permissions app APP_ID` exports one application's permission-store grants and resets that application after confirmation.
- `config reset app-grid` restores the default GNOME application-grid layout.
- `clean logs` vacuums old journal data and clears the DNF package cache after confirmation; it does not delete log files directly.
- `use server [DIRECTORY] [--public]` serves a directory with `python3`, or the `python` fallback; `DIRECTORY` defaults to the current directory.
- `playlist URL OUTPUT_DIRECTORY`, `video-downloader OUTPUT_DIRECTORY URL...`, and `audio-to-ogg SOURCE OUTPUT_DIRECTORY` use explicit output directories, stable names, and no-overwrite behavior.

Flatpak permission exports are stored privately under `~/.host/backups/flatpak-permissions/` with mode `0700` for directories and `0600` for files. The export is completed before the reset confirmation is requested, so a declined reset never modifies permissions and an approved reset always has a private copy of the preceding state. Flatpak does not expose a single atomic command for the complete global reset; if Flatpak reports a failure after some grants were processed, those earlier grants can remain reset. The helper reports this partial-change state and retains the private export for recovery.

On Silverblue, the package choices selected for the Toolbox are saved to `data/toolbox/packages.txt` in the managed directory. Distrobox, direnv, and Starship remain intentionally rolling tools: they are installed outside Fedora's package manager, are not pinned in the extras manifest, and are updated independently through their own installers. Rolling-installer downloads disable user-supplied `curl` configuration before fetching the installer script.

## Automation, logging, and recovery

The main runtime controls are available as command-line options and environment equivalents:

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--state-file PATH` | `POSTINSTALL_STATE_FILE` | Select the typed TSV resume-state file. |
| `--cache-dir PATH` | `POSTINSTALL_CACHE_DIR` | Select the cache root for verified additional-tool artifacts and the default lock scope. |
| `--lock-file PATH` | `POSTINSTALL_LOCK_FILE` | Select the advisory lock file used by real installation runs. |
| `--resume` | `POSTINSTALL_RESUME` | Reuse compatible completed modules and restored shared context. |
| `--log-file PATH` | `POSTINSTALL_LOG_FILE` | Write runtime events to a log file. |
| `--log-format json` | `POSTINSTALL_LOG_FORMAT=json` | Write JSON Lines logs. |
| `--log-level LEVEL` | `POSTINSTALL_LOG_LEVEL` | Filter events by `debug`, `info`, `warn`, or `error`. |
| `--log-stdout` | `POSTINSTALL_LOG_STDOUT=1` | Also write logs to standard output; JSON logs are routed to standard error so JSON output remains clean. |

Other environment equivalents include `POSTINSTALL_FLAVOR`, `POSTINSTALL_ARCHITECTURE`, `POSTINSTALL_PROFILE`, `POSTINSTALL_PROFILE_FILE`, `POSTINSTALL_TOOLS`, `POSTINSTALL_CACHE_DIR`, `POSTINSTALL_LOCK_FILE`, and `POSTINSTALL_DRY_RUN`. Command-line options take precedence over environment values, including invalid environment defaults; repeated `--tool` and `--tools` options combine, while `--all-extras` replaces an environment tool selection. Without an explicit command-line profile option, `POSTINSTALL_PROFILE` and `POSTINSTALL_PROFILE_FILE` cannot both be set; `--profile` and `--profile-file` cannot be combined. `doctor` rejects runtime logging options instead of silently ignoring them.

The default state file is `${XDG_STATE_HOME:-${HOME}/.local/state}/fedora-postinstall/state.tsv`. The default cache directory is `${XDG_CACHE_HOME:-${HOME}/.cache}/fedora-postinstall`, and the default lock file is `postinstall.lock` inside the effective cache directory. Relative state, cache, and lock paths resolve from the directory where the installer is invoked. Plans report both effective paths without creating them. A real `install`, `extras`, or `snapshot` run creates the cache and lock securely, holds exclusive `flock` locks on both the lock file and its parent-directory scope through the operation and cleanup, and exits with status `75` when another run already holds that scope. Snapshot listing and comparison therefore share the same contention behavior as installation runs. A dedicated owner and an independent lock sentinel mutually monitor one another while retaining the exact locked descriptors, so unrelated installation descendants cannot extend either lock domain. Unexpected owner or sentinel/support loss aborts the installer with status `141` after acquisition; loss during acquisition is reported as an acquisition failure with status `73`. The parent-directory scope prevents replacing the public lock pathname from creating a second installer lock domain; lock files that share a parent directory therefore contend with one another.

State records include the flavor, architecture, profile digest, explicit extras selection, module checksum, and shared values such as `MACHINE_NAME`, `ROOT_DIRECTORY_STRUCTURE`, `COMMAND_NAME`, and `TOOLBOX_NAME`. The runtime stops at the first unhandled module failure, runs cleanup callbacks, and rejects malformed or unsafe state files. Snapshot creation and restoration use the saved `ROOT_DIRECTORY_STRUCTURE` value as the authoritative managed-root discovery input rather than trusting snapshot metadata.

Interactive runs print the effective flavor, architecture, profile, module count, and selected extra tools before prompting. Modules are reported as `Module N/TOTAL`, and the final result summarizes completed, skipped, and failed units together with the elapsed time. Profile exclusions, resumed modules, and mutating modules skipped by a dry run are counted as skipped rather than completed. An operation-level failure after all modules complete counts as one failed unit. A cleanup-only failure replaces a pending success summary, counts as one failed unit, and preserves the cleanup failure's exact status. An explicit exit inside an active module is a module failure: status `0` becomes `1`, while a nonzero status is preserved.

## What does this script do?

A lot of things, actually. The following table summarizes the tasks:

| Task name  | Description | For Workstation? | For Silverblue? |
|------------|-------------|------------------|-----------------|
| Flathub (config) | Configures Flathub, a centralized app store for Linux distributions that use the Flatpak packaging format. | Yes | Yes |
| Flatpaks (unpin) | Unpins all Flatpak runtimes to allow automatic updates. | No | Yes |
| Flatpaks (cleanup) | Removes several applications that come with Fedora, installed as Flatpaks (user selection). | No | Yes |
| Packages (cleanup) | Removes several packages that come with Fedora (user selection). | Yes | No |
| RPM Fusion (config) | Configures RPM Fusion, a project that provides a repository of additional software packages for Fedora. | Yes | No |
| `ffmpeg` (config) | Replaces Fedora's `ffmpeg` with the version available in the RPM Fusion repositories. | Yes | No |
| Terra (install) | Installs Terra, a rolling RPM repository for Fedora. | Yes | No |
| Flatpaks (install) | Installs several applications as Flatpaks (user selection). | Yes | Yes |
| GNOME (config) | Configures and tweaks GNOME (see the table below). | Yes | Yes |
| Hostname (config) | Configures the machine hostname. | Yes | Yes |
| Home directory (config) | Configures a predefined home directory structure for improved organization. | Yes | Yes |
| `starship` (install) | Installs Starship, a highly customizable shell prompt that aims to provide a modern, feature-rich, and efficient user experience for the command-line. | Yes | Yes |
| `carapace-bin` (install) | Installs `carapace-bin`, a command-line tool that generates shell completion scripts for various command-line tools and applications. | Yes | Yes |
| zoxide (install) | Installs Zoxide, a tool designed to enhance navigation in the terminal by allowing users to quickly jump to frequently accessed directories. | Yes | Yes |
| `uv` (install) | Installs `uv`, an extremely fast Python package and project manager, written in Rust. | Yes | Yes |
| SDKMAN (install) | Installs SDKMAN, a tool for managing multiple Software Development Kits (SDKs) on Unix-based systems. | Yes | Yes |
| Rust (install) | Installs Rust, a systems programming language that focuses on performance, safety, and concurrency. | Yes | Yes |
| Go (install) | Installs Go, a programming language developed by Google. | Yes | Yes |
| Node Version Manager (install) | Installs Node Version Manager, a tool that allows developers to easily install, manage, and switch between different versions of the Node.js runtime on their local machines. | Yes | Yes |
| `mise` (install) | Installs `mise`, a command-line tool designed for setting up and managing development environments. | Yes | Yes |
| vim (install) | Installs Vim, a highly configurable, open source text editor known for its powerful and efficient command-line interface. | Yes | No |
| neovim (install) | Installs Neovim, an open source, community-driven, and highly customizable fork of the Vim text editor. | Yes | Yes (inside a toolbox) |
| Taskwarrior (install) | Installs Taskwarrior, a flexible and powerful open source task management software. | Yes | No |
| `forgit` (install) | Installs `forgit`, a command-line tool that combines Git and `fzf`. | Yes | No |
| Ghostty (install) | Installs Ghostty, a terminal emulator that uses platform-native UI and GPU acceleration. | Yes | No |
| `yazi` (install) | Installs `yazi`, a blazing fast terminal file manager. | Yes | No |
| Terminal colors | Configures the colorized output of `ls`, `tree`, `fd`, `bfs`, `dust`, and many other tools. | Yes | Yes |
| Useful packages (install) | Installs a collection of useful packages that can provide additional functionality for your command-line workflow. | Yes | Yes (inside a toolbox) |
| Git (config) | Configures Git, adding the user name and email, as well as defining the editor and diff viewer. | Yes | Yes |
| VSCodium (install) | Installs VSCodium, a binary distribution of Microsoft's Visual Studio Code editor, without the telemetry and proprietary features. | Yes (RPM package) | Yes (Flatpak) |
| TeX Live (configuration) | Configures a script for TeX Live, a comprehensive distribution of the TeX typesetting system. | Yes | No |
| Nerd Fonts (install) | Installs fonts from Nerd Fonts, a project that provides patched versions of popular programming fonts. | Yes | Yes |
| Cascadia Code font (install) | Installs Cascadia Code, a monospaced font designed for programming. | Yes | Yes |
| `yt-dlp` (install) | Installs `yt-dlp`, a tool that allows users to download videos and audio from a wide range of online platforms. | Yes | Yes |
| Nix (install) | Installs Nix, a functional package manager and build system that provides a declarative and reproducible approach to software deployment and configuration management. | Yes (Linux planner) | Yes (OSTree planner) |
| Nix Toolbox (config) | Configures Nix Toolbox, a project that enhances the Fedora Toolbox container image by integrating the Nix package manager and optionally Home Manager. | Yes | Yes |
| Distrobox (install) | Installs Distrobox, a tool that enables users to run different Linux distributions as isolated containers within their host operating system. | Yes | Yes |
| Toolbox (config) | Configures Toolbox, a tool that provides a convenient way to create and manage isolated development environments within Fedora. | No | Yes |
| Homebrew (install) | Installs Homebrew, a package manager for macOS and Linux. | No | Yes (inside a toolbox) |
| `direnv` (install) | Installs `direnv`, an environment variable management tool that automatically loads and unloads environment variables based on the current directory. | Yes | Yes |
| Helix (install) | Installs Helix, an open source, modal code editor. | Yes | Yes |
| Zed Editor (install) | Installs Zed, a code editor for Rust. | Yes | Yes |
| `tmux` (install) | Installs `tmux`, a terminal multiplexer that allows you to create and manage multiple terminal sessions within a single window. | Yes | Yes |
| Miniconda (install) | Installs Miniconda, a lightweight distribution of the Anaconda Python and R data science platform. | Yes | Yes |
| Profile photo (config) | Configures a profile photo as a visual identifier that makes it easier to recognize the user at a glance. | Yes | Yes |
| Additional command-line tools (install) | Installs a collection of command-line tools, covering a wide range of functionalities (user selection, see the table below). | Yes | Yes |

GNOME configurations and tweaks:

| Component | Description | For Workstation? | For Silverblue? |
|-----------|-------------|------------------|-----------------|
| Autorun settings for removable media | Disables the autorun feature for removable media, preventing automatic execution of programs or scripts when a removable device is inserted. | Yes | Yes |
| Clock | Modifies the GNOME clock settings to display the weekday in addition to the time. | Yes | Yes |
| Font rendering | Applies font antialiasing and hinting settings to improve the rendering and appearance of fonts. | Yes | Yes |
| Display Manager | Removes the Fedora logo from the GNOME Display Manager (GDM). | Yes | Yes |
| Nautilus | Configures the GNOME Nautilus file manager to set the default folder viewer to icon view and disable the display of image thumbnails. | Yes | Yes |
| Night light | Enables the GNOME night light feature, which adjusts the screen's color temperature to reduce blue light exposure during the evening hours. | Yes | Yes |
| Notification banners | Adjusts the GNOME desktop settings by disabling the display of notification banners and the appearance of notifications on the lock screen. | Yes | Yes |
| Software | Configures the GNOME Software application to disable the automatic download and notification of software updates. | Yes | Yes |
| Technical reports | Disables the GNOME technical problem reporting feature, preventing the automatic submission of diagnostic information to the developers. | Yes | Yes |
| Touchpad configuration | Modifies the GNOME touchpad configuration to enable tap-to-click functionality and two-finger scrolling, providing a more intuitive and responsive touchpad experience. | Yes | Yes |
| Text Editor | Applies a set of tweaks to the GNOME text editor, including highlighting the current line, disabling session restoration, showing the grid, line numbers, and right margin, as well as disabling spellcheck. | Yes | No |

Additional command-line tools (deployed in `${HOME}/.local/bin`):

Downloads use the pinned URLs and SHA-256 checksums in `extras/tools-manifest.json`. Each selected tool is downloaded into the cache when no matching artifact exists, or reused from the cache after its pinned checksum is verified; verified interrupted downloads are recovered for retry without another transfer. The manifest records the authoritative upstream source, and runtime validation rejects a URL that does not belong to that source and pinned release. Download commands disable user-supplied `curl` configuration.

Runtime and maintainer refreshes share the same URL policy: GitHub release assets, raw GitHub commit assets, and the official ncdu download host are the only supported URL families. Source, version, host, and path components must match exactly; encoded separators, queries, fragments, user information, explicit ports, control characters, and unpinned paths are rejected. A 40-character hexadecimal release tag remains a release, while a raw commit asset still requires a full commit SHA. TAR extraction preflights the raw archive headers, bounds PAX and GNU extended metadata, rejects sparse members, and enforces member and expanded-size limits before Python's archive parser consumes the file. Only the exact verified artifact is unpacked in an isolated temporary workspace, and deployment replaces each executable atomically. Verified artifacts are retained under `${POSTINSTALL_CACHE_DIR}/extras/`. Temporary extraction and deployment files are removed when the script exits. The manifest provides native x86-64 and AArch64 releases where upstream publishes them (`jless` currently supports x86-64 only).

| Tool | Description |
|------|-------------|
| `atuin` | Search and sync shell history across machines. |
| `bandwhich` | Show network bandwidth usage by process. |
| `binsider` | Inspect binary files and extract their contents. |
| `bottom` | Monitor system resources and processes (deployed as btm). |
| `bun` | Run JavaScript applications and manage packages. |
| `caddy` | Serve HTTP and HTTPS applications. |
| `deno` | Run JavaScript and TypeScript applications. |
| `duckdb` | Query data with an embedded SQL database. |
| `duf` | Inspect disk usage across file systems. |
| `eza` | List files with colors and metadata. |
| `f2` | Rename files and directories in batches. |
| `fd` | Find files by name or pattern. |
| `freeze` | Capture terminal output as an image. |
| `fx` | Explore and transform JSON data. |
| `glow` | Render Markdown in the terminal. |
| `gping` | Show ping latency with a terminal interface. |
| `grex` | Generate regular expressions from sample text. |
| `gum` | Build interactive command-line interfaces. |
| `hexyl` | Inspect binary data in hexadecimal. |
| `ipinfo` | Show information about an IP address. |
| `jless` | Explore and filter JSON data. |
| `lapce` | Edit files from the terminal. |
| `lsd` | List files with icons and file-type indicators. |
| `ncdu` | Browse disk usage interactively. |
| `ouch` | Compress and decompress files and directories. |
| `picocrypt` | Encrypt and decrypt files. |
| `pingu` | Show colored ping results. |
| `procs` | Inspect running processes. |
| `ripgrep` | Search file contents with regular expressions (deployed as rg). |
| `shellcheck` | Find bugs and issues in shell scripts. |
| `surreal` | Query a SurrealDB database. |
| `tlrc` | Show concise command examples from tldr (deployed as tldr). |
| `tokei` | Count lines of code by language. |
| `trdsql` | Query CSV, JSON, and databases with SQL. |
| `trippy` | Diagnose network routes and latency (deployed as trip). |
| `trivy` | Scan images, filesystems, and repositories for vulnerabilities. |
| `ttyd` | Share a terminal session through a web browser. |
| `unimatrix` | Display animated Matrix-style characters. |
| `usage` | Define reusable command-line tools. |
| `vhs` | Record and replay terminal sessions. |
| `vimv` | Rename files from Vim. |
| `vivid` | Generate terminal color themes. |
| `yazi` | Browse files from the terminal (deployed as yazi and ya). |
| `yq` | Query and transform YAML files. |
| `zellij` | Manage terminal panes, tabs, and sessions. |

## Refreshing pinned extras (maintainers)

Maintainers can refresh release metadata in the reviewed manifest without creating a Git commit:

```bash
python3 tools/refresh-extras-manifest.py --tool fd --check
python3 tools/refresh-extras-manifest.py --tool fd --write
python3 tools/refresh-extras-manifest.py --all --check
```

The refresher reads the authoritative registry from `extras/tools-list.sh` and the schema-v2 release policy from `tools/extras-refresh-config.json`. That configuration is authoritative for each tool's release source, archive type, architecture asset pattern, and archive-to-command mapping. Archive mappings select a unique member by its basename; the refreshed manifest records the resolved archive-relative member path.

The refresher queries official release metadata, rejects drafts, prereleases, rolling or unstable tags, invalid publication timestamps, ambiguous architecture assets, malformed upstream digests, and version downgrades. It resolves exactly one distinct asset per supported architecture and binds every URL to the configured source and pinned release. Release API digests, candidate-specific sidecars, generic checksum manifests, and conventional direct sidecars are combined; each digest must be associated with the exact candidate filename. GNU `digest *filename` and BSD `SHA256 (filename) = digest` forms are supported. Conflicting authoritative digests are rejected, an unassociated bare digest is never attributed to an asset, and a checksum is calculated locally only when no exact upstream association exists.

Commit-based tools are accepted only when GitHub's comparison metadata proves that the candidate is identical to or descends from the current pin; behind, divergent, incomplete, or inconsistent comparisons are rejected before the asset is downloaded. The candidate manifest, bounded archive contents, extracted executable, and local mocked extras tests must all pass before a unified diff is shown. The checked mode is read-only. The write mode requires the explicit `--write` option and updates `extras/tools-manifest.json` only after validation by using Linux `renameat2(RENAME_EXCHANGE)` with source-identity checks. A concurrent change causes the update to be rejected without overwriting the concurrent content. Rollback verifies both the original manifest and the private recovery inode before every exchange; modified recovery bytes are never installed, and recovery data is retained when it cannot be restored safely.

Set `GITHUB_TOKEN` when refreshing all tools so GitHub API requests use an authenticated quota. The token is removed from child-process environments, the token-bearing Linux refresher is made non-dumpable before children start so its inherited environment cannot be recovered through `/proc`, and authenticated requests receive the token only through a mode-`0600` temporary `curl` configuration file. Authenticated API redirects are disabled so the authorization header cannot cross hosts. Distrobox, direnv, and Starship are explicitly excluded because their installers remain rolling and independent of the pinned extras manifest.

## What to do if something goes wrong?

Please inspect this script before running it. It should not be difficult to understand what it does on every line of code. There is always room for improvement, and make sure to have a fantastic Fedora experience! Have fun!

## License

This script is released under the MIT License.
