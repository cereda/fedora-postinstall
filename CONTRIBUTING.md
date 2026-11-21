<!-- SPDX-License-Identifier: MIT -->

# Contributing

## Safety

The installer is interactive and can modify the host system. Never run
`bash fedora-postinstall.sh` as a smoke test. Tests must use mocked commands,
temporary directories, and temporary home/state/log/cache/lock paths.

## Quality gates

Install the required tools and run the complete gate suite:

```bash
sudo dnf install bats jq shellcheck util-linux
make check
```

Individual targets are also available:

```bash
make test
make syntax
make shellcheck
make format-check
make python
make json
make license
```

`make format-check` requires the official `shfmt` 3.14.1 release. Run
`make format` to apply the repository's four-space shell formatting before
committing.

Tests must not contact the network or use the real host home directory. A test
that exercises a download must mock `curl` and verify the pinned checksum from
an injected manifest fixture.
