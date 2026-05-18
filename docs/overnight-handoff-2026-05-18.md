# Overnight handoff — 2026-05-18

## TL;DR

**Mackin blender shipped** to branch `mackin-impl-wip`. HDL + sim 100% bit-exact (3360 vectors + 8.4M property checks). Vivado bitstream + Vitis firmware building. **iter5-1080p-clean QSPI flash untouched** — boot from QSPI tomorrow comes up exactly as you left it.

## What's done

| Item | Status |
|---|---|
| Research: Mackin algorithm spec, FPGA precision, dual-VDMA patterns | ✅ 3 deep agents, ~30 min each |
| HDL: `hdl/mackin_blender.v` + `hdl/axis_clone.v` | ✅ |
| Python golden: `sim/mackin/mackin_ref.py` | ✅ |
| Verilog testbench + 8-alpha sweep | ✅ 3360/3360 bit-exact |
| Python property sweep (monotonic + endpoints + step≤1 LSB) | ✅ 8.4M checks PASS |
| Design doc: `docs/mackin-blender-design.md` | ✅ |
| Dual-VDMA recipe: `docs/mackin-dual-vdma-recipe.md` | ✅ |
| BD integration (placeholder via axis_clone) | ✅ |
| Firmware: `mackin_set()` + UART `a <hex>` | ✅ |
| Vivado bitstream | (building — should be done by morning) |
| Vitis firmware ELF | (rebuilds after bitstream) |
| Memory: `schindler_mackin_implementation` + index update | ✅ |

## Branch state

```
mackin-impl-wip                 ← you are here (recommended branch for tomorrow's review)
├── 4a44f4b mackin_blender: HDL + Python golden + sim suite
├── 8f6324e axis_clone: break combinational loop
├── 9XXXXXX mackin: BD placeholder + axi_gpio_7 + UART 'a' cmd
└── XXXXXXX mackin: Python property sweep

iter5-1080p-clean              ← unchanged from yesterday
└── f97da45 firmware: boot default = identity matrix
```

## What's NOT done (deliberately deferred)

- **Dual-VDMA wiring** — would have required restructuring iter5's proven Dynamic Genlock pipeline mid-overnight without bench validation. Risky. Full recipe in `docs/mackin-dual-vdma-recipe.md`; estimated 2-3 hour bench session.
- **Real blending visible on screen** — needs dual-VDMA. Currently mackin is a 3-cycle pass-through (curr==prev → diff=0 → out=curr regardless of α).
- **Gamma-linearized blending** — Mackin's Eq. 2 calls for blending in linear light. Current HDL blends encoded RGB. Visible error bounded; full linearization needs gamma LUT (task #28).
- **3-frame Mackin** — for K > 2 (60→24, K=2.5), the algorithm ideally blends 3 input frames. Current HDL does 2-frame. Acceptable for FRC ugly-ratio motivation; future iter.

## What to do tomorrow

### Option 1: minimal — verify the placeholder works (5 min bench)
1. JP5 → JTAG
2. Power cycle
3. `git checkout mackin-impl-wip`
4. `xsct tcl/program_phase_b_full.tcl` — programs new bitstream + firmware
5. UART listen: `cat /dev/ttyUSB1`
6. Look for `MACKIN: alpha=0x8000 base=0x... RB=0x...` at boot — verifies axi_gpio_7 + slice routing works
7. Send `a 4000` over UART — GPIO readback should show `RB=0x00004000`
8. Visual: should look IDENTICAL to iter5 (because placeholder makes α a no-op)

### Option 2: integrate dual-VDMA (2-3 hour bench)
Follow `docs/mackin-dual-vdma-recipe.md`. The big steps:
- Switch axi_vdma_0 from Dynamic to classic Genlock
- Add axi_vdma_1 as MM2S-only Genlock Slave FrmDly=2
- Wire fan-out of frame_ptr_out, separate HP port
- Remove axis_clone, wire VDMA outputs directly to mackin

After: send `a 4000` to see real 50/50 motion blend on moving content.

### Option 3: stay on iter5 — boot from QSPI
1. JP5 → QSPI
2. Power cycle
3. Should boot in full color identity (the change you made last night)
4. UART commands all work as yesterday

QSPI is unchanged; this is the safe "demo to anyone" path.

## Why I bothered the placeholder

Two choices for overnight: (a) try dual-VDMA fully → risk breaking iter5 pipeline mid-overnight without bench access; (b) integrate as placeholder → blender in the pipeline, GPIO works, alpha verifiable via UART, but no visual change yet.

I picked (b). The blender is now structurally part of the pipeline — when you wire dual-VDMA in your next session, the mackin module is already there waiting, alpha control plumbing is built, you just swap axis_clone for the real second VDMA stream. ~75-80% of the integration work is done; the remaining 20-25% is bench-iterative work that needs your eyes.

## Confidence levels

- **HDL math correctness**: very high (3360 bit-exact vectors + 8.4M property checks)
- **HDL synthesis cleanly**: high (combinational loop fix applied; awaiting build confirmation)
- **BD wiring works**: high (matches the same patterns as color_correct/saturation/matrix that are all bench-validated)
- **Firmware GPIO roundtrip**: high (same pattern as color_matrix_set which we verified on bench yesterday)
- **No regression vs iter5**: high (placeholder is mathematically a no-op; pipeline shape preserved)

## Risks / things to double-check

1. **Vivado WNS regression** — mackin adds 3-stage pipeline + axis_clone fan-out + new GPIO + slice. Could marginally tighten timing. Check `phase_b_bd_wrapper_timing_summary_routed.rpt` if Vivado finishes by morning.
2. **`a` command parser edge cases** — only handles hex with optional leading whitespace; doesn't validate non-hex chars cleanly. Worst case: weird input gives weird α value. Won't crash.
3. **XPAR_AXI_GPIO_7_BASEADDR** macro — Vivado naming may vary (XPAR_AXI_GPIO_7 vs XPAR_PHASE_B_BD_AXI_GPIO_7). Firmware has #if/#elif fallback so either name works.

## Open question for you

Did you have a specific source for the "Mackin" attribution? Research found Alex Mackin (BBC/Bristol, ICIP 2019), **not** Tyler Mackin. RT4K doesn't publicly cite Mackin in any firmware notes I could find. If you've seen a specific RT4K reference / Mike Chi tweet, that link would tighten the attribution chain. (Not blocking — the algorithm is correctly named and authored regardless.)

---

Sleep well.
