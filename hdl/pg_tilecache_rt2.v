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
    // DMA: fetch request (held combinationally; VALID independent of READY), consumed on t_ready.
    // Multiple fetches may be outstanding (pending-slot FIFO); fills return in request order.
    output wire        fetch_req,
    output wire [11:0] fetch_tx, fetch_ty,
    input  wire        t_ready,            // tile_dma can accept a fetch this cycle
    input  wire        fill_valid,
    input  wire [95:0] fill_blk,            // a 2x2 source block {p11,p01,p10,p00} -> all 4 banks/cycle
    input  wire        fill_last
);
    localparam integer TILE=(1<<LTILE), HT=LTILE-1, BPT=(TILE*TILE)/4;
    localparam integer TX=(IN_W+TILE-1)/TILE, SLW=$clog2(NTILE), BAW=SLW+2*HT, TIDW=24;
    localparam integer WAY=4, SETW=SLW-2, NSET=(1<<SETW);   // 4-way set-assoc; NSET=2^SETW; NTILE=NSET*4

    (* ram_style="block" *) reg [23:0] b00[0:NTILE*BPT-1], b10[0:NTILE*BPT-1],
                                       b01[0:NTILE*BPT-1], b11[0:NTILE*BPT-1];
    reg [TIDW-1:0] tag[0:NTILE-1]; reg vld[0:NTILE-1]; reg rsv[0:NTILE-1]; reg [1:0] rr_way;
    // vld = resident (consumable). rsv = slot reserved for an in-flight fill (not yet consumable).
    // ---- multi-outstanding pending-fill FIFO: up to PD tiles in flight ----
    // PD=16 (with tile_dma DREQ=16 + a deep prefetch lead) covers shrink's worst tile-row-crossing
    // burst (~a full tile-row of misses); 12 still starves, 16 clears all four transforms.
    localparam integer PD=16, PW=$clog2(PD);
    reg [SLW-1:0] pf_slot[0:PD-1]; reg [TIDW-1:0] pf_tid[0:PD-1]; reg pf_occ[0:PD-1];
    reg [PW-1:0]  pf_wr, pf_rd; reg [PW:0] pf_cnt;
    wire pf_full  = (pf_cnt==PD[PW:0]);
    wire pf_empty = (pf_cnt==0);
    // a tile is in-flight if any occupied pending slot holds its id
    function automatic pend_has; input [TIDW-1:0] t; integer i; begin pend_has=1'b0;
        for(i=0;i<PD;i=i+1) if(pf_occ[i] && pf_tid[i]==t) pend_has=1'b1; end
    endfunction
    // victim way for a set: prefer a way that is neither resident nor reserved (free), so a fill never
    // evicts a live tile while a free way exists. Only when all 4 ways are occupied (which, given
    // worst-set-live<=4, means at least one holds a now-dead tile) do we round-robin. This is the
    // non-thrashing victim policy the multi-outstanding prefetch needs.
    function automatic [1:0] vict; input [SETW-1:0] st; reg o0,o1,o2,o3; begin
        o0=vld[{st,2'b00}]||rsv[{st,2'b00}]; o1=vld[{st,2'b01}]||rsv[{st,2'b01}];
        o2=vld[{st,2'b10}]||rsv[{st,2'b10}]; o3=vld[{st,2'b11}]||rsv[{st,2'b11}];
        if(!o0) vict=2'b00; else if(!o1) vict=2'b01; else if(!o2) vict=2'b10;
        else if(!o3) vict=2'b11; else vict=rr_way; end
    endfunction

    // tile id = {ty,tx} concatenation (unique, NO multiply) — the multiply was on the lookup path
    function [TIDW-1:0] tidf; input [11:0] px,py; tidf={py[11:LTILE], px[11:LTILE]}; endfunction
    // set index = mixing hash (tx*13 + ty*7). Validated worst-set-live<=4 for ALL swept transforms
    // at NTILE=512 (128 sets x 4 ways) — tools/warp_assoc_sweep.py. The plain {ty,tx} low-bits index
    // concentrated shrink's diagonal/ty-constant access onto few sets (15 live tiles/set -> 4-way
    // thrash); this hash spreads them so 4-way holds. tag is still the full tile-id (tidf).
    function [SETW-1:0] setf; input [11:0] px,py;
        setf=(((px>>LTILE)*13) + ((py>>LTILE)*7)) & {SETW{1'b1}}; endfunction
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
    // av* : resident (pr*) OR in-flight (matches an occupied pending slot). The pending compare is
    // INLINED here (not via a function) so the always@* is sensitive to the pf_occ/pf_tid array reads
    // — a wire/function form misses a tile becoming pending and the prefetch re-issues it forever.
    reg av00, av10, av01, av11; integer ai;
    always @* begin
        av00 = pr00; av10 = pr10; av01 = pr01; av11 = pr11;
        for(ai=0;ai<PD;ai=ai+1) if(pf_occ[ai]) begin
            if(pf_tid[ai]==pt00) av00=1'b1; if(pf_tid[ai]==pt10) av10=1'b1;
            if(pf_tid[ai]==pt01) av01=1'b1; if(pf_tid[ai]==pt11) av11=1'b1;
        end
    end
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

    // issue a fetch for the first unavailable tile while the pending FIFO has room. fetch_req is held
    // combinationally (VALID independent of t_ready) and is accepted by tile_dma on t_ready.
    wire issue_want = p_busy && pin_ && !all_av && !pf_full;
    assign fetch_req = issue_want;
    assign fetch_tx  = ua_tx;
    assign fetch_ty  = ua_ty;
    wire   issue_go  = issue_want && t_ready;       // fetch accepted this cycle -> becomes pending

    reg [2*HT-1:0] fcw; integer pj;
    wire fill_pop = !pf_empty && fill_valid && fill_last;
    wire [1:0] ua_way = vict(ua_set);                     // victim way in the unavailable tile's set
    wire [SLW-1:0] ua_slot = {ua_set, ua_way};
    wire [BAW-1:0] fwa = (pf_slot[pf_rd]<<(2*HT)) | fcw;   // fills route to the pending-FIFO head slot

    always @(posedge clk) begin
        if(!rstn) begin p_busy<=0; rr_way<=0; fcw<=0; pf_wr<=0; pf_rd<=0; pf_cnt<=0;
            for(pj=0;pj<NTILE;pj=pj+1) begin vld[pj]<=0; rsv[pj]<=0; end
            for(pj=0;pj<PD;pj=pj+1) pf_occ[pj]<=0; end
        else begin
            // issue: pick a free (or dead) victim way, invalidate it now (no stale hits during the
            // fill), reserve the slot, enqueue as pending. rr_way advances only as the all-occupied
            // tiebreak so it stays meaningful.
            if(issue_go) begin
                pf_slot[pf_wr]<=ua_slot; pf_tid[pf_wr]<=ua_tid; pf_occ[pf_wr]<=1'b1;
                vld[ua_slot]<=1'b0; rsv[ua_slot]<=1'b1;
                pf_wr<=pf_wr+1'b1; rr_way<=rr_way+1'b1;
            end
            // accept next prefetch coord when current is done; else drop busy if nothing pending
            if(pf_valid && pf_ready) begin px_<=pf_x; py_<=pf_y; pin_<=pf_inwin; p_busy<=1; end
            else if(p_busy && cur_done) p_busy<=0;
            // DMA fill: one 2x2 block/beat -> all 4 banks at the same within-tile addr (head tile's slot)
            if(!pf_empty && fill_valid) begin
                b00[fwa]<=fill_blk[23:0];  b10[fwa]<=fill_blk[47:24];
                b01[fwa]<=fill_blk[71:48]; b11[fwa]<=fill_blk[95:72];
                fcw<=fcw+1'b1;
                if(fill_last) begin                        // tile complete -> commit + pop head
                    tag[pf_slot[pf_rd]]<=pf_tid[pf_rd]; vld[pf_slot[pf_rd]]<=1'b1; rsv[pf_slot[pf_rd]]<=1'b0;
                    pf_occ[pf_rd]<=1'b0; pf_rd<=pf_rd+1'b1; fcw<=6'd0;
                end
            end
            pf_cnt <= pf_cnt + (issue_go?1:0) - (fill_pop?1:0);
        end
    end
endmodule

`default_nettype wire
