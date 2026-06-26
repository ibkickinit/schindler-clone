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
    parameter integer WAY   = 4,          // set-associativity (power of 2); NSET = NTILE/WAY
    parameter integer PD    = 16,         // multi-outstanding pending-fill depth (real geom needs ~64)
    parameter integer SB    = 4
) (
    input  wire        clk, rstn,
    // DYNAMIC RING (2026-06-26): runtime active source dims (the LOD set by the
    // read engine). Used ONLY for the bilinear edge clamps below; the cache
    // hash/sizing (TX, NTILE banks) stay build-time MAX (IN_W/IN_H). 0 ->
    // fall back to build-time max so legacy builds are bit-identical.
    input  wire [11:0] in_w_rt, in_h_rt,
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
    localparam integer TX=(IN_W+TILE-1)/TILE, SLW=$clog2(NTILE), BAW=SLW+2*HT, TIDW=16;

    // DYNAMIC RING: runtime edge-clamp bounds (active source width/height - 1).
    wire [11:0] inw_m1 = ((in_w_rt == 12'd0) ? IN_W[11:0] : in_w_rt) - 12'd1;
    wire [11:0] inh_m1 = ((in_h_rt == 12'd0) ? IN_H[11:0] : in_h_rt) - 12'd1;
    localparam integer WAYW=$clog2(WAY), SETW=SLW-WAYW, NSET=(1<<SETW); // WAY-way set-assoc; NTILE=NSET*WAY

    (* ram_style="block" *) reg [23:0] b00[0:NTILE*BPT-1], b10[0:NTILE*BPT-1],
                                       b01[0:NTILE*BPT-1], b11[0:NTILE*BPT-1];
    // SET-INDEXED WIDE-WORD storage (was flat reg x[0:NTILE-1] read at the 9-bit {set,way} slot -> a
    // 512:1 mux that WAS the WNS critical cone). Now the SET addresses storage (128-deep) and the WAY
    // ways come out in one wide word -> WAY parallel comparators. tagset[set] packs WAY tag-slices
    // ({way*TIDW +: TIDW}); vldset/rsvset are WAY-bit-per-set. Identical logic, storage-shape only.
    reg [WAY*TIDW-1:0] tagset[0:NSET-1];
    reg [WAY-1:0]      vldset[0:NSET-1];
    reg [WAY-1:0]      rsvset[0:NSET-1];
    // CONSUMER-private replica of tag+vld (the gather looka reads ONLY vld+tag for a hit; never rsv).
    // Written in PARALLEL with tagset/vldset on issue/fill/reset -> identical contents, separate physical
    // LUTRAM. P&R places this copy next to the consumer gather, so the hit lookup no longer routes across
    // the die to the prefetch-side tagset (the post-CDC -1.26 ns cone was 62% route: cx_ -> tagset @far).
    reg [WAY*TIDW-1:0] tagset_c[0:NSET-1];
    reg [WAY-1:0]      vldset_c[0:NSET-1];
    reg [WAY-1:0]      rsvset_c[0:NSET-1];          // consumer-side mirror of rsvset (in-flight). Lets the
                                                    // consumer tell "absent" (must demand-fetch) from
                                                    // "in-flight" (just wait) on a gather miss.
    // vld = resident (consumable). rsv = slot reserved for an in-flight fill (not yet consumable).
    // FIFO-by-fetch eviction via a PER-SET victim pointer rr_set[set] (the way to evict next). The
    // prefetch fetches in consumer-future-access order, so within a set the oldest-fetched way is the
    // dead one. rr_set advances on each EVICTION (rr-victim issue, i.e. no free way), so it naturally
    // fills the empty ways 0..WAY-1 first, then cycles through them in fetch order = FIFO ~ LRU for the
    // streaming pattern. O(1) victim (a register read) — replaces the global fseq/seq age-argmax, which
    // was a CARRY4-heavy 16-bit-subtract cone on the prefetch issue critical path (WNS).
    // ---- multi-outstanding pending-fill FIFO: up to PD tiles in flight ----
    // Keeps the DataMover continuously fed across the prefetch's bursty miss pattern. The small TB clears
    // all four at PD=16; the full 1280x720<-1920x1080 geometry needs PD~64 (set at instantiation).
    // Holds only the in-FIFO-order victim SLOTS for in-order fill routing; "in-flight" is not tracked by
    // scanning this FIFO — the tag is written at issue (with rsv=1), so availability (resident OR pending)
    // is a single (vld||rsv)&&tag lookup over a set's WAY ways, NOT a PD-deep scan.
    localparam integer PW=$clog2(PD);
    reg [SLW-1:0] pf_slot[0:PD-1];
    reg [PW-1:0]  pf_wr, pf_rd; reg [PW:0] pf_cnt;
    wire pf_full  = (pf_cnt==PD[PW:0]);
    wire pf_empty = (pf_cnt==0);
    reg [WAYW-1:0] rr_set[0:NSET-1];                  // per-set FIFO victim pointer (way to evict next)
    // victim way for a set: (1) a FREE way (not resident, not reserved) if any — a fill never evicts a
    // live tile while a free way exists; (2) else the rr_set pointer way if it isn't reserved (FIFO);
    // (3) else any non-reserved way (all-reserved is rare). O(1): a register read + a 4-way scan, no
    // age-argmax / subtracts.
    function automatic [WAYW-1:0] vict; input [SETW-1:0] st;
        integer w; reg [WAYW-1:0] v; reg gotfree; reg [WAY-1:0] vw, rw; begin
        vw=vldset[st]; rw=rsvset[st];                     // one wide read; ways come out in parallel
        gotfree=1'b0; v=rr_set[st];
        for(w=WAY-1;w>=0;w=w-1)
            if(!vw[w[WAYW-1:0]] && !rw[w[WAYW-1:0]]) begin v=w[WAYW-1:0]; gotfree=1'b1; end
        if(!gotfree && rw[rr_set[st]])
            for(w=WAY-1;w>=0;w=w-1) if(!rw[w[WAYW-1:0]]) v=w[WAYW-1:0];
        vict = v;
        end
    endfunction

    // DEMAND victim: like vict() but NEVER evicts one of the consumer's 4 current neighbour tiles (n0..n3,
    // all still needed) — that ping-pongs (evict sibling -> miss it -> evict the other) and hangs steep
    // rotations. When the consumer is stalled at most 3 ways hold neighbours, so a free/non-needed way
    // always exists. Prefer free, then a non-reserved non-needed occupied way.
    function automatic [WAYW-1:0] vict_dem; input [SETW-1:0] st; input [TIDW-1:0] n0,n1,n2,n3;
        integer w; reg [WAYW-1:0] v; reg got; reg [WAY-1:0] vw,rw; reg [WAY*TIDW-1:0] tg; reg [TIDW-1:0] tw; reg need; begin
        vw=vldset[st]; rw=rsvset[st]; tg=tagset[st]; got=1'b0; v=rr_set[st];
        for(w=WAY-1;w>=0;w=w-1) if(!vw[w[WAYW-1:0]]&&!rw[w[WAYW-1:0]]) begin v=w[WAYW-1:0]; got=1'b1; end
        if(!got) for(w=WAY-1;w>=0;w=w-1) begin
            tw=tg[w*TIDW +: TIDW]; need=(tw==n0)||(tw==n1)||(tw==n2)||(tw==n3);
            if(!rw[w[WAYW-1:0]] && !need) begin v=w[WAYW-1:0]; got=1'b1; end
        end
        vict_dem=v; end
    endfunction

    // tile id = {ty,tx} concatenation (unique, NO multiply) — the multiply was on the lookup path
    function [TIDW-1:0] tidf; input [11:0] px,py; tidf={py[11:LTILE], px[11:LTILE]}; endfunction
    // set index = mixing hash (tx*1 + ty*33). KEY FINDING (2026-06-24, exhaustive offline sweep of EVERY
    // degree 1-179 against the working-set model): NO linear OR non-linear hash keeps worst-set-live<=4 at
    // ALL continuous angles -- a 4-way cache structurally can't serve continuous rotation (some narrow angle
    // band always overflows for any hash; bench-confirmed: 13,7 fails ~17-19deg, 5,59 fails ~90+125-140deg).
    // The product therefore CLAMPS rotation to 10-degree increments (firmware snaps the W angle). On that
    // 10deg grid {0,10,...,170}, (1,33) holds worst-set-live<=3 (a full way of margin under 4-way), so the
    // working set FITS with zero eviction at every supported angle -> bench-clean. metric<=4 == fits-4-way
    // == clean (proven: clean angles sit at 2-3, every bench failure was at metric>4). tag = full tile-id.
    function [SETW-1:0] setf; input [11:0] px,py;
        setf=(((px>>LTILE)*1) + ((py>>LTILE)*33)) & {SETW{1'b1}}; endfunction
    function [BAW-1:0] baddr; input [SLW-1:0] s; input [11:0] px,py;
        baddr=(s<<(2*HT))|(((py[LTILE-1:0]>>1)<<HT)|(px[LTILE-1:0]>>1)); endfunction
    // Consumer hit detect is INLINED in the gather always@* below (the setf ×13/×7 multiply + tidf are
    // pipelined into the consumer feedforward cs*/ct*, so the per-cycle gather path is just the registered
    // replica read + WAY comparators). Inlined (not a function) so xsim tracks the array reads.

    // ===================== CONSUMER (gather) =====================
    reg [11:0] cx_,cy_,cfx_,cfy_; reg cin_; reg [SB-1:0] csb_; reg c_busy;
    wire [11:0] cxr=(cx_>=inw_m1)?cx_:cx_+1, cyb=(cy_>=inh_m1)?cy_:cy_+1;
    wire ce_x=(cxr==cx_), ce_y=(cyb==cy_);
    wire [11:0] cpx0=(cx_[0]==0)?cx_:cxr, cpx1=(cx_[0]==1)?cx_:cxr;
    wire [11:0] cpy0=(cy_[0]==0)?cy_:cyb, cpy1=(cy_[0]==1)?cy_:cyb;
    // ---- consumer feedforward: 2x2 neighbour set-indices + tile-ids of the INCOMING coord (c_x/c_y),
    //      computed combinationally and registered into cs*/ct* alongside cx_/cy_. Same coord, same edge,
    //      same source -> the setf ×13/×7 multiply leaves the looka loop (prefetch stage-1 trick, read side).
    wire [11:0] nxr=(c_x>=inw_m1)?c_x:c_x+1, nyb=(c_y>=inh_m1)?c_y:c_y+1;
    wire [11:0] npx0=(c_x[0]==0)?c_x:nxr, npx1=(c_x[0]==1)?c_x:nxr;
    wire [11:0] npy0=(c_y[0]==0)?c_y:nyb, npy1=(c_y[0]==1)?c_y:nyb;
    wire [SETW-1:0] ncs00=setf(npx0,npy0), ncs10=setf(npx1,npy0), ncs01=setf(npx0,npy1), ncs11=setf(npx1,npy1);
    wire [TIDW-1:0] nct00=tidf(npx0,npy0), nct10=tidf(npx1,npy0), nct01=tidf(npx0,npy1), nct11=tidf(npx1,npy1);
    reg [SETW-1:0] cs00,cs10,cs01,cs11; reg [TIDW-1:0] ct00,ct10,ct01,ct11;  // staged, in step with cx_/cy_
    reg gh00,gh10,gh01,gh11; reg [SLW-1:0] gs00,gs10,gs01,gs11; integer gw;
    // INLINED hit detect (direct vldset_c/tagset_c reads in always@* so xsim tracks them — a function
    // form is not sensitive to internal array reads, same gotcha the prefetch availability avoids).
    reg [WAY-1:0] gv00,gv10,gv01,gv11; reg [WAY*TIDW-1:0] gt00,gt10,gt01,gt11;
    reg [WAY-1:0] gr00,gr10,gr01,gr11;                 // rsvset_c reads (in-flight)
    reg cif00,cif10,cif01,cif11;                       // neighbour tile is IN-FLIGHT (reserved, filling)
    always @* begin
        gv00=vldset_c[cs00]; gt00=tagset_c[cs00]; gr00=rsvset_c[cs00];
        gv10=vldset_c[cs10]; gt10=tagset_c[cs10]; gr10=rsvset_c[cs10];
        gv01=vldset_c[cs01]; gt01=tagset_c[cs01]; gr01=rsvset_c[cs01];
        gv11=vldset_c[cs11]; gt11=tagset_c[cs11]; gr11=rsvset_c[cs11];
        gh00=1'b0; gh10=1'b0; gh01=1'b0; gh11=1'b0;
        cif00=1'b0; cif10=1'b0; cif01=1'b0; cif11=1'b0;
        gs00={cs00,{WAYW{1'b0}}}; gs10={cs10,{WAYW{1'b0}}}; gs01={cs01,{WAYW{1'b0}}}; gs11={cs11,{WAYW{1'b0}}};
        for(gw=0;gw<WAY;gw=gw+1) begin
            if(gv00[gw[WAYW-1:0]]&&gt00[gw*TIDW +: TIDW]==ct00) begin gh00=1'b1; gs00={cs00,gw[WAYW-1:0]}; end
            if(gv10[gw[WAYW-1:0]]&&gt10[gw*TIDW +: TIDW]==ct10) begin gh10=1'b1; gs10={cs10,gw[WAYW-1:0]}; end
            if(gv01[gw[WAYW-1:0]]&&gt01[gw*TIDW +: TIDW]==ct01) begin gh01=1'b1; gs01={cs01,gw[WAYW-1:0]}; end
            if(gv11[gw[WAYW-1:0]]&&gt11[gw*TIDW +: TIDW]==ct11) begin gh11=1'b1; gs11={cs11,gw[WAYW-1:0]}; end
            if(gr00[gw[WAYW-1:0]]&&gt00[gw*TIDW +: TIDW]==ct00) cif00=1'b1;
            if(gr10[gw[WAYW-1:0]]&&gt10[gw*TIDW +: TIDW]==ct10) cif10=1'b1;
            if(gr01[gw[WAYW-1:0]]&&gt01[gw*TIDW +: TIDW]==ct01) cif01=1'b1;
            if(gr11[gw[WAYW-1:0]]&&gt11[gw*TIDW +: TIDW]==ct11) cif11=1'b1;
        end
    end
    wire c_all = gh00&gh10&gh01&gh11;
    // DEMAND-FETCH: a neighbour that is neither resident (gh) nor in-flight (cif) is truly ABSENT — the
    // prefetch evicted it (or never fetched it) and, being lead-gated, won't. The consumer issues its OWN
    // fetch for it (mux'd into the issue path below, priority, lead-gate bypassed) so it can ALWAYS make
    // progress. This breaks the steep-rotation/zoom-out eviction deadlock. Pick the first absent neighbour.
    wire cab00=!gh00&&!cif00, cab10=!gh10&&!cif10, cab01=!gh01&&!cif01, cab11=!gh11&&!cif11;
    reg [TIDW-1:0] cd_tid; reg [SETW-1:0] cd_set; reg cd_v;
    always @* begin
        cd_v=1'b1;
        if     (cab00) begin cd_tid=ct00; cd_set=cs00; end
        else if(cab10) begin cd_tid=ct10; cd_set=cs10; end
        else if(cab01) begin cd_tid=ct01; cd_set=cs01; end
        else if(cab11) begin cd_tid=ct11; cd_set=cs11; end
        else           begin cd_tid=ct00; cd_set=cs00; cd_v=1'b0; end   // all misses are in-flight -> just wait
    end
    wire cdemand = c_busy && cin_ && !c_all && cd_v;   // consumer stalled on a TRULY absent tile (combinational
                                                       // TRIGGER; the request is REGISTERED below for timing)
    // DEMAND-FETCH PIPELINE (timing): the combinational gather->cdemand->vict_dem->commit cone was 25 logic
    // levels (WNS -12ns). REGISTER the demand request: stage 1 latches the absent tile + its 4 neighbour tids
    // here; stage 2 (issue, below) runs vict_dem from the REGISTERED set, breaking the cone into 2 shallow
    // stages. The consumer is STALLED while demand-fetching, so the 1-2 cycle latency is free. dem_busy
    // interlocks one tile at a time: the issued tile shows in-flight (rsv) the next cycle, so the gather then
    // advances cd to the next absent neighbour -> no double-issue.
    reg dem_busy, dem_iss; reg [TIDW-1:0] cd_tid_r; reg [SETW-1:0] cd_set_r; reg [WAYW-1:0] ua_way_r;
    reg [TIDW-1:0] cn0_r, cn1_r, cn2_r, cn3_r;
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
                    if(c_valid) begin cx_<=c_x;cy_<=c_y;cfx_<=c_fx;cfy_<=c_fy;cin_<=c_inwin;csb_<=c_sb;
                        cs00<=ncs00;cs10<=ncs10;cs01<=ncs01;cs11<=ncs11;ct00<=nct00;ct10<=nct10;ct01<=nct01;ct11<=nct11; c_busy<=1'b1; end
                end else if(stage_ready) begin
                    s1d_v<=1'b1; s1d_x0<=cx_[0]; s1d_y0<=cy_[0]; s1d_ex<=ce_x; s1d_ey<=ce_y;
                    s1d_fx<=cfx_; s1d_fy<=cfy_; s1d_in<=cin_; s1d_sb<=csb_;
                    if(c_valid) begin cx_<=c_x;cy_<=c_y;cfx_<=c_fx;cfy_<=c_fy;cin_<=c_inwin;csb_<=c_sb;
                        cs00<=ncs00;cs10<=ncs10;cs01<=ncs01;cs11<=ncs11;ct00<=nct00;ct10<=nct10;ct01<=nct01;ct11<=nct11; end
                    else c_busy<=1'b0;
                end else s1d_v<=1'b0;                            // staged miss -> bubble
            end
        end
    end

    // ============= PREFETCH — 2-STAGE: feedforward registered, state-dependent suffix ATOMIC =========
    // The 41-level WNS cone was px_ -> setf *13/*7 mults -> availability -> victim -> tag write, all in
    // one cycle. Split: STAGE 1 = the incoming coord; its 2x2 neighbour set-indices (setf, the multiply)
    // + tile-ids are combinational from px_ and REGISTERED into STAGE 2. The state-dependent suffix
    // (availability lookup -> first-unavailable -> victim age-argmax -> tag/rsv WRITE) reads the
    // registered stage-2 values and writes ATOMICALLY in the same cycle, so a just-issued tile's rsv is
    // visible to the next cycle -> NO re-issue / double-victim hazard (the reservation never trails the
    // read). The multiply is now between registers (px_ -> stage 2), out of the lookup cone. The prefetch
    // leads by LEAD, so the 1-cycle pipeline fill is free; throughput stays 1 coord/cycle through hits.
    localparam integer HALF = 12-LTILE;             // tile-coord bits/axis in tidf = {py-tile, px-tile}
    // ---- stage 1: incoming coord + combinational feedforward (neighbours, setf, tidf) ----
    reg [11:0] px_,py_; reg pin_; reg s1_v;
    wire [11:0] pxr=(px_>=inw_m1)?px_:px_+1, pyb=(py_>=inh_m1)?py_:py_+1;
    wire [11:0] ppx0=(px_[0]==0)?px_:pxr, ppx1=(px_[0]==1)?px_:pxr;
    wire [11:0] ppy0=(py_[0]==0)?py_:pyb, ppy1=(py_[0]==1)?py_:pyb;
    wire [TIDW-1:0] f_pt00=tidf(ppx0,ppy0), f_pt10=tidf(ppx1,ppy0), f_pt01=tidf(ppx0,ppy1), f_pt11=tidf(ppx1,ppy1);
    wire [SETW-1:0] f_ps00=setf(ppx0,ppy0), f_ps10=setf(ppx1,ppy0), f_ps01=setf(ppx0,ppy1), f_ps11=setf(ppx1,ppy1);
    // ---- stage 2: registered feedforward of the coord being processed ----
    reg [TIDW-1:0] pt00,pt10,pt01,pt11; reg [SETW-1:0] ps00,ps10,ps01,ps11; reg pin2,s2_v;
    // av* : (resident OR fill-in-flight) per the WAY ways of each tile's set, off the REGISTERED ps/pt.
    // Inlined (direct vld/rsv/tag array reads) so the always@* tracks them (a function form is not
    // sensitive to internal array reads in xsim). Cost WAY per tile, bounded by associativity.
    reg av00, av10, av01, av11; integer aw;
    // wide reads of the 4 neighbour sets (4 simultaneous 128-deep set-reads of the packed ways), then
    // WAY parallel comparators per tile — replaces the 16 flat 512:1 slot muxes that were the issue cone.
    reg [WAY-1:0] avw00,avw10,avw01,avw11, arw00,arw10,arw01,arw11;
    reg [WAY*TIDW-1:0] atw00,atw10,atw01,atw11;
    always @* begin
        avw00=vldset[ps00]; arw00=rsvset[ps00]; atw00=tagset[ps00];
        avw10=vldset[ps10]; arw10=rsvset[ps10]; atw10=tagset[ps10];
        avw01=vldset[ps01]; arw01=rsvset[ps01]; atw01=tagset[ps01];
        avw11=vldset[ps11]; arw11=rsvset[ps11]; atw11=tagset[ps11];
        av00=1'b0; av10=1'b0; av01=1'b0; av11=1'b0;
        for(aw=0;aw<WAY;aw=aw+1) begin
            if((avw00[aw[WAYW-1:0]]||arw00[aw[WAYW-1:0]]) && atw00[aw*TIDW +: TIDW]==pt00) av00=1'b1;
            if((avw10[aw[WAYW-1:0]]||arw10[aw[WAYW-1:0]]) && atw10[aw*TIDW +: TIDW]==pt10) av10=1'b1;
            if((avw01[aw[WAYW-1:0]]||arw01[aw[WAYW-1:0]]) && atw01[aw*TIDW +: TIDW]==pt01) av01=1'b1;
            if((avw11[aw[WAYW-1:0]]||arw11[aw[WAYW-1:0]]) && atw11[aw*TIDW +: TIDW]==pt11) av11=1'b1;
        end
    end
    // ===== STAGE 3 — availability SNAPSHOT + issue loop (avm-snapshot, WNS step 2) =====
    // The ~7 ns tagset-read+compare (av00..11 above) is now PIPELINED: it is a stage-2-internal
    // register-to-register path (ps2/tagset -> av2 -> the av3 snapshot below). The per-cycle ISSUE LOOP
    // runs in stage 3 OFF the registered snapshot, so the deep array read is out of the recurrence.
    // FRESHNESS (why no CAM is needed): av00..11 are recomputed LIVE every cycle in stage 2 from the
    // written tagset and are captured into av3 ONLY at the hand-off edge — the edge the PRECEDING stage-3
    // coord is cur_done3 (so it issues nothing that edge). Thus av3 sees every prior coord's committed
    // issues; there is no stale-availability window. Intra-coord 2x2 tile sharing is handled by done3 (a
    // tile issued for one position resolves all positions with the same tile-id). A tile that is resident
    // OR in-flight (rsv) reads available, so a fill completing mid-issue can never apply to a tile this
    // coord still wants -> freezing av3 for the coord's issue window is exact.
    reg av3_0,av3_1,av3_2,av3_3; reg [TIDW-1:0] t3_0,t3_1,t3_2,t3_3;
    reg [SETW-1:0] s3_0,s3_1,s3_2,s3_3; reg pin3,s3_v; reg [3:0] done3;
    wire eu0 = pin3 && !av3_0 && !done3[0];      // position still needs a fetch (unavailable + unresolved)
    wire eu1 = pin3 && !av3_1 && !done3[1];
    wire eu2 = pin3 && !av3_2 && !done3[2];
    wire eu3 = pin3 && !av3_3 && !done3[3];
    wire any_eu = eu0|eu1|eu2|eu3;
    reg [TIDW-1:0] ua_tid; reg [SETW-1:0] ua_set;        // first unresolved-unavailable tile of the coord
    always @* begin
        if(eu0) begin ua_tid=t3_0; ua_set=s3_0; end
        else if(eu1) begin ua_tid=t3_1; ua_set=s3_1; end
        else if(eu2) begin ua_tid=t3_2; ua_set=s3_2; end
        else begin ua_tid=t3_3; ua_set=s3_3; end
    end
    wire cur_done3 = !pin3 || !any_eu;                   // stage-3 coord fully resolved
    wire s3_adv = !s3_v || cur_done3;                    // stage 3 free to take stage 2's snapshot
    wire s2_adv = !s2_v || s3_adv;                       // stage 2 free to take stage 1's coord
    assign pf_ready = !s1_v || s2_adv;                   // stage 1 can take a new skid coord
    // positions of THIS coord sharing the issued tile-id (intra-coord 2x2 overlap) -> resolve together
    wire [3:0] sh3 = {(t3_3==ua_tid),(t3_2==ua_tid),(t3_1==ua_tid),(t3_0==ua_tid)};

    // issue a fetch: the CONSUMER DEMAND (cdemand) has PRIORITY over the prefetch (it blocks the output and
    // bypasses the lead-gate); otherwise the first unresolved-unavailable prefetch tile. On a demand cycle
    // the prefetch's stage-3 HOLDS (cur_done3 stays low -> it doesn't advance), so the prefetch isn't lost.
    wire issue_pf   = s3_v && pin3 && any_eu && !dem_busy;  // prefetch BLOCKED while a demand is in flight, so
                                                         // the demand's registered victim (ua_way_r) can't
                                                         // collide with a prefetch issue (single issuer).
    wire dem_room   = !(&rsvset[cd_set_r]);              // a non-reserved way exists -> vict won't evict an
                                                         // in-flight fill; if the set is FULL of reservations
                                                         // the demand waits (those fills WILL complete + free).
    wire issue_dem  = dem_iss;                            // STAGE 3: victim already computed (registered) -> issue
    wire issue_want = (issue_dem || issue_pf) && !pf_full;
    wire [TIDW-1:0] iss_tid = issue_dem ? cd_tid_r : ua_tid;
    wire [SETW-1:0] iss_set = issue_dem ? cd_set_r : ua_set;
    assign fetch_req = issue_want;
    assign fetch_tx  = iss_tid[HALF-1:0];                // tidf low half = px-tile, high half = py-tile
    assign fetch_ty  = iss_tid[2*HALF-1:HALF];
    wire   issue_go  = issue_want && t_ready;            // fetch accepted -> becomes pending

    reg [2*HT-1:0] fcw; integer pj;
    wire fill_pop = !pf_empty && fill_valid && fill_last;
    // demand uses the REGISTERED victim (computed in the VICT stage); prefetch uses the plain FIFO victim.
    // TIMING FIX (2026-06-24): prefetch victim off the REGISTERED s3 set (ua_set), NOT iss_set. iss_set =
    // issue_dem?cd_set_r:ua_set, so feeding vict(iss_set) put the dem_iss FF in front of the deep vict() scan
    // -> dem_iss_reg/C -> ...vict()... -> tagset RAMD64E write was the worst path. On a DEMAND issue ua_way_r
    // (registered) is selected and pf_way is a dead mux input; on a PREFETCH issue iss_set==ua_set so
    // vict(ua_set)==vict(iss_set). Functionally bit-identical (faithful-TB verified), but dem_iss no longer
    // fans into vict() -> ~4-6 LUT levels off the demand write path.
    wire [WAYW-1:0] pf_way = vict(ua_set);               // prefetch victim, off registered s3 set (no dem_iss)
    wire [WAYW-1:0] ua_way = issue_dem ? ua_way_r : pf_way;
    wire [SLW-1:0] ua_slot = {iss_set, ua_way};
    wire [BAW-1:0] fwa = (pf_slot[pf_rd]<<(2*HT)) | fcw;  // fills route to the pending-FIFO head slot
    wire [SETW-1:0] fl_set = pf_slot[pf_rd][SLW-1:WAYW];  // fill-complete slot -> {set,way} for wide writes
    wire [WAYW-1:0] fl_way = pf_slot[pf_rd][WAYW-1:0];

    always @(posedge clk) begin
        if(!rstn) begin s1_v<=0; s2_v<=0; s3_v<=0; done3<=4'b0; fcw<=0; pf_wr<=0; pf_rd<=0; pf_cnt<=0; dem_busy<=0; dem_iss<=0;
            for(pj=0;pj<NSET;pj=pj+1) begin vldset[pj]<=0; vldset_c[pj]<=0; rsvset[pj]<=0; rsvset_c[pj]<=0; rr_set[pj]<=0; end
            end
        else begin
            // ---- demand-fetch FSM (3 registered stages: LATCH -> VICT -> ISSUE) ----
            if(!dem_busy) begin                              // IDLE/LATCH: capture the absent tile + neighbours
                if(cdemand) begin cd_tid_r<=cd_tid; cd_set_r<=cd_set;
                    cn0_r<=ct00; cn1_r<=ct10; cn2_r<=ct01; cn3_r<=ct11; dem_busy<=1'b1; dem_iss<=1'b0; end
            end else if(!dem_iss) begin                      // VICT: compute + REGISTER the victim (when room)
                if(dem_room) begin ua_way_r <= vict_dem(cd_set_r, cn0_r, cn1_r, cn2_r, cn3_r); dem_iss<=1'b1; end
            end else if(issue_go) begin dem_busy<=1'b0; dem_iss<=1'b0; end  // ISSUE: fetched -> next absent
            // issue: pick a free (or rr-victim) way; write the NEW tag now (so availability sees the
            // tile as in-flight) and invalidate-as-resident (rsv=1, vld=0 -> no stale hits during fill).
            // Enqueue the slot for in-order fill routing. ATOMIC with the availability read (same cycle,
            // stage 2). If the victim was an OCCUPIED way (an actual eviction, not a free way), advance
            // that set's FIFO pointer so the next victim is the next-oldest way. (the victim is never
            // reserved, so vldset[ua_set][ua_way] alone distinguishes evict-vs-fill-empty.)
            if(issue_go) begin
                pf_slot[pf_wr]<=ua_slot; pf_wr<=pf_wr+1'b1;
                tagset[iss_set][ua_way*TIDW +: TIDW]<=iss_tid;    // write the chosen way's tag slice
                tagset_c[iss_set][ua_way*TIDW +: TIDW]<=iss_tid;  // mirror to the consumer replica
                vldset[iss_set][ua_way]<=1'b0; rsvset[iss_set][ua_way]<=1'b1;
                vldset_c[iss_set][ua_way]<=1'b0; rsvset_c[iss_set][ua_way]<=1'b1;  // mirror rsv to consumer
                if(vldset[iss_set][ua_way]) rr_set[iss_set]<=rr_set[iss_set]+1'b1;
            end
            // 3-STAGE prefetch pipeline. stage 1 <- skid; stage 2 <- stage-1 feedforward (setf mults);
            // stage 3 <- stage-2 availability SNAPSHOT (av3) + reset the per-position done mask. Stage 2
            // HOLDS (recomputing av live) across a miss coord's multi-cycle issuing in stage 3, so the
            // snapshot captured at the hand-off edge is fresh.
            if(pf_valid && pf_ready) begin px_<=pf_x; py_<=pf_y; pin_<=pf_inwin; s1_v<=1'b1; end
            else if(s2_adv) s1_v<=1'b0;
            if(s2_adv) begin
                pt00<=f_pt00; pt10<=f_pt10; pt01<=f_pt01; pt11<=f_pt11;
                ps00<=f_ps00; ps10<=f_ps10; ps01<=f_ps01; ps11<=f_ps11;
                pin2<=pin_; s2_v<=s1_v;
            end
            if(s3_adv) begin                              // capture the FRESH availability snapshot
                av3_0<=av00; av3_1<=av10; av3_2<=av01; av3_3<=av11;
                t3_0<=pt00; t3_1<=pt10; t3_2<=pt01; t3_3<=pt11;
                s3_0<=ps00; s3_1<=ps10; s3_2<=ps01; s3_3<=ps11;
                pin3<=pin2; s3_v<=s2_v; done3<=4'b0;
            end else if(issue_go && !issue_dem) done3<=done3|sh3;  // prefetch issue only (demand isn't its coord)
            // DMA fill: one 2x2 block/beat -> all 4 banks at the same within-tile addr (head tile's slot)
            if(!pf_empty && fill_valid) begin
                b00[fwa]<=fill_blk[23:0];  b10[fwa]<=fill_blk[47:24];
                b01[fwa]<=fill_blk[71:48]; b11[fwa]<=fill_blk[95:72];
                fcw<=fcw+1'b1;
                if(fill_last) begin                        // tile complete -> make resident + pop head
                    vldset[fl_set][fl_way]<=1'b1; rsvset[fl_set][fl_way]<=1'b0; // tag already written at issue
                    vldset_c[fl_set][fl_way]<=1'b1; rsvset_c[fl_set][fl_way]<=1'b0; // mirror to consumer replica
                    pf_rd<=pf_rd+1'b1; fcw<=6'd0;
                end
            end
            pf_cnt <= pf_cnt + (issue_go?1:0) - (fill_pop?1:0);
        end
    end
endmodule

`default_nettype wire
