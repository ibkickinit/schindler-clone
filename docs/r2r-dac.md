# R-2R DAC Wiring (8-bit, Pmod JC → analog output)

Reference doc for building the first-light DAC perfboard. Output goes through
a scope probe directly (no op-amp yet) — produces a 0-3.3 V unipolar signal
shaped exactly like NTSC composite. The op-amp scaling stage (to proper
−286 / +714 mV NTSC range) is a follow-on once the raw signal is verified.

## Bill of materials

| Qty | Part | Value | Tolerance | Notes |
|---:|---|---|---|---|
| 7 | Resistor "R" | 1.0 kΩ | 1% metal film | Rung resistors |
| 9 | Resistor "2R" | 2.0 kΩ | 1% metal film | 8 series + 1 termination |
| 1 | 2×6 right-angle header | 2.54 mm pitch | — | Pmod JC connector |
| 1 | Perfboard | 2.54 mm grid, ~30×60 mm | — | Or scrap |
| 1 | 2-pin header | 2.54 mm | — | Scope probe output |
| ~ | Wire (24 AWG) | — | — | Bus lines + jumpers |

**On resistor values:** 1k/2k gives ~5 ns RC settling (set by ~5 pF node
parasitics) — adequate at 18.5 ns sample period for 54 MS/s. Avoid 10k/20k:
settles in ~50 ns, smears the 3.58 MHz colorburst and luma edges.

## Pmod JC pinout (looking at the connector from above the PCB)

```
              ┌─────────────────────────────────────────────────┐
   Top row    │  JC1   JC2   JC3   JC4   JC5    JC6             │
   (pins 1-6) │  V15   W15   T11   T10   GND    +3V3            │
              │  ●     ●     ●     ●     ●      ●               │
              │                                                  │
              │  ●     ●     ●     ●     ●      ●               │
   Bottom row │  W14   Y14   T12   U12   GND    +3V3            │
   (pins 7-12)│  JC7   JC8   JC9   JC10  JC11   JC12            │
              └─────────────────────────────────────────────────┘
                                ▲
                       (notch / key — orient header this way)
```

DAC bit assignment (from `constraints/zybo_z7_20.xdc`):

```
  dac_pmod[7]  MSB ─ JC1   weight 128
  dac_pmod[6]      ─ JC2   weight  64
  dac_pmod[5]      ─ JC3   weight  32
  dac_pmod[4]      ─ JC4   weight  16
  dac_pmod[3]      ─ JC7   weight   8
  dac_pmod[2]      ─ JC8   weight   4
  dac_pmod[1]      ─ JC9   weight   2
  dac_pmod[0]  LSB ─ JC10  weight   1
  GND              ─ JC5  (or JC11 — same net)
  +3V3             ─ JC6/JC12  ✗ do NOT use; not needed
```

## R-2R ladder schematic

Standard MSB-at-top topology. Each bit input passes through a "2R" series
resistor onto a shared ladder; adjacent ladder nodes are tied by "R"; the
LSB end terminates with "2R" to ground.

```
                                                      ┌───► Vout (scope probe tip)
                                                      │
                                                     [R 1k]
                                                      │
   JC1  dac[7] MSB ─[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC2  dac[6] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC3  dac[5] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC4  dac[4] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC7  dac[3] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC8  dac[2] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC9  dac[1] ────[2R 2k]────────────────────────── ┤
                                                      │
                                                     [R 1k]
                                                      │
   JC10 dac[0] LSB ─[2R 2k]────────────────────────── ┤
                                                      │
                                                    [2R 2k]   ← termination
                                                      │
   JC5 / JC11 GND ─────────────────────────────────── ┴───► GND (scope probe clip)
```

Total: 7×R (1k) + 9×2R (2k) = 16 resistors.

## Perfboard layout (suggested)

One option: Pmod header along the LEFT edge, ladder running horizontally to
the right, output pickup on the FAR RIGHT. The ladder line is one
continuous horizontal "rung" bus with vertical taps to each Pmod pin.

```
   Pmod JC (left edge of board)                      OUTPUT (right edge)
   ┌────────┐                                          ┌───────┐
   │ JC1  ●─┼──[2R]──┐                                 │       │
   │ JC2  ●─┼──[2R]──┤  ← N7 node                      │  ●─── Vout
   │ JC3  ●─┼──[2R]──┤←── 2R termination               │       │
   │ JC4  ●─┼──[2R]──┤  to GND below                   │  ●─── GND
   │ JC5  ●─┼─[GND bus]                                └───────┘
   │ JC6  ●─┼─(NC)
   │                 [R][R][R][R][R][R][R]   ← rung resistors
   │ JC7  ●─┼──[2R]──┤  (one R between each pair of nodes)
   │ JC8  ●─┼──[2R]──┤
   │ JC9  ●─┼──[2R]──┤
   │ JC10 ●─┼──[2R]──┤
   │ JC11 ●─┼─[GND bus, same as JC5]
   │ JC12 ●─┼─(NC)
   └────────┘
                      └─[2R]─[GND bus]    ← termination to ground (below LSB tap)
```

That's the topology view. In actual perfboard real estate you'd:

- Run a continuous **ground bus wire** along one edge (connecting JC5, JC11,
  the termination 2R, and the output GND header).
- Run a continuous **ladder bus wire** along another edge — this is where
  every "2R" series resistor meets the "R" rung resistor below it.
- Each ladder node Ni gets three connections: the "2R" from its bit input,
  the "R" up to Ni+1, and the "R" down to Ni−1 (or the 2R termination at
  the LSB end, or the Vout pickoff at the MSB end).

## Build sequence

1. **Solder the Pmod header** with the long pins down so it presses into
   JC. Verify pin orientation against the photos — JC1 must align with
   pin 1 of the connector.
2. **Lay the ground bus**: a continuous wire from JC5 → JC11 → termination
   2R bottom → output GND pin. Soldered as a single net.
3. **Solder all 8 series 2R resistors**, vertically from each Pmod-pin
   landing to a single horizontal "ladder line" of perfboard pads.
4. **Solder the 7 rung R resistors** between each pair of adjacent ladder
   nodes (between bit 7's tap and bit 6's tap, etc.).
5. **Termination 2R**: from the node BELOW dac[0] (the bottom end of the
   ladder) to the ground bus.
6. **Output pickoff**: from the node ABOVE dac[7] (the top end of the
   ladder) up through one more R, then out to the output header signal pin.
7. **Visually verify**: count resistors (should be exactly 16), trace each
   net once with a fingertip, then continuity-check ground and Vout to
   confirm no shorts.

## Pre-power checklist

- [ ] Zybo SW4 OFF
- [ ] Pmod header plugged into JC, oriented correctly (JC1 corner matches)
- [ ] Scope probe attached: tip to OUT signal, clip to OUT GND
- [ ] Scope: **DC coupled**, **500 mV/div**, **10 µs/div**, trigger on
      falling edge ~0 V (sync tip), 1 MΩ input impedance
- [ ] Power Zybo on (SW4)

## Expected scope readings (raw, no op-amp)

Output is unipolar 0–3.3 V. DAC code → voltage:

| DAC code (8-bit) | Voltage | Meaning |
|---:|---:|---|
| 0   | 0.00 V | Sync tip (becomes −286 mV after op-amp) |
| 73  | 0.94 V | Blanking (becomes 0 mV) |
| 87  | 1.12 V | Black setup, 7.5 IRE (becomes +54 mV) |
| 165 | 2.13 V | 50 IRE gray (becomes +357 mV) |
| 255 | 3.29 V | Peak white, 100 IRE (becomes +714 mV) |

One horizontal line at SW0=0, SW1=1 (pattern_sel=10 = bars, default):

```
3.3 V ┤              ┌─────┐
      │              │bar1 │
      │              │ 77  │┌────┐
      │              │ IRE ││bar2│
2.0 V ┤              │     ││ 69 │ ...     ┌────┐
      │              │     ││ IRE│         │bar7│
      │              │     ││    │         │ 15 │
0.95 V┤────┐        ┌┘     └┘    │         │ IRE│┌──── (blanking)
      │    │        │ back porch └─────────┴────┘
      │    │ sync   │ + burst region (no chroma yet — Phase 4)
      │    │ pulse  │
0.0 V ┤    └────────┘
      └─────────────────────────────────────────────────────► t
      0    1.5    6.2  10.9                              63.6 µs
      │ front │sync│back│         active video             │
      │ porch │    │porch│        (7 luma bars)            │
```

Every ~21 lines, the H-pulse pattern changes briefly (VBI: equalizing
pulses, broad V-sync with serrations). On a slow timebase (5 ms/div),
that VBI region is the visible "dip" once per frame at 24 Hz.

## Common build mistakes

| Symptom | Likely cause |
|---|---|
| All 3.3 V (constant) | All DAC pins floating — Pmod header off by one row, or LSB tied to power |
| All 0 V (constant) | Ladder shorted to ground somewhere, OR every series-2R missing |
| Staircase but wrong order (e.g., bars reversed) | Pin ordering: MSB and LSB swapped in your wiring |
| Smeared/rounded edges | Resistor values too high (>5k) — replace with 1k/2k |
| Ringing / oscillation | Long unshielded lead between board and scope, or scope input set to 50 Ω |

## Next: the op-amp scaling stage

To drive a real CRT we need to convert 0-3.3 V (R-2R out) into the
standard NTSC composite range of −286 / +714 mV at 75 Ω source impedance.
That's a separate small board: one rail-to-rail op-amp (e.g. LMH6643),
a couple of resistors for gain (~0.303) and offset (−0.286 V), a 75 Ω
series resistor, and a BNC connector. Document and BOM for that stage
will come once the R-2R is verified on the scope.
