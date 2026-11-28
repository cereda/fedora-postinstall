# SPDX-License-Identifier: MIT
SHELL := /bin/bash

DIFF_BASE ?= HEAD^

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
		'  diff-check    Check working tree and committed range for whitespace errors'

check: format-check syntax shellcheck python json license test diff-check

test:
	@$(BATS) --print-output-on-failure tests/unit

syntax:
	@git ls-files -z --cached --others --exclude-standard -- '*.sh' | \
		xargs -0 -r -n1 sh -c 'test ! -f "$$0" || bash -n "$$0"'

shellcheck:
	@git ls-files -z --cached --others --exclude-standard -- '*.sh' | \
		xargs -0 -r -n1 sh -c 'test ! -f "$$0" || $(SHELLCHECK) --severity=error "$$0"'

format-check:
	@git ls-files -z --cached --others --exclude-standard -- '*.sh' | \
		xargs -0 -r -n1 sh -c 'test ! -f "$$0" || $(SHFMT) -d $(SHFMT_FLAGS) "$$0"'

format:
	@git ls-files -z --cached --others --exclude-standard -- '*.sh' | \
		xargs -0 -r -n1 sh -c 'test ! -f "$$0" || $(SHFMT) -w $(SHFMT_FLAGS) "$$0"'

python:
	@files="$$(git ls-files --cached --others --exclude-standard -- '*.py')"; \
	if [ -n "$$files" ]; then \
		cache="$$(mktemp -d)"; \
		trap 'rm -rf "$$cache"' EXIT; \
		PYTHONPYCACHEPREFIX="$$cache" $(PYTHON) -m py_compile $$files; \
	fi

json:
	@files="$$(git ls-files --cached --others --exclude-standard -- '*.json')"; \
	if [ -n "$$files" ]; then \
		while IFS= read -r file; do $(JQ) empty "$$file"; done <<< "$$files"; \
	fi

license:
	@$(PYTHON) tools/check-spdx.py

diff-check:
	@git diff --check
	@git diff --cached --check
	@base="$(DIFF_BASE)"; \
	if [ -z "$$base" ] || [[ "$$base" =~ ^0+$$ ]]; then \
		base="HEAD^"; \
	fi; \
	if ! git rev-parse --verify --quiet "$$base^{commit}" >/dev/null; then \
		printf '%s\n' "Skipping committed-range whitespace check: base '$$base' is unavailable"; \
	else \
		git diff --check "$$base...HEAD"; \
	fi
