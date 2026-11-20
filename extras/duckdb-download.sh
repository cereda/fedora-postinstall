#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

tool-section "duckdb"

description "duckdb provides a lightweight, embedded SQL database engine, \
allowing users to quickly query and analyze data directly from the terminal \
without the need for a separate database server."

echo

download_extras_tool "duckdb"
