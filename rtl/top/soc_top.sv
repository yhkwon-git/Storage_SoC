`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// soc_top
//
// The SoC as far as step 1-6 (docs/04_cpu_subsystem.md, docs/06_dma.md): one
// clock domain (clk_sys), one reset.
//
//   M0 Ibex instruction port  -> obi2axi (read only)
//   M1 Ibex data port         -> obi2axi
//   M2 DMA                    -> dma (registers in APB slot 4)
//   M3                        -> port ext_* (the host interface comes in phase
//                                2; the testbench drives traffic on it)
//   S0 boot ROM 16 KiB        -> axi_mem, read only, loaded from +rom=<file>
//   S1 SRAM 64 KiB            -> axi_mem
//   S2 APB window             -> axi2apb: slot 0 SYS, 2 INTC, 3 TIMER, 4 DMA
//   S3, S4 NAND page buffers  -> axi_mem 4 KiB each until the NAND channels exist
//
// The timer drives the core's timer interrupt and the INTC its external
// interrupt. INTC sources: 1 DMA done, 2 DMA error (docs/01, section 7); the
// others are not wired yet.
// -----------------------------------------------------------------------------

module soc_top (
  input  wire                    clk,
  input  wire                    rst_n,

  // AXI4 master port M3, 2-bit IDs.
  input  wire  [1:0]             ext_awid,
  input  wire  [31:0]            ext_awaddr,
  input  wire  [7:0]             ext_awlen,
  input  wire  [2:0]             ext_awsize,
  input  wire  [1:0]             ext_awburst,
  input  wire  [2:0]             ext_awprot,
  input  wire  [3:0]             ext_awcache,
  input  wire  [3:0]             ext_awqos,
  input  wire                    ext_awvalid,
  output logic                   ext_awready,
  input  wire  [63:0]            ext_wdata,
  input  wire  [7:0]             ext_wstrb,
  input  wire                    ext_wlast,
  input  wire                    ext_wvalid,
  output logic                   ext_wready,
  output logic [1:0]             ext_bid,
  output logic [1:0]             ext_bresp,
  output logic                   ext_bvalid,
  input  wire                    ext_bready,
  input  wire  [1:0]             ext_arid,
  input  wire  [31:0]            ext_araddr,
  input  wire  [7:0]             ext_arlen,
  input  wire  [2:0]             ext_arsize,
  input  wire  [1:0]             ext_arburst,
  input  wire  [2:0]             ext_arprot,
  input  wire  [3:0]             ext_arcache,
  input  wire  [3:0]             ext_arqos,
  input  wire                    ext_arvalid,
  output logic                   ext_arready,
  output logic [1:0]             ext_rid,
  output logic [63:0]            ext_rdata,
  output logic [1:0]             ext_rresp,
  output logic                   ext_rlast,
  output logic                   ext_rvalid,
  input  wire                    ext_rready,

  // Simulation console and exit (SYS block), and a core lock-up flag.
  output logic                   console_valid,
  output logic [7:0]             console_char,
  output logic                   exit_valid,
  output logic [31:0]            exit_code,
  output logic                   cpu_double_fault
);

  localparam int NM = 4;
  localparam int NS = 5;

  // ---------------------------------------------------------------------------
  // Crossbar signals
  // ---------------------------------------------------------------------------
  logic [NM-1:0][1:0]  s_awid,  s_arid,  s_bid,   s_rid;
  logic [NM-1:0][31:0] s_awaddr, s_araddr;
  logic [NM-1:0][7:0]  s_awlen, s_arlen;
  logic [NM-1:0][2:0]  s_awsize, s_arsize, s_awprot, s_arprot;
  logic [NM-1:0][1:0]  s_awburst, s_arburst, s_bresp, s_rresp;
  logic [NM-1:0][3:0]  s_awcache, s_arcache, s_awqos, s_arqos;
  logic [NM-1:0]       s_awvalid, s_awready, s_arvalid, s_arready;
  logic [NM-1:0][63:0] s_wdata, s_rdata;
  logic [NM-1:0][7:0]  s_wstrb;
  logic [NM-1:0]       s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
  logic [NM-1:0]       s_rlast, s_rvalid, s_rready;

  logic [NS-1:0][3:0]  m_awid,  m_arid,  m_bid,   m_rid;
  logic [NS-1:0][31:0] m_awaddr, m_araddr;
  logic [NS-1:0][7:0]  m_awlen, m_arlen;
  logic [NS-1:0][2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
  logic [NS-1:0][1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
  logic [NS-1:0][3:0]  m_awcache, m_arcache, m_awqos, m_arqos;
  logic [NS-1:0]       m_awvalid, m_awready, m_arvalid, m_arready;
  logic [NS-1:0][63:0] m_wdata, m_rdata;
  logic [NS-1:0][7:0]  m_wstrb;
  logic [NS-1:0]       m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [NS-1:0]       m_rlast, m_rvalid, m_rready;

  logic [NM-1:0]       stat_aw_id_stall, stat_ar_id_stall;

  axi_xbar u_xbar (.*);

  // ---------------------------------------------------------------------------
  // CPU: Ibex and its two AXI ports (M0, M1)
  // ---------------------------------------------------------------------------
  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;
  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic        irq_timer, irq_external, core_busy;

  cpu_ibex u_cpu (
    .clk          (clk),
    .rst_n        (rst_n),
    .instr_req    (instr_req),
    .instr_gnt    (instr_gnt),
    .instr_rvalid (instr_rvalid),
    .instr_addr   (instr_addr),
    .instr_rdata  (instr_rdata),
    .instr_err    (instr_err),
    .data_req     (data_req),
    .data_gnt     (data_gnt),
    .data_rvalid  (data_rvalid),
    .data_we      (data_we),
    .data_be      (data_be),
    .data_addr    (data_addr),
    .data_wdata   (data_wdata),
    .data_rdata   (data_rdata),
    .data_err     (data_err),
    .irq_timer    (irq_timer),
    .irq_external (irq_external),
    .core_busy    (core_busy),
    .double_fault (cpu_double_fault)
  );

  obi2axi #(.READ_ONLY(1'b1), .MAX_OUT(2), .IDW(2)) u_ibus (
    .clk       (clk),          .rst_n     (rst_n),
    .req       (instr_req),    .gnt       (instr_gnt),    .we       (1'b0),
    .be        (4'hF),         .addr      (instr_addr),   .wdata    (32'd0),
    .rvalid    (instr_rvalid), .rdata     (instr_rdata),  .err      (instr_err),
    .m_awid    (s_awid[0]),    .m_awaddr  (s_awaddr[0]),  .m_awlen  (s_awlen[0]),
    .m_awsize  (s_awsize[0]),  .m_awburst (s_awburst[0]), .m_awvalid(s_awvalid[0]),
    .m_awready (s_awready[0]),
    .m_wdata   (s_wdata[0]),   .m_wstrb   (s_wstrb[0]),   .m_wlast  (s_wlast[0]),
    .m_wvalid  (s_wvalid[0]),  .m_wready  (s_wready[0]),
    .m_bid     (s_bid[0]),     .m_bresp   (s_bresp[0]),   .m_bvalid (s_bvalid[0]),
    .m_bready  (s_bready[0]),
    .m_arid    (s_arid[0]),    .m_araddr  (s_araddr[0]),  .m_arlen  (s_arlen[0]),
    .m_arsize  (s_arsize[0]),  .m_arburst (s_arburst[0]), .m_arvalid(s_arvalid[0]),
    .m_arready (s_arready[0]),
    .m_rid     (s_rid[0]),     .m_rdata   (s_rdata[0]),   .m_rresp  (s_rresp[0]),
    .m_rlast   (s_rlast[0]),   .m_rvalid  (s_rvalid[0]),  .m_rready (s_rready[0])
  );

  obi2axi #(.READ_ONLY(1'b0), .MAX_OUT(2), .IDW(2)) u_dbus (
    .clk       (clk),          .rst_n     (rst_n),
    .req       (data_req),     .gnt       (data_gnt),     .we       (data_we),
    .be        (data_be),      .addr      (data_addr),    .wdata    (data_wdata),
    .rvalid    (data_rvalid),  .rdata     (data_rdata),   .err      (data_err),
    .m_awid    (s_awid[1]),    .m_awaddr  (s_awaddr[1]),  .m_awlen  (s_awlen[1]),
    .m_awsize  (s_awsize[1]),  .m_awburst (s_awburst[1]), .m_awvalid(s_awvalid[1]),
    .m_awready (s_awready[1]),
    .m_wdata   (s_wdata[1]),   .m_wstrb   (s_wstrb[1]),   .m_wlast  (s_wlast[1]),
    .m_wvalid  (s_wvalid[1]),  .m_wready  (s_wready[1]),
    .m_bid     (s_bid[1]),     .m_bresp   (s_bresp[1]),   .m_bvalid (s_bvalid[1]),
    .m_bready  (s_bready[1]),
    .m_arid    (s_arid[1]),    .m_araddr  (s_araddr[1]),  .m_arlen  (s_arlen[1]),
    .m_arsize  (s_arsize[1]),  .m_arburst (s_arburst[1]), .m_arvalid(s_arvalid[1]),
    .m_arready (s_arready[1]),
    .m_rid     (s_rid[1]),     .m_rdata   (s_rdata[1]),   .m_rresp  (s_rresp[1]),
    .m_rlast   (s_rlast[1]),   .m_rvalid  (s_rvalid[1]),  .m_rready (s_rready[1])
  );

  // The CPU ports carry no protection, cache or QoS attributes.
  for (genvar i = 0; i < 2; i++) begin : g_cpu_attr
    assign s_awprot[i]  = 3'b000;
    assign s_arprot[i]  = (i == 0) ? 3'b100 : 3'b000;  // instruction fetch
    assign s_awcache[i] = 4'b0000;
    assign s_arcache[i] = 4'b0000;
    assign s_awqos[i]   = 4'b0000;
    assign s_arqos[i]   = 4'b0000;
  end

  // ---------------------------------------------------------------------------
  // APB signals (bridge below), declared here for the DMA's register port
  // ---------------------------------------------------------------------------
  localparam int NSLOT = 8;

  logic [NSLOT-1:0]       psel;
  logic                   penable, pwrite;
  logic [15:0]            paddr;
  logic [31:0]            pwdata;
  logic [3:0]             pstrb;
  logic [2:0]             pprot;
  logic [NSLOT-1:0][31:0] prdata;
  logic [NSLOT-1:0]       pready, pslverr;

  // ---------------------------------------------------------------------------
  // M2: DMA (its APB side is slot 4, below)
  // ---------------------------------------------------------------------------
  logic        dma_psel;
  logic [31:0] dma_prdata;
  logic        dma_pready, dma_pslverr;
  logic        irq_dma_done, irq_dma_err;

  dma u_dma (
    .clk       (clk),          .rst_n     (rst_n),
    .psel      (dma_psel),     .penable   (penable),      .paddr    (paddr[11:0]),
    .pwrite    (pwrite),       .pwdata    (pwdata),       .pstrb    (pstrb),
    .prdata    (dma_prdata),   .pready    (dma_pready),   .pslverr  (dma_pslverr),
    .m_awid    (s_awid[2]),    .m_awaddr  (s_awaddr[2]),  .m_awlen  (s_awlen[2]),
    .m_awsize  (s_awsize[2]),  .m_awburst (s_awburst[2]), .m_awprot (s_awprot[2]),
    .m_awcache (s_awcache[2]), .m_awqos   (s_awqos[2]),   .m_awvalid(s_awvalid[2]),
    .m_awready (s_awready[2]),
    .m_wdata   (s_wdata[2]),   .m_wstrb   (s_wstrb[2]),   .m_wlast  (s_wlast[2]),
    .m_wvalid  (s_wvalid[2]),  .m_wready  (s_wready[2]),
    .m_bid     (s_bid[2]),     .m_bresp   (s_bresp[2]),   .m_bvalid (s_bvalid[2]),
    .m_bready  (s_bready[2]),
    .m_arid    (s_arid[2]),    .m_araddr  (s_araddr[2]),  .m_arlen  (s_arlen[2]),
    .m_arsize  (s_arsize[2]),  .m_arburst (s_arburst[2]), .m_arprot (s_arprot[2]),
    .m_arcache (s_arcache[2]), .m_arqos   (s_arqos[2]),   .m_arvalid(s_arvalid[2]),
    .m_arready (s_arready[2]),
    .m_rid     (s_rid[2]),     .m_rdata   (s_rdata[2]),   .m_rresp  (s_rresp[2]),
    .m_rlast   (s_rlast[2]),   .m_rvalid  (s_rvalid[2]),  .m_rready (s_rready[2]),
    .irq_done  (irq_dma_done), .irq_err   (irq_dma_err)
  );

  // ---------------------------------------------------------------------------
  // External master port (M3)
  // ---------------------------------------------------------------------------
  assign s_awid[3]    = ext_awid;
  assign s_awaddr[3]  = ext_awaddr;
  assign s_awlen[3]   = ext_awlen;
  assign s_awsize[3]  = ext_awsize;
  assign s_awburst[3] = ext_awburst;
  assign s_awprot[3]  = ext_awprot;
  assign s_awcache[3] = ext_awcache;
  assign s_awqos[3]   = ext_awqos;
  assign s_awvalid[3] = ext_awvalid;
  assign ext_awready  = s_awready[3];
  assign s_wdata[3]   = ext_wdata;
  assign s_wstrb[3]   = ext_wstrb;
  assign s_wlast[3]   = ext_wlast;
  assign s_wvalid[3]  = ext_wvalid;
  assign ext_wready   = s_wready[3];
  assign ext_bid      = s_bid[3];
  assign ext_bresp    = s_bresp[3];
  assign ext_bvalid   = s_bvalid[3];
  assign s_bready[3]  = ext_bready;
  assign s_arid[3]    = ext_arid;
  assign s_araddr[3]  = ext_araddr;
  assign s_arlen[3]   = ext_arlen;
  assign s_arsize[3]  = ext_arsize;
  assign s_arburst[3] = ext_arburst;
  assign s_arprot[3]  = ext_arprot;
  assign s_arcache[3] = ext_arcache;
  assign s_arqos[3]   = ext_arqos;
  assign s_arvalid[3] = ext_arvalid;
  assign ext_arready  = s_arready[3];
  assign ext_rid      = s_rid[3];
  assign ext_rdata    = s_rdata[3];
  assign ext_rresp    = s_rresp[3];
  assign ext_rlast    = s_rlast[3];
  assign ext_rvalid   = s_rvalid[3];
  assign s_rready[3]  = ext_rready;

  // ---------------------------------------------------------------------------
  // Memories: S0 ROM, S1 SRAM, S3/S4 NAND page buffers
  // ---------------------------------------------------------------------------
  localparam int MEM_WORDS [NS] = '{2048, 8192, 0, 512, 512};

  for (genvar s = 0; s < NS; s++) begin : g_mem
    if (s != 2) begin : g_m
      axi_mem #(
        .WORDS        (MEM_WORDS[s]),
        .READ_ONLY    (s == 0),
        .IDW          (4),
        .INIT_PLUSARG ((s == 0) ? "rom" : "")
      ) u_mem (
        .clk       (clk),          .rst_n     (rst_n),
        .s_awid    (m_awid[s]),    .s_awaddr  (m_awaddr[s]),  .s_awlen  (m_awlen[s]),
        .s_awvalid (m_awvalid[s]), .s_awready (m_awready[s]),
        .s_wdata   (m_wdata[s]),   .s_wstrb   (m_wstrb[s]),   .s_wlast  (m_wlast[s]),
        .s_wvalid  (m_wvalid[s]),  .s_wready  (m_wready[s]),
        .s_bid     (m_bid[s]),     .s_bresp   (m_bresp[s]),   .s_bvalid (m_bvalid[s]),
        .s_bready  (m_bready[s]),
        .s_arid    (m_arid[s]),    .s_araddr  (m_araddr[s]),  .s_arlen  (m_arlen[s]),
        .s_arvalid (m_arvalid[s]), .s_arready (m_arready[s]),
        .s_rid     (m_rid[s]),     .s_rdata   (m_rdata[s]),   .s_rresp  (m_rresp[s]),
        .s_rlast   (m_rlast[s]),   .s_rvalid  (m_rvalid[s]),  .s_rready (m_rready[s])
      );
    end
  end

  // ---------------------------------------------------------------------------
  // S2: APB window
  // ---------------------------------------------------------------------------
  axi2apb #(.IDW(4), .NSLOT(NSLOT), .SLOT_EN(8'b0001_1101)) u_apb (
    .clk       (clk),          .rst_n     (rst_n),
    .s_awid    (m_awid[2]),    .s_awaddr  (m_awaddr[2]),  .s_awlen  (m_awlen[2]),
    .s_awsize  (m_awsize[2]),  .s_awprot  (m_awprot[2]),  .s_awvalid(m_awvalid[2]),
    .s_awready (m_awready[2]),
    .s_wdata   (m_wdata[2]),   .s_wstrb   (m_wstrb[2]),   .s_wlast  (m_wlast[2]),
    .s_wvalid  (m_wvalid[2]),  .s_wready  (m_wready[2]),
    .s_bid     (m_bid[2]),     .s_bresp   (m_bresp[2]),   .s_bvalid (m_bvalid[2]),
    .s_bready  (m_bready[2]),
    .s_arid    (m_arid[2]),    .s_araddr  (m_araddr[2]),  .s_arlen  (m_arlen[2]),
    .s_arsize  (m_arsize[2]),  .s_arprot  (m_arprot[2]),  .s_arvalid(m_arvalid[2]),
    .s_arready (m_arready[2]),
    .s_rid     (m_rid[2]),     .s_rdata   (m_rdata[2]),   .s_rresp  (m_rresp[2]),
    .s_rlast   (m_rlast[2]),   .s_rvalid  (m_rvalid[2]),  .s_rready (m_rready[2]),
    .psel      (psel),         .penable   (penable),      .paddr    (paddr),
    .pwrite    (pwrite),       .pwdata    (pwdata),       .pstrb    (pstrb),
    .pprot     (pprot),        .prdata    (prdata),       .pready   (pready),
    .pslverr   (pslverr)
  );

  apb_sys u_sys (
    .clk (clk), .rst_n (rst_n),
    .psel (psel[0]), .penable (penable), .paddr (paddr[11:0]), .pwrite (pwrite),
    .pwdata (pwdata), .pstrb (pstrb), .prdata (prdata[0]), .pready (pready[0]),
    .pslverr (pslverr[0]),
    .console_valid (console_valid), .console_char (console_char),
    .exit_valid (exit_valid), .exit_code (exit_code)
  );

  apb_intc u_intc (
    .clk (clk), .rst_n (rst_n),
    .psel (psel[2]), .penable (penable), .paddr (paddr[11:0]), .pwrite (pwrite),
    .pwdata (pwdata), .pstrb (pstrb), .prdata (prdata[2]), .pready (pready[2]),
    .pslverr (pslverr[2]),
    .src ({29'd0, irq_dma_err, irq_dma_done, 1'b0}), .irq (irq_external)
  );

  apb_timer u_timer (
    .clk (clk), .rst_n (rst_n),
    .psel (psel[3]), .penable (penable), .paddr (paddr[11:0]), .pwrite (pwrite),
    .pwdata (pwdata), .pstrb (pstrb), .prdata (prdata[3]), .pready (pready[3]),
    .pslverr (pslverr[3]), .irq (irq_timer)
  );

  assign dma_psel   = psel[4];
  assign prdata[4]  = dma_prdata;
  assign pready[4]  = dma_pready;
  assign pslverr[4] = dma_pslverr;

  // Slots without a peripheral: the bridge never selects them.
  for (genvar i = 0; i < NSLOT; i++) begin : g_empty_slot
    if (i == 1 || i >= 5) begin : g_e
      assign prdata[i]  = 32'd0;
      assign pready[i]  = 1'b1;
      assign pslverr[i] = 1'b1;
    end
  end

  // Fields the memories and peripherals do not use (sizes, bursts, cache and
  // QoS attributes, protection on the APB, the crossbar's statistics, and the
  // core's busy flag, which feeds clock gating in step 1-7).
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{m_awsize, m_arsize, m_awburst, m_arburst, m_awcache, m_arcache,
                     m_awqos, m_arqos, m_awprot, m_arprot, pprot, paddr[15:12],
                     psel[1], psel[NSLOT-1:5],
                     stat_aw_id_stall, stat_ar_id_stall, core_busy};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : soc_top

`default_nettype wire
