# iter4g diagnostic session findings — bottom-rows artifact

## Hard data from counter infrastructure

Per-source-frame counters latched at TUSER, read via AXI GPIO 2:

| Counter | Reading | Expected | Status |
|---|---|---|---|
| `h_in` | 1080 | 1080 | ✓ correct |
| `v_in` | 1080 | 1080 | ✓ correct |
| `v_emit` | 720 | 720 | ✓ correct |
| `mm2s` | 0 | ? | MM2S doesn't assert TLAST on its output |

Source dimensions (VTC RX detector): **HACTIVE=1920, VACTIVE=1080** = standard SMPTE 274M 1080p60.

VDMA register dump (offsets from base):
```
+0x00 MM2S_DMACR    = 0x0001008B
+0x04 MM2S_DMASR    = 0x00011000  (FrmCnt=1, EOLLate set)
+0x30 S2MM_DMACR    = 0x00018083
+0x34 S2MM_DMASR    = 0x0001D000 → 0x00011000 after W1C → re-asserts every frame
+0x50 MM2S_VSIZE    = 720   (0x2D0)
+0x54 MM2S_HSIZE    = 3840  (0xF00)
+0x58 MM2S_STRIDE   = 3840
+0x5C MM2S_START_1  = 0x10000F00  (slot 0 + STRIDE = +iter3j offset)
+0x60 MM2S_START_2  = 0x102A4E00
+0x64 MM2S_START_3  = 0x10548D00
+0xA0 S2MM_VSIZE    = 720
+0xA4 S2MM_HSIZE    = 3840
+0xA8 S2MM_STRIDE   = 3840
+0xAC S2MM_START_1  = 0x10000000  (slot 0 base)
+0xB0 S2MM_START_2  = 0x102A3F00
+0xB4 S2MM_START_3  = 0x10547E00
```

All configuration values are correct.

## EOLLateErr (bit 12)

Fires on **both** S2MM and MM2S DMASR, every frame, persists after W1C clear.
Confirmed at both 720p50 (FRC) and 720p60 (matching rates) — NOT FRC-specific.

Per Xilinx `xaxivdma_hw.h` bit definitions:
- Bit 12 (0x1000) = `XAXIVDMA_SR_ERR_EOL_LATE_MASK`
- Per PG020 v6.3 EOLLate is documented for MM2S; S2MM bit 12 marked reserved.
  Hardware appears to set it for S2MM too in this IP version.

EOLLate means: TLAST arrived later than HSIZE bytes of data per row. Since scaler
correctly outputs exactly 1280 pixels (3840 bytes) with TLAST on the last pixel,
the cause is unclear. Possibly related to AXIS handshake stall handling between
HSIZE expectation and actual handshake timing.

## Direct intervention tests

| Intervention | Bottom-rows artifact result |
|---|---|
| 720p50 (FRC) vs 720p60 (matching) | Same artifact, ~25 rows of next-frame-top at bottom |
| MM2S +STRIDE offset enabled (iter3j) | Same artifact (rows 694..718 wrong) |
| MM2S +STRIDE offset DISABLED | Same artifact (now rows 694..719 wrong, slot row 719 also wrong) |

Removing the +STRIDE offset moves the visible bottom by 1 row but doesn't
change the pattern — confirming the artifact is in the DATA WRITTEN to slot rows,
not in MM2S's read range.

## Reasoning so far

1. **Scaler counters say 720 emits/frame, but slot row 719 contains RED-bar data instead of expected PLUGE-bottom content.**

2. Possible causes (none confirmed):
   - Scaler emits a "row 719" with wrong tap data (some lbuf state issue)
   - S2MM partially writes frame N, then frame N+1, into the same slot
   - Some interaction between Dynamic Genlock and frame transitions

3. The "look like next-frame top" pattern strongly suggests **slot contains a mix of frame N's start + some other data**, OR **MM2S advances slot mid-read** (but we proved data is wrong in the slot itself, not just in MM2S's range).

## Open questions for next session

1. **Why does scaler emit 720 (per counter) but slot has wrong data at the bottom?**
   - Either counter is wrong (TUSER timing issue) or scaler's MAC pulls wrong data for last emits
   - Add a counter at scaler_v's m_axis output (count m_axis_tlast firings vs v_cross firings — should be equal but verify)
2. **What does MM2S actually deliver per output frame?**
   - mm2s=0 currently (TLAST not generated). Need different metric — count pixels (tvalid+tready) per VTC output frame
3. **Why does EOLLateErr fire on both channels every frame?**
   - May be benign warning or may indicate the actual problem
4. **What if we instrument the slot DDR3 contents directly?**
   - Firmware reads memory at slot N row 719 base and dumps the bytes — confirms what S2MM wrote there
5. **What if v_vid_in_axi4s asserts TLAST on hsync edges during V-blank?**
   - Even though our counter says h_in=1080, maybe v_vid_in_axi4s emits "extra" TLAST events that scaler_h drops or v_cross doesn't fire for. Would explain artifact mechanism.

## Resume plan

1. Add scaler_v m_axis_tlast counter (verify equals emit_count = v_cross count)
2. Add axis_to_vid_io pixel counter (count tvalid+tready cycles between vtg_vsync rising edges, expected = 720 × 1280 = 921600)
3. Firmware memory read of slot bytes at known offsets to inspect actual slot content
4. Consider: temporarily replace scaler MAC bypass with a pattern that encodes emit_row_count AT EMIT TIME (vs latched at v_cross) — distinguishes "scaler emits 720 events but with wrong tap data" from "v_cross fires 720 times but emits less than 720 rows worth of data"
