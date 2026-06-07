// pg_tilecache_rt2.v — Phase-2 fetch, MILESTONE 3b: CONCURRENT prefetch + gather (real-time).
//
// Two independent engines share the 4-bank tile BRAM + tag/vld:
//   * PREFETCH: walks a coord stream running ahead of the consumer; issues DMA fills for tiles not
//     resident/in-flight, warming the cache. Fill writes one pixel/cycle into the parity bank.
//   * CONSUMER: the M3a 1px/clock 4-bank 2x2 gather; outputs when its 4 tiles are resident, else
//     stalls (waits for prefetch). Gather reads (combinational) run CONCURRENTLY with fill writes
//     (clocked) — each bank is 1W1R dual-port — so a 1px/clock fill overlaps the gather and a whole
//     cold frame (fill ~= frame px, gather ~= frame px, concurrent) fits one frame period.
//
// The prefetch staying ahead (warmed through V-blank) is what makes the consumer never stall — the
// real-time TB proves it (no underrun). 16x16 tiles. Single in-flight DMA (1 fill at a time).

`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache_rt2 #(
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter integer LTILE = 4,
    parameter integer NTILE = 64,
    parameter integer SB    = 4
) (
    input  wire        clk, rstn,
    // prefetch coord stream (runs ahead)
    input  wire        pf_valid,
    input  wire [11:0] pf_x, pf_y,
    input  wire        pf_inwin,
    output wire        pf_ready,
    // consumer coord stream (output rate)
    input  wire        c_valid,
    input  wire [11:0] c_x, c_y, c_fx, c_fy,
    input  wire        c_inwin,
    input  wire [SB-1:0] c_sb,
    output wire        c_ready,
    // gather result
    output reg         out_valid,
    output reg  [23:0] out_p00, out_p10, out_p01, out_p11,
    output reg  [11:0] out_fx, out_fy,
    output reg         out_inwin,
    output reg  [SB-1:0] out_sb,
    input  wire        out_ready,
    // DMA (behavioral)
    output reg         fetch_req,
    output reg  [11:0] fetch_tx, fetch_ty,
    input  wire        fill_valid,
    input  wire [95:0] fill_blk,            // a 2x2 source block {p11,p01,p10,p00} -> all 4 banks/cycle
    input  wire        fill_last
);
    localparam integer TILE=(1<<LTILE), HT=LTILE-1, BPT=(TILE*TILE)/4;
    localparam integer TX=(IN_W+TILE-1)/TILE, SLW=$clog2(NTILE), BAW=SLW+2*HT, TIDW=24;
    localparam integer WAY=4, SETW=SLW-2, SKH=SETW/2;   // 4-way set-assoc; NSET=2^SETW; NTILE=NSET*4

    (* ram_style="block" *) reg [23:0] b00[0:NTILE*BPT-1], b10[0:NTILE*BPT-1],
                                       b01[0:NTILE*BPT-1], b11[0:NTILE*BPT-1];
    reg [TIDW-1:0] tag[0:NTILE-1]; reg vld[0:NTILE-1]; reg [1:0] rr_way;  // round-robin victim way
    reg [TIDW-1:0] pend_tid; reg pend_v;        // single in-flight fill

    // tile id = {ty,tx} concatenation (unique, NO multiply) — the multiply was on the lookup path
    function [TIDW-1:0] tidf; input [11:0] px,py; tidf={py[11:LTILE], px[11:LTILE]}; endfunction
    // set index = low SKH bits of (ty,tx) — spreads adjacent tiles (the 2x2's 4 tiles) across sets
    function [SETW-1:0] setf; input [11:0] px,py;
        setf={py[LTILE+SKH-1:LTILE], px[LTILE+SKH-1:LTILE]}; endfunction
    function [BAW-1:0] baddr; input [SLW-1:0] s; input [11:0] px,py;
        baddr=(s<<(2*HT))|(((py[LTILE-1:0]>>1)<<HT)|(px[LTILE-1:0]>>1)); endfunction
    // 4-way set-assoc lookup: tile (px,py) -> {hit, slot}. Reads vld/tag -> only in always@*.
    function automatic [SLW:0] looka; input [11:0] px,py;
        integer w; reg hh; reg [SLW-1:0] s; reg [SETW-1:0] st; reg [TIDW-1:0] t; begin
        st=setf(px,py); t=tidf(px,py); hh=1'b0; s={st,2'b00};
        for(w=0;w<WAY;w=w+1) if(vld[{st,w[1:0]}]&&tag[{st,w[1:0]}]==t) begin hh=1'b1; s={st,w[1:0]}; end
        looka={hh,s}; end
    endfunction

    // ===================== CONSUMER (gather) =====================
    reg [11:0] cx_,cy_,cfx_,cfy_; reg cin_; reg [SB-1:0] csb_; reg c_busy;
    wire [11:0] cxr=(cx_>=IN_W-1)?cx_:cx_+1, cyb=(cy_>=IN_H-1)?cy_:cy_+1;
    wire ce_x=(cxr==cx_), ce_y=(cyb==cy_);
    wire [11:0] cpx0=(cx_[0]==0)?cx_:cxr, cpx1=(cx_[0]==1)?cx_:cxr;
    wire [11:0] cpy0=(cy_[0]==0)?cy_:cyb, cpy1=(cy_[0]==1)?cy_:cyb;
    reg gh00,gh10,gh01,gh11; reg [SLW-1:0] gs00,gs10,gs01,gs11;
    always @* begin
        {gh00,gs00}=looka(cpx0,cpy0); {gh10,gs10}=looka(cpx1,cpy0);
        {gh01,gs01}=looka(cpx0,cpy1); {gh11,gs11}=looka(cpx1,cpy1);
    end
    wire c_all = gh00&gh10&gh01&gh11;
    wire op_rdy = !out_valid || out_ready;             // OUT stage can take a gather result
    wire stage_ready = cin_ ? c_all : 1'b1;            // staged coord resident (or matte)?
    assign c_ready = op_rdy && (!c_busy || stage_ready);

    // 2-STAGE gather pipeline (the registered BRAM read adds a cycle):
    //   S1: present addr -> REGISTERED bank reads (cr*) [true BRAM]; carry the coord's parity/edge/frac
    //       (s1d) latched the SAME clock, so s1d aligns with cr* (both capture the accepted coord).
    //   OUT: route cr* by carried parity/edge -> out_p (registered).  All gated by op_rdy = lockstep.
    reg [23:0] cr00,cr10,cr01,cr11;
    reg s1d_v, s1d_x0, s1d_y0, s1d_ex, s1d_ey, s1d_in; reg [11:0] s1d_fx, s1d_fy; reg [SB-1:0] s1d_sb;
    always @(posedge clk) if(op_rdy) begin
        cr00<=b00[baddr(gs00,cpx0,cpy0)]; cr10<=b10[baddr(gs10,cpx1,cpy0)];
        cr01<=b01[baddr(gs01,cpx0,cpy1)]; cr11<=b11[baddr(gs11,cpx1,cpy1)];
    end
    wire [23:0] cg00=s1d_x0?(s1d_y0?cr11:cr10):(s1d_y0?cr01:cr00);
    wire [23:0] cg10=s1d_x0?(s1d_y0?cr01:cr00):(s1d_y0?cr11:cr10);
    wire [23:0] cg01=s1d_x0?(s1d_y0?cr10:cr11):(s1d_y0?cr00:cr01);
    wire [23:0] cg11=s1d_x0?(s1d_y0?cr00:cr01):(s1d_y0?cr10:cr11);
    wire [23:0] cpp00=cg00, cpp10=s1d_ex?cg00:cg10, cpp01=s1d_ey?cg00:cg01,
                cpp11=s1d_ex?cpp01:(s1d_ey?cpp10:cg11);

    always @(posedge clk) begin
        if(!rstn) begin c_busy<=0; out_valid<=0; s1d_v<=0; end
        else begin
            if(out_valid && out_ready) out_valid<=0;
            if(op_rdy) begin
                // OUT <= gather result of the coord captured into cr*/s1d on the previous accept
                out_valid<=s1d_v; out_inwin<=s1d_in; out_fx<=s1d_fx; out_fy<=s1d_fy; out_sb<=s1d_sb;
                out_p00<=cpp00; out_p10<=cpp10; out_p01<=cpp01; out_p11<=cpp11;
                // S1 produce: capture the staged coord (cr* clocked above) + carry its meta
                if(!c_busy) begin
                    s1d_v<=1'b0;
                    if(c_valid) begin cx_<=c_x;cy_<=c_y;cfx_<=c_fx;cfy_<=c_fy;cin_<=c_inwin;csb_<=c_sb; c_busy<=1'b1; end
                end else if(stage_ready) begin
                    s1d_v<=1'b1; s1d_x0<=cx_[0]; s1d_y0<=cy_[0]; s1d_ex<=ce_x; s1d_ey<=ce_y;
                    s1d_fx<=cfx_; s1d_fy<=cfy_; s1d_in<=cin_; s1d_sb<=csb_;
                    if(c_valid) begin cx_<=c_x;cy_<=c_y;cfx_<=c_fx;cfy_<=c_fy;cin_<=c_inwin;csb_<=c_sb; end
                    else c_busy<=1'b0;
                end else s1d_v<=1'b0;                            // staged miss -> bubble
            end
        end
    end

    // ============= PREFETCH (fill) — PARALLEL 4-tile check, ~1 coord/cycle =============
    reg [11:0] px_,py_; reg pin_; reg p_busy;
    wire [11:0] pxr=(px_>=IN_W-1)?px_:px_+1, pyb=(py_>=IN_H-1)?py_:py_+1;
    wire [11:0] ppx0=(px_[0]==0)?px_:pxr, ppx1=(px_[0]==1)?px_:pxr;
    wire [11:0] ppy0=(py_[0]==0)?py_:pyb, ppy1=(py_[0]==1)?py_:pyb;
    wire [TIDW-1:0] pt00=tidf(ppx0,ppy0), pt10=tidf(ppx1,ppy0), pt01=tidf(ppx0,ppy1), pt11=tidf(ppx1,ppy1);
    reg pr00,pr10,pr01,pr11; reg [SLW-1:0] pd;
    always @* begin
        {pr00,pd}=looka(ppx0,ppy0); {pr10,pd}=looka(ppx1,ppy0);
        {pr01,pd}=looka(ppx0,ppy1); {pr11,pd}=looka(ppx1,ppy1);
    end
    wire av00=pr00||(pend_v&&pend_tid==pt00), av10=pr10||(pend_v&&pend_tid==pt10),
         av01=pr01||(pend_v&&pend_tid==pt01), av11=pr11||(pend_v&&pend_tid==pt11);
    wire all_av = av00&av10&av01&av11;
    reg [TIDW-1:0] ua_tid; reg [11:0] ua_tx, ua_ty; reg [SETW-1:0] ua_set;   // first unavailable tile
    always @* begin
        if(!av00) begin ua_tid=pt00; ua_tx=ppx0>>LTILE; ua_ty=ppy0>>LTILE; ua_set=setf(ppx0,ppy0); end
        else if(!av10) begin ua_tid=pt10; ua_tx=ppx1>>LTILE; ua_ty=ppy0>>LTILE; ua_set=setf(ppx1,ppy0); end
        else if(!av01) begin ua_tid=pt01; ua_tx=ppx0>>LTILE; ua_ty=ppy1>>LTILE; ua_set=setf(ppx0,ppy1); end
        else begin ua_tid=pt11; ua_tx=ppx1>>LTILE; ua_ty=ppy1>>LTILE; ua_set=setf(ppx1,ppy1); end
    end
    wire cur_done = !pin_ || all_av;
    assign pf_ready = !p_busy || cur_done;

    reg [2*HT-1:0] fcw; reg [SLW-1:0] fill_slot; integer pj;
    wire [BAW-1:0] fwa = (fill_slot<<(2*HT)) | fcw;

    always @(posedge clk) begin
        if(!rstn) begin p_busy<=0; fetch_req<=0; rr_way<=0; pend_v<=0;
            for(pj=0;pj<NTILE;pj=pj+1) vld[pj]<=0; end
        else begin
            fetch_req<=0;
            // issue one fill for the first unavailable tile -> victim = round-robin way in that tile's set
            if(p_busy && pin_ && !all_av && !pend_v) begin
                fetch_req<=1; fetch_tx<=ua_tx; fetch_ty<=ua_ty;
                fill_slot<={ua_set,rr_way}; fcw<=0; pend_tid<=ua_tid; pend_v<=1;
            end
            // accept next prefetch coord when current is done; else drop busy if nothing pending
            if(pf_valid && pf_ready) begin px_<=pf_x; py_<=pf_y; pin_<=pf_inwin; p_busy<=1; end
            else if(p_busy && cur_done) p_busy<=0;
            // DMA fill: one 2x2 block/beat -> all 4 banks at the same within-tile addr
            if(pend_v && fill_valid) begin
                b00[fwa]<=fill_blk[23:0];  b10[fwa]<=fill_blk[47:24];
                b01[fwa]<=fill_blk[71:48]; b11[fwa]<=fill_blk[95:72];
                fcw<=fcw+1'b1;
                if(fill_last) begin tag[fill_slot]<=pend_tid; vld[fill_slot]<=1'b1; rr_way<=rr_way+1'b1; pend_v<=0; end
            end
        end
    end
endmodule

`default_nettype wire
