`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// dma
//
// Descriptor-based copy engine: an AXI4 master on crossbar port M2 and the
// APB register block DMA (slot 4, 0x4000_4000; registers generated as
// dma_regs from rtl/csr/rdl/soc_apb.rdl). Full description, measurements and
// limits: docs/06_dma.md.
//
// Descriptor, 16 bytes, 16-byte aligned, read as one 2-beat burst:
//   +0x0 SRC   source byte address
//   +0x4 DST   destination byte address
//   +0x8 LEN   [23:0] length in bytes (1 .. 2^24-1); [24] FENCE: start this
//              descriptor's reads only after every earlier write has its B
//   +0xC NEXT  next descriptor, 16-byte aligned; 0 ends the chain
// SRC, DST and LEN have no alignment requirement.
//
// Datapath, one descriptor ("job") after another without a gap:
//   descriptor fetch  ARID 1, one descriptor ahead: the next one is fetched
//                     as soon as the current one starts
//   read engine       ARID 0, 64-bit INCR bursts of up to 16 beats, split at
//                     4 KB boundaries; a burst is issued only when the read
//                     FIFO has room for all of it (rd_space), so RREADY is
//                     always high
//   aligner           shifts the source byte stream to the destination's byte
//                     offset: output beat j is bytes s..s+7 of the previous
//                     and current read beats, s = (SRC - DST) mod 8, with the
//                     first and last beat's strobes cut to the job
//   write engine      AWID 0, the same burst rules; an AW is issued only when
//                     all of its beats are in the write FIFO (wr_avail), so a
//                     burst never holds the slave's W channel waiting for data
//
// Reads and writes each use one ID, so their responses come back in order.
// Data reads and descriptor reads use different IDs and are told apart by
// RID. A descriptor whose source overlaps an earlier descriptor's destination
// needs FENCE; one whose own source and destination overlap is not supported.
//
// On an error response, a bad descriptor (LEN 0, NEXT not 16-byte aligned,
// DESC_PTR not 16-byte aligned) or ABORT, ERR_INFO and ERR_ADDR record the
// first cause, nothing new is issued, every transaction already issued
// completes (DRAIN), the FIFOs are emptied (FLUSH), and then STATUS.ERR is
// set. A chain that ends normally sets STATUS.DONE on the B of its last
// burst. DONE and ERR are the interrupt outputs.
// -----------------------------------------------------------------------------

module dma #(
  parameter int RD_DEPTH = 32,  // read FIFO, beats
  parameter int WR_DEPTH = 32,  // write FIFO, beats
  parameter int MAX_RD   = 4,   // data read bursts outstanding (power of two)
  parameter int MAX_WR   = 4    // write bursts outstanding (power of two)
) (
  input  wire          clk,
  input  wire          rst_n,

  // APB slave (slot 4)
  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  // AXI4 master (M2), 2-bit IDs
  output logic [1:0]   m_awid,
  output logic [31:0]  m_awaddr,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic [2:0]   m_awprot,
  output logic [3:0]   m_awcache,
  output logic [3:0]   m_awqos,
  output logic         m_awvalid,
  input  wire          m_awready,
  output logic [63:0]  m_wdata,
  output logic [7:0]   m_wstrb,
  output logic         m_wlast,
  output logic         m_wvalid,
  input  wire          m_wready,
  input  wire  [1:0]   m_bid,
  input  wire  [1:0]   m_bresp,
  input  wire          m_bvalid,
  output logic         m_bready,
  output logic [1:0]   m_arid,
  output logic [31:0]  m_araddr,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic [2:0]   m_arprot,
  output logic [3:0]   m_arcache,
  output logic [3:0]   m_arqos,
  output logic         m_arvalid,
  input  wire          m_arready,
  input  wire  [1:0]   m_rid,
  input  wire  [63:0]  m_rdata,
  input  wire  [1:0]   m_rresp,
  input  wire          m_rlast,
  input  wire          m_rvalid,
  output logic         m_rready,

  output logic         irq_done,
  output logic         irq_err
);

  localparam logic [1:0] ID_DATA = 2'd0;
  localparam logic [1:0] ID_DESC = 2'd1;
  localparam logic [1:0] OKAY    = 2'b00;

  localparam logic [2:0] C_DESC_RD = 3'd1;
  localparam logic [2:0] C_DATA_RD = 3'd2;
  localparam logic [2:0] C_DATA_WR = 3'd3;
  localparam logic [2:0] C_BAD     = 3'd4;
  localparam logic [2:0] C_ABORT   = 3'd5;

  localparam int RSW = $clog2(RD_DEPTH + 1);
  localparam int WSW = $clog2(WR_DEPTH + 1);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  dma_regs_pkg::dma_regs__in_t  hwif_in;
  dma_regs_pkg::dma_regs__out_t hwif_out;

  dma_regs u_regs (
    .clk           (clk),
    .arst_n        (rst_n),
    .s_apb_psel    (psel),
    .s_apb_penable (penable),
    .s_apb_pwrite  (pwrite),
    .s_apb_pprot   (3'b000),
    .s_apb_paddr   (paddr),
    .s_apb_pwdata  (pwdata),
    .s_apb_pstrb   (pstrb),
    .s_apb_pready  (pready),
    .s_apb_prdata  (prdata),
    .s_apb_pslverr (pslverr),
    .hwif_in       (hwif_in),
    .hwif_out      (hwif_out)
  );

  wire        start_req = hwif_out.CTRL.start.value;
  wire        abort_req = hwif_out.CTRL.abort.value;
  wire [31:0] desc_ptr  = hwif_out.DESC_PTR.addr.value;

  // ---------------------------------------------------------------------------
  // Run state
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DRAIN, S_FLUSH} state_e;
  state_e state;
  wire    run = (state == S_RUN);

  logic [31:0] cur_desc;
  logic [15:0] desc_done;
  logic [31:0] cycles;

  // ---------------------------------------------------------------------------
  // Descriptor fetch: one descriptor buffered ahead of the read engine
  // ---------------------------------------------------------------------------
  logic        df_req;      // the descriptor at df_addr has to be fetched
  logic        df_wait;     // its AR was issued; beats pending
  logic        df_beat1;    // the next descriptor beat is beat 1
  logic [31:0] df_addr;
  logic        nd_valid;    // a fetched descriptor waits for the read engine
  logic [31:0] nd_addr, nd_src, nd_dst, nd_next;
  logic [23:0] nd_len;
  logic        nd_fence;

  // ---------------------------------------------------------------------------
  // FIFOs
  // ---------------------------------------------------------------------------
  // Read data
  logic        rd_push, rd_pop, rd_full, rd_empty;
  logic [63:0] rd_dout;
  // Aligner jobs: shift, lead (first output needs no primed beat), first
  // beat's byte offset, end offset of the last beat (0 = full), beat counts
  localparam int AJW = 3 + 1 + 3 + 3 + 22 + 22;
  logic           aj_push, aj_pop, aj_full, aj_empty;
  logic [AJW-1:0] aj_din, aj_dout;
  // Write jobs: destination word address, beats, last job of the chain
  localparam int WJW = 29 + 22 + 1;
  logic           wj_push, wj_pop, wj_full, wj_empty;
  logic [WJW-1:0] wj_din, wj_dout;
  // Write data with strobes
  logic        wr_push, wr_pop, wr_full, wr_empty;
  logic [71:0] wr_din, wr_dout;
  // Start address of each data read burst in flight (for ERR_ADDR)
  logic        rt_push, rt_pop, rt_full, rt_empty;
  logic [31:0] rt_dout;
  // Each write burst issued: start address, last burst of a job, last of the chain
  logic        wt_push, wt_pop, wt_full, wt_empty;
  logic [33:0] wt_din, wt_dout;
  // Length of each write burst whose W beats are still to be sent
  logic        wl_push, wl_pop, wl_full, wl_empty;
  logic [3:0]  wl_din, wl_dout;

  fifo_sync #(.WIDTH(64),  .DEPTH(RD_DEPTH)) u_rd_fifo (
    .clk (clk), .rst_n (rst_n), .push (rd_push), .din (m_rdata), .full (rd_full),
    .pop (rd_pop), .dout (rd_dout), .empty (rd_empty));
  fifo_sync #(.WIDTH(AJW), .DEPTH(2)) u_aj_fifo (
    .clk (clk), .rst_n (rst_n), .push (aj_push), .din (aj_din), .full (aj_full),
    .pop (aj_pop), .dout (aj_dout), .empty (aj_empty));
  fifo_sync #(.WIDTH(WJW), .DEPTH(2)) u_wj_fifo (
    .clk (clk), .rst_n (rst_n), .push (wj_push), .din (wj_din), .full (wj_full),
    .pop (wj_pop), .dout (wj_dout), .empty (wj_empty));
  fifo_sync #(.WIDTH(72),  .DEPTH(WR_DEPTH)) u_wr_fifo (
    .clk (clk), .rst_n (rst_n), .push (wr_push), .din (wr_din), .full (wr_full),
    .pop (wr_pop), .dout (wr_dout), .empty (wr_empty));
  fifo_sync #(.WIDTH(32),  .DEPTH(MAX_RD)) u_rt_fifo (
    .clk (clk), .rst_n (rst_n), .push (rt_push), .din ({re_addr, 3'b000}), .full (rt_full),
    .pop (rt_pop), .dout (rt_dout), .empty (rt_empty));
  fifo_sync #(.WIDTH(34),  .DEPTH(MAX_WR)) u_wt_fifo (
    .clk (clk), .rst_n (rst_n), .push (wt_push), .din (wt_din), .full (wt_full),
    .pop (wt_pop), .dout (wt_dout), .empty (wt_empty));
  fifo_sync #(.WIDTH(4),   .DEPTH(MAX_WR)) u_wl_fifo (
    .clk (clk), .rst_n (rst_n), .push (wl_push), .din (wl_din), .full (wl_full),
    .pop (wl_pop), .dout (wl_dout), .empty (wl_empty));

  // ---------------------------------------------------------------------------
  // Burst length: up to 16 beats, never past a 4 KB boundary, never past the
  // end of the job. page_beat is the address's beat index in its 4 KB page.
  // ---------------------------------------------------------------------------
  function automatic logic [4:0] burst_beats(logic [8:0] page_beat, logic [21:0] left);
    logic [9:0] to_page;
    logic [4:0] b;
    to_page = 10'd512 - {1'b0, page_beat};
    b       = 5'd16;
    if (to_page < 10'd16) b = to_page[4:0];
    if (left < 22'(b))    b = left[4:0];
    return b;
  endfunction

  // ---------------------------------------------------------------------------
  // Read engine
  // ---------------------------------------------------------------------------
  logic           re_busy;
  logic [28:0]    re_addr;    // word address
  logic [21:0]    re_left;    // beats still to request
  logic [RSW-1:0] rd_space;   // read FIFO entries neither filled nor reserved
  wire  [4:0]     re_len = burst_beats(re_addr[8:0], re_left);

  wire ar_free = !m_arvalid || m_arready;
  wire df_go   = run && df_req && !df_wait && !nd_valid && ar_free;
  wire re_go   = run && !df_go && re_busy && ar_free && !rt_full &&
                 (rd_space >= RSW'(re_len));

  // ---------------------------------------------------------------------------
  // Write engine
  // ---------------------------------------------------------------------------
  logic           we_busy;
  logic [28:0]    we_addr;
  logic [21:0]    we_left;
  logic           we_last;    // this job ends the chain
  logic [WSW-1:0] wr_avail;   // write FIFO beats not yet given to an AW
  wire  [4:0]     we_len = burst_beats(we_addr[8:0], we_left);

  wire aw_free = !m_awvalid || m_awready;
  wire aw_go   = run && we_busy && aw_free && !wt_full && !wl_full &&
                 (wr_avail >= WSW'(we_len));

  // ---------------------------------------------------------------------------
  // Aligner
  // ---------------------------------------------------------------------------
  logic        al_busy, al_primed, al_first;
  logic [2:0]  al_shift, al_doff, al_eoff;
  logic [21:0] al_in_left, al_out_left;
  logic [63:0] al_prev;

  wire         al_need_in = (al_in_left != 22'd0);
  wire [63:0]  al_cur     = al_need_in ? rd_dout : 64'd0;
  wire         al_prime   = run && al_busy && !al_primed && !rd_empty;
  wire         al_step    = run && al_busy && al_primed && (!al_need_in || !rd_empty) && !wr_full;
  wire [63:0]  al_out     = 64'({al_cur, al_prev} >> {al_shift, 3'b000});
  logic [7:0]  al_strb;

  always_comb begin
    al_strb = 8'hFF;
    if (al_first) al_strb = al_strb & (8'hFF << al_doff);
    if ((al_out_left == 22'd1) && (al_eoff != 3'd0)) al_strb = al_strb & ~(8'hFF << al_eoff);
  end

  // ---------------------------------------------------------------------------
  // Launch: the buffered descriptor becomes the next job
  // ---------------------------------------------------------------------------
  wire wr_idle  = !we_busy && wj_empty && !al_busy && aj_empty && wt_empty && wl_empty;
  wire can_take = run && nd_valid && !re_busy && !aj_full && !wj_full && (!nd_fence || wr_idle);
  wire bad_desc = (nd_len == 24'd0) || (nd_next[3:0] != 4'd0);
  wire launch   = can_take && !bad_desc;

  wire [2:0]  nd_soff = nd_src[2:0];
  wire [2:0]  nd_doff = nd_dst[2:0];
  wire [21:0] nd_nin  = 22'((27'(nd_soff) + 27'(nd_len) + 27'd7) >> 3);
  wire [21:0] nd_nout = 22'((27'(nd_doff) + 27'(nd_len) + 27'd7) >> 3);

  assign aj_din = {nd_soff - nd_doff, (nd_soff < nd_doff), nd_doff, nd_doff + nd_len[2:0],
                   nd_nin, nd_nout};
  assign wj_din = {nd_dst[31:3], nd_nout, (nd_next == 32'd0)};
  assign aj_push = launch;
  assign wj_push = launch;

  // ---------------------------------------------------------------------------
  // Response channels
  // ---------------------------------------------------------------------------
  assign m_rready = 1'b1;
  assign m_bready = 1'b1;

  wire r_hs      = m_rvalid;            // RREADY is always high
  wire r_desc    = r_hs && (m_rid == ID_DESC);
  wire r_data    = r_hs && (m_rid != ID_DESC);
  wire r_bad     = (m_rresp != OKAY);
  wire b_hs      = m_bvalid;

  assign rd_push = run && r_data && !r_bad;
  assign rt_pop  = r_data && m_rlast;

  wire wt_jlast = wt_dout[1];
  wire wt_clast = wt_dout[0];
  assign wt_pop = b_hs;

  wire done_evt = run && b_hs && (m_bresp == OKAY) && wt_jlast && wt_clast;

  // First error of a run, highest priority first.
  logic        err_evt;
  logic [2:0]  err_cause;
  logic [1:0]  err_resp;
  logic [31:0] err_addr;
  always_comb begin
    err_evt   = 1'b0;
    err_cause = 3'd0;
    err_resp  = 2'd0;
    err_addr  = 32'd0;
    if (run && !done_evt) begin
      if (b_hs && (m_bresp != OKAY)) begin
        err_evt = 1'b1; err_cause = C_DATA_WR; err_resp = m_bresp; err_addr = wt_dout[33:2];
      end else if (r_desc && r_bad) begin
        err_evt = 1'b1; err_cause = C_DESC_RD; err_resp = m_rresp; err_addr = df_addr;
      end else if (r_data && r_bad) begin
        err_evt = 1'b1; err_cause = C_DATA_RD; err_resp = m_rresp; err_addr = rt_dout;
      end else if (can_take && bad_desc) begin
        err_evt = 1'b1; err_cause = C_BAD; err_addr = nd_addr;
      end else if (abort_req) begin
        err_evt = 1'b1; err_cause = C_ABORT; err_addr = cur_desc;
      end
    end
  end

  wire start_ok  = (state == S_IDLE) && start_req;
  wire start_bad = start_ok && (desc_ptr[3:0] != 4'd0);
  wire drained   = !m_arvalid && rt_empty && !df_wait && !m_awvalid && wt_empty && wl_empty;
  wire flushed   = rd_empty && wr_empty && aj_empty && wj_empty;

  // ---------------------------------------------------------------------------
  // AR channel
  // ---------------------------------------------------------------------------
  assign m_arsize  = 3'd3;
  assign m_arburst = 2'b01;
  assign m_arprot  = 3'b000;
  assign m_arcache = 4'b0000;
  assign m_arqos   = 4'b0000;
  // A data read's tag is pushed when its AR is loaded, so rt_full counts every
  // data read from load to RLAST; R cannot arrive before the AR is accepted.
  assign rt_push   = re_go;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_arvalid <= 1'b0;
      m_arid    <= ID_DATA;
      m_araddr  <= 32'd0;
      m_arlen   <= 8'd0;
    end else if (ar_free) begin
      m_arvalid <= df_go || re_go;
      if (df_go) begin
        m_arid   <= ID_DESC;
        m_araddr <= df_addr;
        m_arlen  <= 8'd1;
      end else if (re_go) begin
        m_arid   <= ID_DATA;
        m_araddr <= {re_addr, 3'b000};
        m_arlen  <= 8'(re_len - 5'd1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AW and W channels
  // ---------------------------------------------------------------------------
  assign m_awid    = ID_DATA;
  assign m_awsize  = 3'd3;
  assign m_awburst = 2'b01;
  assign m_awprot  = 3'b000;
  assign m_awcache = 4'b0000;
  assign m_awqos   = 4'b0000;

  // Tags are pushed when the AW is loaded; B cannot arrive before the AW is
  // accepted, and W waits at the crossbar until it is.
  wire we_job_end = (we_left == 22'(we_len));
  assign wt_push = aw_go;
  assign wt_din  = {we_addr, 3'b000, we_job_end, we_job_end && we_last};
  assign wl_push = aw_go;
  assign wl_din  = 4'(we_len - 5'd1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_awvalid <= 1'b0;
      m_awaddr  <= 32'd0;
      m_awlen   <= 8'd0;
    end else if (aw_free) begin
      m_awvalid <= aw_go;
      if (aw_go) begin
        m_awaddr <= {we_addr, 3'b000};
        m_awlen  <= 8'(we_len - 5'd1);
      end
    end
  end

  logic [3:0] w_beat;
  assign m_wvalid = !wl_empty && !wr_empty;
  assign m_wdata  = wr_dout[63:0];
  assign m_wstrb  = wr_dout[71:64];
  assign m_wlast  = (w_beat == wl_dout);
  wire   w_hs     = m_wvalid && m_wready;
  assign wl_pop   = w_hs && m_wlast;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_beat <= 4'd0;
    end else if (w_hs) begin
      w_beat <= m_wlast ? 4'd0 : w_beat + 4'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // FIFO pops: the aligner and W in normal operation; everything in FLUSH
  // ---------------------------------------------------------------------------
  wire flush = (state == S_FLUSH);
  assign rd_pop  = flush || al_prime || (al_step && al_need_in);
  assign wr_push = al_step;
  assign wr_din  = {al_strb, al_out};
  assign wr_pop  = flush || w_hs;
  assign aj_pop  = flush || (run && !al_busy && !aj_empty);
  assign wj_pop  = flush || (run && !we_busy && !wj_empty);

  // ---------------------------------------------------------------------------
  // Sequential state
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      cur_desc    <= 32'd0;
      desc_done   <= 16'd0;
      cycles      <= 32'd0;
      df_req      <= 1'b0;
      df_wait     <= 1'b0;
      df_beat1    <= 1'b0;
      df_addr     <= 32'd0;
      nd_valid    <= 1'b0;
      nd_addr     <= 32'd0;
      nd_src      <= 32'd0;
      nd_dst      <= 32'd0;
      nd_next     <= 32'd0;
      nd_len      <= 24'd0;
      nd_fence    <= 1'b0;
      re_busy     <= 1'b0;
      re_addr     <= 29'd0;
      re_left     <= 22'd0;
      rd_space    <= RSW'(RD_DEPTH);
      we_busy     <= 1'b0;
      we_addr     <= 29'd0;
      we_left     <= 22'd0;
      we_last     <= 1'b0;
      wr_avail    <= '0;
      al_busy     <= 1'b0;
      al_primed   <= 1'b0;
      al_first    <= 1'b0;
      al_shift    <= 3'd0;
      al_doff     <= 3'd0;
      al_eoff     <= 3'd0;
      al_in_left  <= 22'd0;
      al_out_left <= 22'd0;
      al_prev     <= 64'd0;
    end else begin
      // Run state
      case (state)
        S_IDLE: begin
          if (start_ok && !start_bad) begin
            state     <= S_RUN;
            desc_done <= 16'd0;
            cycles    <= 32'd0;
            df_req    <= 1'b1;
            df_addr   <= desc_ptr;
            cur_desc  <= desc_ptr;
          end
        end
        S_RUN: begin
          cycles <= cycles + 32'd1;
          if (done_evt)     state <= S_IDLE;
          else if (err_evt) state <= S_DRAIN;
        end
        S_DRAIN: begin
          cycles <= cycles + 32'd1;
          if (drained) state <= S_FLUSH;
        end
        S_FLUSH: begin
          cycles <= cycles + 32'd1;
          if (flushed) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase

      if (run && b_hs && (m_bresp == OKAY) && wt_jlast) desc_done <= desc_done + 16'd1;

      // Descriptor fetch
      if (df_go) begin
        df_req   <= 1'b0;
        df_wait  <= 1'b1;
        df_beat1 <= 1'b0;
      end
      if (r_desc) begin
        if (!df_beat1) begin
          nd_src   <= m_rdata[31:0];
          nd_dst   <= m_rdata[63:32];
          df_beat1 <= 1'b1;
        end else begin
          nd_len   <= m_rdata[23:0];
          nd_fence <= m_rdata[24];
          nd_next  <= m_rdata[63:32];
        end
        if (m_rlast) begin
          df_wait  <= 1'b0;
          nd_valid <= run && !r_bad;
          nd_addr  <= df_addr;
        end
      end

      // Launch
      if (launch) begin
        nd_valid <= 1'b0;
        cur_desc <= nd_addr;
        re_busy  <= 1'b1;
        re_addr  <= nd_src[31:3];
        re_left  <= nd_nin;
        if (nd_next != 32'd0) begin
          df_req  <= 1'b1;
          df_addr <= nd_next;
        end
      end

      // Read engine
      if (re_go) begin
        re_addr <= re_addr + 29'(re_len);
        re_left <= re_left - 22'(re_len);
        if (re_left == 22'(re_len)) re_busy <= 1'b0;
      end
      rd_space <= rd_space - (re_go ? RSW'(re_len) : RSW'(0)) + (rd_pop && !flush ? RSW'(1) : RSW'(0));

      // Aligner
      if (aj_pop && !flush) begin
        al_busy     <= 1'b1;
        al_shift    <= aj_dout[53:51];
        al_primed   <= aj_dout[50];
        al_doff     <= aj_dout[49:47];
        al_eoff     <= aj_dout[46:44];
        al_in_left  <= aj_dout[43:22];
        al_out_left <= aj_dout[21:0];
        al_first    <= 1'b1;
        al_prev     <= 64'd0;
      end
      if (al_prime) begin
        al_prev    <= rd_dout;
        al_in_left <= al_in_left - 22'd1;
        al_primed  <= 1'b1;
      end
      if (al_step) begin
        al_prev     <= al_cur;
        al_first    <= 1'b0;
        al_out_left <= al_out_left - 22'd1;
        if (al_need_in) al_in_left <= al_in_left - 22'd1;
        if (al_out_left == 22'd1) al_busy <= 1'b0;
      end

      // Write engine
      if (wj_pop && !flush) begin
        we_busy <= 1'b1;
        we_addr <= wj_dout[51:23];
        we_left <= wj_dout[22:1];
        we_last <= wj_dout[0];
      end
      if (aw_go) begin
        we_addr <= we_addr + 29'(we_len);
        we_left <= we_left - 22'(we_len);
        if (we_job_end) we_busy <= 1'b0;
      end
      wr_avail <= wr_avail + (wr_push ? WSW'(1) : WSW'(0)) - (aw_go ? WSW'(we_len) : WSW'(0));

      // FLUSH and IDLE: nothing is left in flight
      if (state == S_FLUSH || state == S_IDLE) begin
        df_req   <= (state == S_IDLE) && start_ok && !start_bad;
        nd_valid <= 1'b0;
        re_busy  <= 1'b0;
        we_busy  <= 1'b0;
        al_busy  <= 1'b0;
        rd_space <= RSW'(RD_DEPTH);
        wr_avail <= '0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Register inputs
  // ---------------------------------------------------------------------------
  wire err_capture = err_evt || start_bad;
  wire err_raise   = (flush && flushed) || start_bad;

  always_comb begin
    hwif_in.STATUS.busy.next     = (state != S_IDLE);
    hwif_in.STATUS.done.hwset    = done_evt;
    hwif_in.STATUS.done.hwclr    = start_ok;
    hwif_in.STATUS.err.hwset     = err_raise;
    hwif_in.STATUS.err.hwclr     = start_ok;
    hwif_in.ERR_INFO.cause.we    = err_capture || start_ok;
    hwif_in.ERR_INFO.cause.next  = start_bad ? C_BAD : (err_evt ? err_cause : 3'd0);
    hwif_in.ERR_INFO.resp.we     = err_capture || start_ok;
    hwif_in.ERR_INFO.resp.next   = err_evt ? err_resp : 2'd0;
    hwif_in.ERR_ADDR.addr.we     = err_capture || start_ok;
    hwif_in.ERR_ADDR.addr.next   = start_bad ? desc_ptr : (err_evt ? err_addr : 32'd0);
    hwif_in.CUR_DESC.addr.next   = cur_desc;
    hwif_in.DESC_DONE.count.next = desc_done;
    hwif_in.CYCLES.count.next    = cycles;
  end

  assign irq_done = hwif_out.STATUS.done.value;
  assign irq_err  = hwif_out.STATUS.err.value;

  // BID is always the write ID. The read FIFO cannot overflow: every beat is
  // reserved in rd_space before its AR is issued.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{m_bid, rd_full};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : dma

`default_nettype wire
