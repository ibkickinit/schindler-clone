# Schindler 4K — scaler platform idea (memo)

> **Provenance:** written 2026-10-13 by a **separate Claude session working on the Crossover project**
> (`usbc-dual-sdi/`), **not by the main Schindler agent**. It records an idea Justin raised in that
> session so it's here when Schindler work resumes. **Not reviewed against the Schindler spec, not a
> decision, no Schindler code or plan was changed.** Treat it as input for a future Schindler session.

## The idea (Justin)

Pivot the Schindler video core into a **4K-capable scaler / frame-rate converter** for a **4K model**,
and **drop the composite/component/S-Video side** on that model. The existing 1080p Zynq-7020 CRT
product is unaffected.

## Why it's plausible

The Schindler HDL (newest on branch `v1-tsg`) already has bench-validated building blocks at 1080p:
frame buffer + tiled DMA, `pg_cadence` FRC (60/59.94/50/30/29.97/24 → 60), `pg_genlock` frame-follow,
8-tap polyphase scaler, `pg_compose` compositor, color/gamma, `pg_tsg` test patterns, `pg_osd`.
Crossover's "Pro" tier needs the same engine at 4K, so the widening work can be shared.
Module-by-module reuse map: `usbc-dual-sdi/docs/10-schindler-reuse-map.md`.

## What a 4K model would need (notes from the Crossover session)

| Area | Note |
|---|---|
| **Platform** | Zynq-7020 has **no multi-gigabit transceivers** → no 4K I/O, no in-FPGA SDI. Needs a GTH-class part. |
| **Control plane** | Schindler's PetaLinux/web UI/WiFi runs on the Zynq PS. Artix UltraScale+ has no ARM → either **Zynq UltraScale+ with GTH** (e.g. Kria K26-class; verify GTH count/cost) or **Artix US+ + small Linux SoC/MCU** (port the control plane). |
| **Pipeline width** | 1 px/clk 8-bit RGB → **4 px/clk @ 148.5 MHz, 10-bit YCbCr 4:2:2**. |
| **Scaler** | Currently **downscale-only** → add **upscaling** (HD → 4K is the main 4K-model use case). |
| **Memory** | One 4K60 channel through FRC with blending ≈ ~30 Gb/s → a 32-bit DDR4 is adequate (the Crossover bench board, Avnet AUBoard 15P, would work as a 4K bench). |
| **Warp/geometry** | 4K tile cache likely **won't fit** AU15P BRAM → scaler + FRC + color + genlock first; warp later / bigger part. |
| **SDI out** | Crossover is building an **in-house SDI TX** (no paid IP): `usbc-dual-sdi/hdl/sdi_tx/`, plan in `usbc-dual-sdi/docs/12-sdi-tx-plan.md`. On a GTH platform it replaces the GS2962 serializer; a **cable driver per output** is still needed. |
| **SDI in / reference** | GS3470's job (SDI input, SDI ref, VITC) is a **receiver** — separate, harder core (or an external 12G RX chip). |
| **HDMI/DP in** | External receiver chips (GSV2011-class HDMI 2.0; Lontium LT7911UXC DP 1.4) — no AMD IP. |
| **HDMI out** | External HDMI 2.0 TX chip (no AMD IP). |
| **Genlock** | Extend the existing genlock subsystem to tri-level/black-burst for 4K rates. |

## Product framing

Without CRT outputs the 4K model is a different product: a **4K FRC/scaler with camera genlock** for
sets (computer playback onto in-shot monitors / LED walls locked to the camera). Competes with the
Teranex / AJA FS class — **market check needed**.

**Open question for the Schindler line:** two platforms (1080p CRT on Zynq-7020 + 4K on a new part)
doubles maintenance — keep both, or eventually fold the CRT model into the 4K platform with an optional
analog board?

**Sequencing suggested from the Crossover side:** Crossover v1 (no frame buffer) first → shared 4-px/clk
FRC/scaler widening (+ upscaling) → Crossover Pro and Schindler 4K on top.
