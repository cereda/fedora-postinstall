#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

tool-section "Trivy"

description "Trivy scans container images, file systems, and Git repositories \
for known vulnerabilities. It provides a comprehensive security analysis, \
identifying potential security risks and vulnerabilities within the scanned \
targets."

echo

download_extras_tool "trivy"
