`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_xbar
//
// Sparse AXI4 crossbar, NM masters by NS slaves (docs/01_soc_architecture.md,
// section 5, and docs/03_axi_crossbar.md).
//
// Address decode. Slave s owns the addresses where (addr & SLV_MASK[s]) ==
// SLV_BASE[s]. A master reaches slave s only if CONN[m][s] is set. Any other
// address goes to that master's own default slave, which answers DECERR.
//
// IDs. A master's ID is MIDW bits. Toward the slaves the crossbar prepends the
// master index, so slave-side IDs are MIDW + log2(NM) bits, and B and R are
// routed back by those top bits.
//
// Ordering. Per master and direction, axi_id_tracker holds a request while
// MAX_OUT are outstanding, or while its ID has transactions outstanding at a
// different target. Responses with one ID therefore come from one slave and
// stay in order.
//
// Arbitration. AW and AR are round-robin per slave; B and R are round-robin
// per master. A grant whose VALID waits for READY is held, so VALID and its
// payload never change before the handshake. R is held to one slave from the
// first beat to RLAST, so read bursts are not interleaved at a master; this
// needs slaves that do not interleave read bursts themselves.
//
// Write data. Each master keeps the targets of its accepted AWs in order, and
// each slave keeps the masters of the AWs it accepted in order. A W beat moves
// when both heads agree, so W follows AW order on both sides. W is not
// accepted before its AW.
//
// Statistics. stat_*_id_stall[m] is high in a cycle where master m presents a
// request that the same-ID rule holds.
// -----------------------------------------------------------------------------

module axi_xbar #(
  parameter  int NM      = 4,
  parameter  int NS      = 5,
  parameter  int AW      = 32,
  parameter  int DW      = 64,
  parameter  int MIDW    = 2,
  parameter  int MAX_OUT = 4,
  // Slaves: 0 ROM, 1 SRAM, 2 APB, 3 NAND0, 4 NAND1.
  parameter  logic [NS-1:0][AW-1:0] SLV_BASE = {32'h3001_0000, 32'h3000_0000,
                                                32'h4000_0000, 32'h1000_0000,
                                                32'h0000_0000},
  parameter  logic [NS-1:0][AW-1:0] SLV_MASK = {32'hFFFF_F000, 32'hFFFF_F000,
                                                32'hFFFF_0000, 32'hFFFF_0000,
                                                32'hFFFF_C000},
  // Masters: 0 CPU instruction, 1 CPU data, 2 DMA, 3 host. Bit s = slave s.
  parameter  logic [NM-1:0][NS-1:0] CONN     = {5'b00110, 5'b11010, 5'b11111,
                                                5'b00011},
  localparam int SW       = DW / 8,
  localparam int MW       = (NM > 1) ? $clog2(NM) : 1,
  localparam int SIDW     = MIDW + MW,
  localparam int TW       = $clog2(NS + 1),
  localparam int WS_DEPTH = 1 << $clog2(NM * MAX_OUT)
) (
  input  wire                        clk,
  input  wire                        rst_n,

  // Slave ports, one per master.
  input  wire  [NM-1:0][MIDW-1:0]    s_awid,
  input  wire  [NM-1:0][AW-1:0]      s_awaddr,
  input  wire  [NM-1:0][7:0]         s_awlen,
  input  wire  [NM-1:0][2:0]         s_awsize,
  input  wire  [NM-1:0][1:0]         s_awburst,
  input  wire  [NM-1:0][2:0]         s_awprot,
  input  wire  [NM-1:0][3:0]         s_awcache,
  input  wire  [NM-1:0][3:0]         s_awqos,
  input  wire  [NM-1:0]              s_awvalid,
  output logic [NM-1:0]              s_awready,

  input  wire  [NM-1:0][DW-1:0]      s_wdata,
  input  wire  [NM-1:0][SW-1:0]      s_wstrb,
  input  wire  [NM-1:0]              s_wlast,
  input  wire  [NM-1:0]              s_wvalid,
  output logic [NM-1:0]              s_wready,

  output logic [NM-1:0][MIDW-1:0]    s_bid,
  output logic [NM-1:0][1:0]         s_bresp,
  output logic [NM-1:0]              s_bvalid,
  input  wire  [NM-1:0]              s_bready,

  input  wire  [NM-1:0][MIDW-1:0]    s_arid,
  input  wire  [NM-1:0][AW-1:0]      s_araddr,
  input  wire  [NM-1:0][7:0]         s_arlen,
  input  wire  [NM-1:0][2:0]         s_arsize,
  input  wire  [NM-1:0][1:0]         s_arburst,
  input  wire  [NM-1:0][2:0]         s_arprot,
  input  wire  [NM-1:0][3:0]         s_arcache,
  input  wire  [NM-1:0][3:0]         s_arqos,
  input  wire  [NM-1:0]              s_arvalid,
  output logic [NM-1:0]              s_arready,

  output logic [NM-1:0][MIDW-1:0]    s_rid,
  output logic [NM-1:0][DW-1:0]      s_rdata,
  output logic [NM-1:0][1:0]         s_rresp,
  output logic [NM-1:0]              s_rlast,
  output logic [NM-1:0]              s_rvalid,
  input  wire  [NM-1:0]              s_rready,

  // Master ports, one per slave.
  output logic [NS-1:0][SIDW-1:0]    m_awid,
  output logic [NS-1:0][AW-1:0]      m_awaddr,
  output logic [NS-1:0][7:0]         m_awlen,
  output logic [NS-1:0][2:0]         m_awsize,
  output logic [NS-1:0][1:0]         m_awburst,
  output logic [NS-1:0][2:0]         m_awprot,
  output logic [NS-1:0][3:0]         m_awcache,
  output logic [NS-1:0][3:0]         m_awqos,
  output logic [NS-1:0]              m_awvalid,
  input  wire  [NS-1:0]              m_awready,

  output logic [NS-1:0][DW-1:0]      m_wdata,
  output logic [NS-1:0][SW-1:0]      m_wstrb,
  output logic [NS-1:0]              m_wlast,
  output logic [NS-1:0]              m_wvalid,
  input  wire  [NS-1:0]              m_wready,

  input  wire  [NS-1:0][SIDW-1:0]    m_bid,
  input  wire  [NS-1:0][1:0]         m_bresp,
  input  wire  [NS-1:0]              m_bvalid,
  output logic [NS-1:0]              m_bready,

  output logic [NS-1:0][SIDW-1:0]    m_arid,
  output logic [NS-1:0][AW-1:0]      m_araddr,
  output logic [NS-1:0][7:0]         m_arlen,
  output logic [NS-1:0][2:0]         m_arsize,
  output logic [NS-1:0][1:0]         m_arburst,
  output logic [NS-1:0][2:0]         m_arprot,
  output logic [NS-1:0][3:0]         m_arcache,
  output logic [NS-1:0][3:0]         m_arqos,
  output logic [NS-1:0]              m_arvalid,
  input  wire  [NS-1:0]              m_arready,

  input  wire  [NS-1:0][SIDW-1:0]    m_rid,
  input  wire  [NS-1:0][DW-1:0]      m_rdata,
  input  wire  [NS-1:0][1:0]         m_rresp,
  input  wire  [NS-1:0]              m_rlast,
  input  wire  [NS-1:0]              m_rvalid,
  output logic [NS-1:0]              m_rready,

  output logic [NM-1:0]              stat_aw_id_stall,
  output logic [NM-1:0]              stat_ar_id_stall
);

  localparam logic [TW-1:0] T_ERR = TW'(NS);

  function automatic logic [TW-1:0] decode(input logic [AW-1:0] a, input logic [NS-1:0] conn);
    logic [TW-1:0] t;
    t = T_ERR;
    for (int s = 0; s < NS; s++) begin
      if (conn[s] && ((a & SLV_MASK[s]) == SLV_BASE[s])) t = TW'(s);
    end
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Per-master state
  // ---------------------------------------------------------------------------
  logic [NM-1:0][TW-1:0] aw_tgt, ar_tgt;
  logic [NM-1:0]         aw_allow, ar_allow, aw_idblk, ar_idblk;
  logic [NM-1:0]         aw_req, ar_req;
  logic [NM-1:0][TW-1:0] wt_head;
  logic [NM-1:0]         wt_empty, wt_full;
  logic [NM-1:0]         aw_fire, ar_fire, w_last_fire, b_fire, r_last_fire;

  // Default slaves.
  logic [NM-1:0]            err_awready, err_wready, err_arready;
  logic [NM-1:0][MIDW-1:0]  err_bid, err_rid;
  logic [NM-1:0][1:0]       err_bresp, err_rresp;
  logic [NM-1:0]            err_bvalid, err_bready;
  logic [NM-1:0][DW-1:0]    err_rdata;
  logic [NM-1:0]            err_rlast, err_rvalid, err_rready;

  // ---------------------------------------------------------------------------
  // Per-slave state
  // ---------------------------------------------------------------------------
  logic [NS-1:0][NM-1:0] aw_sreq, ar_sreq, aw_gnt, ar_gnt;
  logic [NS-1:0][MW-1:0] aw_gidx, ar_gidx;
  logic [NS-1:0][MW-1:0] ws_head;
  logic [NS-1:0]         ws_empty, ws_full;

  // Per-master response arbitration over NS slaves plus the default slave.
  logic [NM-1:0][NS:0]   b_sreq, r_sreq, b_gnt, r_gnt;
  logic [NM-1:0][TW-1:0] b_gidx, r_gidx;
  logic [NM-1:0]         r_inburst;

  for (genvar m = 0; m < NM; m++) begin : g_m
    assign aw_tgt[m] = decode(s_awaddr[m], CONN[m]);
    assign ar_tgt[m] = decode(s_araddr[m], CONN[m]);

    axi_id_tracker #(.IDW(MIDW), .TW(TW), .MAX_OUT(MAX_OUT)) u_trk_aw (
      .clk      (clk),
      .rst_n    (rst_n),
      .req_id   (s_awid[m]),
      .req_tgt  (aw_tgt[m]),
      .allow    (aw_allow[m]),
      .id_block (aw_idblk[m]),
      .push     (aw_fire[m]),
      .done     (b_fire[m]),
      .done_id  (s_bid[m])
    );

    axi_id_tracker #(.IDW(MIDW), .TW(TW), .MAX_OUT(MAX_OUT)) u_trk_ar (
      .clk      (clk),
      .rst_n    (rst_n),
      .req_id   (s_arid[m]),
      .req_tgt  (ar_tgt[m]),
      .allow    (ar_allow[m]),
      .id_block (ar_idblk[m]),
      .push     (ar_fire[m]),
      .done     (r_last_fire[m]),
      .done_id  (s_rid[m])
    );

    // Targets of this master's accepted AWs, in order, for routing its W.
    fifo_sync #(.WIDTH(TW), .DEPTH(MAX_OUT)) u_wt (
      .clk   (clk),
      .rst_n (rst_n),
      .push  (aw_fire[m]),
      .din   (aw_tgt[m]),
      .full  (wt_full[m]),
      .pop   (w_last_fire[m]),
      .dout  (wt_head[m]),
      .empty (wt_empty[m])
    );

    assign aw_req[m] = s_awvalid[m] && aw_allow[m] && !wt_full[m];
    assign ar_req[m] = s_arvalid[m] && ar_allow[m];

    assign stat_aw_id_stall[m] = s_awvalid[m] && aw_idblk[m];
    assign stat_ar_id_stall[m] = s_arvalid[m] && ar_idblk[m];

    assign aw_fire[m]     = s_awvalid[m] && s_awready[m];
    assign ar_fire[m]     = s_arvalid[m] && s_arready[m];
    assign w_last_fire[m] = s_wvalid[m] && s_wready[m] && s_wlast[m];
    assign b_fire[m]      = s_bvalid[m] && s_bready[m];
    assign r_last_fire[m] = s_rvalid[m] && s_rready[m] && s_rlast[m];

    axi_err_slv #(.IDW(MIDW), .DW(DW)) u_err (
      .clk     (clk),
      .rst_n   (rst_n),
      .awid    (s_awid[m]),
      .awvalid (aw_req[m] && (aw_tgt[m] == T_ERR)),
      .awready (err_awready[m]),
      .wlast   (s_wlast[m]),
      .wvalid  (s_wvalid[m] && !wt_empty[m] && (wt_head[m] == T_ERR)),
      .wready  (err_wready[m]),
      .bid     (err_bid[m]),
      .bresp   (err_bresp[m]),
      .bvalid  (err_bvalid[m]),
      .bready  (err_bready[m]),
      .arid    (s_arid[m]),
      .arlen   (s_arlen[m]),
      .arvalid (ar_req[m] && (ar_tgt[m] == T_ERR)),
      .arready (err_arready[m]),
      .rid     (err_rid[m]),
      .rdata   (err_rdata[m]),
      .rresp   (err_rresp[m]),
      .rlast   (err_rlast[m]),
      .rvalid  (err_rvalid[m]),
      .rready  (err_rready[m])
    );

    // AW and AR ready back to the master.
    logic awready_m, arready_m, wready_m;
    always_comb begin
      awready_m = (aw_tgt[m] == T_ERR) && aw_req[m] && err_awready[m];
      arready_m = (ar_tgt[m] == T_ERR) && ar_req[m] && err_arready[m];
      for (int s = 0; s < NS; s++) begin
        if (aw_tgt[m] == TW'(s)) awready_m = aw_gnt[s][m] && aw_sreq[s][m] && m_awready[s];
        if (ar_tgt[m] == TW'(s)) arready_m = ar_gnt[s][m] && ar_sreq[s][m] && m_arready[s];
      end
    end
    assign s_awready[m] = awready_m;
    assign s_arready[m] = arready_m;

    // W ready: the head target of this master must have this master at the
    // head of its own order.
    always_comb begin
      wready_m = 1'b0;
      if (!wt_empty[m]) begin
        if (wt_head[m] == T_ERR) wready_m = err_wready[m];
        for (int s = 0; s < NS; s++) begin
          if (wt_head[m] == TW'(s)) begin
            wready_m = !ws_empty[s] && (ws_head[s] == MW'(m)) && m_wready[s];
          end
        end
      end
    end
    assign s_wready[m] = wready_m;

    // B: requests from every slave whose BID names this master, plus the
    // default slave as source NS.
    for (genvar s = 0; s < NS; s++) begin : g_bsrc
      assign b_sreq[m][s] = m_bvalid[s] && (m_bid[s][SIDW-1:MIDW] == MW'(m));
      assign r_sreq[m][s] = m_rvalid[s] && (m_rid[s][SIDW-1:MIDW] == MW'(m));
    end
    assign b_sreq[m][NS] = err_bvalid[m];
    assign r_sreq[m][NS] = err_rvalid[m];

    rr_arb #(.N(NS + 1)) u_b_arb (
      .clk   (clk),
      .rst_n (rst_n),
      .req   (b_sreq[m]),
      .keep  (s_bvalid[m] && !s_bready[m]),
      .fire  (b_fire[m]),
      .gnt   (b_gnt[m]),
      .idx   (b_gidx[m])
    );

    // R stays with one source from the first beat to RLAST.
    logic keep_r;
    assign keep_r = s_rvalid[m] ? !(s_rready[m] && s_rlast[m]) : r_inburst[m];

    rr_arb #(.N(NS + 1)) u_r_arb (
      .clk   (clk),
      .rst_n (rst_n),
      .req   (r_sreq[m]),
      .keep  (keep_r),
      .fire  (r_last_fire[m]),
      .gnt   (r_gnt[m]),
      .idx   (r_gidx[m])
    );

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        r_inburst[m] <= 1'b0;
      end else if (s_rvalid[m] && s_rready[m]) begin
        r_inburst[m] <= !s_rlast[m];
      end
    end

    always_comb begin
      s_bvalid[m] = |(b_gnt[m] & b_sreq[m]);
      s_bid[m]    = err_bid[m];
      s_bresp[m]  = err_bresp[m];
      s_rvalid[m] = |(r_gnt[m] & r_sreq[m]);
      s_rid[m]    = err_rid[m];
      s_rdata[m]  = err_rdata[m];
      s_rresp[m]  = err_rresp[m];
      s_rlast[m]  = err_rlast[m];
      for (int s = 0; s < NS; s++) begin
        if (b_gidx[m] == TW'(s)) begin
          s_bid[m]   = m_bid[s][MIDW-1:0];
          s_bresp[m] = m_bresp[s];
        end
        if (r_gidx[m] == TW'(s)) begin
          s_rid[m]   = m_rid[s][MIDW-1:0];
          s_rdata[m] = m_rdata[s];
          s_rresp[m] = m_rresp[s];
          s_rlast[m] = m_rlast[s];
        end
      end
    end

    assign err_bready[m] = b_gnt[m][NS] && s_bready[m];
    assign err_rready[m] = r_gnt[m][NS] && s_rready[m];
  end : g_m

  for (genvar s = 0; s < NS; s++) begin : g_s
    for (genvar m = 0; m < NM; m++) begin : g_req
      assign aw_sreq[s][m] = aw_req[m] && (aw_tgt[m] == TW'(s)) && !ws_full[s];
      assign ar_sreq[s][m] = ar_req[m] && (ar_tgt[m] == TW'(s));
    end

    rr_arb #(.N(NM)) u_aw_arb (
      .clk   (clk),
      .rst_n (rst_n),
      .req   (aw_sreq[s]),
      .keep  (m_awvalid[s] && !m_awready[s]),
      .fire  (m_awvalid[s] && m_awready[s]),
      .gnt   (aw_gnt[s]),
      .idx   (aw_gidx[s])
    );

    rr_arb #(.N(NM)) u_ar_arb (
      .clk   (clk),
      .rst_n (rst_n),
      .req   (ar_sreq[s]),
      .keep  (m_arvalid[s] && !m_arready[s]),
      .fire  (m_arvalid[s] && m_arready[s]),
      .gnt   (ar_gnt[s]),
      .idx   (ar_gidx[s])
    );

    // Masters of the AWs this slave accepted, in order, for its W.
    fifo_sync #(.WIDTH(MW), .DEPTH(WS_DEPTH)) u_ws (
      .clk   (clk),
      .rst_n (rst_n),
      .push  (m_awvalid[s] && m_awready[s]),
      .din   (aw_gidx[s]),
      .full  (ws_full[s]),
      .pop   (m_wvalid[s] && m_wready[s] && m_wlast[s]),
      .dout  (ws_head[s]),
      .empty (ws_empty[s])
    );

    always_comb begin
      m_awvalid[s] = |(aw_gnt[s] & aw_sreq[s]);
      m_arvalid[s] = |(ar_gnt[s] & ar_sreq[s]);
      m_awid[s]    = '0;  m_awaddr[s]  = '0;  m_awlen[s]   = '0;  m_awsize[s] = '0;
      m_awburst[s] = '0;  m_awprot[s]  = '0;  m_awcache[s] = '0;  m_awqos[s]  = '0;
      m_arid[s]    = '0;  m_araddr[s]  = '0;  m_arlen[s]   = '0;  m_arsize[s] = '0;
      m_arburst[s] = '0;  m_arprot[s]  = '0;  m_arcache[s] = '0;  m_arqos[s]  = '0;
      m_wvalid[s]  = 1'b0;
      m_wdata[s]   = '0;  m_wstrb[s]   = '0;  m_wlast[s]   = 1'b0;
      for (int m = 0; m < NM; m++) begin
        if (aw_gidx[s] == MW'(m)) begin
          m_awid[s]    = {MW'(m), s_awid[m]};
          m_awaddr[s]  = s_awaddr[m];
          m_awlen[s]   = s_awlen[m];
          m_awsize[s]  = s_awsize[m];
          m_awburst[s] = s_awburst[m];
          m_awprot[s]  = s_awprot[m];
          m_awcache[s] = s_awcache[m];
          m_awqos[s]   = s_awqos[m];
        end
        if (ar_gidx[s] == MW'(m)) begin
          m_arid[s]    = {MW'(m), s_arid[m]};
          m_araddr[s]  = s_araddr[m];
          m_arlen[s]   = s_arlen[m];
          m_arsize[s]  = s_arsize[m];
          m_arburst[s] = s_arburst[m];
          m_arprot[s]  = s_arprot[m];
          m_arcache[s] = s_arcache[m];
          m_arqos[s]   = s_arqos[m];
        end
        if (!ws_empty[s] && (ws_head[s] == MW'(m))) begin
          m_wvalid[s] = s_wvalid[m] && !wt_empty[m] && (wt_head[m] == TW'(s));
          m_wdata[s]  = s_wdata[m];
          m_wstrb[s]  = s_wstrb[m];
          m_wlast[s]  = s_wlast[m];
        end
      end
    end

    // B and R ready back to the slave: the master its ID names has granted
    // this slave and is ready.
    always_comb begin
      m_bready[s] = 1'b0;
      m_rready[s] = 1'b0;
      for (int m = 0; m < NM; m++) begin
        if (b_gnt[m][s] && b_sreq[m][s] && s_bready[m]) m_bready[s] = 1'b1;
        if (r_gnt[m][s] && r_sreq[m][s] && s_rready[m]) m_rready[s] = 1'b1;
      end
    end
  end : g_s

endmodule : axi_xbar

`default_nettype wire
