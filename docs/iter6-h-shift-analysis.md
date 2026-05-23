# iter6 residual H-shift — diagnostic plan for tomorrow

**Status:** OPEN as of 2026-05-22 evening. iter6 (S2MM hardware fsync) resolves the 27-row vertical bottom-bars artifact across iter5-1080p-clean, mackin-impl-wip, and phase-e1-pll-spike. A residual **2-3 pixel per-line horizontal shift** is present on all three branches; the last 3 pixels of each row appear at the start of the next row.

## Symptom precisely

User report 2026-05-22: "each line starts 2-3 pixels late, and the last pixels of line 1 are the first pixels of line 2 and so on." → constant per-row shift of ~3 pixels = ~9 bytes (24-bit RGB). Persistent across boots. Same on all three iter6'd branches.

**Almost certainly pre-existing, unmasked by iter6.** Reasoning: the ~3-pixel shift is invisible against the 27-row V-wrap signature. MS2109 framebuffer further masked it. New monitor + iter6's clean slot tails finally exposed it. No iter6 code path obviously introduces a per-row byte offset (iter6 only changes slot-transition timing, not per-row AXIS handshake or AXI burst sizing).

## Decisive next probe (firmware-only, no Vivado rebuild)

**Modify `dump_slot_bytes` to sample row-boundary columns.** Today's dump samples cols `{90, 270, 460, 640, 820, 1010}` — none near the H-shift's transition zone. Add samples at `{0, 1, 2, 3, 1276, 1277, 1278, 1279}` to see what's in DDR3 at the row boundaries.

The patch:
1. Add a second sample set in `dump_slot_bytes` (in `sw/phase-b/src/main.c`) covering boundary cols.
2. Dump TWO adjacent rows showing where one row ends and the next begins.
3. Compare against expected SMPTE content for that area.

**Decision criteria:**
- **If slot row N cols 1277-1279 contain row N's expected last 3 pixels** AND **slot row N+1 cols 0-2 contain row N+1's expected first 3 pixels**: SLOT is byte-clean. The shift is in **MM2S read** (read pointer +9-byte offset, OR MM2S packer state carry-over between rows).
- **If slot row N cols 1277-1279 contain SOMETHING ELSE** (looks like row N+1's first 3 pixels, or stale data, or zeros): SLOT is byte-shifted. The shift is in **S2MM write** (write pointer offset, OR S2MM packer state carry-over).

This single probe definitively localizes pre vs post.

## Hypotheses for the cause, ranked

Whichever side (S2MM or MM2S) the probe localizes to, the mechanism is most likely one of:

### H1 — Packer state carry-over between rows (HIGHEST LIKELIHOOD)
24-bit AXIS ↔ 64-bit AXI packer. Per row = 1280 pixels = 3840 bytes = 480 AXI beats. AXI/AXIS ratio is 8:3 (8 AXI bytes ≈ 2.67 AXIS pixels), with pixels straddling AXI beats (pixel 2 spans bytes 6,7 of beat 0 + byte 0 of beat 1, etc.). The packer holds 0-7 bytes of leftover state between AXI beats.

At row boundary (1280 pixels): pattern repeats every 8 pixels = 3 AXI beats, so SHOULD reset cleanly. But if HSIZE/AXI beats don't quite align in the IP's implementation (e.g., burst length truncation, or last-burst handling), residual bytes from row N's last AXI beat could leak into row N+1's first AXIS output.

**Test:** the boundary-column dump shows pre/post side, then the fix is on whichever side: add a packer flush at row boundary (via VDMA register tweak, or via an AXIS register slice between scaler/S2MM or MM2S/axis_to_vid_io with TLAST-driven flush).

### H2 — VTC TX active window / `axis_to_vid_io` tready timing
`hdl/axis_to_vid_io.v:57` has `s_axis_tready = vtg_active_video && enable` (combinational). The `vtg_active_video` input is registered from VTC's `active_video_out`, so there's a small pipeline delay vs VTC's internal active-counter. If `axis_to_vid_io`'s output (`vid_active_r`, `vid_data_r`, `vid_hsync_r`, `vid_vsync_r` — all registered) doesn't perfectly align with the MM2S handshake timing at active-video boundaries, MM2S could consume slightly fewer or more pixels per row than VTC's actual active window.

Walked through the pipeline timing on paper — looks 2-cycle-aligned (vid_active and pixel data both come out of stage-1 reg), so probably not this. But worth verifying: count MM2S handshakes per row via a quick HDL counter (similar to `out_tlast_count_snap` we added to scaler_v).

**Test (no rebuild tonight):** if tomorrow's boundary dump shows the slot is clean (post-MM2S issue), add an MM2S-handshake-per-row counter HDL+firmware to confirm if MM2S consumes 1277, 1280, or 1283 pixels per row.

### H3 — MM2S Dynamic-Slave + repeat_en first-row alignment
`c_mm2s_genlock_mode=3` + `c_mm2s_genlock_repeat_en=1`. The repeat behavior might re-emit the LAST row of a frame at the START of the next frame's read window if the slot pointer transitions during pre-fetch. That'd cause a row-level offset, not a per-pixel offset — DOESN'T match the symptom. Probably not this.

### H4 — Firmware off-by-9 in slot address math
Already verified: `mm2s_frame_addrs[i] = s2mm_frame_addrs[i] + STRIDE` — exact row offset, no fractional. NOT this.

### H5 — Pre-iter6 latent and unrelated to fsync
Same code path was present on iter5 substrate before iter6. The H-shift was masked by the 27-row V-wrap signature. iter6 cleans the V-wrap, exposes the H-shift. **This is the most likely framing** — the bug existed since the early iter3/iter4 scaler+VDMA hookup; nobody saw it because the V-wrap was always dominant on monitor and MS2109 hid both.

If H5 holds: the fix path is on the data-pipeline side (scaler or VDMA config), not iter6's fsync wiring. We could iterate iter6 down to JUST the c_use_s2mm_fsync change and verify the H-shift is independent of iter6's wiring.

## Concrete tomorrow plan

1. **First (5 min)** — apply the `dump_slot_bytes` row-boundary sample patch (drafted below). Rebuild Vitis ELF only (~30s); the iter6 bitstream stays. Program board. Capture UART.
2. **Second (decision tree based on dump)**:
   - **Slot clean (post-MM2S issue)**: add MM2S handshake counter HDL (similar to scaler_v's `out_tlast_count_snap`). Vivado rebuild ~30 min. Confirms count, narrows to H1/H2.
   - **Slot shifted (pre-MM2S issue, in S2MM)**: scaler emits 1280-beat rows (we already know from `v_out_tlast=720` snapshot), so the shift is in S2MM's write path. Investigate S2MM packer / burst flush behavior. Likely fix: add an AXIS register slice with TLAST-flush between scaler_top and axi_vdma's S_AXIS_S2MM port.
3. **If hypothesis H5 turns out correct** (H-shift pre-existing): revert iter6 to minimum scope (just `c_use_s2mm_fsync=1`, no flush, no pulse generator) and verify the H-shift persists — confirms it was never iter6's doing. Then fix on the proper layer.

## Patch for dump_slot_bytes (draft, do NOT apply tonight)

In `sw/phase-b/src/main.c`, replace the `SAMPLE_COLS` array in `dump_slot_bytes` with a wider boundary-focused set, and call it explicitly for a low-noise row pair like slot 0 rows 100 and 101 (well clear of leak zone, surrounded by uniform SMPTE bars content):

```c
/* iter6-hshift probe (2026-05-23): sample columns near row boundaries
 * to disambiguate pre-MM2S (slot bytes shifted) vs post-MM2S
 * (slot bytes clean, MM2S read shifted). */
static const u32 SAMPLE_COLS[] = {
    0, 1, 2, 3,           /* row N first 4 pixels */
    640,                  /* row N middle (= bar 4 / green in main bars) */
    1276, 1277, 1278, 1279 /* row N last 4 pixels */
};
```

Then call `dump_slot_bytes(0, 100, 102);` (3 rows of dump) so we see row 100 (full middle of bars), 101 (next), 102 (next). Each row's last 4 cols + next row's first 4 cols give a continuous view of the boundary.

## Bench observation pattern to look for

For a 1080p60 SMPTE bars source downscaled to 720p60:
- Source row ~150 (input row that maps to output row ~100) is in the middle of the main color bars region.
- Output row 100 expected content at col samples:
  - col 0-3: WHITE bar (~CDCDCD)
  - col 640: GREEN bar (~D50000 in our R-B-G byte order)
  - col 1276-1279: BLUE bar (~0000CC or similar)

Row 101 should look identical (same color bars region, just one output row down).

**Pre-MM2S shift case**: slot row 100 cols 1276-1279 would contain... whatever S2MM wrote. If S2MM has a 9-byte per-row drift, cols 1276-1279 might show data from somewhere else.

**Post-MM2S shift case**: slot row 100 cols 1276-1279 show clean BLUE bar bytes (`0000CC`), slot row 101 cols 0-3 show clean WHITE bar bytes (`CDCDCD`).
