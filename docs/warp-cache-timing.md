# Warp cache — silicon (OOC synth/impl) findings, 2026-06-07

Goal: make `pg_tilecache_rt2` + `pg_warp_engine` fit and close timing on xc7z020clg400-**1** @ 74.25 MHz
(13.468 ns), before the full BD build. OOC = out-of-context (engine alone).

| Step | Fix | LUT | BRAM | WNS (synth) | WNS (impl P&R) |
|---|---|---|---|---|---|
| start | sim-oriented cache | 57k (107%) | 0 | -6.7 | — (won't place) |
| Fix1 | registered BRAM reads | 17k | 48 | -6.7 | — |
| Fix2 | 4-way set-assoc tags | 12k | 48 | -3.4 | — |
| Fix3 | pipelined bilinear (H/V) | 12k | 48 | -3.5→-3.4 | — |
| Fix4 | skid-decoupled affine handshake | 12k | 48 | -3.4 | — |
| Fix5 | tidf {ty,tx} concat (no multiply) | 12k | 48 | **-0.637** | -2.78 |
| Fix6 | registered lead-counter events | 12k | 48 | — | -2.89 (logic **3.9ns**, route 12.2ns) |

**Conclusion: cache LOGIC is timing-clean (3.9 ns of 13.5 ns).** The residual OOC impl deficit is
**routing**, and it is an artifact of unconstrained OOC placement scattering a 12k-LUT design across
the whole die. Logic delay is placement-independent; route delay shrinks dramatically in a real,
packed, in-context build. **The definitive timing test is the full BD build.** Held in reserve if the
in-context build misses: pipeline the tag lookup into its own register stage (prefetch has slack).

Fits comfortably: 12k/53k LUT (22%), 48/140 BRAM (34%), 5.4k regs. Sim bit-exact throughout
(`pg_warp_engine_tb` rot20: 0 err, real-time 38.4k<56.1k cyc).
