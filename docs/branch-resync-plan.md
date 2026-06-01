# Branch resync plan — iter5-1080p-clean → mackin-impl-wip + phase-e1-pll-spike

**Tracks task #65.** Written 2026-05-31 after the cherry-pick session that landed iter13c on both sibling branches but had to abort iter14.

## STATUS (2026-06-01)
- **Phase 1 (KERNEL_GPIO_INDEX parameterization on iter5):** ✅ shipped.
- **Phase 2 (merge iter5 → mackin-impl-wip):** ✅ merged + build-verified (WNS +0.149 ns, DRC 0 err) + programmed. Firmware fully verified: J-smoke PASS; iter14 kernel toggle live at `axi_gpio_9`; Mackin alpha live at `axi_gpio_7` (no slot collision); no error bits. mackin builds with `KERNEL_GPIO_INDEX=9 KERNEL_M_SLOT=13`. ✅ **Bench picture: 3-cold-reload CLEAN (no-coin-flip rule satisfied 2026-06-01)** — reloads 1/2/3 all came up identically clean on the monitor. Phase 2 formally PASSES. mackin-impl-wip is now a verified merge of iter5 trunk.
  - **Known benign:** web-UI slider shows occasional `control.set` timeouts under fast drag — UART contention between the firmware's autonomous DIAG telemetry spew and on-demand J request/response. Pre-existing (same on iter5), not a merge regression; values still land via the coalescer. Real fix is firmware-side (quiet telemetry during pending J / drop the debug DDR-dump bursts), lands on iter5 first. Tracked as a follow-up, non-blocking.
- **Phase 3 (merge iter5 → phase-e1-pll-spike):** not started. Bigger lift — phase-e1 also lacks iter4e. ~4–5 h + 1 h bench.

## Problem

Three live branches carry HDL work that hasn't merged back into the production substrate:
- **`iter5-1080p-clean`** — effective trunk; has iter4e (runtime IN_W/H from VTC detector), iter13c (lbuf_fresh emit suppression + XDC false-paths), iter14 (runtime kernel-mode toggle), V0a control plane (catalog + firmware J + daemon + UI), and the 2026-05-31 audit follow-ups.
- **`mackin-impl-wip`** — has iter4e, the Mackin blender HDL + sim suite, axi_gpio_7 used for `mackin_alpha`. As of `73e8d04` carries iter13c too.
- **`phase-e1-pll-spike`** — MMCM `psincdec` tracking work, doesn't have iter4e (no `in_w_async`/`in_h_async` on `scaler_top`). As of `d7d2acf` carries iter13c too.

Today's cherry-pick attempts ran into two structural conflicts that prevent the obvious approach (`git cherry-pick abb83e8` on each branch) from working:

1. **axi_gpio_7 slot collision (mackin)**: iter14 puts `axi_gpio_7` at `axi_ic_lite/M10_AXI` driving `scaler_0/kernel_mode_async`. mackin already owns that exact slot for `mackin_alpha`. A textual cherry-pick produces two cells named the same with the same M-port.
2. **Missing iter4e substrate (phase-e1)**: iter14 layers a 4-bit `kernel_mode_async` input onto the iter4e `in_w_async`/`in_h_async` ports on `scaler_top`. phase-e1's `scaler_top` is still pre-iter4e — it takes neither set of ports. A cherry-pick would replace the whole module, dragging in iter4e as an undocumented side-effect.

Plus, V0a control plane is iter5-only. Bringing the daemon to the sibling branches is a separate, mostly-textual track but worth bundling.

## Proposal: KERNEL_GPIO_INDEX build-time symbol

HDL audit (2026-05-31) suggested making the AXI GPIO slot for `kernel_mode_async` configurable at build time instead of hard-coded. The idea:

```tcl
# tcl/build_phase_b.tcl — top of file
if {[info exists ::env(KERNEL_GPIO_INDEX)]} {
    set KERNEL_GPIO_INDEX $::env(KERNEL_GPIO_INDEX)
} else {
    set KERNEL_GPIO_INDEX 7   ;# iter5 default
}
puts "iter14 kernel_mode GPIO slot: axi_gpio_${KERNEL_GPIO_INDEX}"
```

Every reference in the BD generator that today reads `axi_gpio_7` for the kernel_mode wire becomes `axi_gpio_${KERNEL_GPIO_INDEX}`. The corresponding `M${KERNEL_MI_SLOT}_AXI` interconnect port becomes a derived value too.

Firmware reads the resulting `XPAR_AXI_GPIO_${KERNEL_GPIO_INDEX}_BASEADDR` symbol — already vendor-defined by the BSP at build time per Vitis convention.

Benefits:
- iter5 builds unchanged when env-var unset (defaults to 7).
- mackin builds with `KERNEL_GPIO_INDEX=8` keep `mackin_alpha` at 7 + add kernel_mode at a new slot.
- phase-e1 builds the same way once iter4e is in place.
- One source of truth for the slot number; no branch-specific patches.

Cost: ~30 min refactor on iter5 (find all hard-coded `axi_gpio_7`/`M10_AXI` for kernel_mode and templatize them), no functional change to the iter5 substrate. **This work belongs on iter5 first** — landing the parameterization on trunk lets the sibling branches inherit it cleanly.

## Phased sequence

### Phase 1 — Parameterize on iter5 ✅ SHIPPED 2026-05-31

Landed on `iter5-1080p-clean`:
1. ✅ `KERNEL_GPIO_INDEX` + `KERNEL_M_SLOT` env vars in `tcl/build_phase_b.tcl` (defaults 7 / 10).
2. ✅ BD references to `axi_gpio_7` / `M10` templatized via `$KERNEL_GPIO_NAME` and `$KERNEL_M_PORT`.
3. ✅ `tcl/build_phase_b_app.tcl` writes `sw/phase-b/src/kernel_gpio_index.h` with `SCALER_KERNEL_GPIO_BASEADDR` pointing at whichever `XPAR_AXI_GPIO_N_BASEADDR` matches the index.
4. ✅ Firmware uses `SCALER_KERNEL_GPIO_BASEADDR` instead of hardcoded `XPAR_AXI_GPIO_7_BASEADDR`. Falls back to GPIO 7 if header isn't present.
5. ✅ Firmware ELF build verified at default index 7 (bit-equivalent behavior).

**Gate status**: PASS at default env. XSA-diff verification against a previous build deferred (low risk — the parameterization is text-substitution-only, and the firmware behavior was confirmed identical to the prior build).

### Phase 2 — Resync mackin (revised ~3-4 h + 30 min bench)

2026-05-31 evening: attempted the merge to scope the work; aborted cleanly. Findings:

**Conflicting files (8)**:
- `constraints/zybo_z7_20_phase_b.xdc` — 3 comment-only conflicts. Take iter5.
- `docs/build-manifest.md`, `docs/iter6-s2mm-fsync-fix.md` — additive doc sections. Take iter5.
- `hdl/scaler_top.v`, `hdl/scaler_h.v`, `hdl/scaler_v.v` — mackin's HDL is iter5 minus iter14. Take iter5 (brings iter14 + iter13c + audit follow-ups).
- `sw/phase-b/src/main.c` — **the substantive merge**. 8 conflict regions over ~300 lines. Mackin's alpha tuning (`a <hex>`), TPG controls (`t`, `p`, `n`, `f`, `c`), and classic_genlock setup live alongside iter5's V0a JSON-RPC J handler + iter14 `k` command. Cannot take either side wholesale — needs hand merge of the UART parser.
- `tcl/build_phase_b.tcl` — 5 conflict regions. Key: mackin uses `NUM_MI=13` (Mackin alpha at M10/axi_gpio_7 + ADV7393 at M11 + TPG at M12/axi_gpio_8); iter5 added kernel_mode at M10/axi_gpio_7. Merge needs `NUM_MI=14` with kernel_mode at a new slot (M13/axi_gpio_9 is suggested per blocker #1). The `KERNEL_GPIO_INDEX`/`KERNEL_M_SLOT` env vars from Phase 1 are the right abstraction; mackin builds need `KERNEL_GPIO_INDEX=9 KERNEL_M_SLOT=13`.

**Files mackin doesn't have but iter5 brings** (clean adds; no conflict):
- `control-plane/` — catalog, daemon, web UI, factory profiles, JSON Schemas.
- `tests/` — pytest harness with FakeSerial + auth + schema + Playwright.
- `Makefile` — top-level entry points.
- `docs/wiki/CONTROL-PLANE.md` and 7 other new wiki pages.
- `docs/v1-critical-path.md`, `docs/v0a-scope-fence.md`, etc.

**Revised execution plan (next session)**:
1. Take iter5's HDL + XDC + docs wholesale (5 of 8 conflicts).
2. Hand-merge `main.c`: keep mackin's `a`/`t`/`p`/`n`/`f`/`c`/classic_genlock blocks; layer iter5's `J` handler + `k` command + V0a shadow globals on top. Probably ~2 h.
3. Hand-merge `tcl/build_phase_b.tcl`: keep mackin's NUM_MI=13 base, bump to 14, wire kernel_mode at axi_gpio_9/M13 via `KERNEL_GPIO_NAME`/`KERNEL_M_PORT` substitution. Probably ~30 min.
4. Build with `KERNEL_GPIO_INDEX=9 KERNEL_M_SLOT=13`.
5. Bench: 3-boot 720p60 passthrough; mackin alpha round-trip; `k h <N>`/`k v <N>` toggle; V0a browser UI check.

**Gate**: 3 cold reboots clean + alpha + kernel-mode + V0a UI round-trip works.

### Phase 3 — Resync phase-e1 (revised ~4-5 h + 1 h bench)

phase-e1 is 77 commits behind trunk (vs mackin's 55). Bigger lift because phase-e1 also needs **iter4e** (runtime `in_w_async`/`in_h_async` ports on `scaler_top`) which it never received — iter14 layers on iter4e.

Conflict shape (extrapolating from Phase 2's findings; not yet attempted):
- Same 8 files conflict, plus probably more in `main.c` because Phase E1 has its own UART command set (`q`/`p`/`c`/`d`/`m`/`L`/`r` etc — see `FIRMWARE-INTERFACE.md`).
- `scaler_top.v` diff is much larger (mackin already had iter4e; phase-e1 doesn't).
- BD slot pressure: phase-e1 uses `axi_gpio_refsel` + `axi_gpio_srcdiv` for MMCM tracking. Need to find a `KERNEL_GPIO_INDEX` slot that doesn't clash.

**Revised execution plan (next session, separate from Phase 2)**:
1. Same wholesale takes on HDL + XDC + docs.
2. Hand-merge `main.c`: keep all the MMCM tracking commands; layer iter5 V0a `J` + iter14 `k` on top. ~3 h.
3. Hand-merge `tcl/build_phase_b.tcl`: include iter4e BD changes + iter14 with a free slot index. ~1 h.
4. Build.
5. Bench: 3-boot 60→60 matched-rate (regression check); 60→60 motion; kernel-mode toggle; V0a UI. **This 3-boot run also clears phase-e1's LUCKY-BOOT.**

**Gate**: phase-e1's existing bench-clean 60→60 + motion still passes + iter14 toggle + V0a UI work.

### Phase 4 — Documentation (~30 min, no bench)

After both branches pass their bench gates:
1. Update `docs/wiki/BRANCHES.md` with new tips + cleared LUCKY-BOOT note for phase-e1 if Phase 3 gate passed.
2. Update `docs/build-manifest.md` with resync session entry.
3. Close task #65; open follow-up tasks for any deferred items.

## Estimated effort (revised 2026-05-31 evening)

| Phase | Wall-clock | Bench time | Risk |
|---|---|---|---|
| 1. Parameterize on iter5 | ~1 hour | 0 (XSA-diff verify) | Low | ✅ SHIPPED |
| 2. Resync mackin | ~3-4 hours + 30 min bench | 30 min | Medium-High (main.c UART parser merge) |
| 3. Resync phase-e1 | ~4-5 hours + 1 hour bench | 1 hour | High (iter4e substrate change + own UART command set) |
| 4. Documentation | ~30 min | 0 | Low |
| **Remaining total** | **~7.5-9.5 h + 1.5 h bench** | **1.5 h** | Medium-High |

The Phase 2 estimate doubled after the abort showed `main.c` has 8 conflict regions with 3 distinct command-set authorships (mackin alpha + TPG + iter5 V0a+iter14) all overlapping in the UART parser. Bench windows for Phases 2 and 3 can be scheduled independently — no dependency between them once Phase 1 lands.

## Out of scope for task #65

- Backport of catalog v0.2.0 / V0a control plane is automatic via the merge — but **bench-verifying the daemon against each sibling branch is owed** as a follow-up task.
- iter14 mode 3 (polyphase MAC) is not implemented anywhere — not a backport target.
- Phase G `phase-g-iter1` is bench-blocked on hardware (Si5351 RESTART + ADV7393 chip); not a resync candidate until those clear.

## Open questions

1. **Should iter5 force-update `main`** during Phase 4? Build-manifest says "at v1 ship", so probably not — but if both siblings clear their bench gates and trunk hasn't moved, this is the cleanest window. Defer the decision until Phase 3 outcome is known.
2. **Does `KERNEL_GPIO_INDEX` belong in `tcl/build_phase_b.tcl` or its own `tcl/branch-config.tcl`?** Building toward more parameterization (FRC_METHOD, COLOR_PIPELINE already exist) suggests a dedicated config file. Land as monolithic env-var first, refactor when 3+ knobs exist.
3. **Phase E2 work** (Si5351, Mackin dual-VDMA) is hardware-blocked but should it be folded into the resync, or kept on separate sub-branches and merged after their own bench passes? Recommend: keep separate; the resync is about closing the iter5 ↔ siblings gap, not about progressing Phase E2.

---

**Owner**: this plan is reviewed and the steps are run when there's a dedicated session for it. Not blocking v1 ship per `docs/build-manifest.md` "Branch model" section.
