#!/usr/bin/env bash
# make_boot.sh — Generate FSBL + assemble BOOT.bin (FSBL + top.bit) for QSPI.
#
# Reads:  build/schindler-2.0.xsa, build/schindler-2.0/.../top.bit
# Writes: build/boot/fsbl.elf, build/boot/BOOT.bin
#
# Prereqs:
#   source /tools/Xilinx/2025.2/Vitis/settings64.sh   (provides xsct, bootgen, ARM gcc)
#   tcl/build.tcl must have run successfully first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
XSA="${BUILD_DIR}/schindler-2.0.xsa"
BIT="${BUILD_DIR}/schindler-2.0/schindler-2.0.runs/impl_1/top.bit"
BOOT_DIR="${BUILD_DIR}/boot"
FSBL_APP_DIR="${BOOT_DIR}/fsbl_app"
FSBL_ELF="${BOOT_DIR}/fsbl.elf"
BIF="${BOOT_DIR}/boot.bif"
BOOT_BIN="${BOOT_DIR}/BOOT.bin"

[[ -f "${XSA}" ]] || { echo "ERROR: ${XSA} not found — run tcl/build.tcl first"; exit 1; }
[[ -f "${BIT}" ]] || { echo "ERROR: ${BIT} not found — run tcl/build.tcl first"; exit 1; }
command -v xsct >/dev/null   || { echo "ERROR: xsct not in PATH — source Vitis settings64.sh"; exit 1; }
command -v bootgen >/dev/null || { echo "ERROR: bootgen not in PATH — source Vitis settings64.sh"; exit 1; }

mkdir -p "${BOOT_DIR}"
rm -rf "${FSBL_APP_DIR}"

# --- 1. Generate + compile FSBL via xsct ---
echo "==> Generating FSBL from ${XSA}"
cat > "${BOOT_DIR}/gen_fsbl.tcl" <<EOF
hsi open_hw_design ${XSA}
hsi generate_app -hw [hsi current_hw_design] -os standalone -proc ps7_cortexa9_0 -app zynq_fsbl -compile -sw fsbl -dir ${FSBL_APP_DIR}
hsi close_hw_design [hsi current_hw_design]
EOF
xsct "${BOOT_DIR}/gen_fsbl.tcl"

# Locate the compiled FSBL .elf — xsct names it executable.elf
FSBL_BUILT=$(find "${FSBL_APP_DIR}" -name "*.elf" -type f | head -n 1)
[[ -n "${FSBL_BUILT}" ]] || { echo "ERROR: FSBL .elf not produced"; exit 1; }
cp "${FSBL_BUILT}" "${FSBL_ELF}"
echo "==> FSBL: ${FSBL_ELF}  ($(stat -c%s "${FSBL_ELF}") bytes)"

# --- 2. bootgen assembles BOOT.bin ---
echo "==> Building BOOT.bin via bootgen"
cat > "${BIF}" <<EOF
the_ROM_image:
{
    [bootloader]${FSBL_ELF}
    ${BIT}
}
EOF

rm -f "${BOOT_BIN}"
bootgen -arch zynq -image "${BIF}" -o "${BOOT_BIN}" -w on

[[ -f "${BOOT_BIN}" ]] || { echo "ERROR: BOOT.bin not produced"; exit 1; }
echo "==> BOOT.bin: ${BOOT_BIN}  ($(stat -c%s "${BOOT_BIN}") bytes)"
echo "STAGE_OK: boot image assembled"
