# SPDX-License-Identifier: MIT
SHELL := /bin/bash

BATS ?= bats
JQ ?= jq
PYTHON ?= python3
SHELLCHECK ?= shellcheck
SHFMT ?= shfmt
SHFMT_FLAGS ?= -i 4

.PHONY: help check test syntax shellcheck format format-check python json license diff-check

help:
	@printf '%s\n' \
		'Available targets:' \
		'  check         Run every quality gate' \
		'  test          Run the mocked Bats test suite' \
		'  syntax        Check Bash syntax' \
		'  shellcheck    Run ShellCheck at error severity' \
		'  format-check  Check Shell formatting' \
		'  format        Format tracked Shell scripts' \
		'  python        Compile the Python helpers' \
		'  json          Validate tracked JSON files' \
		'  license       Validate SPDX license headers' \
		'  diff-check    Check the working tree for whitespace errors'

check: format-check syntax shellcheck python json license test diff-check

test:
	@$(BATS) --print-output-on-failure tests/unit

syntax:
	@git ls-files -z '*.sh' | xargs -0 -n1 bash -n

shellcheck:
	@git ls-files -z '*.sh' | xargs -0 $(SHELLCHECK) --severity=error

format-check:
	@git ls-files -z '*.sh' | xargs -0 -r $(SHFMT) -d $(SHFMT_FLAGS)

format:
	@git ls-files -z '*.sh' | xargs -0 -r $(SHFMT) -w $(SHFMT_FLAGS)

python:
	@files="$$(git ls-files '*.py')"; \
	if [ -n "$$files" ]; then \
		cache="$$(mktemp -d)"; \
		trap 'rm -rf "$$cache"' EXIT; \
		PYTHONPYCACHEPREFIX="$$cache" $(PYTHON) -m py_compile $$files; \
	fi

json:
	@files="$$(git ls-files '*.json')"; \
	if [ -n "$$files" ]; then \
		while IFS= read -r file; do $(JQ) empty "$$file"; done <<< "$$files"; \
	fi

license:
	@$(PYTHON) tools/check-spdx.py

diff-check:
	@git diff --check
	@git diff --cached --check
