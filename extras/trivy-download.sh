#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

extras_describe_tool "trivy" "Trivy" || return 1
download_extras_tool "trivy" || return 1
