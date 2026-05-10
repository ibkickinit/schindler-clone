# Schindler 2.0 — 00 Index

**Status:** ACTIVE — early prototype phase, hardware ordered
**Type:** Personal venture
**Code location:** `_PROJECTS/Schindler-2.0/` (this folder, repo at root)
**GitHub:** `ibkickinit/schindler-clone` *(rename to `schindler-2` planned in Phase 3)*

## What this is

FPGA-based hardware project to drive 24fps content to legacy monitors. The "2.0" name reflects that this is a modern reimplementation/spiritual successor to a Schindler-branded device (whose original behavior is being replicated and improved with current FPGA tech).

The mission: keep heritage display gear functional and useful in modern production workflows, where 24fps cinema cadence needs to drive into displays designed for older signal standards.

## Hardware ordered

- FPGA development kit
- Oscilloscope (for signal analysis during bring-up)
- (more to be added as procurement progresses)

## Folder structure

- `00-index.md` — this file (vault MOC)
- `README.md` — repo README (canonical for clone-and-build context)
- `docs/` — development playbook, design notes
- `.git/` — git repo (synced via Dropbox; do not delete from cloud)

This project keeps the repo flat at the project root rather than under `code/`, since the project is small and the README + docs are the main content currently.

## Operating principle (code in vault)

`.git/` syncs to Dropbox cloud. NEVER delete `.git/` from cloud — propagates to local and destroys repo. See `_PROJECTS/NovaTool/00-index.md` for full rationale on code-in-vault.

## Active workstreams

- README and development playbook (initial commit complete)
- Hardware bring-up (pending FPGA dev kit + oscilloscope arrival)
- VHDL/Verilog architecture design (pending)
- Signal characterization vs original Schindler device (pending hardware)

## Migration status

- [x] Migrated from `~/schindler-clone/` to `_PROJECTS/Schindler-2.0/` (2026-05-06)
- [x] Remote URL cleaned (no embedded PAT)
- [x] Renamed locally during migration (`schindler-clone` → `Schindler-2.0`)
- [ ] Rename GitHub repo: `schindler-clone` → `schindler-2` (Phase 3, batch with other renames)
- [ ] Document FPGA-specific `.dropboxignore` patterns once active build artifacts appear

## Naming history

- Working title: `schindler-clone` (placeholder during initial setup)
- Final name: **Schindler 2.0** (chosen 2026-05-06 from candidate list; emphasizes spiritual successor framing rather than direct clone)
