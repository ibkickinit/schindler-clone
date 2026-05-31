# Branch resync plan — iter5-1080p-clean → mackin-impl-wip + phase-e1-pll-spike

**Tracks task #65.** Written 2026-05-31 after the cherry-pick session that landed iter13c on both sibling branches but had to abort iter14.

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

### Phase 1 — Parameterize on iter5 (~1 hour, no bench)

Land on `iter5-1080p-clean`:
1. Add `KERNEL_GPIO_INDEX` env var to `tcl/build_phase_b.tcl` (default 7).
2. Templatize the BD axi_gpio_7 / M10_AXI references for kernel_mode.
3. Verify default build produces an identical XSA (no functional change).
4. Commit + push.

**Gate**: clean Vivado build with `KERNEL_GPIO_INDEX` unset (matches today's XSA).

### Phase 2 — Resync mackin (~2 hours + bench)

On `mackin-impl-wip`:
1. Merge-from-iter5 to bring in V0a, iter14, the audit follow-ups, the new parameterized slot picker.
2. Resolve BD conflicts: keep `mackin_alpha` at axi_gpio_7 / M10; iter14 picks up a free slot (axi_gpio_8 / M13).
3. Build with `KERNEL_GPIO_INDEX=8`.
4. Bench: 3-boot rule on 720p60→720p60 passthrough first; then alpha command roundtrip; then `k h <N>` / `k v <N>` toggle.

**Gate**: 3 cold reboots clean on bench monitor + alpha + kernel-mode round-trip works via UART.

### Phase 3 — Resync phase-e1 (~3 hours + bench)

Bigger lift because phase-e1 needs both iter4e *and* iter14 backported.

On `phase-e1-pll-spike`:
1. Merge-from-iter5 (will pull iter4e, iter14, V0a, slot-picker, all audit follow-ups).
2. Resolve conflicts: keep MMCM `psincdec` work; pick a `KERNEL_GPIO_INDEX` slot that doesn't clash with phase-e1's `axi_gpio_refsel`/`axi_gpio_srcdiv`.
3. Build.
4. Bench: 3-boot rule on 60→60 matched-rate first (regression check vs phase-e1's prior LUCKY-BOOT pass); then 60→60 diagonal motion; then runtime kernel-mode toggle.

**Gate**: phase-e1's existing bench-clean 60→60 + motion still passes + new iter14 toggle works. **This is also the first opportunity to clear phase-e1's LUCKY-BOOT debt** — 3 boots on the resync'd build promotes it ⚠️→✅.

### Phase 4 — Documentation (~30 min, no bench)

After both branches pass their bench gates:
1. Update `docs/wiki/BRANCHES.md` with new tips + cleared LUCKY-BOOT note for phase-e1 if Phase 3 gate passed.
2. Update `docs/build-manifest.md` with resync session entry.
3. Close task #65; open follow-up tasks for any deferred items.

## Estimated effort

| Phase | Wall-clock | Bench time | Risk |
|---|---|---|---|
| 1. Parameterize on iter5 | ~1 hour | 0 (XSA-diff verify) | Low |
| 2. Resync mackin | ~2 hours + 30 min bench | 30 min | Medium (conflict resolution) |
| 3. Resync phase-e1 | ~3 hours + 1 hour bench | 1 hour | Medium-High (iter4e is a substrate change phase-e1 has never seen) |
| 4. Documentation | ~30 min | 0 | Low |
| **Total** | **~6.5 hours + 1.5 hours bench** | **1.5 hours** | Medium |

Bench windows for Phases 2 and 3 can be scheduled independently — no dependency between them once Phase 1 lands.

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
