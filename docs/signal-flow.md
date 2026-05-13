# Schindler 2.0 — Signal Flow

**Status:** Draft 2026-05-13
**Sources:** [`01-spec.md`](01-spec.md), [`packaging-skus.md`](packaging-skus.md), `hdl/*.v`
**Working level:** functional block diagram, not schematic. Wire-level connectivity belongs in the KiCad carrier schematic (later).

**SKU scope:** the three diagrams describe the **Pro v2** architecture (full silicon stuffing). Mini v1 is a subset — same diagrams, with the SDI subsystem unpopulated, no dual SYNC OUT driver chain, no per-connector LED drivers, no rear-LCD wiring, and a simpler control plane (PetaLinux on Zynq drives a mono OLED + buttons directly instead of the RP2040 + BT817Q mezzanine). Mini-specific differences called out per-diagram. See [`packaging-skus.md`](packaging-skus.md) for SKU stuffing matrix.

This doc captures three views:

1. **Video signal path** — pixels from any input to any output.
2. **Sync / genlock subsystem** — how the output pixel clock locks to an external reference.
3. **Control plane** — Zynq PS, UI MCU, and how the operator drives the box.

Mermaid block diagrams render natively in GitHub. To edit: change the source between the ` ```mermaid` fences and the rendered diagram updates on push.

---

## 1. Video signal path

```mermaid
flowchart TB
    classDef in fill:#d9eaff,stroke:#3a6ea5,color:#000
    classDef decode fill:#fff4d9,stroke:#a58634,color:#000
    classDef sdi fill:#ffeed9,stroke:#a56234,color:#000
    classDef pipe fill:#e6f6e6,stroke:#3a8e3a,color:#000
    classDef term fill:#d9efe6,stroke:#2d7e64,color:#000
    classDef out fill:#ffe2e2,stroke:#a54040,color:#000

    subgraph IN[Inputs - rear panel connectors]
        HDMI_IN[HDMI IN<br/>Type A panel-mount]:::in
        SDI_IN[SDI IN BNC<br/>75 ohm]:::in
        CVBS_IN[Composite IN BNC<br/>75 ohm]:::in
        YPBPR_IN[Component IN BNCs<br/>3x 75 ohm YPbPr]:::in
    end

    subgraph DECODE[Front-end decoder chips]
        TPD_IN[ESD plus level shift<br/>TI TPD12S016PWR]:::decode
        LT8619C[HDMI 1.4 RX<br/>parallel RGB to FPGA<br/>Lontium LT8619C]:::decode
        GS3470[SDI RX<br/>recovers clock + VITC<br/>Semtech GS3470<br/>broadcast tier only]:::sdi
        ADV7280[Analog video decoder<br/>SD to BT.656 YCbCr 4:2:2<br/>ADI ADV7280AWBCPZ-M-RL]:::decode
    end

    subgraph FPGA[Zynq-7020 FPGA fabric on Trenz TE0720 SOM]
        subgraph PIPE[HD pipeline - RGB or YCbCr 4:2:2, up to 1080p60]
            SOURCE_MUX{{Source selector<br/>HDMI / SDI / Composite / Component / TPG}}:::pipe
            VDMA[AXI VDMA<br/>DDR3L HD frame buffer<br/>Xilinx IP]:::pipe
            SCALE[Polyphase scaler<br/>8-tap H / 4-tap V<br/>HD-to-SD or pass-through<br/>custom HDL]:::pipe
            COLOR[Color pipeline<br/>1D LUT then 3x3 matrix then trim<br/>custom HDL - Screenie port]:::pipe
            GEOM[Geometry warp<br/>pincushion / keystone / 4-corner<br/>custom HDL]:::pipe
            TPG[Test pattern generator<br/>SMPTE bars / PLUGE / grid / ramps<br/>hdl/sample_gen.v]:::pipe
            HD_BUS([HD signal bus<br/>processed video at master rate]):::pipe
        end

        subgraph TERM[Output terminal encoders - independent, concurrent]
            HDMI_TERM[HDMI passthrough terminal<br/>format match + rate convert<br/>HDCP gate via UI consent<br/>HDMI 1.4 TX TMDS serialize<br/>Xilinx free HDMI IP]:::term
            COMP_TERM[NTSC/PAL composite encoder<br/>HD-to-SD downconvert + cadence<br/>luma + chroma + sync<br/>hdl/vid_timing.v + vbi_gen.v +<br/>chroma_gen.v]:::term
            YPBPR_TERM[Component YPbPr encoder<br/>HD pass-through or SD downconvert<br/>custom HDL]:::term
            SDI_TERM[SDI TX terminal<br/>parallel HD video + clock<br/>to GS2962<br/>custom HDL]:::term
        end
    end

    subgraph OUT[Output chips + rear panel connectors]
        ADV7393[Output DAC<br/>composite/S-Video OR component<br/>I2C runtime mode select<br/>ADI ADV7393BCPZ-REEL]:::out
        OPAMPS[Output buffer op-amps<br/>OPA2350 SDTV + LMH6643 HD<br/>TI]:::out
        GS2962[SDI TX serializer<br/>3G-SDI<br/>Semtech GS2962<br/>broadcast tier only]:::sdi
        TPD_OUT[ESD plus level shift<br/>TI TPD12S016PWR]:::out
        CVBS_OUT[Composite OUT BNC<br/>75 ohm]:::out
        YPBPR_OUT[Component OUT BNCs<br/>3x 75 ohm YPbPr]:::out
        SDI_OUT[SDI OUT BNC<br/>75 ohm]:::out
        HDMI_OUT[HDMI OUT<br/>Type A panel-mount]:::out
    end

    HDMI_IN --> TPD_IN --> LT8619C --> SOURCE_MUX
    SDI_IN --> GS3470 --> SOURCE_MUX
    CVBS_IN --> ADV7280
    YPBPR_IN --> ADV7280 --> SOURCE_MUX
    TPG --> SOURCE_MUX

    SOURCE_MUX --> VDMA --> SCALE --> COLOR --> GEOM --> HD_BUS

    HD_BUS --> HDMI_TERM
    HD_BUS --> COMP_TERM
    HD_BUS --> YPBPR_TERM
    HD_BUS --> SDI_TERM

    HDMI_TERM --> TPD_OUT --> HDMI_OUT
    COMP_TERM --> ADV7393
    YPBPR_TERM --> ADV7393
    ADV7393 --> OPAMPS
    OPAMPS --> CVBS_OUT
    OPAMPS --> YPBPR_OUT
    SDI_TERM --> GS2962 --> SDI_OUT
```

**Notes**

- **The pipeline carries HD-bandwidth video throughout** (RGB or YCbCr 4:2:2, up to 1080p60 / 148.5 MHz pixel clock). Source resolution and rate are preserved through scaler / color / geometry; downconversion to SD or rate-conversion happens only inside the terminal encoder for outputs that demand it (composite, S-Video, SD component).
- **Outputs are independent and concurrent.** Same source video → multiple terminal encoders running simultaneously, each at its own format and rate. Example: 1080p60 HDMI source → 1080p60 HDMI OUT (passthrough) + NTSC composite OUT (downconvert + 5:2 cadence + encode) + HD component OUT (YPbPr) live simultaneously.
- **Terminal encoders are independent FPGA pipelines** consuming a shared HD signal bus. The composite encoder block contains the HDL we have today (`vid_timing.v`, `vbi_gen.v`, `chroma_gen.v`, `sample_gen.v`); HDMI / YPbPr / SDI terminals haven't been written yet.
- **HDMI OUT is full-quality HD passthrough** (1080p60 / 1080p24 / etc) — NOT a degraded monitoring view. **HDCP-protected content is blocked from HDMI OUT by default** at the HDMI passthrough terminal. Operator can override via a UI consent dialog ("I attest this is a non-violating use") which unlocks full-quality HDMI passthrough for protected content. Attorney-advised posture — keeps liability with the operator. Non-protected content flows through HDMI OUT without any gate.
- **`SOURCE_MUX`** picks one input (HDMI / SDI / composite / component) OR the internal test pattern generator. Operator selects via UI; TPG is the default at power-on before any source is connected.
- **ADV7393 composite/S-Video and component output are mutually exclusive at runtime** (I²C-switched). The COMP_TERM and YPBPR_TERM blocks feed into the DAC, but only the one matching the selected output mode is active on the analog BNCs at any moment.
- **SDI chips (GS3470, GS2962) are broadcast-tier only** — colored orange. Every V1 carrier has the footprints; broadcast units have them populated, base units do not. Daughter-card delivery on headers is the field-upgrade vector (see `01-spec.md` SDI daughter card section).
- **GS3470 also feeds the genlock subsystem** (SDI recovered clock + VITC extraction) — see diagram 2.
- **Phase 2 bring-up uses a degenerate version of this pipeline:** TPG → COMP_TERM directly (no scaler/color/geometry, no real source mux, no HD bus), driving the Zybo R2R DAC for first-light NTSC composite. The full HD pipeline is built incrementally after first-light.

---

## 2. Sync / genlock subsystem

```mermaid
flowchart TB
    classDef in fill:#d9eaff,stroke:#3a6ea5,color:#000
    classDef analog fill:#fff4d9,stroke:#a58634,color:#000
    classDef digital fill:#e6f6e6,stroke:#3a8e3a,color:#000
    classDef clk fill:#f0d9ff,stroke:#6f3aa5,color:#000
    classDef ctrl fill:#ffe2e2,stroke:#a54040,color:#000
    classDef sdi fill:#ffeed9,stroke:#a56234,color:#000
    classDef out fill:#ffd9c9,stroke:#a55a2c,color:#000

    subgraph REFIN[Reference inputs]
        REF_IN[REF IN BNC<br/>autosense - LTC / BB / tri-level<br/>75 ohm panel-mount]:::in
        REF_LOOP[REF LOOP BNC<br/>passive loop-through<br/>75 ohm panel-mount]:::in
        GS3470_REF[GS3470 SDI recovered clock + VITC<br/>same chip as diagram 1<br/>Semtech GS3470<br/>broadcast tier only]:::sdi
    end

    subgraph FE[Analog front-end - autosense path]
        CLAMP[Input conditioning<br/>clamp diodes + 75 ohm term +<br/>AC-coupled buffer +<br/>switchable analog LPF]:::analog
        PGA[2-channel PGA<br/>AGC loop driven by classifier<br/>ADI/LTC LTC6912CGN-2#PBF]:::analog
        ADC[Dual 10-bit 20 MSPS ADC<br/>ADI AD9204BCPZ-20]:::analog
    end

    subgraph CLASSIFY[Reference recovery - FPGA fabric on TE0720 SOM]
        AUTOSENSE[Autosense classifier<br/>LTC biphase mark +<br/>BB 15.734 kHz line rate +<br/>tri-level pulse signature<br/>custom HDL]:::digital
        LTC_DEC[LTC frame decoder<br/>biphase demod + 0xBFFC sync<br/>+ frame edge + TC parser<br/>custom HDL]:::digital
        BB_DEC[BB sync separator<br/>line + field + colorburst<br/>phase extract<br/>custom HDL]:::digital
        TRI_DEC[Tri-level decoder<br/>HD sync edge extractor<br/>custom HDL]:::digital
    end

    REF_MUX{{Reference selector mux<br/>operator override OR autosense priority<br/>LTC -> tri-level -> BB -> SDI -> free-run}}:::digital

    subgraph LOOP[Digital genlock loop core - FPGA]
        DIVN[Output divider /N<br/>match selected ref rate<br/>from master clock]:::digital
        PHASE_DET[Phase + frequency detector<br/>sample-and-hold edge comparator<br/>sub-line phase accuracy]:::digital
        LOOP_FILT[Loop filter<br/>configurable bandwidth<br/>default ~0.5 Hz<br/>playbook Ch. 8]:::digital
        INTEG[NCO / integrator<br/>holds last value on ref loss<br/>= free-run hold behavior]:::digital
        LOCK_DET[Lock detector<br/>phase-error magnitude +<br/>1 s stddev = quality metric<br/>state: Acquiring / Locked / Lost]:::digital
    end

    subgraph CLK[Master clock generation]
        RP2040[RP2040 slow-control<br/>I2C config of Si5351 + PGA gain<br/>autosense status + lock reporting]:::digital
        SI5351[Si5351 programmable<br/>3-channel clock generator<br/>ch0 to FPGA master<br/>ch1 + ch2 reserved]:::analog
        FPGA_MASTER[FPGA master clock<br/>locked to selected reference]:::clk
    end

    subgraph UI[Operator control + status]
        UIMCU[UI MCU front panel<br/>encoders + buttons + TFT<br/>source select + per-OUT config]:::ctrl
        ZYNQ_PS[Zynq PS<br/>web UI + REST API +<br/>state aggregator SSOT]:::ctrl
        STATUS[Rear LCD + per-connector LEDs<br/>selected source + lock state +<br/>quality metric + rates]:::ctrl
    end

    subgraph SYNCOUT[Dual SYNC OUT generation]
        ACC[Per-OUT phase accumulators 1 + 2<br/>independent format + rate]:::digital
        WAVE[Waveform gen per OUT<br/>BB / tri-level / LTC<br/>HW-ready for DARS / WC]:::digital
        DAC[12-bit DAC per OUT]:::analog
        DRV[75 ohm cable driver per OUT]:::analog
        OUT1[SYNC OUT 1 BNC]:::out
        OUT2[SYNC OUT 2 BNC]:::out
    end

    %% Reference signal path
    REF_IN --> CLAMP
    REF_IN -.passive.-> REF_LOOP
    CLAMP --> PGA --> ADC --> AUTOSENSE
    AUTOSENSE --> LTC_DEC
    AUTOSENSE --> BB_DEC
    AUTOSENSE --> TRI_DEC

    %% Reference selection
    LTC_DEC --> REF_MUX
    BB_DEC --> REF_MUX
    TRI_DEC --> REF_MUX
    GS3470_REF --> REF_MUX

    %% Closed PLL loop
    REF_MUX --> PHASE_DET
    FPGA_MASTER --> DIVN --> PHASE_DET
    PHASE_DET --> LOOP_FILT --> INTEG
    PHASE_DET --> LOCK_DET
    INTEG --> RP2040
    RP2040 --> SI5351 --> FPGA_MASTER

    %% Slow-control side
    AUTOSENSE -->|gain command| RP2040
    RP2040 -->|I2C| PGA

    %% Operator + status
    LOCK_DET --> ZYNQ_PS
    RP2040 <--> ZYNQ_PS
    UIMCU <-->|UART or SPI<br/>state sync| ZYNQ_PS
    ZYNQ_PS -->|source override| REF_MUX
    ZYNQ_PS -->|format + rate per OUT| ACC
    ZYNQ_PS --> STATUS

    %% Sync OUT path
    FPGA_MASTER --> ACC --> WAVE --> DAC --> DRV
    DRV --> OUT1
    DRV --> OUT2

```

**Notes**

- **The genlock loop is fully digital** — FPGA fabric implements the phase/frequency detector, loop filter, NCO/integrator, and lock detector. Si5351 is the only physical clock generator; the integrator's accumulated correction is pushed to Si5351 via RP2040 over I²C as slow-control updates.
- **No dedicated "SDI ref" input.** SDI reference is derived from the SDI VIDEO IN via GS3470's recovered clock + VITC extraction, on broadcast-tier units only. This unifies the SDI path: one input connector serves video data + reference. The earlier scoping treating SDI as its own ref-input channel is obsolete. The GS3470 block appears in both diagrams 1 and 2 — same chip, two roles — colored orange in both to indicate it's the broadcast-tier-only SDI silicon.
- **Autosense classifier** runs continuously on the 20 MSPS ADC stream; identifies signal type by characteristic signature (LTC biphase pattern, BB 15.734 kHz line rate + 3.58 MHz burst, tri-level pulse pattern) and routes the corresponding decoder output into the reference selector mux.
- **Per-format decoders** sit between the classifier and the mux:
  - `LTC_DEC` — biphase mark demod, sync word 0xBFFC detection, frame edge extraction, timecode parser
  - `BB_DEC` — sync separator (H/V/colorburst), line/field extraction
  - `TRI_DEC` — HD sync edge extractor for tri-level
  - `GS3470_REF` — recovered clock + VITC from GS3470 (broadcast tier only, orange); shown in REFIN as a separate "input" since conceptually it's a reference source even though physically it's the same chip handling SDI video data in diagram 1.
- **Reference selector mux** is operator-controlled via Zynq PS (front panel or web UI) with an autosense-priority fallback (LTC > tri-level > BB > SDI > free-run). Operator can pin a specific source or let autosense pick.
- **Loop filter bandwidth default 0.5 Hz** — slow enough to ignore reference jitter, fast enough to track drift (playbook Ch. 8). Configurable via UI for tighter tracking when needed.
- **NCO holds last value on reference loss** — produces free-run / hold behavior so the output stays clean while the operator reconnects or switches sources. Lock detector reports "Lost" state; UI flags the missing reference.
- **Lock detector** outputs a 3-state machine (Acquiring / Locked / Lost) plus a continuous quality metric (phase-error magnitude + 1 s standard deviation). Both flow up to Zynq PS, which aggregates and pushes to the rear status LCD, per-connector LEDs, front-panel UI MCU, and web UI.
- **Operator control surface (front panel + web UI):**
  - Reference source selection (auto / LTC / BB / tri-level / SDI / free-run / hold)
  - Loop filter bandwidth tweak (default / tight / wide)
  - Per-OUT format selection (BB / tri-level / LTC; DARS / WC hardware-ready)
  - Per-OUT frame rate selection (24 / 23.976 / 25 / 29.97 / 30, drop-frame TC modes)
  - Lock state + quality readout (real-time, on TFT and web UI)
- **Dual SYNC OUT design** — each OUT has its own FPGA phase accumulator ticking at the rate needed for its selected format and frame rate; both phase-locked to the master clock via rational ratios. Both can target independent rates simultaneously (V1.5 sync conversion absorbed into V1). Si5351 ch1/ch2 stay reserved (future GPSDO 10 MHz distribution).
- **DARS / Word Clock readiness** — waveform gen + driver chain support both as firmware-only future formats. Driver bandwidth DC to ~10 MHz, output swing ≥2 Vpp into 75 Ω. Word Clock at 1–2 Vpp, not vintage 5 Vpp CMOS — accepted by all modern WC inputs.
- **XLR balanced LTC IN/OUT dropped from V1**; LTC routes through the autosense BNC input or via OUT format selection.

---

## 3. Control plane

```mermaid
flowchart TB
    classDef ps fill:#d9eaff,stroke:#3a6ea5,color:#000
    classDef mcu fill:#fff4d9,stroke:#a58634,color:#000
    classDef ext fill:#e6f6e6,stroke:#3a8e3a,color:#000

    subgraph ZYNQ[Zynq PS - dual A9 under PetaLinux]
        WEB[Node.js web UI<br/>REST API plus mDNS plus OTA]:::ps
        EDID[EDID negotiation<br/>per HDMI/DP input]:::ps
        CONFIG[Config persistence<br/>JSON profiles]:::ps
        COLOR_JS[Color pipeline runtime<br/>Screenie codebase port]:::ps
        STATE[I/O state aggregator<br/>signal lock, rate, format, faults]:::ps
        PL_BRIDGE[AXI bridge to PL fabric]:::ps
    end

    subgraph REAR[Rear-panel display and LEDs]
        REAR_LCD[Rear status LCD<br/>NHD-1.5 240x240 IPS square<br/>ST7789VI controller, SPI<br/>1 s refresh, paginated summary]:::mcu
        TLC_LEDS[3x TLC59116F<br/>I2C LED drivers, 48 channels<br/>per-connector R/A/G + dimming]:::mcu
    end

    subgraph UIMEZ[Front-panel mezzanine board]
        RP2040_UI[RP2040 UI MCU<br/>reads inputs + sends EVE commands<br/>UART to Zynq PS]:::mcu
        BT817Q[BridgeTek BT817Q EVE 4<br/>graphics controller<br/>1 MB RAM_G frame buffer]:::mcu
        TFT_DRV[Front TFT<br/>NHD-2.9 960x376 IPS<br/>24-bit parallel RGB]:::mcu
        ENC[ALPS EC11 encoders<br/>x2 plus pushbuttons]:::mcu
        BTN[4 fixed buttons +<br/>2-3 quick-select]:::mcu
        FP_LED[Front status LED column<br/>mirrors rear LED state]:::mcu
    end

    subgraph EXTERNAL[External]
        BROWSER[Browser, mobile / desktop]:::ext
        WIFI[Laird LWB5+<br/>AP plus STA plus BLE]:::ext
        GBE[GbE on TE0720]:::ext
        BLE_APP[Companion app<br/>BLE pairing]:::ext
    end

    BROWSER --> GBE --> WEB
    BROWSER --> WIFI --> WEB
    BLE_APP --> WIFI

    WEB --> EDID
    WEB --> CONFIG
    WEB --> COLOR_JS
    COLOR_JS --> PL_BRIDGE
    CONFIG --> PL_BRIDGE

    STATE -->|SPI| REAR_LCD
    STATE -->|I2C| TLC_LEDS
    STATE <-->|UART<br/>state sync| RP2040_UI
    EDID --> STATE
    PL_BRIDGE --> STATE

    RP2040_UI <--> ENC
    RP2040_UI <--> BTN
    RP2040_UI --> FP_LED
    RP2040_UI -->|SPI command list| BT817Q
    BT817Q -->|24-bit parallel RGB| TFT_DRV
```

**Notes**

- Pi CM4 is **not** in V1 (dropped 2026-05-11). Zynq PS hosts everything Linux-side; front-panel mezzanine owns the front panel.
- **Front panel is its own mezzanine board** (revised 2026-05-11). RP2040 reads encoders + buttons + drives the front-panel LED column. EVE 4 (BT817Q) handles all graphics — RP2040 sends high-level draw commands; EVE holds the frame in 1 MB internal RAM_G and refreshes the NHD-2.9 over 24-bit parallel RGB autonomously. STM32H735 retires from V1. Mezzanine ↔ main carrier link is UART + power only.
- UI alive in <1 s from cold boot via RP2040 (no Linux dependency). Main system can take 15–30 s to boot Linux behind the scenes with progress bar shown on the front TFT.
- All AXI traffic from PS to FPGA fabric (color matrix loads, EDID writes, mode changes, register pokes) goes through `PL_BRIDGE` — a single memory-mapped region with sequence numbers for atomic updates, same pattern as NovaTool / Screenie config systems.
- **`STATE` is the single source of truth for per-I/O status** (lock, rate, format, fault). It feeds three sinks: rear-panel LCD (SPI), per-connector LED drivers (I²C), and the front-panel mezzanine RP2040 (UART state-sync). Front-panel LEDs mirror rear-panel LEDs so the operator sees identical state from front or back of the rack.

---

## TODO / refinements

- Add the V1.5 sync-conversion expansion blocks (LTC OUT, ref OUT, timecode-math module) — currently absent because spec marks them [PROPOSED] absorbed into V1.
- Add the SDI daughter card as a dashed-outline group in diagram 1 so the conditional population is visible.
- Add power tree as a fourth diagram (PSU → rails → consumers) once PSU style is decided.
- Once rear-panel I/O layout is settled, mirror it as a physical-panel diagram.
