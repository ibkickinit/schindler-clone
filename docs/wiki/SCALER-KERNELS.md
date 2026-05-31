# Scaler Kernels

Runtime kernel-mode selection for the H and V downscalers. Shipped iter14 on 2026-05-31; runtime toggle via `axi_gpio_7` (or per-branch `KERNEL_GPIO_INDEX` after [BRANCH-RESYNC-PLAYBOOK](BRANCH-RESYNC-PLAYBOOK.md) lands).

Closes `AGENT_TASK[docs-15]`.

## The three modes

| Mode value | Name | Behavior | Trade-off |
|---|---|---|---|
| `0` | NN (Nearest Neighbor) | Output pixel = the closest input pixel. | Sharpest; drops columns/rows visibly on non-integer ratios. |
| `1` | 2-tap boxcar | `(a + b + 1) >> 1` of two consecutive input samples (post-iter13b round-to-nearest). | **Production default.** Mild softening; clean DC. |
| `2` | 4-tap boxcar | `(a + b + c + d + 2) >> 2` of four consecutive samples. | Softer; better-behaved on aggressive downscales (≥ 2:1). |
| `3` | Reserved | (placeholder for polyphase MAC if/when it ships) | n/a today |

H and V modes are independent. Default at boot is `H=1, V=1` (4'b0101 on the 4-bit GPIO).

## Runtime control

Three surfaces, all wired to the same `axi_gpio_7` (iter5):

### UART (legacy)

```
k h <0-3>    set H mode
k v <0-3>    set V mode
k            print current modes
```

### JSON-RPC (V0a)

```json
{"jsonrpc":"2.0","id":1,"method":"control.set","params":{"id":"scaler.kernel_h","value":"nn"}}
{"jsonrpc":"2.0","id":2,"method":"control.set","params":{"id":"scaler.kernel_v","value":"boxcar_4tap"}}
```

Enum strings (`nn` / `boxcar_2tap` / `boxcar_4tap`) translate to integers (0/1/2) at the daemon boundary.

### Web UI

Two dropdowns in the Scaler section. Live update on change.

## Implementation

- HDL: `hdl/scaler_h.v`, `hdl/scaler_v.v` compute all three modes in parallel (mode0/mode1/mode2 wires), then a combinational mux on `kernel_mode` selects the output. ~50 logic-cell overhead per axis, no LUT or DSP cost beyond what 4-tap was already paying.
- CDC: 4-bit `kernel_mode_async` GPIO output → 2-FF `ASYNC_REG` synchronizer in `scaler_top.v` (`km_q1/km_q2`). Reset default `4'b0101`. False-path in `constraints/zybo_z7_20_phase_b.xdc` (added 2026-05-31 per HDL audit).
- Firmware: GPIO 7 bit layout `[1:0] = H_mode`, `[3:2] = V_mode`. Single 32-bit register; H and V toggled independently with read-modify-write.

## Why iter12+iter13 default to 2-tap boxcar

History recap (see [`../scaler-kernel-iter12-iter13.md`](../scaler-kernel-iter12-iter13.md) memory for the long form):

- Pre-iter12: Lanczos/Mitchell with 8-tap polyphase. Looked good in sim, but at runtime exposed: H-shift in iter6, missing-lines in iter11 (lbuf newest-tap race).
- iter12: H 2-tap `(s_axis_tdata + tap0) >> 1` — newest sample participates directly, no race window. Fixes H-shift.
- iter13: V 2-tap `(tap2 + tap3) >> 1` after rotation — same fix on V axis.
- iter13b: `+1` round-to-nearest pre-shift; removes the −0.5 LSB DC bias from `>> 1` of `(a + b)`.
- iter13c: `lbuf_fresh`-gated emit suppression; removes top-of-frame black band that iter13 was emitting when tap2/tap3 lbufs hadn't been written yet.

The 2-tap is intentionally simple. Polyphase / Mitchell / Lanczos can be added back later as `mode 3` (polyphase MAC) but the priority on the 720p60 production substrate was correctness, not academic kernel choice.

## Open work

- Mode 3 (polyphase MAC) implementation. Reserved in the GPIO bit layout and catalog enum. No HDL yet.
- iter14 backport to mackin / phase-e1 — gated on the `KERNEL_GPIO_INDEX` slot-picker (task #65, see [BRANCH-RESYNC-PLAYBOOK](BRANCH-RESYNC-PLAYBOOK.md)).
- Runtime kernel-mode telemetry (which mode is active right now in DIAG) — currently has to be read back through `k` / `control.get`. Low priority.

## Cross-links

- [ARCHITECTURE](ARCHITECTURE.md) — pipeline topology, scaler placement
- [PHASES](PHASES.md) — iter ledger
- [`../iter14-plan.md`](../iter14-plan.md) — the design doc
- [CONTROL-PLANE](CONTROL-PLANE.md) — JSON-RPC surface for the runtime toggle
- [[schindler_scaler_kernel_iter12_iter13]] — memory deep-dive on the kernel choice
- [[schindler_iter14_plan]] — memory for the runtime-toggle design

<!-- AGENT_TASK[docs-15]: DONE 2026-05-31 — this page replaces the task marker. -->
