# 02 — System Architecture

## Signal path, end to end

```mermaid
flowchart LR
    subgraph HOST[Laptop]
        GPU[GPU / DP source]
        APP["Config app (optional)\nUSB HID"]
    end

    subgraph BOX[Crossover box]
        direction TB
        CC["USB-C port\n(DP Alt Mode 4-lane +\nUSB2 sideband)"]
        MST["DP1.4 MST hub/sink\n1 DP in -> 2 streams"]
        subgraph CH1[Channel 1]
            RX1[DP/HDMI RX]
            MAP1["FPGA: format conv\nST2082 mapping\naudio embed (ST299)\nST352 payload ID"]
            DRV1[12G-SDI cable driver]
        end
        subgraph CH2[Channel 2]
            RX2[DP/HDMI RX]
            MAP2["FPGA: format conv\nST2082 mapping\naudio embed\nST352 payload ID"]
            DRV2[12G-SDI cable driver]
        end
        MCU["Mgmt MCU\nEDID emulation\nUSB HID\nOLED/LED"]
    end

    GPU -- "DP Alt Mode" --> CC --> MST
    MST -- "stream A" --> RX1 --> MAP1 --> DRV1 --> BNC1["BNC OUT 1"]
    MST -- "stream B" --> RX2 --> MAP2 --> DRV2 --> BNC2["BNC OUT 2"]
    APP <-- "USB2" --> CC <--> MCU
    MCU -- "EDID/DDC" --> MST
    MCU -- "config/status" --> MAP1 & MAP2
```

## Block-by-block

### 1. USB-C front end
- USB-C receptacle wired for **DisplayPort Alt Mode**. A USB-C **PD/Alt-Mode
  controller** (CC-line negotiation) requests **4-lane DP** configuration.
- **Why 4-lane:** two independent 4K streams do not fit in 2-lane DP (see
  budget below). 4-lane DP Alt Mode means the SuperSpeed USB pairs are
  repurposed for DP, leaving **USB 2.0** for the management sideband — which is
  all we need for HID config (no high-rate USB data path in v1).
- Sideband: USB 2.0 D+/D- → management MCU as a **USB HID + vendor** device.

### 2. DP MST hub / sink (the "two displays" trick)
- A **DP 1.4 Multi-Stream Transport** hub takes the single DP link and exposes
  **two sink endpoints** to the host. The GPU then drives two logical displays.
- Equivalent commercial topology: the MST-hub chips used in USB-C → dual-HDMI
  docks. Output of the hub is two HDMI 2.0 / DP streams feeding the conversion
  stage.
- Each endpoint owns its **EDID/DDC channel**, which the management MCU
  controls — this is where EDID/frame-rate management lives (see `03`).

### 3. Per-channel conversion (FPGA)
The HDMI/DP-to-SDI conversion is done in an **FPGA** because it needs runtime-
reconfigurable control of timing, payload ID, color, and EDID — fixed-function
bridge silicon can't expose that. Per channel the FPGA:
1. Receives the HDMI 2.0 / DP stream (FPGA transceiver + HDMI/DP RX core).
2. **Maps to SMPTE serial-digital:** ST 2082-10 (12G, 2160p50/59.94/60),
   ST 2081 (6G, 2160p ≤30), ST 425 (3G, 1080p), ST 292 (HD).
3. **Embeds audio** (ST 299 audio data packets) from the DP/HDMI audio stream.
4. Inserts **ST 352 payload identifier** and any ancillary (VPID, RP188 TC if
   sourced).
5. Serializes to the cable driver at the SDI line rate.

A single mid-size FPGA with ≥4 multi-gigabit transceivers handles **both**
channels (2 RX + 2 TX serial links). One FPGA, two pipelines.

### 4. SDI cable drivers
- One **12G-SDI cable driver** per output → 75Ω BNC. Auto rate 12G/6G/3G/HD/SD.
- Optional **reclocker** if jitter budget requires it before the driver.

### 5. Management MCU
- **EDID emulation** for both sink endpoints (writable EDID, profile store).
- **USB HID** endpoint for the config app.
- Drives **status LEDs** and optional **OLED**.
- Configures the FPGA pipelines (output format lock, color range, audio
  routing) over a control bus (SPI/I2C/UART).

## Link-bandwidth budget

**DP 1.4 HBR3, 4 lanes:** 4 × 8.1 Gbit/s = 32.4 Gbit/s raw → ×0.8 (8b/10b) =
**25.92 Gbit/s usable**, shared across both MST streams.

Per-stream active video rate (pixel rate × bits/pixel; blanking adds overhead
but illustrates feasibility):

| Format | Pixel rate | bits/px | Rate/stream | **Two streams** | Fits 4-lane HBR3? |
|---|---|---|---|---|---|
| 1080p59.94 4:2:2 10b | 124 Mpx/s | 20 | 2.49 Gb/s | 4.97 Gb/s | ✅ trivially |
| 2160p30 4:2:2 10b | 249 Mpx/s | 20 | 4.97 Gb/s | 9.95 Gb/s | ✅ easily |
| 2160p59.94 4:2:2 10b | 498 Mpx/s | 20 | 9.95 Gb/s | **19.9 Gb/s** | ✅ with blanking margin |
| 2160p59.94 4:4:4 8b | 498 Mpx/s | 24 | 11.94 Gb/s | 23.9 Gb/s | ⚠️ needs **DSC** or 4:2:2 |

**Headline capability:** two independent outputs up to **2160p59.94 4:2:2
10-bit** — which is exactly the color sampling 12G-SDI carries (ST 2082-10), so
nothing is lost in conversion. Full-4:4:4 dual-4K60 needs DP **DSC** and is a
stretch goal; everything at/below dual-4K60 4:2:2 is the design target.

**SDI side capacities (per output, single-link):**
- 12G (ST 2082-1, 11.88 Gb/s): 2160p 50 / 59.94 / 60.
- 6G (ST 2081): 2160p 23.98 / 24 / 25 / 29.97 / 30.
- 3G (ST 425): 1080p 50 / 59.94 / 60.
- HD (ST 292): 1080i / 720p / 1080p ≤30.

## Power

Dual 12G cable drivers + FPGA + MST hub is a **multi-watt** load (rough order:
FPGA 2–4 W, two 12G drivers ~1 W each, MST hub + housekeeping ~1–2 W →
**~5–8 W total**). A host USB-C port without a PD contract may only offer
~4.5–7.5 W, so **bus power is marginal for dual 4K**. Design decisions:

- Primary: negotiate **USB PD** to pull adequate power from the host where
  available.
- Fallback: a **secondary USB-C power-in** (or barrel) for hosts that won't
  source enough. The box should brown-out gracefully — e.g. allow dual 1080p on
  bus power, require aux power for dual 4K60.
- Power budget is an **open question** (`06`) pending real silicon current
  draw.

## Latency

Native DP Alt Mode + line-based SDI mapping is **sub-frame** (no frame buffer in
v1). Active FRC (Tier 2) adds ≥1 frame of buffering by definition — that is the
cost of true rate conversion and is opt-in.
</content>
