<!-- SPDX-License-Identifier: MIT -->

# Profiles

Profiles provide a repeatable **selection** of post-installation modules and additional command-line tools. They are intentionally not configuration files: a profile cannot run commands, override download URLs or checksums, change archive types, select deployment targets, or provide arbitrary script paths.

The JSON Schema is [`profile.schema.json`](profile.schema.json), and the same strict rules are enforced by the runtime parser.

## Format

```json
{
  "schema_version": 1,
  "name": "developer",
  "description": "Install common development tools and skip optional desktop setup.",
  "flavors": [
    "workstation",
    "silverblue"
  ],
  "modules": {
    "include": [
      "common/*-installation.sh"
    ],
    "exclude": [
      "common/flatpaks-installation.sh"
    ]
  },
  "extras": {
    "tools": [
      "fd",
      "ripgrep",
      "yq"
    ]
  }
}
```

### Fields

| Field | Required | Meaning |
|-------|----------|---------|
| `schema_version` | Yes | Must currently be `1`. |
| `name` | Yes | A profile identifier containing letters, digits, `.`, `_`, or `-`. |
| `description` | Yes | Human-readable description. |
| `flavors` | No | Supported flavors: `workstation` and/or `silverblue`. If omitted, the profile supports both. |
| `modules.include` | No | Module names or glob patterns to select. If omitted or empty, all flavor modules are eligible. |
| `modules.exclude` | No | Module names or glob patterns to remove. |
| `extras.tools` | No | Registered extra-tool identifiers to select. |

Unknown fields, duplicate JSON keys, duplicate array entries, invalid patterns, unknown modules, and unknown tools are rejected before installation begins.

## Selecting a profile

Use a bundled or user profile name:

```bash
bash fedora-postinstall.sh plan --profile developer
bash fedora-postinstall.sh install --profile minimal
```

Use an explicit JSON file:

```bash
bash fedora-postinstall.sh plan --profile-file ./my-profile.json
bash fedora-postinstall.sh install --profile-file ./my-profile.json
```

`--profile` and `--profile-file` are mutually exclusive. The corresponding environment variables, `POSTINSTALL_PROFILE` and `POSTINSTALL_PROFILE_FILE`, are also mutually exclusive when no command-line profile option is supplied. An explicit command-line profile selection overrides both environment profile settings.

Profile names are resolved in this order:

1. An explicit `--profile-file` path.
2. A path supplied directly to `--profile`.
3. `${XDG_CONFIG_HOME:-$HOME/.config}/fedora-postinstall/profiles/NAME.json`.
4. The bundled `profiles/NAME.json`.

Symbolic-link profile files are rejected.

## Module selection

Module patterns are matched against the canonical inventory for the selected Fedora flavor. The two inventories are:

- `common/workstation-modules.psv`
- `common/silverblue-modules.psv`

The order of `modules.include` and `modules.exclude` has no effect. The effective execution order always follows the canonical inventory.

When `modules.include` is empty, every flavor module is eligible. `modules.exclude` is applied after inclusion. The extras module is represented by `extras/additional-tools.sh` and may be selected with that exact name or a pattern such as `extras/*`.

### Dependency closure

Some modules consume shared values produced by earlier modules. For example, a module that uses `MACHINE_NAME` requires the hostname provider, and a module that uses `ROOT_DIRECTORY_STRUCTURE` requires the flavor-specific home-configuration provider.

Required providers are included automatically even when they are not listed in `modules.include`. If a required provider is excluded, the profile is rejected with an error. This prevents a profile from producing an incomplete installation.

## Extras selection

`extras.tools` accepts only identifiers from the authoritative registry in `extras/tools-list.sh`. Each selected identifier must also exist in `extras/tools-manifest.json` and have an asset for the selected architecture, either `x86_64`, `aarch64`, or the explicit universal key `assets.any`.

An empty `extras.tools` array selects no extra tools. If the profile also excludes `extras/additional-tools.sh`, the extras module is omitted entirely.

Command-line tool selection has higher precedence than a profile's extras selection:

```bash
bash fedora-postinstall.sh install --profile developer --tool bottom
```

## Bundled profiles

| Profile | Purpose |
|---------|---------|
| `default` | Run every module in the selected flavor and use the interactive extras chooser. |
| `minimal` | Keep core configuration while skipping optional applications, package cleanup, and extra tools. |
| `developer` | Keep common development tooling while skipping heavyweight and optional desktop setup. |

Inspect a profile before using it:

```bash
bash fedora-postinstall.sh plan --profile developer
bash fedora-postinstall.sh plan --profile developer --json
```

The plan is always non-mutating. Use `install --dry-run --json` to validate the same effective selection before a real installation.
