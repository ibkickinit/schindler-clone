# Historical Narrative

Big-picture chronological story of the Schindler 2.0 project, May 2026. Reads alongside `../schindler-playbook.md` (the aspirational narrative) and `../build-manifest.md` (the empirical ledger).

## Origin: rescue of the MVPHD-24

Cal Media's Schindler MVPHD-24 is a niche 24fps frame-rate converter built in the late 1990s / early 2000s for film-shoot CRT monitor reference. Used on set, in rental houses, by music-video and period-shooting DPs. ~75 units survive. Unmaintained, parts unavailable, prone to PSU and capacitor failure.

The project's premise: **preserve the operator workflow.** What an on-set DP plugs in and what they see on the monitor should be indistinguishable from the original Schindler experience — but the box underneath is modern, repairable, and connected.

Justin started development on a Digilent Zybo Z7-20 dev board. HDL targets Zynq-7020 silicon; the production hardware will be a Trenz TE0720 SoM on a custom carrier PCB.

## Phase A (early May 2026) — HDMI passthrough

Ground-truth baseline. Get the Zybo to receive HDMI, decode it, and re-emit it without modification. dvi2rgb → axis_to_vid_io → rgb2dvi.

Shipped 2026-05-13 on `phase-a-hdmi-passthrough`. WNS +0.23 / WHS +0.06. Bench-clean.

## Phase B (mid-May 2026) — DDR3 VDMA frame buffer

Get a frame buffer inserted between input and output. dvi2rgb → S2MM → DDR3 → MM2S → axis_to_vid_io. This is the substrate everything that follows builds on.

Shipped 2026-05-14 on `phase-b-vdma-passthrough` lineage (later forks).

## Phase C (mid-May 2026) — Polyphase scaler

Add 1080p → 720p downscale. Initially designed with 8-tap horizontal + 4-tap vertical polyphase using Mitchell-Netravali coefficients.

Shipped a series of iters but had problems:
- Mitchell's negative sidelobes amplified source/TMDS noise into colored speckle at high-contrast edges
- Alternative all-positive kernels (Linear, Gaussian) had different texture issues
- iter3q reverted to NN single-tap bypass — calmed the noise but introduced bugs we wouldn't see for weeks

## Phase D (May 14-22, 2026) — FRC via Dynamic Genlock

Add frame-rate conversion using VDMA's Dynamic Genlock mode. S2MM writes whenever source has a frame; MM2S reads whenever output asks. `repeat_en=1` causes MM2S to re-read the last completed frame when output is faster than source.

Many iterations chasing nested bugs:
- **iter4d-3** — production-clean 60→60 substrate, ancestor of everything since
- **iter4g** — diagnostic counter infrastructure
- **iter4h** — attempted VSIZE=747 fix for bottom-bars artifact. ❌ Caused 1-row-per-frame scroll. Abandoned.
- **iter5-bisect** — removed iter4h additions, found stable substrate
- **iter5-1080p-clean** — 1080p substrate + color stack on top

**2026-05-21 — bench-equipment crisis.** A faulty bench monitor cost ~4 hours of phantom debugging. Memory: `schindler_bench_equipment_confounder`. The bench-rule "suspect equipment first" was born here.

**2026-05-21 — MS2109 verification trap discovery.** Realized that the cheap HDMI capture stick has its own framebuffer that absorbs FRC drift / vertical wrap. ALL prior PASS claims using MS2109 evidence are now suspect. Memory: `schindler_ms2109_verification_trap`. The bench-rule "monitor-only for motion artifacts" was born here.

**2026-05-21 — no-coin-flip rule.** Justin's directive after the equipment confounder: "if you cant look at any particular build and identify whether that build passes clean image, we have failed somewhere." The rule: ≥3 cold reboots showing same picture before any ✅ claim. Memory: `schindler_no_coin_flip_rule`.

## iter6 (2026-05-22) — Bottom-bars artifact RESOLVED

The 27-row leak of frame K+1's top into slot K's tail was traced to VDMA's internal TUSER pipeline lag. Fix: enable hardware S2MM fsync from the source vsync edge, bypassing the pipeline.

Resolved across all three production branches: iter5-1080p-clean, mackin-impl-wip, phase-e1-pll-spike.

**But:** iter6 unmasked a residual 2-3 pixel per-line H-shift. The H-shift had been there all along; the more dramatic 27-row leak hid it.

## iter7-iter11 (2026-05-22 to 2026-05-24) — H scaler kernel experimentation

The H-shift was initially hypothesized to be on S2MM or MM2S. Boundary-col DDR3 dumps disproved that — the slot bytes were clean. The shift was in scaler_h.

Many sub-iters experimenting with tap picks:
- iter7: clear window on TLAST (prevents row-tail bleed into row N+1)
- iter8: tap pick window[3] → window[0] (eliminated left margin, introduced right margin)
- iter9: tap = window[1] (balanced margins, still hard NN)
- iter10: 8-tap boxcar (too soft, lost right edge anyway)
- iter11: 2-tap boxcar (tight blur, but last emit missed source col 1919)

## iter12 (2026-05-24) — H scaler ✅

Final H form: 2-tap boxcar with newest tap = `s_axis_tdata` (the freshly arriving pixel). First emit reads source cols 0, 1; last emit reads source cols 1918, 1919. Full source col range sampled.

## iter13 (2026-05-24) — V scaler ✅

Same class of bug on V scaler. NN bypass `mac_r = tap1` dropped 1 of every 3 source rows at 1080→720. Fix: 2-tap boxcar `(tap2 + tap3) / 2` post-rotation.

Bench-verified on all three branches via DDR3 byte dumps + monitor inspection.

## iter13b (2026-05-30) — DC bias removed

The 2026-05-30 audit panel's HDL Correctness agent flagged a −0.5 LSB DC bias from the truncating `>>1` in the iter12/iter13 boxcars. Cumulative H+V = −1 LSB per channel = slight dark shift. Fix: `+ 9'd1` before `>>1`. Costs 3 LUTs per scaler.

## Phase E1 (2026-05-19) — MMCM tracking spike

In parallel with Phase D iters: closed-loop MMCM `psincdec` tracking. Firmware measures vsync delta; PI controller computes per-frame phase step; applies via clk_wiz DRP.

Shipped on `phase-e1-pll-spike`. ±500 ppm pull range. Bench-clean 60→60 motion as of 2026-05-30.

## Phase E2 (2026-05-18 to present) — Si5351 + Mackin

Two threads running in parallel, both partial:

**Mackin temporal blender:** HDL + Python golden + 3360-vector sim suite passed 100% bit-exact 2026-05-18. Bench wiring is placeholder `axis_clone` — real dual-VDMA wiring deferred.

**Si5351 actuator:** Phases A/B/C-lite PASS 2026-05-20. Phase D Stage 1 BLOCKED on flaky multi-byte I²C writes. Multi-agent research 2026-05-21 identified 3 reinforcing root causes (AXI IIC prologue, SYS_INIT poll, JESSINIE decoupling). Plus a 4th issue 2026-05-21: missing RESTART when SDA rise time is too slow.

Both threads paused pending bench session.

## Phase G (2026-05-17 to present) — Analog out via ADV7393

The whole point of the project. ADV7393 DAC drives composite/S-Video/component analog outputs.

iter1.0 through iter1.6: BD scaffolding, AXI IIC, 27 MHz CLKIN, direct-register-bang firmware. AXI IIC proven healthy.

**2026-05-20 — chip dead.** Single-byte probe NAKs. Scope shows 9th SCL with no slave ACK. Replacement on order.

Paused. Resume gated on chip arrival + 1 kΩ RESETB resistor mod.

## 2026-05-30 — Multi-agent audit + restructure

Justin requested a 7-agent independent audit while wall-clock-limited (new baby). Audits found:
- Documentation cohesion: PARTIAL — multiple stale references
- HDL correctness: −0.5 LSB DC bias (fixed iter13b)
- Test methodology: ⚠️ LUCKY-BOOT not ✅ CLEAN under strict reading
- Git hygiene: phase-g-iter1 had 9 unpushed commits (data-loss risk; fixed by pushing)
- PM trajectory: Phase G vs E2 ordering question raised
- Risk audit: MMCM budget, branch sprawl, velocity collapse, verification debt = ~40 hours owed
- Wiki editor: 17-page wiki structure proposed (this set)

This wiki is the result. The project is now documented at a navigable conceptual layer for the first time.

## What's next

Current open work (in priority order from the 2026-05-30 PM brief):

1. 3-cold-boot verification of iter5-1080p-clean (formal no-coin-flip retirement)
2. iter13b backport to mackin + phase-e1
3. Phase E2 Si5351 multi-byte fix (when at bench)
4. Phase G ADV7393 resume (when replacement chip arrives)
5. Scope decision: Phase G first OR Si5351 first when both unblocked

See [BRANCHES](BRANCHES.md) for tips, [KNOWN-BUGS](KNOWN-BUGS.md) for open work, [PHASES](PHASES.md) for phase status.

<!-- AGENT_TASK[docs-14]: This historical narrative needs periodic updates. Pattern: every major phase ship or substrate-altering event gets a section here. -->
