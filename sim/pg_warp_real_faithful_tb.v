// pg_warp_real_faithful_tb.v — FAITHFUL DataMover + buffered-sink gate for the warp DMA deadlock.
//
// Why this exists: pg_warp_real_tb's behavioral DataMover is GAP-FREE (registered output, one beat the
// instant the consumer is ready) and pg_warp_real_bursty_tb's model X-propagates (cq_cnt=x) and starves
// at startup — neither reproduces the on-silicon mid-stream freeze (engine makes ~1 output line, then the
// DataMover beat stream wedges, beat_cnt frozen, dm_tready=0). This TB models the REAL AXI MM2S DataMover:
//   * a DEEP command FIFO (the issuer runs many row-commands ahead of data, like the IP's cmd queue),
//   * a cmd->first-beat LATENCY (DDR read latency),
//   * mid-burst GAPS (shared-HP-port / VDMA contention throttling the beat stream),
//   * and it NEVER loses a beat (beat_valid held until beat_ready — real AXI can't drop data).
// Output side: a line-FIFO sink that mimics axis_to_vid_io — o_ready is gated to FIFO-room (the consumer
// pulls AHEAD during blanking to keep the line buffer full), NOT strictly to active video. That keeps the
// consumer flowing through warm-up exactly as the real v_axi4s_vid_out does, so any freeze we see is the
// DUT's, not a TB-warmup artifact.
//
// Knobs (override with xvlog -d NAME=val): CMD_LAT, GAP_EVERY, GAP_LEN, CMDFD (cmd FIFO depth), LFD (line
// FIFO depth), LEADV. Default config reproduces the freeze; a fixed DUT must PASS all four geometries.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_real_faithful_tb;
    localparam OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080;
    localparam LTILE=4, TILE=16, CW=32, FB=12, NA=OUT_W*OUT_H;
    // Cache config — default = the BENCH BD config (readengine_warp_bd.tcl: 4-way/512, PD/DREQ=64,
    // LEAD=4096, lead_rt tied 0). Override with -d NTILEV/WAYV/PDV/DREQV to compare against the
    // real_tb production config (8-way/1024/LEAD=32768).
`ifdef NTILEV
    localparam NTILE=`NTILEV;
`else
    localparam NTILE=512;
`endif
`ifdef WAYV
    localparam WAY=`WAYV;
`else
    localparam WAY=4;
`endif
`ifdef PDV
    localparam PD=`PDV;
`else
    localparam PD=64;
`endif
`ifdef DREQV
    localparam DREQ=`DREQV;
`else
    localparam DREQ=64;
`endif
`ifdef LEADV
    localparam LEAD=`LEADV;
`else
    localparam LEAD=4096;          // BENCH default (readengine_warp_bd.tcl), lead_rt tied 0
`endif
    // --- DataMover faithfulness knobs ---
`ifdef CMD_LAT
    localparam integer CMD_LAT=`CMD_LAT;     // cmd-accept -> first beat (DDR read latency)
`else
    localparam integer CMD_LAT=28;
`endif
`ifdef GAP_EVERY
    localparam integer GAP_EVERY=`GAP_EVERY; // insert a gap after every Nth beat (0 = never)
`else
    localparam integer GAP_EVERY=3;
`endif
`ifdef GAP_LEN
    localparam integer GAP_LEN=`GAP_LEN;     // gap length in clocks
`else
    localparam integer GAP_LEN=2;
`endif
`ifdef CMDFD
    localparam integer CMDFD=`CMDFD;         // DataMover command FIFO depth
`else
    localparam integer CMDFD=16;
`endif
`ifdef LFD
    localparam integer LFD=`LFD;             // output line-FIFO depth (axis_to_vid_io buffer)
`else
    localparam integer LFD=2048;
`endif
    localparam STRIDE=IN_W*3, H_TOT=1650, V_TOT=750, VB=30, FRAME_PERIOD=H_TOT*V_TOT;
    localparam integer NBEAT=(TILE*3)/8;     // 6 beats per 16-px row command (48 bytes / 8)

    reg clk=0, rstn=0, sof=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; wire o_ready;
    wire wreq; wire [11:0] wtx,wty; wire fv; wire [95:0] fblk; wire fl;
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; wire dm_ready; wire t_ready;
    reg [63:0] beat_data=0; reg beat_valid=0; wire beat_ready; reg beat_last=0;

    // LEADRTV (optional): exercise the RUNTIME lead_rt port (the GPIO path) instead of the build LEAD.
    // build LEAD is forced deep (0xFFFFF) so a wrong lead_rt route would deadlock -> proves the port wins.
`ifdef LEADRTV
    localparam [19:0] LEAD_RT = `LEADRTV;
`else
    localparam [19:0] LEAD_RT = 20'd0;       // 0 -> engine uses build LEAD (default behaviour)
`endif
    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.WAY(WAY),.PD(PD),.CW(CW),.FB(FB),.LEAD(LEAD)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),.lead_rt(LEAD_RT),.lod(3'd0),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));
    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.DREQ(DREQ)) u_dma (
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_buf_base(32'd0),.rd_slot(6'd0),.lod(3'd0),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat_data),.beat_valid(beat_valid),.beat_ready(beat_ready),.beat_last(beat_last));
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // ============================ FAITHFUL AXI MM2S DataMover ============================
    // command FIFO (deep — issuer runs ahead of data)
    reg [31:0] cfa[0:CMDFD-1];
    reg [$clog2(CMDFD):0] cf_cnt; reg [$clog2(CMDFD)-1:0] cf_wr, cf_rd;
    wire cf_full  = (cf_cnt==CMDFD[$clog2(CMDFD):0]);
    wire cf_empty = (cf_cnt==0);
    assign dm_ready = !cf_full;                      // accept commands while the FIFO has room
    wire cf_push = dm_req && dm_ready;

    // PIPELINED data engine: the real MM2S overlaps command latency, so beats stream at ~1 beat/clk once
    // warm. We pay CMD_LAT only as a COLD pipeline-fill (when the data side has caught up to the command
    // side and must wait for the next read to return), and inject GAPS (GAP_LEN clocks every GAP_EVERY
    // beats) for shared-HP-port/VDMA contention. A presented beat is HELD until beat_ready — never lost.
    reg        loaded;                                // rb holds a fetched source row, bi = next beat
    reg [3:0]  bi;                                    // 0..NBEAT (==NBEAT -> row exhausted)
    reg [383:0] rb; integer srow, scol, kk;
    reg [9:0]  cold, gapc, bsg;
    reg        cf_load;                               // pop-a-command event (combinational pulse via reg)
    wire out_free = !beat_valid || beat_ready;        // output reg can accept a new beat next cycle

    always @(posedge clk) begin
        if(!rstn) begin
            cf_cnt<=0; cf_wr<=0; cf_rd<=0; loaded<=0; bi<=0; cold<=CMD_LAT[9:0];
            gapc<=0; bsg<=0; beat_valid<=0; beat_data<=0; beat_last<=0;
        end else begin
            cf_load=1'b0;
            if(cf_push) begin cfa[cf_wr]<=dm_addr; cf_wr<=cf_wr+1'b1; end
            // ---- cold pipeline-fill latency: only while the data side is starved of a loaded row ----
            if(!loaded) begin
                if(cf_empty) cold<=CMD_LAT[9:0];      // truly idle -> reload the cold timer
                else if(cold!=0) cold<=cold-1'b1;     // refilling -> count the read latency down
                else begin                             // latency elapsed -> fetch the next row
                    srow = cfa[cf_rd]/STRIDE; scol = (cfa[cf_rd]-srow*STRIDE)/3;
                    for(kk=0;kk<TILE;kk=kk+1) rb[kk*24 +: 24] = pxf(scol+kk, srow);
                    cf_rd<=cf_rd+1'b1; cf_load=1'b1; loaded<=1'b1; bi<=0;
                end
            end
            // ---- gap timer ----
            if(gapc!=0) gapc<=gapc-1'b1;
            // ---- present a beat when the output reg is free, a row is loaded, and not gapping ----
            if(out_free) begin
                if(loaded && bi<NBEAT[3:0] && gapc==0) begin
                    beat_data<=rb[bi*64 +: 64]; beat_last<=(bi==NBEAT[3:0]-1'b1); beat_valid<=1'b1;
                    bi<=bi+1'b1;
                    if(bi==NBEAT[3:0]-1'b1) begin loaded<=1'b0; cold<=1; end // row exhausted -> 1-clk reload
                    if(GAP_EVERY!=0 && (bsg+1>=GAP_EVERY[9:0])) begin gapc<=GAP_LEN[9:0]; bsg<=0; end
                    else bsg<=bsg+1'b1;
                end else beat_valid<=1'b0;             // nothing to present (gap / between rows / starved)
            end
            cf_cnt <= cf_cnt + (cf_push?1:0) - (cf_load?1:0);
        end
    end

    // ============================ BUFFERED OUTPUT SINK (mimics axis_to_vid_io) ============================
    // A line FIFO the consumer fills AHEAD; raster-active drains it. o_ready = FIFO-has-room (the consumer
    // pulls during blanking too), so warm-up flows like the real v_axi4s_vid_out instead of stalling.
    reg [23:0] lf[0:LFD-1];
    reg [$clog2(LFD):0] lf_cnt; reg [$clog2(LFD)-1:0] lf_wr, lf_rd;
    reg started;
    wire lf_full  = (lf_cnt>=LFD[$clog2(LFD):0]-2);
    wire lf_empty = (lf_cnt==0);
    assign o_ready = started && !lf_full;

    reg [11:0] hx, vy;
    wire active = started && (vy>=VB) && (vy<VB+OUT_H) && (hx<OUT_W);  // raster drain window
    integer cn, errors, underruns, total, cyc, axx, ayy; real PI;
    wire push_px = o_valid && o_ready;
    wire pop_px  = active && !lf_empty;     // one display pixel per active clock

    always @(posedge clk) cyc<=cyc+1;
    always @(posedge clk) begin
        if(!rstn) begin hx<=0; vy<=0; end
        else if(started) begin
            if(hx==H_TOT-1) begin hx<=0; vy<=(vy==V_TOT-1)?0:vy+1; end else hx<=hx+1;
        end
    end
    always @(posedge clk) begin
        if(!rstn) begin lf_wr<=0; lf_rd<=0; lf_cnt<=0; end
        else begin
            if(push_px) begin lf[lf_wr]<=o_pix; lf_wr<=lf_wr+1'b1; end
            if(pop_px) begin
                if(lf[lf_rd]!==golden(cn)) begin errors<=errors+1;
                    if(errors<8) $display("  ERR idx %0d got %h exp %h",cn,lf[lf_rd],golden(cn)); end
                lf_rd<=lf_rd+1'b1; cn<=cn+1; total<=total+1;
            end
            if(active && lf_empty) underruns<=underruns+1;   // display starved -> real underrun
            lf_cnt <= lf_cnt + (push_px?1:0) - (pop_px?1:0);
        end
    end

    // golden (identical lerp to pg_warp_engine)
    function [7:0] g8; input [7:0] a,b; input [7:0] w;
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); g8=r[7:0]; end endfunction
    function [23:0] g24; input [23:0] a,b; input [7:0] w;
        g24={g8(a[23:16],b[23:16],w),g8(a[15:8],b[15:8],w),g8(a[7:0],b[7:0],w)}; endfunction
    function [23:0] golden; input integer idx; integer ox,oy,sxq,syq,col,row,cn1,rn1; reg[7:0] wx,wy;
        reg[23:0] p00,p10,p01,p11,tp,bt; begin
        ox=idx%OUT_W; oy=idx/OUT_W; sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e;
        col=sxq>>>FB; row=syq>>>FB;
        if(col<0||row<0||col>=IN_W||row>=IN_H) golden=matte;
        else begin cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1;
            wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;
            p00=pxf(col,row);p10=pxf(cn1,row);p01=pxf(col,rn1);p11=pxf(cn1,rn1);
            tp=g24(p00,p10,wx); bt=g24(p01,p11,wx); golden=g24(tp,bt,wy); end end
    endfunction

    task setaff; input real deg; input real invx; input real invy; begin : s
        real th,co,si,cxo,cyo,cxs,cys;
        th=deg*PI/180.0;co=$cos(th);si=$sin(th);
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        m_a=$rtoi(co*invx*4096);m_b=$rtoi(si*invx*4096);
        m_d=$rtoi(-si*invy*4096);m_e=$rtoi(co*invy*4096);
        m_c=$rtoi((cxs-co*invx*cxo-si*invx*cyo)*4096);
        m_f=$rtoi((cys+si*invy*cxo-co*invy*cyo)*4096);
    end endtask

    task run_x; input real deg; input real invx; input real invy; input [127:0] nm; begin
        setaff(deg,invx,invy);
        cn=0;errors=0;underruns=0;started=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; started<=1; @(posedge clk); sof<=0;
        repeat(FRAME_PERIOD + 8000) @(posedge clk);
        started<=0;
        $display("FAITHFUL %0s LEAD=%0d CMD_LAT=%0d GAP=%0d/%0d CMDFD=%0d LFD=%0d: underruns=%0d bit-err=%0d collected=%0d/%0d | %s",
                 nm, LEAD, CMD_LAT, GAP_EVERY, GAP_LEN, CMDFD, LFD, underruns, errors, cn, NA,
                 (underruns==0 && errors==0 && cn==NA) ? "PASS" : "FAIL");
        repeat(80)@(posedge clk);
    end endtask

    initial begin
        PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        total=0;cyc=0;
        run_x(0.0,  1.0, 1.0, "identity ");   // <-- the actual BENCH BOOT geometry (warp_set_rotation(0,4096,4096))
        run_x(20.0, 1.0, 1.0, "rot20    ");
        run_x(45.0, 1.0, 1.0, "rot45    ");
        run_x(0.0,  1.5, 1.5, "shrink1.5");
        run_x(30.0, 1.5, 1.0, "aniso30  ");
        // Formerly-WEDGING cases: with consumer demand-fetch they now COMPLETE bit-exact (cn advances,
        // no freeze, no bit-errors). Steep angles still UNDERRUN at this lead (prefetch can't warm them) —
        // a performance knob, not a wedge. The key invariant: NONE deadlock.
        run_x(90.0,   1.0, 1.0, "rot90    ");
        run_x(162.0,  1.0, 1.0, "rot162   ");
        run_x(-162.0, 1.0, 1.0, "rot-162  ");
        $finish;
    end
    // stall probe: periodic dump of prefetch/consumer/DMA state to locate the deadlock
    initial begin #95_000_000; $display("WATCHDOG cn=%0d err=%0d",cn,errors); $finish; end

    // heartbeat: see the pipeline come alive (or not)
    integer hb=0;
    always @(posedge clk) if(rstn && started) begin
        hb<=hb+1;
        if(hb%500000==0)
            $display("  HB cyc=%0d cn=%0d lf=%0d cf=%0d loaded=%b bi=%0d beat_v=%b beat_r=%b dm_req=%b dm_rdy=%b rx_act=%b rx_left=%0d nbits=%0d em=%b rx=%b f0=%b f1=%b rq=%0d lead=%0d pfcnt=%0d fr(tc)=%b",
                hb, cn, lf_cnt, cf_cnt, loaded, bi, beat_valid, beat_ready, dm_req, dm_ready,
                u_dma.rx_act, u_dma.rx_left, u_dma.nbits, u_dma.em_pp, u_dma.rx_pp, u_dma.full[0], u_dma.full[1],
                u_dma.rq_cnt, dut.lead_cnt, dut.u_tc.pf_cnt, dut.u_tc.fetch_req);
    end

    // CORRUPTION DETECTOR: flag if the prefetch ever issues a fetch whose victim way is RESERVED
    // (an in-flight fill) -> vict() returned a reserved slot (set fully reserved) -> the new tag overwrites
    // an in-flight fill's slot -> pf-FIFO double-slot / fill-routing corruption. This is the unrecoverable
    // wedge variant (distinct from evict-unconsumed-resident). Counts occurrences per geometry.
    integer corrupt_cnt=0; reg corrupt_seen=0;
    always @(posedge clk) begin
        if(!(rstn && started)) corrupt_seen<=0;
        else if(dut.u_tc.issue_go && dut.u_tc.rsvset[dut.u_tc.ua_set][dut.u_tc.ua_way]) begin
            corrupt_cnt<=corrupt_cnt+1;
            if(!corrupt_seen) begin corrupt_seen<=1;
                $display("  CORRUPT @cn=%0d: vict() returned RESERVED way set=%0d way=%0d (rsv=%b vld=%b) -> in-flight slot overwrite",
                    cn, dut.u_tc.ua_set, dut.u_tc.ua_way, dut.u_tc.rsvset[dut.u_tc.ua_set], dut.u_tc.vldset[dut.u_tc.ua_set]);
            end
        end
    end

    // WEDGE DETECTOR: consumer makes no progress for a long time -> dump full DUT + DMA state (once per
    // geometry; does NOT $finish, so the suite continues and we see deadlock-vs-underrun for every case).
    integer stuck=0, lastcn=0; reg dumped=0;
    always @(posedge clk) begin
        if(!(rstn && started)) begin stuck<=0; dumped<=0; lastcn<=0; end
        else begin
            if(cn==lastcn) stuck<=stuck+1; else stuck<=0;
            lastcn<=cn;
            if(stuck==200000 && !dumped) begin
                dumped<=1;
                $display("STALL @cn=%0d  DMA[ rx_act=%b rx_left=%0d nbits=%0d rx_pp=%b em_pp=%b f0=%b f1=%b emit_act=%b iss_act=%b rq_cnt=%0d ]  IO[ dm_req=%b beat_v=%b beat_r=%b cf_cnt=%0d loaded=%b o_valid=%b o_ready=%b lf_cnt=%0d ]  ENG[ lead_cnt=%0d pf_cnt(tc)=%0d fetch_req(tc)=%b pf_full=%b ]",
                    cn, u_dma.rx_act, u_dma.rx_left, u_dma.nbits, u_dma.rx_pp, u_dma.em_pp, u_dma.full[0], u_dma.full[1],
                    u_dma.emit_act, u_dma.iss_act, u_dma.rq_cnt,
                    dm_req, beat_valid, beat_ready, cf_cnt, loaded, o_valid, o_ready, lf_cnt,
                    dut.lead_cnt, dut.u_tc.pf_cnt, dut.u_tc.fetch_req, dut.u_tc.pf_full);
            end
        end
    end
endmodule

`default_nettype wire
