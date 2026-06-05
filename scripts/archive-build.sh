#!/usr/bin/env bash
# archive-build.sh — snapshot the current build's re-programmable artifacts so ANY
# build can be re-flashed instantly (no ~30 min rebuild). Run right after a build.
#
#   scripts/archive-build.sh <tag>     e.g.  scripts/archive-build.sh 34-720p60
#
# Artifacts land in artifacts/<tag>/ (gitignored — ~4 MB each, Dropbox-backed).
# The build-manifest.md still records commit+OUTPUT_MODE for full recreatability;
# this just avoids the rebuild when you only need to put a known build back on the board.
set -euo pipefail
ROOT="/home/justin/Dropbox/_PROJECTS/Schindler-2.0"
TAG="${1:?usage: archive-build.sh <tag>  (e.g. 34-720p60)}"
BIT="$ROOT/build/vitis-phase-b/phase_b_pf/hw/phase_b.bit"
ELF="$ROOT/build/vitis-phase-b/vdma_init/Debug/vdma_init.elf"
DST="$ROOT/artifacts/$TAG"
[ -f "$BIT" ] || { echo "no .bit at $BIT — build first"; exit 1; }
[ -f "$ELF" ] || { echo "no .elf at $ELF — build first"; exit 1; }
mkdir -p "$DST"
cp -f "$BIT" "$DST/phase_b.bit"
cp -f "$ELF" "$DST/vdma_init.elf"
{
  echo "tag:    $TAG"
  echo "commit: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "bit:    $(stat -c '%y %s' "$BIT")"
  echo "elf:    $(stat -c '%y %s' "$ELF")"
} > "$DST/INFO.txt"
echo "archived → artifacts/$TAG/  (re-flash with: scripts/program-archived.sh $TAG)"
