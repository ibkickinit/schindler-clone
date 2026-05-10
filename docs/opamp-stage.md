# Op-amp Output Stage

Converts the R-2R DAC's 0–3.3 V output into a properly-impedance-matched
composite video signal driving a 75 Ω BNC. After this stage you can connect
a CRT, PVM, or scope-with-termination directly.

**Goal:** 1.0 Vpp at the 75 Ω-terminated load, AC-coupled. CRT/PVM internal
clamping circuits restore the DC reference (sync tip → −286 mV). Single
+5 V supply, two op-amps, ~10 components total.

> First-light note: this version is **AC-coupled**, which means the absolute
> DC voltage levels at the scope won't read as the canonical NTSC values
> (sync tip won't measure −286 mV on a DC-coupled scope without a 75 Ω load
> doing the clamping). The CRT sees the right *shape* and clamps correctly.
> A future DC-accurate variant (dual supply) is sketched at the bottom of
> this doc.

## Topology overview

```
  R-2R OUT ─► U1 (buffer) ─► [resistive divider 0.606] ─► U2 (buffer)
                                                              │
                                                              ▼
                                                          [Ccouple]
                                                              │
                                                              ▼
                                                          [75 Ω series]
                                                              │
                                                              ▼
                                                          BNC OUT
                                                          (to 75 Ω load)
```

Rationale for each block:

- **U1 (input buffer)** — R-2R has ~1 kΩ source impedance; we don't want
  the divider loading it. Op-amp follower presents MΩ input Z, drives the
  divider from low Z.
- **Resistive divider 0.606** — scales 0–3.3 V down to 0–2.0 V. The 2.0 Vpp
  source level, halved by 75 Ω source + 75 Ω termination, gives 1.0 Vpp at
  the CRT (= proper NTSC composite swing).
- **U2 (output buffer)** — re-buffers after the divider so the source
  impedance entering the 75 Ω series resistor is essentially 0 Ω. Without
  this, the divider's ~1.3 kΩ output Z would form an unintended divider
  with the 75 Ω + 75 Ω load.
- **Ccouple** — AC-couples the output. Strips the ~+1.0 V DC bias so the
  CRT's clamp circuit can re-establish blanking and sync tip at the right
  absolute voltages.
- **75 Ω series** — source impedance matching for the 75 Ω composite cable.

## Bill of materials

| Qty | Part | Value | Notes |
|---:|---|---|---|
| 1 | Op-amp, dual rail-to-rail input+output | **OPA2350** (TI) | 38 MHz GBW, single +5 V, DIP-8 hand-solderable |
| 1 | Decoupling cap | 100 nF (0.1 µF) | Ceramic, across op-amp Vcc/GND |
| 1 | Bulk cap | 10 µF | Electrolytic or tantalum, near op-amp |
| 1 | Divider R1 | 2.2 kΩ | 1% metal film |
| 1 | Divider R2 | 3.3 kΩ | 1% metal film |
| 1 | Output coupling cap | 10 µF | Electrolytic, low-ESR; or 4.7 µF tantalum |
| 1 | Series R | 75 Ω | 1% metal film; do not substitute 100 Ω |
| 1 | BNC connector | Female, chassis or PCB mount | 75 Ω composite standard |
| ~ | 8-pin DIP socket | optional | Avoids resoldering if op-amp dies |
| ~ | Power input header | 2-pin | +5 V + GND from bench supply or Zybo Vbus |

### Op-amp alternatives

If OPA2350 isn't to hand, the requirements are:
- **Single +5 V supply capable** (or up to ±15 V)
- **Rail-to-rail output** (must reach within ~50 mV of both rails)
- **GBW ≥ 30 MHz** (for clean burst + edges at 3.58 MHz subcarrier)
- **Slew rate ≥ 20 V/µs**

Acceptable substitutes (DIP-8 dual):
- **MCP6022** (TI/Microchip) — 10 MHz, marginal for burst, OK for sync-only first test
- **AD8042** — 160 MHz, dual, but only 6 V max supply (still works on +5 V)
- **LMH6645** — single, 55 MHz, SOIC only — needs ×2 + SMD adapter

Anything labeled "video op-amp" with the right supply range will work.

## Design math

**Gain target:**
- Input range: 0 – 3.3 V (R-2R 8-bit output)
- Source target: 2.0 V pp at the op-amp's output, before AC coupling
- Through 75 Ω series + 75 Ω cable termination: 50/50 divider → 1.0 V pp at the load
- That 1.0 V pp is NTSC composite's standard sync-to-white swing

**Divider ratio:** 2.0 / 3.3 = **0.606**

With R1 = 2.2 kΩ, R2 = 3.3 kΩ:
- Ratio = R2 / (R1 + R2) = 3.3 / 5.5 = **0.600** (within 1% of target — fine)
- Output range: 0 – 1.98 V (≈ 2.0 V)
- Sync tip (DAC code 0) → 0.0 V
- Blanking (code 73) → 0.55 V
- Peak white (code 255) → 1.94 V

After AC coupling (DC removed), centered around 0 V:
- Sync tip → −0.55 V
- Blanking → 0.00 V (DC reference)
- Peak white → +1.39 V
- Total swing 1.94 V pp at source; 0.97 V pp at 75 Ω load — close enough to 1.0 V pp NTSC standard.

**Coupling cap value:** Needs to pass the lowest video frequency component
(field rate, 24 Hz) without significant attenuation. Cutoff frequency
f_c = 1 / (2π·R·C) where R = 75 + 75 = 150 Ω (worst case, with load).

- C = 10 µF, R = 150 Ω → f_c = 106 Hz. Plenty of margin below 24 Hz.

Use **non-polarized** if possible, since the signal swings around 0 V. If
electrolytic, orient `+` toward the higher average DC (op-amp side).
Tantalum is ideal: small, non-polarized in practice for low ripple.

## Schematic

```
                                                                    
    +5V ─┬──┬──[100nF]──┬─ GND                                       
         │  │           │                                            
         │  └──[10µF]───┤                                            
         │              │                                            
         │  ┌───────────┘                                            
         │  │   ┌──────┐                                             
         ├──┴───┤ V+   │   U1 (½ of OPA2350)                         
         │      │      │   unity gain buffer                         
         │   ┌──┤ +    │                                             
   R-2R ─┼───┤  │      ├───┬──── U1_OUT (0–3.3 V, low Z)             
   in    │   │  │      │   │                                         
         │   │  │ −    ├───┘                                         
         │   │  │      │                                             
         │   │  │ V−   │                                             
         │   │  └──────┘                                             
         │   │     │                                                 
         │   │     GND                                               
         │   │                                                       
         │   │                                                       
         │   │  ┌─────[R1 = 2.2k]─────┐                              
         │   └──┤                     │                              
         │      │                     │                              
         │      └──[R2 = 3.3k]──┐     │                              
         │                      │     │                              
         │                     GND    │                              
         │                            │                              
         │                            │  Vmid (0–2.0 V at this node) 
         │      ┌──────┐              │                              
         ├──────┤ V+   │   U2 (other ½ of OPA2350)                   
         │      │      │   unity gain buffer                         
         │   ┌──┤ +    │                                             
         │   │  │      │              │                              
         │   │  │      ├──────────────┘                              
         │   │  │      │                                             
         │   │  │      ├───┬──── U2_OUT (0–2.0 V, low Z)             
         │   │  │ −    │   │                                         
         │   │  │      ├───┘                                         
         │   │  │ V−   │                                             
         │   │  └──────┘                                             
         │   │     │                                                 
         │   │     GND                                               
         │                                                           
         │                       │                                   
         │                  [Ccouple = 10µF]                         
         │                       │                                   
         │                       ▼                                   
         │                  [Rseries = 75Ω]                          
         │                       │                                   
         │                       ▼                                   
         │                  ●  BNC center pin                        
         │                                                           
         GND ───────────────●  BNC shield                            
```

The "two halves of OPA2350" notation: pins 1/2/3 = U1 (out/−/+),
pins 5/6/7 = U2 (+/−/out), pin 4 = V−, pin 8 = V+. Standard DIP-8
dual op-amp footprint.

## Power supply

**+5 V** is the only supply needed.

Easy options:
1. **From Zybo USB-power rail** — there's a 5 V USB rail on the Zybo. You'd
   solder a wire to a 5 V test point or use a Pmod that exposes 5V.
   Risk: noisy (FPGA load on the same rail); decoupling matters.
2. **Bench supply** — cleanest. Set to 5.0 V, current limit 100 mA.
3. **USB wall wart + barrel jack** — convenient for portable demo. Make
   sure it's regulated to 5 V.

**Decoupling is mandatory:**
- 100 nF ceramic right at the op-amp's pin 8 (V+)
- 10 µF bulk within 25 mm of the op-amp

Without decoupling, the op-amp will oscillate at the supply impedance.

## Build sequence

1. Solder DIP-8 socket (optional but recommended) at one end of the perfboard.
2. Solder the two decoupling caps directly between V+ pin and a ground bus.
3. Bring in +5 V and GND on a 2-pin header at the same end.
4. R1 (2.2 k) from U1 output to the divider midpoint node.
5. R2 (3.3 k) from the divider midpoint node to ground bus.
6. Jumper wire from divider midpoint to U2's V+ input (pin 5).
7. U2 V− (pin 6) tied to U2 output (pin 7) — unity gain feedback.
8. U1 V− (pin 2) tied to U1 output (pin 1) — same.
9. U1 V+ (pin 3) gets input wire from R-2R Vout. Make this lead short.
10. U2 output (pin 7) → 10 µF cap (+ toward op-amp) → 75 Ω → BNC center pin.
11. Ground bus → BNC shield.
12. **Plug in the op-amp last.** Power on bench supply, check for ~+5 V
    on pin 8 with a multimeter, then insert chip.

## Scope verification

Three checkpoints from input to output:

| Probe location | Coupling | What you should see |
|---|---|---|
| **R-2R out (U1 input)** | DC | 0–3.3 V composite-shaped, big 3.3 V sync excursions |
| **U2 output (before Ccouple)** | DC | 0–2.0 V same shape, scaled by 0.606 |
| **After Ccouple, no load** | DC | −1 V to +1 V centered at 0 V (no DC bias) |
| **After Rseries with 75 Ω termination at probe** | DC | −0.5 V to +0.5 V (1.0 V pp at the load) |

Sanity checks:
- Signal **shape** at each stage should be identical (just scaled & DC-shifted)
- **Edges** should be clean — no ringing, < 50 ns rise/fall
- **Burst region** (3.58 MHz sine on back porch) should show ~9 visible cycles, not smeared
- **Sync tip** at the load (after termination) should sit at exactly −0.5 V on a DC-coupled scope with 75 Ω termination on the probe

If burst is smeared but sync is sharp, op-amp GBW is too low — swap op-amp.

## Common build issues

| Symptom | Likely cause |
|---|---|
| Output stuck at +5 V or 0 V | Op-amp inserted wrong way (pin 1 not in pin-1 socket) |
| Output is right shape but only 0.5 V swing | 75 Ω terminating elsewhere; check that you're not double-terminating |
| Square wave at 100 kHz + signal | Op-amp oscillating — insufficient decoupling; add more 100 nF |
| DC offset on AC-coupled output | Coupling cap leakage; replace with film or tantalum |
| Black levels rising during high-content lines | Coupling cap value too small; signal averaging shifts DC |
| Mirror-image of input | Inverting op-amp by mistake; verify V+ and V− pin assignments |

## Future: DC-accurate variant (dual supply)

For Schindler-authentic output (sync tip at exactly −286 mV on a
DC-coupled scope, no AC-coupling cap), the topology changes to:

- **Dual supply** ±5 V (or ±12 V)
- **Single op-amp** with gain 0.303 and DC offset −286 mV
- Implemented as inverting summer with a reference voltage from a divider on the negative rail

This is a separate doc when we get there. The AC-coupled variant in this
doc is sufficient for first-light CRT lock and for all hobbyist-scope
verification work.

## Summary

```
parts:  1× op-amp + 5 resistors + 3 caps + 1 BNC + 1 power input = ~$10
power:  single +5 V at <50 mA
output: 1.0 V pp into 75 Ω, AC-coupled, ready for CRT / PVM / scope
limit:  absolute DC levels not NTSC-spec until DC-accurate variant
```
