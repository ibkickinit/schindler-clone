# iter6: bottom-bars artifact — root cause + fix

**Status:** **RESOLVED 2026-05-22.** Bench-verified on monitor + DDR3 dump on branch `iter5-1080p-clean` head with iter6 changes applied.

**TL;DR:** The "bottom-bars artifact" / "bottom-rows leak" was on the **S2MM (write) side of VDMA**, not the scaler. The default AXIS-TUSER-driven frame boundary detection in `axi_vdma` v6.3 has ~27 rows of internal pipeline lag between TUSER on AXIS and the actual slot-pointer transition in DDR3. The first 27 rows of frame K+1 get written into the tail of slot K. **Fix:** drive S2MM's external `s2mm_fsync` input with a 1-cycle pulse on the rising edge of source vsync (`dvi2rgb_0/vid_pVSync`), enable `c_use_s2mm_fsync=1` and `c_flush_on_fsync=1`. The hardware fsync bypasses the AXIS-side detection entirely.

This doc supersedes:
- iter4g's hypothesis that the scaler was emitting wrong tap data ([docs/iter4g-diagnostic-findings.md](iter4g-diagnostic-findings.md)). The scaler is healthy — see "Counter evidence" below.
- iter4h's `VSIZE=747` over-allocate workaround which masked the bug but introduced 1-row-per-frame scroll.
- The memory note `schindler-bottom-bars-artifact` (mark RESOLVED).

## Symptom

On a 1280×720 output substrate fed by 1920×1080 SMPTE bars:

- **Slot K rows 0-693**: correct frame K content.
- **Slot K row 693**: BLACK (one cosmetic row, see "Side note" below).
- **Slot K rows 694-719**: **frame K+1's top-of-bars content** — exact byte-for-byte match against slot K+1 rows 0-26. **The 27-row leak.**
- **Guard row 720**: `0x000000` — S2MM does NOT write past VSIZE.

On the bench monitor with `MM2S +STRIDE shift` enabled (iter3i): the bottom ~26 displayed rows show SMPTE-main-bars content instead of PLUGE content. Visually presents as a thin colored strip at the very bottom of the frame.

**Deterministic across boots.** Not a coin-flip; not rate drift. Same content position every frame on a static source.

**Hidden by three confounders** prior to 2026-05-21:
1. MS2109 capture stick's framebuffer smooths out partial-row artifacts.
2. A faulty bench monitor displayed the artifact as different geometry than reality.
3. Osee GoStream switcher's input 2 was a motion loop; the motion masked the static leak signature.

## Counter evidence — the bug is on S2MM's side

Add scaler_v output TLAST counter ([hdl/scaler_v.v](../hdl/scaler_v.v) — see `out_tlast_count_snap`). Per source frame, snapshotted at input TUSER:

| Counter | Value | Meaning |
|---|---|---|
| `h_in` | 1080 | scaler_h received 1080 input TLASTs (= source rows) ✓ |
| `v_in` | 1080 | scaler_v received 1080 input TLASTs ✓ |
| `v_emit` | 720 | scaler_v fired 720 `v_cross` events (= internal emit triggers) ✓ |
| `v_out_tlast` | **720** | scaler_v's `m_axis_tlast` handshake fired 720 times ✓ |

Scaler emits exactly **720 valid output rows per source frame**, each with a proper TLAST handshake. The leak cannot be on the scaler side.

This counter was the critical piece of evidence. iter4g had `v_emit=720` but lacked `v_out_tlast`, leaving it ambiguous whether the scaler was aborting the last emits silently. iter6's counter rules that out.

### Latent bug discovered along the way: CDC truncation

`hdl/axi_sync_inputs.v` declared `diag_counts_async` as 64-bit input but the internal 2-FF synchronizer regs and `diag_counts_sync` output were **48-bit**. The upper 16 bits were silently truncated by Vivado. This had been harmless until iter6 because the old occupant of `[63:48]` (`axis_to_vid_io_0/mm2s_tlast_snap`) always read 0 anyway. Fixed in the iter6 commit — widened the entire CDC to 64-bit. Worth checking on any branch that uses `axi_sync_inputs`.

## Root cause — S2MM's internal SOF pipeline lag

With `c_use_s2mm_fsync=0` (default for axi_vdma v6.3), S2MM uses AXIS `tuser` as the start-of-frame marker. iter4h's analysis was on the right track:

> "S2MM's end-of-frame state machine (firing at VSIZE-complete) was queuing frame N+1's first 26 rows into slot K's last 26 rows."

Specifically: there's a ~27-row pipeline between where TUSER arrives on AXIS and where S2MM's slot pointer actually updates in its AXI-write address generator. When TUSER lands on AXIS for frame K+1's first beat, S2MM has 27 rows still in flight on the slot K transfer; those 27 beats get committed to DDR3 at slot K's tail addresses before the slot pointer advances.

The 27 rows is **not** a configurable burst size or FIFO depth — it's an architectural property of the IP's slot-transition state machine. No firmware-side or AXIS-side tweak can avoid it while the IP is in TUSER-driven mode.

## The fix

Hardware fsync. Drive `axi_vdma_0/s2mm_fsync` with a clean 1-cycle pulse on the rising edge of source vsync. Combined with `c_flush_on_fsync=1`, S2MM aborts any in-flight transfer on the fsync edge and re-anchors the slot pointer immediately, bypassing the AXIS-side pipeline.

### Concrete file changes

**`tcl/build_phase_b.tcl`:**

```tcl
# Add vsync_cdc_pulse to add_files:
add_files -norecurse [file join $project_root hdl vsync_cdc_pulse.v]

# In the axi_vdma_0 set_property block:
CONFIG.c_flush_on_fsync {1}   ;# was 0

# Replace the explicit c_use_s2mm_fsync=0 override:
set_property -dict [list CONFIG.c_use_s2mm_fsync {1}] [get_bd_cells axi_vdma_0]

# After rst_axi is created (e.g., right before the LED composition block):
create_bd_cell -type module -reference vsync_cdc_pulse s2mm_fsync_pulse_gen
connect_bd_net $pclk_in                                      [get_bd_pins s2mm_fsync_pulse_gen/dst_clk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]      [get_bd_pins s2mm_fsync_pulse_gen/dst_rstn]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pVSync]            [get_bd_pins s2mm_fsync_pulse_gen/vsync_async]
connect_bd_net [get_bd_pins s2mm_fsync_pulse_gen/pulse_out]  [get_bd_pins axi_vdma_0/s2mm_fsync]
```

**`hdl/vsync_cdc_pulse.v`:** already existed (was orphan HDL). 2-FF synchronizer + edge detector. Both clocks tied to `pclk_in` (`dvi2rgb_0/PixelClk`) for this use because `vid_pVSync` and `s_axis_s2mm_aclk` are both on `pclk_in`.

**`hdl/scaler_v.v`:** added `out_tlast_count_snap` output and counter logic. Snapshotted at input TUSER. Not strictly required for the fix, but lets future agents verify the scaler is healthy in one DIAG line.

**`hdl/scaler_top.v`:** forwarded `out_tlast_snap` as a new 16-bit output port. Wired into BD's `diag_concat/In1` (replacing the dead `axis_to_vid_io_0/mm2s_tlast_snap` slot).

**`hdl/axi_sync_inputs.v`:** widened `diag_counts_q1/q2/_sync` from 48 to 64 bits (the CDC bug noted above).

**`sw/phase-b/src/main.c`:** renamed the diag field to `v_out_tlast` and updated the DIAG print format.

### Acceptance criteria

After applying the fix, on iter5-1080p-clean substrate with 1080p60 SMPTE bars source through Osee input 1 → 720p60 output:

- ✅ Monitor: clean SMPTE bars, no thin colored strip at the bottom.
- ✅ DDR3 dump of slot 0 rows 690-719: uniform PLUGE-like content (`col90=000000 col270=FFFFFF col460=FFFFFF col640=000000 col820=000000 col1010=000000`). No SMPTE-bars-top fingerprint anywhere in those rows.
- ✅ DDR3 dump of slot 1 row 0: `000000` (BLACK — the scaler's lbuf_fresh first-row cosmetic). Rows 1+: SMPTE-bars-top.
- ✅ `v_out_tlast=720` per source frame (scaler still healthy).
- ⚠️ `S2MM_SR` shows `SOFLate` flag (`0x800`) set every frame. **Benign.** It just means S2MM sees fsync slightly before AXIS TUSER arrives (TUSER follows the scaler's input-pipeline latency, so fsync from raw source vsync rising edge is a few rows earlier). With `c_flush_on_fsync=1`, S2MM handles this cleanly. If aesthetics matter, mask this bit in the firmware DIAG print.

## Side note: the 1-row BLACK at slot top

Every slot's row 0 is `0x000000` after the fix. That's **not the bug** — it's scaler_v's known-cosmetic lbuf_fresh warmup. The first `v_cross` of a new frame fires at input row 1's TLAST, with only 2 of 4 lbufs marked fresh (`lbuf_fresh = 0011`). The shipped MAC-bypass output picks `tap1` which under that v_cross's `tap0_slot=2` rotation reads `lbuf3` (not fresh), gated to zero. So the first output row is always BLACK.

This was documented in `hdl/scaler_v.v` lines 20-22 (the "First-cut simplifications still present" comment) and shows up in the dump as `slot 1 row 0 = 000000`. One row of black at the top of every frame on the monitor; barely perceptible. Not addressed by iter6.

## Reproducing the diagnostic

If you encounter this bug on another branch:

1. **Confirm the symptom is the bottom-rows leak**, not the Phase D vsync coin-flip or output-clock drift:
   - Static source (Osee input 1 = ImagePro SMPTE bars).
   - Cold-boot ≥3 times — pattern is identical across boots → not coin-flip.
   - Watch for ≥10 seconds — no rolling content → not drift.
   - Source-rate UART read shows `src=60.9 Hz` (NTSC source, pre-iter4a-bias-fix branches) or `src=59.94 Hz` (post-fix branches).

2. **Add the `out_tlast_count_snap` counter** to scaler_v if the branch doesn't already have it. See [hdl/scaler_v.v](../hdl/scaler_v.v) post-iter6. The counter, the scaler_top forwarding, and the BD rewiring of `diag_concat/In1` are the minimum changes.

3. **Fix the `axi_sync_inputs.v` 48→64 CDC bug** if the branch has it. Reading `v_out_tlast=0` is the telltale: the counter is incrementing in scaler_v but the value is being silently truncated in the CDC.

4. **Run the firmware dump probe** (`dump_slot_bytes` in [sw/phase-b/src/main.c](../sw/phase-b/src/main.c)). Confirm slot 0 rows 694-719 show SMPTE-main-bars-top fingerprint matching slot 1 rows 0-8. That's the leak signature.

5. **Apply the iter6 BD edits.** Rebuild Vivado. The leak should be gone in one rebuild.

## Reproducibility on other branches

**Yes, the fix replicates cleanly to any branch that has the same VDMA + scaler topology.** The fix is mechanically a 4-file change (1 TCL, 3 HDL, optional 1 firmware) with no dependency on iter5-specific state.

Branches that should benefit, ranked by likely impact:

| Branch | Current state per build manifest | iter6 applicability | Notes |
|---|---|---|---|
| `iter5-1080p-clean` | ✅ iter6 fix verified here 2026-05-22 | (applied) | Production substrate. |
| `mackin-impl-wip` | Forked from iter5 substrate; bench never validated under no-coin-flip rule | **High** — should apply iter6 before any bench work. Bug would propagate through the Mackin blender unchanged. | Same VDMA + scaler topology. |
| `phase-e1-pll-spike` | Forked from earlier iter5 + PLL tracking added. Memory says "claimed Phase E1 SHIPPED 2026-05-19" but tip has moved | **High** — the bench-session-2 doc on this branch identified the same 27-row leak under a different lens (PI-loop phase offset). iter6 fix likely resolves that "product blocker" too. Worth re-reading `tests/phase-e1/phase_e2_psincdec_limit.md` after applying. | Same topology + Si5351/MMCM tracking layer on top. Phase tracking work doesn't conflict with iter6. |
| `iter4g-counter-infra` | Pre-iter5 ancestry, merged to main as PR #3 | **N/A — superseded.** Don't apply; just use iter5 substrate. | iter4g introduced the diagnostic counters iter6 builds on. |
| `iter4h-axis-fifo` | Strictly worse than iter5 (scroll + bottom-bars both present) | **N/A — abandoned.** Don't apply; iter4h's premise (VSIZE=747 over-allocate) is the wrong mechanism. | Listed for completeness. |
| `iter5-bisect-720p`, `iter5-wip`, `iter4f-wip-pattern-diag`, `main` | Pre-iter5 or abandoned WIP | **Probably N/A.** Bug exists but no reason to fix on cold-storage branches. | Use iter5-1080p-clean. |
| `phase-g-iter1` | Phase G ADV7393 hardware bring-up; hardware-blocked on chip replacement | **No video path regression risk** — Phase G isn't about image quality. iter6 can be merged in when phase-g resumes, but no urgency. | Different bring-up axis. |

### Replication procedure (for any target branch)

```bash
git checkout <target-branch>
# Cherry-pick the four files. Adjust line numbers as needed:
git checkout iter5-1080p-clean -- \
  hdl/scaler_v.v \
  hdl/scaler_top.v \
  hdl/axi_sync_inputs.v \
  hdl/vsync_cdc_pulse.v
# Then re-apply the BD TCL edits to the target branch's tcl/build_phase_b.tcl:
#   1. add_files line for vsync_cdc_pulse.v
#   2. CONFIG.c_flush_on_fsync {0} → {1}
#   3. CONFIG.c_use_s2mm_fsync {0} → {1}
#   4. The s2mm_fsync_pulse_gen instantiation + 4 connect_bd_net lines,
#      placed AFTER rst_axi is created and $pclk_in is set.
#   5. Remove (or update) the diag_concat/In1 wiring from
#      axis_to_vid_io_0/mm2s_tlast_snap → scaler_0/out_tlast_snap.
# Rebuild Vivado + Vitis, program, verify dump.
```

The TCL edits don't `git cherry-pick` cleanly because they're inline in a long file — easiest to hand-apply by searching for the iter6 comment markers in the iter5-1080p-clean version and replicating to the target.

### Branches that might NOT have this bug (worth checking before applying)

- **`phase-a-hdmi-passthrough` lineage**: Phase A has no DDR3 buffer, no VDMA — output VSync IS the source VSync. The leak can't exist architecturally. Don't apply iter6 here.
- **Any TPG-only branch**: if there's no real scaler→S2MM AXIS path, the bug doesn't manifest.

When in doubt, run the dump probe first. If `slot K rows ~694-719` show main-bars-top instead of expected end-of-frame content, you have the bug and iter6 applies.

## Open items (post-iter6 followups, not blockers)

> **Status update 2026-05-30:** items 1, 2, 4 partially or fully addressed during the iter12+iter13 cycle. Items 3 and 5 still genuinely open. See `docs/build-manifest.md` "2026-05-24" and "2026-05-30" sections for the post-iter6 work.

1. ~~**Cold-boot ≥3 reboots** under the [[schindler_no_coin_flip_rule]] to formally retire the "OPEN COIN-FLIP" status on `iter5-1080p-clean` in `docs/build-manifest.md`.~~ — *Effective ≥3-reload verification done across multiple input sources during the iter12+iter13 development. Build manifest reflects current status; awaiting formal commit-log entry on the next bench session.*
2. ~~**Motion-source re-test** (Osee input 2)~~ — *Done. phase-e1-pll-spike verified clean under ImagePro diagonal motion 2026-05-30 (`fcd722c`). iter5-1080p-clean motion verification owed on the next bench session.*
3. **SOFLate cleanup** — *Still open.* Either mask the flag in the firmware DIAG print or add a small delay between fsync edge and S2MM transfer-arm so TUSER no longer arrives "late." Cosmetic only — no picture impact observed.
4. **Format-matrix re-verification.** *Partially done.* Row 2 (1080p60→720p60) ✅ on `iter5-1080p-clean` substrate. Other rows still ⚠️ pending. Per the Risk Auditor 2026-05-30: this is ~40 hours of bench time delivering no new features; consider scoping the matrix to ≤5 rows + 1 analog row for v1.
5. **Memory updates** — *Still open.* [[schindler_bottom_bars_artifact]] should add an iter12/13 reference; [[schindler_phase_d_iter4h_state]] should mark workaround obsolete.

## Related (added 2026-05-30)

- [[schindler_scaler_kernel_iter12_iter13]] — the post-iter6 scaler kernel rework that resolved the residual H-shift.
- `docs/iter14-plan.md` — deferred runtime kernel-mode toggle.
- `docs/iter6-h-shift-analysis.md` — H-shift diagnostic narrative (now RESOLVED-banner-marked).
