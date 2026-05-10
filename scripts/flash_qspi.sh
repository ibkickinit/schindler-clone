#!/usr/bin/env bash
# flash_qspi.sh — Write BOOT.bin to the Zybo Z7-20's QSPI flash via JTAG.
#
# Prereqs:
#   source /tools/Xilinx/2025.2/Vitis/settings64.sh   (provides program_flash)
#   scripts/make_boot.sh must have produced BOOT.bin first.
#   Board: JP5 in the JTAG position (programs the flash via JTAG).
#   Once flashed, move JP5 to QSPI for the new image to boot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_DIR="${REPO_ROOT}/build/boot"
BOOT_BIN="${BOOT_DIR}/BOOT.bin"
FSBL_ELF="${BOOT_DIR}/fsbl.elf"

[[ -f "${BOOT_BIN}" ]] || { echo "ERROR: ${BOOT_BIN} not found — run scripts/make_boot.sh first"; exit 1; }
[[ -f "${FSBL_ELF}" ]] || { echo "ERROR: ${FSBL_ELF} not found — run scripts/make_boot.sh first"; exit 1; }
command -v program_flash >/dev/null || { echo "ERROR: program_flash not in PATH — source Vitis settings64.sh"; exit 1; }

echo "==> Flashing ${BOOT_BIN} to QSPI on Zybo Z7-20"
echo "    (JP5 must currently be in JTAG position; move to QSPI after this completes)"

# Zybo Z7-20 QSPI: Spansion S25FL128S, 128 Mb (16 MB), x4 single-device.
program_flash \
    -f "${BOOT_BIN}" \
    -offset 0 \
    -flash_type qspi-x4-single \
    -fsbl "${FSBL_ELF}" \
    -url tcp:localhost:3121 \
    -verify

echo "STAGE_OK: QSPI flash programmed"
echo "Next: power off, move JP5 to QSPI position, power on. Board should auto-boot."
