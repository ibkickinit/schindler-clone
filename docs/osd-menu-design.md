# OSD Menu Generator — Design

Status: **design only** (2026-06-30). Builds on the proven `pg_tsg` text-banner overlay.

## Goal

An on-screen menu/overlay the firmware can drive at runtime — text + selection highlight, composited
over live video on **both** outputs, visible regardless of source. Used for: input/format readout,
the warp/color control menus, status (lock/rate/regime), and eventually a full settings UI on the
device itself (no web client needed).

## What the TSG text banner already proved (reuse directly)

The `pg_tsg` "SCHINDLER TSG" banner (commit `008eb25`) de-risked the hard mechanics on silicon:
- **BRAM glyph fetch with pixel-aligned registered read** (addr@T → data@T+1, select/region regs delayed
  to stay locked). 1 RAMB18, no warp-margin damage.
- **Composite-over-video** at the correct pixel position, **R-B-G byte order** aware (white/black are
  swap-invariant; colored OSD text must apply the `{R,B,G}` swap like the rest of the pipeline — see
  [[schindler_pipeline_rbg_byte_order]]).
- Offline asset generation (PIL → hex → BRAM init).

The OSD generalizes the banner from *one baked string* to *a dynamic, firmware-written grid*.

## Architecture (`pg_osd` — new module, OUTPUT-side compositor)

```
                          ┌─────────────────────────────────────────────┐
   firmware (AXI) ──write─▶│ char RAM (dual-port BRAM)                    │
                          │   ROWS×COLS cells of {char[7:0], attr[7:0]}  │
                          └───────────────┬─────────────────────────────┘
                                          │ cell = textram[ (py/CH)*COLS + (px/CW) ]
                                          ▼
   pixel (px,py) ─────▶ in-OSD? ──▶ char,attr ──▶ font ROM[char*CH + (py%CH)] ──▶ glyph bit
                                                                          │
   video_in ──────────────────────────────────────────────────────────┬─┴─ glyph? fg : (bg or video)
                                                                        ▼
                                                                    video_out
```

Three memories, one composite:
1. **Font ROM** (BRAM, `$readmemh`): e.g. 8×16 glyphs, 128 ASCII → 128×16 = 2048 bytes = 1 RAMB18.
   Indexed by `char*16 + glyph_row`. Rendered offline from DejaVuSansMono (same flow as the banner).
2. **Char RAM** (dual-port BRAM): `ROWS×COLS` cells, each `{char[7:0], attr[7:0]}` (16-bit).
   E.g. 30 rows × 80 cols = 2400 cells × 16b = 38 Kbit → 2 RAMB18. **Port A = firmware write** (AXI/GPIO),
   **Port B = render read**. This is what makes the menu dynamic without rebuilding the bitstream.
3. **attr byte**: `[2:0]` fg color idx, `[5:3]` bg color idx, `[6]` inverse (selection highlight),
   `[7]` blink (optional, frame-counter gated). A small 8-entry color LUT maps idx → 24-bit R-B-G.

### Render pipeline (per output pixel, fully pipelined like pg_tsg)

```
S0: in_osd = (px in [X0,X0+COLS*CW)) && (py in [Y0,Y0+ROWS*CH))
    col = (px-X0)/CW ; row = (py-Y0)/CH ; gx = (px-X0)%CW ; gy = (py-Y0)%CH
S1: cell  = charram[row*COLS + col]            (BRAM read)
S2: gbits = fontrom[cell.char*CH + gy]         (BRAM read; gx selects the bit)
S3: glyph = gbits[CW-1-gx]
    fg = clut[attr fg] ; bg = clut[attr bg] ; if(attr.inverse) swap(fg,bg)
    osd_px = glyph ? fg : bg
S4: out = in_osd ? (transparent_bg && !glyph ? video : osd_px) : video
```
Use power-of-two CW/CH (8×16) so `/CW`, `%CW` are shifts/masks — divide-free, same discipline as pg_tsg.
Two cascaded BRAM reads = 2 cycles; delay `in_osd`/coords/video alongside (the banner's exact pattern).

### Placement: OUTPUT-side, not in a source generator

The TSG banner lives **inside `pg_tsg`** (write side) so it only shows on the generated pattern. A real
OSD must overlay the **output** so it's visible over any source *and after the warp* — so `pg_osd` goes
near `axis_to_vid_io` on each output leg (post-color, post-warp), the same principle as
[[schindler_genlock_geometry_must_match]] ("image geometry belongs in the output compositor"). One
instance per output (HDMI / analog); they can share the font ROM, separate char RAM if the menus differ.

## Firmware interface

A small AXI/GPIO window into the char RAM + a control word:
- `osd_write(row, col, char, attr)` → one cell (Port A address+data).
- `osd_clear()`, `osd_puts(row, col, str, attr)`, `osd_box(...)`, `osd_highlight(row)` helpers.
- control GPIO: `osd_enable`, `osd_x0/y0` (position), optional global alpha for a future blend.
- A C menu layer (`osd_menu.c`): a tree of {label, type, get/set} that renders to the grid and maps the
  existing UART command verbs — so the on-device menu and the web UI drive the **same** control plane.

## Resource / timing budget (7020, on the v1-tsg substrate)

| Memory | Size | BRAM |
|---|---|---|
| Font ROM (128×8×16) | 16 Kbit | 1 RAMB18 |
| Char RAM (30×80×16) | 38 Kbit | 2 RAMB18 |
| Color LUT (8×24) | tiny | LUTs |

~3 RAMB18 per OSD instance. Current build BRAM is ~84% (117/140 tiles) — **2 instances (~6 RAMB18) is
tight but fits**; if not, share one char RAM, or shrink the grid (e.g. 16×40). Logic is small + fully
pipelined → no timing risk on the order of the warp paths. **Watch the warp margin** (the text banner
already showed congestion can squeeze `pg_re_0`); keep `pg_osd` floor-planned away from the warp column.

## Implementation status (2026-07-01)

- **OSD-1/2 compositor: BUILT + sim-proven + FLASHED** (`hdl/pg_osd.v`, `sim/pg_osd_tb.v`, in the regression suite).
  Output-side parallel-video compositor: derives active (hc,vc) from the incoming sync, renders a
  COLSxROWS grid of {inv, char} from a firmware-writable BRAM using the shared 8x16 font ROM,
  with per-cell inverse = selection highlight. `osd_en=0` = bit-passthrough. Verified: passthrough,
  black-box bg, glyph render.
- **Baseline font (2026-07-02, `305f4a9`)**: font ROM regenerated with a fixed baseline (PIL `anchor="ms"`)
  so glyph bottoms align and descenders (q,y,p,g,j) hang — was per-glyph vertically centered.
- **Auto-scale + auto-center (2026-07-02, `b71b589`, WNS +0.286, flashed)**: pg_osd now measures the active
  region from the incoming sync (width latched at active-falling, height at vsync) and adapts to the output
  resolution: **2× cells for ≥1600-wide (1080p), 1× for smaller (720p)**, box **auto-centered** in the
  measured region (no hardcoded X0/Y0). Divide-free — cell coords use a scale-dependent shift (`s2`).
  Defaults to 1080p until first measured. Sim-verified both paths (1× @160w box=1024px, 2× @1620w box=4096px);
  bench-confirmed rendering centered on the monitor (Brio). Re-centers live on a resolution change.
- **Remaining to a live menu:**
  1. BD integration (main build): insert on the HDMI parallel bus — `axis_to_vid_io_0/vid_data` +
     sync -> `pg_osd` -> `rgb2dvi/vid_pData`. Runs on `clk_wiz_pixclk_out` (74.25 MHz). Add a GPIO for
     `osd_load[19:0]` {strobe,inv,addr,char} + `osd_en` (new axi_gpio on a fresh interconnect master
     port, same pattern as axi_gpio_21). pg_osd's ld_q1/2/3 CDC handles FCLK->pixclk (false-path ld_q1/D).
  2. Firmware: `osd_put(row,col,str,inv)` grid writer + a menu tree (`osd_menu.c`) bound to the existing
     UART control verbs; `osd.menu.*` daemon methods.
  3. Navigation: web-driven first (daemon nav up/down/select/back), physical rotary/buttons later.

## Phasing

0. **OSD-0 — runtime-editable banner text** (requested 2026-06-30; the recommended first slice).
   Today the `pg_tsg` banner is a BAKED bitmap ROM (PIL renders "EDGERLY TSG" → BRAM init at synth), so
   changing the text needs a rebuild. Replace it with the minimal OSD path: an **8×16 font ROM** (1 RAMB18)
   + a tiny **firmware-writable char buffer** (e.g. 24 chars × 8-bit = one small dual-port BRAM or even a
   set of GPIO/AXI-BRAM words). Firmware writes ASCII codes; the banner renderer does char-buffer →
   font-ROM → glyph, exactly like the full OSD but with ONE fixed line and no navigation. Wire a UART/daemon/
   UI control (`E n <text>` or a text field in the Source panel → firmware writes the char buffer). This
   de-risks the font-ROM + char-buffer mechanics for the full OSD below, and directly delivers the
   user-adjustable banner. Est: ~1 build (font-gen offline like the current banner; HDL swap the ROM read
   for font-lookup; firmware char-buffer writer; small UI field). Keeps white/black (swap-invariant).
1. **OSD-1**: `pg_osd` with a static-from-firmware char RAM + 8×16 font ROM, mono (white/black),
   on the HDMI output only. Reuse the banner's font-gen + BRAM-read code. Verify with a "HELLO" write.
2. **OSD-2**: color attrs + selection highlight (inverse). Wire `osd_puts`/`osd_highlight` helpers.
3. **OSD-3 — BUILT + bench-verified 2026-07-02** (`7d09911` firmware, `696b37c` daemon/web). A single-
   level list menu rendered into the pg_osd grid, bound live to the control globals: Source, Pattern,
   Bright, Saturat, Gamma, Temp, Chroma, Mono. Each change calls the SAME setter the UART verbs use, so
   menu and CLI stay in sync. Nav verbs `Y m o|x|u|d|-|+` (open/close, up/down, dec/inc) — grouped under
   the OSD verb `Y`, NOT `M` (already the warp mip-fill/Mackin-blend verb; that collision made a first
   `M` branch dead code). Daemon `osd.menu {action: open|close|up|down|dec|inc}`; web UI Menu row
   (Open/▲/▼/−/＋/Close). Verified browser→daemon→firmware end-to-end (pattern 0→3). Deferred: submenus,
   physical rotary/buttons, mirror to analog output, live value read-back into the web UI.
4. **OSD-4** (optional): semi-transparent background blend (global alpha) for overlay-on-video menus.

## Open questions

- **Input device** for on-device navigation: a rotary/buttons on the carrier, or stay web-driven and use
  the OSD as readout-only first? (OSD-1/2 are useful as pure readout even before navigation exists.)
- **Char RAM write transport**: a dedicated AXI BRAM port (clean, needs a BD AXI-BRAM-ctrl) vs the
  existing GPIO-command path (slower, but no new AXI plumbing). GPIO is fine for menus that change a few
  cells per interaction; full-screen redraws want the AXI port.
- Per-output char RAM vs shared (do HDMI and analog ever show different menus simultaneously?).
