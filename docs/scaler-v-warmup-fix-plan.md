# scaler_v top-of-frame warmup — future fix plan

## Problem
At each new input frame, scaler_v's tap rotation reads from lbufs that still
hold the LAST 4 rows of the previous frame. The MAC mixes new-frame top with
old-frame bottom, producing a 2-3 row band of wrong colors at the top of
every output frame.

For a static SMPTE pattern with PLUGE strip at source-bottom: the mix shows
as a dim band of weird hues at the top of every output frame (visible as
the "Black>White>Black" sliver the user reported).

## Why iter3g failed
The straightforward fix tried in iter3g — gate `m_axis_tdata` with a
`warmup_suppress` counter, output `24'h000000` for first 3 emit rows —
worked for the cosmetic suppression (top rows became black) but mysteriously
attenuated the B channel everywhere else in the frame (mean B fell from
~100 to ~57 across all pixels). The corruption pattern was inconsistent
(not a clean ratio), suggesting timing-related: WHS was a tight +0.014 ns
and possibly violated for specific bits of the B channel.

The hypothesis: adding a 24-bit ternary mux on the m_axis_tdata register
disrupted Vivado's preferred routing/placement of that register (which had
been packed efficiently near the MAC outputs), introducing a hold-time
violation on the path from MAC bit-output → register.

## Better approach — per-lbuf fresh tracking

Instead of gating the OUTPUT of the MAC, gate the INPUTS. The MAC always runs
on its inputs; during warmup, taps that point to UNREFRESHED lbufs are forced
to zero. The conditional is on the input side (4 small muxes feeding the MAC),
which Vivado handles more uniformly than an output-side wide mux.

```verilog
reg [3:0] lbuf_fresh;  // bit N: lbuf N has been written with current-frame data

always @(posedge clk) begin
    if (!rstn) begin
        lbuf_fresh <= 4'h0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        if (s_axis_tuser) begin
            lbuf_fresh <= 4'h0;  // new frame: all stale
        end
        if (s_axis_tlast) begin
            lbuf_fresh[in_row[1:0]] <= 1'b1;  // this lbuf just got fresh data
        end
    end
end

// In stage 0 BRAM-read latching, gate by fresh bit:
if (emit) begin
    tap_lbuf0_q <= lbuf_fresh[0] ? lbuf0[out_col] : 24'h0;
    tap_lbuf1_q <= lbuf_fresh[1] ? lbuf1[out_col] : 24'h0;
    tap_lbuf2_q <= lbuf_fresh[2] ? lbuf2[out_col] : 24'h0;
    tap_lbuf3_q <= lbuf_fresh[3] ? lbuf3[out_col] : 24'h0;
    ...
end
```

Effect: during warmup, unrefreshed lbuf taps contribute 0 to the MAC. With
coefficients summing to 1.0, MAC of (some_new_pixel, 0, 0, some_new_pixel)
will give a partial scale of the new pixel rather than mixed garbage.
Still not perfect (DC gain drops while lbufs are still warming), but no
PLUGE-from-old-frame leakage and no synthesis-disrupting output mux.

## Alternative — minimum-rows-emit gate

Don't fire v_cross until all 4 lbufs have been written at least once.
Costs 2-3 output rows at the BOTTOM of the frame (since the total emit
count drops below 720). VDMA might flag a frame-size error.

## Test plan once implemented

1. Rebuild Vivado + Vitis
2. Run 4-boot test via tcl/test_iter3e_alignment.sh
3. Compare:
   - Mean B channel across frame (should match iter3e ≈100)
   - Top rows: should be either black or partially-filled new-frame data,
     NOT old-frame PLUGE colors
   - Q-y position: should still be deterministic across boots
4. Visual check: user verifies on monitor that the top-of-frame artifact
   is gone or reduced.
