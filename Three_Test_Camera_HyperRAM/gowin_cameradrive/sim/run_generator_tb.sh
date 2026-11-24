#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${SCRIPT_DIR}/.ghdl_work"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

ghdl -a --std=08 "${PROJECT_DIR}/src/storage_test_pattern_generator.vhd"
ghdl -a --std=08 "${SCRIPT_DIR}/tb_storage_test_pattern_generator.vhd"
ghdl -e --std=08 tb_storage_test_pattern_generator
ghdl -r --std=08 tb_storage_test_pattern_generator --assert-level=error
