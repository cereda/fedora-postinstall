# Fedora post installation guide

Welcome to my personal Fedora post installation guide. This repository describes most of the tasks I perform after a clean install of this awesome Linux distribution. Ideas and suggestions were collected from various sources, as well as from personal experience and preference. Use this guide at your own risk, and have fun with Fedora!

## Requirements

The project targets Fedora Workstation and Fedora Silverblue. It requires `rpm` and the following commands: `bash`, `coreutils` (including `install`, `mktemp`, and `sha256sum`), `curl`, `findutils`, `git`, `jq`, `python3`, `realpath`, `tar`, `unzip`, and `wget`. On Fedora, install the missing tools with:

```bash
sudo dnf install coreutils curl findutils git jq python3 realpath tar unzip wget
```

An interactive installation also requires a terminal and a working `sudo` session. The `detect`, `plan`, and `--dry-run` commands do not prompt, download files, or change the system.

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
| `help` | Show command and option help. |

A plain `bash fedora-postinstall.sh` retains the legacy interactive flavor chooser. `POSTINSTALL_FLAVOR` does not bypass that chooser for an implicit invocation, although it is honored by an explicit `install` command. The explicit `install` command can use automatic flavor detection, while `--flavor workstation` or `--flavor silverblue` always selects the flavor explicitly. Detection never falls back between native architectures: x86-64 and AArch64 use their own manifest assets, with universal assets selected only through an explicit `assets.any` entry.

Useful non-mutating examples are:

```bash
bash fedora-postinstall.sh detect
bash fedora-postinstall.sh detect --json
bash fedora-postinstall.sh plan
bash fedora-postinstall.sh plan --json --profile developer
bash fedora-postinstall.sh install --dry-run --json
```

`--dry-run` is non-interactive and routes through the same plan engine used by `plan`; it does not bootstrap Gum, download release assets, or execute installation modules.

## Additional command-line tools

Select tools explicitly, or select every tool available for the target architecture:

```bash
bash fedora-postinstall.sh extras --tool fd --tool ripgrep
bash fedora-postinstall.sh extras --tools fd,ripgrep,yq
bash fedora-postinstall.sh extras --all-extras
bash fedora-postinstall.sh extras --dry-run --all-extras
```

The legacy `CLI_TOOLS_ONLY` environment variable remains supported and is presence-based. Setting it to any value, including `0`, selects the extras-only flow:

```bash
CLI_TOOLS_ONLY=1 bash fedora-postinstall.sh
```

The authoritative tool registry is `extras/tools-list.sh`. URLs, versions, checksums, archive types, file mappings, and architecture assets are defined in `extras/tools-manifest.json`; profiles and command-line options can select registered tool identifiers but cannot replace those manifest values.

## Profiles

Profiles are selection-only JSON documents. They can select canonical module names or patterns and registered extra-tool identifiers; they cannot define commands, URLs, checksums, scripts, or arbitrary paths. Bundled profiles are available as `default`, `minimal`, and `developer`:

```bash
bash fedora-postinstall.sh plan --profile minimal
bash fedora-postinstall.sh install --profile developer
bash fedora-postinstall.sh install --profile-file /path/to/profile.json
```

A user profile under `${XDG_CONFIG_HOME:-$HOME/.config}/fedora-postinstall/profiles/` takes precedence over the bundled profile with the same name. Explicit profile paths and user profiles are resolved before bundled profiles. Module order in a profile is ignored; modules always run in the canonical flavor inventory order. Required providers are included automatically, and excluding one is an error.

See [`docs/profiles.md`](docs/profiles.md) for the profile format and [`docs/profile.schema.json`](docs/profile.schema.json) for the JSON Schema.

## Automation, logging, and recovery

The main runtime controls are available as command-line options and environment equivalents:

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--state-file PATH` | `POSTINSTALL_STATE_FILE` | Select the typed TSV resume-state file. |
| `--resume` | `POSTINSTALL_RESUME` | Reuse compatible completed modules and restored shared context. |
| `--log-file PATH` | `POSTINSTALL_LOG_FILE` | Write runtime events to a log file. |
| `--log-format json` | `POSTINSTALL_LOG_FORMAT=json` | Write JSON Lines logs. |
| `--log-level LEVEL` | `POSTINSTALL_LOG_LEVEL` | Filter events by `debug`, `info`, `warn`, or `error`. |
| `--log-stdout` | `POSTINSTALL_LOG_STDOUT=1` | Also write logs to standard output; JSON logs are routed to standard error so JSON output remains clean. |

Other environment equivalents include `POSTINSTALL_FLAVOR`, `POSTINSTALL_ARCHITECTURE`, `POSTINSTALL_PROFILE`, `POSTINSTALL_PROFILE_FILE`, `POSTINSTALL_TOOLS`, and `POSTINSTALL_DRY_RUN`. Command-line options take precedence over environment values. Without an explicit command-line profile option, `POSTINSTALL_PROFILE` and `POSTINSTALL_PROFILE_FILE` cannot both be set; `--profile` and `--profile-file` cannot be combined.

The default state file is `${XDG_STATE_HOME:-${HOME}/.local/state}/fedora-postinstall/state.tsv`. State records include the flavor, architecture, profile digest, explicit extras selection, module checksum, and shared values such as `MACHINE_NAME`, `ROOT_DIRECTORY_STRUCTURE`, `COMMAND_NAME`, and `TOOLBOX_NAME`. The runtime stops at the first unhandled module failure, runs cleanup callbacks, and rejects malformed or unsafe state files.

## What does this script do?

A lot of things, actually. The following table summarizes the tasks:

| Task name  | Description | For Workstation? | For Silverblue? |
|------------|-------------|------------------|-----------------|
| Flathub (config) | Configures Flathub, a centralized app store for Linux distributions that use the Flatpak packaging format. | Yes | Yes |
| Flatpaks (unpin) | Unpins all Flatpak runtimes to allow automatic updates. | No | Yes |
| Flatpaks (cleanup) | Removes several applications that come with Fedora, installed as Flatpaks (user selection). | No | Yes |
| Packages (cleanup) | Removes several packages that come with Fedora (user selection). | Yes | No |
| RPMFusion (config) | Configures RPMFusion, a project that provides a repository of additional software packages for Fedora. | Yes | No |
| `ffmpeg` (config) | Replaces Fedora's `ffmpeg` with the version available in the RPMFusion repositories. | Yes | No |
| Terra (install) | Installs Terra, a rolling RPM repository for Fedora. | Yes | No |
| Flatpaks (install) | Installs several applications as Flatpaks (user selection). | Yes | Yes |
| GNOME (config) | Configures and tweaks GNOME (see the table below). | Yes | Yes |
| Hostname (config) | Configures the machine hostname. | Yes | Yes |
| Home directory (config) | Configures a predefined home directory structure for improved organization. | Yes | Yes |
| `starship` (install) | Installs `starship`, a highly customizable shell prompt that aims to provide a modern, feature-rich, and efficient user experience for the command line. | Yes | Yes |
| `carapace-bin` (install) | Installs `carapace-bin`, a command line tool that generates shell completion scripts for various command line tools and applications. | Yes | Yes |
| zoxide (install) | Installs zoxide, a tool designed to enhance navigation in the terminal by allowing users to quickly jump to frequently accessed directories. | Yes | Yes |
| `uv` (install) | Installs `uv`, an extremely fast Python package and project manager, written in Rust. | Yes | Yes |
| SDKman (install) | Installs SDKman, a tool for managing multiple Software Development Kits (SDKs) on Unix-based systems. | Yes | Yes |
| Rust (install) | Installs Rust, a systems programming language that focuses on performance, safety, and concurrency. | Yes | Yes |
| Go (install) | Installs Go, a programming language developed by Google. | Yes | Yes |
| Node Version Manager (install) | Installs Node Version Manager, a tool that allows developers to easily install, manage, and switch between different versions of the Node.js runtime on their local machines. | Yes | Yes |
| `mise` (install) | Installs `mise`, a command line tool designed for setting up and managing development environments. | Yes | Yes |
| vim (install) | Installs vim, a highly configurable, open source text editor known for its powerful and efficient command-line interface. | Yes | No |
| neovim (install) | Installs neovim, an open source, community-driven, and highly customizable fork of the vim text editor. | Yes | Yes (inside a toolbox) |
| Taskwarrior (install) | Installs Taskwarrior, a flexible and powerful open source task management software. | Yes | No |
| `forgit` (install) | Installs `forgit`, a command line tool that combines Git and `fzf`. | Yes | No |
| Ghostty (install) | Installs Ghostty, a terminal emulator that uses platform-native UI and GPU acceleration. | Yes | No |
| `yazi` (install) | Installs `yazi`, a blazing fast terminal file manager. | Yes | No |
| Terminal colors | Configures the colorized output of `ls`, `tree`, `fd`, `bfs`, `dust`, and many other tools. | Yes | Yes |
| Useful packages (install) | Installs a collection of useful packages that can provide additional functionality for your command line workflow. | Yes | Yes (inside a toolbox) |
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
| Additional command line tools (install) | Installs a collection of command line tools, covering a wide range of functionalities (user selection, see the table below). | Yes | Yes |

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

Additional command line tools (deployed in `${HOME}/.local/bin`):

Downloads use the pinned URLs and SHA-256 checksums in `extras/tools-manifest.json`. Each selected tool is downloaded and verified in an isolated temporary workspace; only the exact tracked artifact is unpacked, and deployment replaces each executable atomically. Temporary files are removed when the script exits. The manifest provides native x86-64 and AArch64 releases where upstream publishes them (`jless` currently supports x86-64 only).

| Tool | Description |
|------|-------------|
| `binsider` | Analyzes the contents of binary files. |
| `bottom` | System monitoring tool, deployed as `btm`. |
| `bun` | A fast JavaScript runtime that provides a command line interface for building, testing, and running web applications. |
| `caddy` | A powerful tool that simplifies the process of setting up and managing web servers. |
| `deno` | A modern, secure, and fast runtime for executing JavaScript and TypeScript. |
| `duckdb` | A lightweight, embedded SQL database engine. |
| `duf` | Provides a detailed and user-friendly overview of disk usage across file systems. |
| `f2` | Quick and safe batch renaming of files and directories. |
| `fd` | An alternative to the standard `find` command. |
| `freeze` | Captures images of code snippets and terminal output. |
| `fx` | Interactive exploration and manipulation of JSON data. |
| `glow` | Renders Markdown documents with syntax highlighting and other formatting enhancements. |
| `gping` | Monitors network connectivity and latency. |
| `grex` | Generates and tests complex regex patterns to match text and data. |
| `gum` | A set of interactive prompts and widgets for building terminal user interfaces. |
| `hexyl` | A user-friendly hexadecimal viewer. |
| `ipinfo` | Provides detailed information about IP addresses, including geolocation data, network details, and other relevant metadata. |
| `jless` | Views and explores JSON data. |
| `lapce` | A feature-rich, terminal-based code editor. |
| `lsd` | A directory listing tool with support for icons, file type indicators, and color coding. |
| `ouch` | A utility for compressing and decompressing files and directories. |
| `picocrypt` | A simple and secure way to encrypt and decrypt files. |
| `pingu` | A modern implementation of the classic `ping` utility. |
| `procs` | Monitors running processes and their resource usage. |
| `ripgrep` | Searches text across files and directories, deployed as `rg`. |
| `surreal` | An interface for working with the SurrealDB database. |
| `tlrc` | The official tldr client, deployed as `tldr`. |
| `trdsql` | Executes SQL queries against various data sources. |
| `trippy` | A network diagnostic tool, deployed as `trip`. |
| `trivy` | Scans container images, file systems, and Git repositories for known vulnerabilities. |
| `ttyd` | Shares terminal sessions over the web. |
| `unimatrix` | Python script to simulate the display from "The Matrix" in terminal. |
| `usage` | A spec and CLI for defining CLI tools. |
| `vhs` | Records and plays back terminal sessions. |
| `vimv` | Renames files and directories. |
| `vivid` | Generates color themes for the terminal. |
| `yazi` | A blazing fast terminal file manager, deployed as `yazi` and `ya`. |
| `yq` | Manipulates YAML files. |
| `zellij` | A modern, feature-rich terminal multiplexer. |

## What to do if something goes wrong?

Please inspect this script before running it. It should not be difficult to understand what it does on every line of code. There is always room for improvement, and make sure to have a fantastic Fedora experience! Have fun!

## License

This script is released under the MIT License.
