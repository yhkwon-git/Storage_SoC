// tb_nvme
//
// Testbench of the NVMe controller's registers and queues (rtl/host/nvme/
// nvme_ctrl.sv, docs/11_nvme_queues.md) behind the transaction layer
// (tl_core). The host model (tlp_tb_pkg) enumerates the device and acts as an
// NVMe host: it writes commands into submission queues in host memory and
// rings doorbells in BAR0. The testbench plays the firmware over APB (slot 8
// registers): it sets up I/O queues, pops fetched commands from CMD, checks
// each one against what the host submitted, and frees the slot. The DMA
// testbench's memory model stands for SRAM (command buffer at 0x1000_BC00).
//
//   +test=<name>  regs, enable, fetch, rr, doorbell, ferr, shutdown, reset,
//                 random, all (default: the directed tests, then random), or
//                 perf (throughput and latency, alone)
//   +n=<cmds>     commands in the random test (default 2000)
//
// Checked for every command: it comes from the queue it was submitted to, in
// submission order, exactly once, and its 64 bytes are the submitted ones.

`timescale 1ns/1ps

module tb_nvme;
  import tlp_tb_pkg::*;

  localparam longint CLK = 20;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK / 2) clk = ~clk;

  tlp_if  tif (.clk(clk), .rst_n(rst_n));
  axi4_if axi (.clk(clk), .rst_n(rst_n));   // M3: the transaction layer's port
  axi4_if mif (.clk(clk), .rst_n(rst_n));   // the memory model behind the crossbar
  axi4_checker #(.KIND("M"), .IDX(3)) u_chk  (.a(axi));
  axi4_checker #(.KIND("S"), .IDX(1)) u_chkm (.a(mif));

  // ---------------------------------------------------------------------------
  // DUT: transaction layer, NVMe controller, and a 1 x 2 crossbar between M3
  // and the memory model (0x1000_0000, 256 MiB: SRAM) and the controller's
  // local buffer (0x5000_0000), as in soc_top
  // ---------------------------------------------------------------------------
  logic        rp_we;
  logic [10:0] rp_dw;
  logic [3:0]  rp_be;
  logic [31:0] rp_wdata, rp_rd0, rp_rd1;
  logic        nv_valid, nv_ready, nv_d2h, nv_done;
  logic [63:2] nv_haddr;
  logic [31:2] nv_laddr;
  logic [17:0] nv_len;
  logic [2:0]  nv_cause;
  logic [1:0]  awid, arid;
  logic        irq, nv_idle;
  logic        nv_mx_req;
  logic [2:0]  nv_mx_vec;
  logic        st_msix_en;
  logic [7:0]  st_msix_pend;

  apb_if aif (.pclk(clk), .presetn(rst_n));

  // The APB master: a class, so that its loop is compiled once (Verilator
  // copies a module task with timing controls into every caller).
  class apb_drv;
    virtual apb_if v;
    int            n;
    function new(virtual apb_if vi);
      v = vi;
      v.psel = 1'b0; v.penable = 1'b0; v.pwrite = 1'b0; v.paddr = '0; v.pwdata = '0;
      v.pstrb = 4'hF; v.pprot = 3'd0;
    endfunction
    task xfer(bit wr, bit [11:0] a, bit [31:0] d, output bit [31:0] rd, output bit err);
      int w = 0;
      @(negedge v.pclk);
      v.psel = 1'b1; v.penable = 1'b0; v.pwrite = wr; v.paddr = {4'd0, a}; v.pwdata = d;
      @(negedge v.pclk);
      v.penable = 1'b1;
      while (v.pready !== 1'b1) begin
        @(negedge v.pclk);
        if (++w > 100) $fatal(1, "[NVME] APB hang at %h", a);
      end
      rd  = v.prdata;
      err = v.pslverr;
      @(negedge v.pclk);
      v.psel = 1'b0; v.penable = 1'b0; v.pwrite = 1'b0;
      n++;
    endtask
  endclass
  apb_drv apbd;

  tl_core u_tl (
    .clk (clk), .rst_n (rst_n),
    .rxp_valid (tif.rx_valid), .rxp_ready (tif.rx_ready), .rxp_data (tif.rx_data),
    .rxp_sop (tif.rx_sop), .rxp_eop (tif.rx_eop), .rxp_ehalf (tif.rx_ehalf), .rxp_bad (tif.rx_bad),
    .txp_valid (tif.tx_valid), .txp_ready (tif.tx_ready), .txp_data (tif.tx_data),
    .txp_sop (tif.tx_sop), .txp_eop (tif.tx_eop), .txp_ehalf (tif.tx_ehalf),
    .m_awid (awid), .m_awaddr (axi.awaddr), .m_awlen (axi.awlen), .m_awsize (axi.awsize),
    .m_awburst (axi.awburst), .m_awvalid (axi.awvalid), .m_awready (axi.awready),
    .m_wdata (axi.wdata), .m_wstrb (axi.wstrb), .m_wlast (axi.wlast), .m_wvalid (axi.wvalid),
    .m_wready (axi.wready),
    .m_bid (axi.bid[1:0]), .m_bresp (axi.bresp), .m_bvalid (axi.bvalid), .m_bready (axi.bready),
    .m_arid (arid), .m_araddr (axi.araddr), .m_arlen (axi.arlen), .m_arsize (axi.arsize),
    .m_arburst (axi.arburst), .m_arvalid (axi.arvalid), .m_arready (axi.arready),
    .m_rid (axi.rid[1:0]), .m_rdata (axi.rdata), .m_rresp (axi.rresp), .m_rlast (axi.rlast),
    .m_rvalid (axi.rvalid), .m_rready (axi.rready),
    .rp_we (rp_we), .rp_dw (rp_dw), .rp_be (rp_be), .rp_wdata (rp_wdata),
    .rp_rd0 (rp_rd0), .rp_rd1 (rp_rd1),
    .nv_valid (nv_valid), .nv_ready (nv_ready), .nv_d2h (nv_d2h), .nv_haddr (nv_haddr),
    .nv_laddr (nv_laddr), .nv_len (nv_len), .nv_done (nv_done), .nv_cause (nv_cause),
    .bar2_win (17'h0_2001), .cto_ticks (8'd64),
    .bm_start (1'b0), .bm_d2h (1'b0), .bm_haddr ('0), .bm_laddr ('0), .bm_len ('0),
    .bm_done (), .bm_cause (), .bm_busy (),
    .msix_req (nv_mx_req), .msix_vec (nv_mx_vec),
    .st_mse (), .st_bme (), .st_msix_en (st_msix_en), .st_msix_fmask (), .st_mps256 (), .st_mrrs (),
    .st_id (), .st_msix_pend (st_msix_pend),
    .ev_ur (), .ev_malformed (), .ev_poisoned (), .ev_unexp_cpl (), .ev_cpl_timeout (),
    .ev_cpl_err (), .ev_axi_err (), .ev_discard (), .ev_msix_drop (), .rx_tlp (), .tx_tlp (),
    .idle ()
  );

  assign axi.awid    = {2'b00, awid};
  assign axi.arid    = {2'b00, arid};
  assign axi.awprot  = 3'd0;
  assign axi.arprot  = 3'd0;
  assign axi.awcache = 4'd0;
  assign axi.arcache = 4'd0;
  assign axi.awqos   = 4'd0;
  assign axi.arqos   = 4'd0;

  // Crossbar: its port names, so that .* connects them.
  localparam logic [1:0][31:0] X_BASE = {32'h5000_0000, 32'h1000_0000};
  localparam logic [1:0][31:0] X_MASK = {32'hFFFF_F000, 32'hF000_0000};

  logic [0:0][1:0]  s_awid,  s_arid,  s_bid,   s_rid;
  logic [0:0][31:0] s_awaddr, s_araddr;
  logic [0:0][7:0]  s_awlen, s_arlen;
  logic [0:0][2:0]  s_awsize, s_arsize, s_awprot, s_arprot;
  logic [0:0][1:0]  s_awburst, s_arburst, s_bresp, s_rresp;
  logic [0:0][3:0]  s_awcache, s_arcache, s_awqos, s_arqos;
  logic [0:0]       s_awvalid, s_awready, s_arvalid, s_arready;
  logic [0:0][63:0] s_wdata, s_rdata;
  logic [0:0][7:0]  s_wstrb;
  logic [0:0]       s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
  logic [0:0]       s_rlast, s_rvalid, s_rready;

  logic [1:0][2:0]  m_awid,  m_arid,  m_bid,   m_rid;
  logic [1:0][31:0] m_awaddr, m_araddr;
  logic [1:0][7:0]  m_awlen, m_arlen;
  logic [1:0][2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
  logic [1:0][1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
  logic [1:0][3:0]  m_awcache, m_arcache, m_awqos, m_arqos;
  logic [1:0]       m_awvalid, m_awready, m_arvalid, m_arready;
  logic [1:0][63:0] m_wdata, m_rdata;
  logic [1:0][7:0]  m_wstrb;
  logic [1:0]       m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [1:0]       m_rlast, m_rvalid, m_rready;
  logic [0:0]       stat_aw_id_stall, stat_ar_id_stall;

  axi_xbar #(.NM(1), .NS(2), .MIDW(2), .SLV_BASE(X_BASE), .SLV_MASK(X_MASK), .CONN(2'b11)) u_xbar (
    .clk (clk), .rst_n (rst_n), .*
  );

  assign s_awid[0]    = awid;           assign s_arid[0]    = arid;
  assign s_awaddr[0]  = axi.awaddr;     assign s_araddr[0]  = axi.araddr;
  assign s_awlen[0]   = axi.awlen;      assign s_arlen[0]   = axi.arlen;
  assign s_awsize[0]  = axi.awsize;     assign s_arsize[0]  = axi.arsize;
  assign s_awburst[0] = axi.awburst;    assign s_arburst[0] = axi.arburst;
  assign s_awprot[0]  = 3'd0;           assign s_arprot[0]  = 3'd0;
  assign s_awcache[0] = 4'd0;           assign s_arcache[0] = 4'd0;
  assign s_awqos[0]   = 4'd0;           assign s_arqos[0]   = 4'd0;
  assign s_awvalid[0] = axi.awvalid;    assign axi.awready  = s_awready[0];
  assign s_arvalid[0] = axi.arvalid;    assign axi.arready  = s_arready[0];
  assign s_wdata[0]   = axi.wdata;      assign s_wstrb[0]   = axi.wstrb;
  assign s_wlast[0]   = axi.wlast;      assign s_wvalid[0]  = axi.wvalid;
  assign axi.wready   = s_wready[0];
  assign axi.bid      = {2'b00, s_bid[0]};
  assign axi.bresp    = s_bresp[0];     assign axi.bvalid   = s_bvalid[0];
  assign s_bready[0]  = axi.bready;
  assign axi.rid      = {2'b00, s_rid[0]};
  assign axi.rdata    = s_rdata[0];     assign axi.rresp    = s_rresp[0];
  assign axi.rlast    = s_rlast[0];     assign axi.rvalid   = s_rvalid[0];
  assign s_rready[0]  = axi.rready;

  // S0: the memory model
  assign mif.awid    = {1'b0, m_awid[0]};  assign mif.arid    = {1'b0, m_arid[0]};
  assign mif.awaddr  = m_awaddr[0];        assign mif.araddr  = m_araddr[0];
  assign mif.awlen   = m_awlen[0];         assign mif.arlen   = m_arlen[0];
  assign mif.awsize  = m_awsize[0];        assign mif.arsize  = m_arsize[0];
  assign mif.awburst = m_awburst[0];       assign mif.arburst = m_arburst[0];
  assign mif.awprot  = m_awprot[0];        assign mif.arprot  = m_arprot[0];
  assign mif.awcache = m_awcache[0];       assign mif.arcache = m_arcache[0];
  assign mif.awqos   = m_awqos[0];         assign mif.arqos   = m_arqos[0];
  assign mif.awvalid = m_awvalid[0];       assign m_awready[0] = mif.awready;
  assign mif.arvalid = m_arvalid[0];       assign m_arready[0] = mif.arready;
  assign mif.wdata   = m_wdata[0];         assign mif.wstrb   = m_wstrb[0];
  assign mif.wlast   = m_wlast[0];         assign mif.wvalid  = m_wvalid[0];
  assign m_wready[0] = mif.wready;
  assign m_bid[0]    = mif.bid[2:0];       assign m_bresp[0]  = mif.bresp;
  assign m_bvalid[0] = mif.bvalid;         assign mif.bready  = m_bready[0];
  assign m_rid[0]    = mif.rid[2:0];       assign m_rdata[0]  = mif.rdata;
  assign m_rresp[0]  = mif.rresp;          assign m_rlast[0]  = mif.rlast;
  assign m_rvalid[0] = mif.rvalid;         assign mif.rready  = m_rready[0];

  nvme_ctrl #(.IDW(3)) u_nv (
    .clk (clk), .rst_n (rst_n),
    .psel (aif.psel), .penable (aif.penable), .paddr (aif.paddr[11:0]), .pwrite (aif.pwrite),
    .pwdata (aif.pwdata), .pstrb (4'hF), .prdata (aif.prdata), .pready (aif.pready), .pslverr (aif.pslverr),
    .reg_we (rp_we), .reg_dw (rp_dw), .reg_be (rp_be), .reg_wdata (rp_wdata),
    .reg_rd0 (rp_rd0), .reg_rd1 (rp_rd1),
    .bm_valid (nv_valid), .bm_ready (nv_ready), .bm_d2h (nv_d2h), .bm_haddr (nv_haddr),
    .bm_laddr (nv_laddr), .bm_len (nv_len), .bm_done (nv_done), .bm_cause (nv_cause),
    // S1: the local buffer
    .s_awid (m_awid[1]), .s_awaddr (m_awaddr[1]), .s_awlen (m_awlen[1]), .s_awvalid (m_awvalid[1]),
    .s_awready (m_awready[1]), .s_wdata (m_wdata[1]), .s_wstrb (m_wstrb[1]), .s_wlast (m_wlast[1]),
    .s_wvalid (m_wvalid[1]), .s_wready (m_wready[1]), .s_bid (m_bid[1]), .s_bresp (m_bresp[1]),
    .s_bvalid (m_bvalid[1]), .s_bready (m_bready[1]),
    .s_arid (m_arid[1]), .s_araddr (m_araddr[1]), .s_arlen (m_arlen[1]), .s_arvalid (m_arvalid[1]),
    .s_arready (m_arready[1]), .s_rid (m_rid[1]), .s_rdata (m_rdata[1]), .s_rresp (m_rresp[1]),
    .s_rlast (m_rlast[1]), .s_rvalid (m_rvalid[1]), .s_rready (m_rready[1]),
    // The transaction layer has no other MSI-X requester here.
    .msix_req (nv_mx_req), .msix_vec (nv_mx_vec), .msix_ack (nv_mx_req),
    .irq (irq), .idle (nv_idle)
  );

  tlp_host              host;
  dma_tb_pkg::mem_slave mem;

  int errors;
  function void fail(string s);
    errors++;
    if (errors <= 30) $display("[NVME] ERROR at %0t: %s", $time, s);
  endfunction

  localparam bit [63:0] BAR0   = 64'h0000_0008_0000_0000;
  localparam bit [63:0] BAR2   = 64'h0000_0000_C000_0000;
  localparam bit [31:0] CMDBUF = 32'h1000_BC00;
  localparam bit [63:0] MSI    = 64'h0000_0000_FEE0_0000;   // vector v at MSI + 16 v, data 0x1000 + v
  localparam int        NQ     = 5;

  // Firmware register offsets (rtl/csr/rdl/soc_apb.rdl, nvme_regs)
  localparam bit [11:0] R_CTRL = 12'h000, R_STATUS = 12'h004, R_EVENT = 12'h008, R_EVEN = 12'h00C,
                        R_CC = 12'h010, R_CMDBUF = 12'h014, R_CMD = 12'h018, R_FREE = 12'h01C,
                        R_DBERR = 12'h020, R_FETCH = 12'h024, R_AQA = 12'h030, R_ASQL = 12'h034,
                        R_ASQH = 12'h038, R_ACQL = 12'h03C, R_ACQH = 12'h040;
  function automatic bit [11:0] r_ioq(int q, int k);   // q = 1..4, k = 0..5 (SQB_LO .. CQ_CFG)
    return 12'h100 + 12'(32 * (q - 1) + 4 * k);
  endfunction
  function automatic bit [11:0] r_sqptr(int q); return 12'h200 + 12'(4 * q); endfunction

  // ---------------------------------------------------------------------------
  // APB (firmware role)
  // ---------------------------------------------------------------------------
  int n_apb;
  task automatic apb(bit wr, bit [11:0] a, bit [31:0] d, output bit [31:0] rd, input bit exp_err = 1'b0);
    bit e;
    apbd.xfer(wr, a, d, rd, e);
    if (e !== exp_err) fail($sformatf("PSLVERR %b at %h, expected %b", e, a, exp_err));
    n_apb++;
  endtask

  task automatic fw_wr(bit [11:0] a, bit [31:0] d);
    bit [31:0] u;
    apb(1'b1, a, d, u);
  endtask

  task automatic fw_rd(bit [11:0] a, output bit [31:0] d);
    apb(1'b0, a, 32'd0, d);
  endtask

  // ---------------------------------------------------------------------------
  // Host side
  // ---------------------------------------------------------------------------
  function automatic byteq_t le_bytes(bit [63:0] v, int n);
    byteq_t b;
    for (int i = 0; i < n; i++) b.push_back(v[8*i +: 8]);
    return b;
  endfunction

  task automatic cfgwr(bit [9:0] r, bit [31:0] d, bit [3:0] be = 4'hF);
    bit [2:0] st;
    host.cfg_wr(r, d, be, st);
    if (st != SC) fail($sformatf("CfgWr %0d status %0d", r, st));
  endtask

  task automatic enumerate();
    cfgwr(10'd4, BAR0[31:0]); cfgwr(10'd5, BAR0[63:32]);
    cfgwr(10'd6, BAR2[31:0]); cfgwr(10'd7, BAR2[63:32]);
    cfgwr(10'd18, 32'h0000_2830, 4'h3);        // MPS 256, MRRS 512
    host.dev_mps = 256; host.dev_mrrs = 512;
    cfgwr(10'd1, 32'h0000_0006, 4'h1);         // Memory Space, Bus Master
    // MSI-X: vector v to MSI + 16 v with data 0x1000 + v, unmasked, then enabled.
    for (int v = 0; v < 8; v++) begin
      host.mem_wr(BAR0 + 64'h2000 + 64'(16 * v), le_bytes(MSI + 64'(16 * v), 8));
      host.mem_wr(BAR0 + 64'h2008 + 64'(16 * v), le_bytes({32'd0, 32'h1000 + 32'(v)}, 8));
    end
    begin
      bit [31:0] d;
      bit [2:0]  st;
      host.cfg_rd(10'd32, d, st);
      cfgwr(10'd32, {1'b1, 1'b0, d[29:0]}, 4'h8);
    end
  endtask

  // Host register access through BAR0.
  task automatic hw32(int off, bit [31:0] v);
    host.mem_wr(BAR0 + 64'(off), le_bytes({32'd0, v}, 4));
  endtask

  task automatic hw64(int off, bit [63:0] v);
    host.mem_wr(BAR0 + 64'(off), le_bytes(v, 8));
  endtask

  task automatic hr32(int off, output bit [31:0] v);
    byteq_t b; bit [2:0] st;
    host.mem_rd(BAR0 + 64'(off), 4, b, st);
    if (st != SC) fail($sformatf("BAR0 read +%h status %0d", off, st));
    v = {b[3], b[2], b[1], b[0]};
  endtask

  task automatic hr64(int off, output bit [63:0] v);
    byteq_t b; bit [2:0] st;
    host.mem_rd(BAR0 + 64'(off), 8, b, st);
    if (st != SC) fail($sformatf("BAR0 read +%h status %0d", off, st));
    for (int i = 0; i < 8; i++) v[8*i +: 8] = b[i];
  endtask

  // Queues as the host sees them
  bit [63:0] sq_base [NQ];
  int        sq_size [NQ];
  int        sq_tail [NQ];
  int        sq_qd   [NQ];   // host's view of the head, refreshed from SQ_PTR
  int        sq_atail[NQ];   // entries submitted since the queue was set up
  int        sq_ahead[NQ];   // the controller's head as the host last learned it, in the same count
  bit [31:0] expect_q [NQ][$];  // per queue: CDW0 of submitted, not yet checked commands
  int        n_sub, n_chk;
  bit [31:0] next_cid;

  // A command: CDW0 = {CID, opcode}, the rest a pattern tied to the CID.
  function automatic bit [31:0] sqe_dw(bit [31:0] dw0, int i);
    return (i == 0) ? dw0 : (dw0 * 32'h9E37_79B9) ^ (32'(i) << 24) ^ 32'h5A5A_0000;
  endfunction

  task automatic ring_sq(int q);
    hw32(32'h1000 + 8 * q, 32'(sq_tail[q]));
  endtask

  // Write a command into the queue in host memory; the doorbell is separate.
  function automatic void put_sqe(int q);
    bit [31:0] dw0;
    bit [63:0] a;
    dw0 = {next_cid[15:0], 8'h00, 8'(8'h80 + q)};
    next_cid++;
    a = sq_base[q] + 64'(64 * sq_tail[q]);
    for (int i = 0; i < 16; i++)
      for (int k = 0; k < 4; k++) host.hmem[a + 64'(4 * i + k)] = sqe_dw(dw0, i)[8*k +: 8];
    expect_q[q].push_back(dw0);
    sq_tail[q] = (sq_tail[q] + 1) % sq_size[q];
    n_sub++;
  endfunction

  function automatic int sq_room(int q);
    return (sq_qd[q] - sq_tail[q] - 1 + sq_size[q]) % sq_size[q];
  endfunction

  // Enable with the admin queue at 0x1_0000_0000 (SQ) and 0x1_0001_0000 (CQ).
  task automatic host_enable(int asqs, int acqs = 16);
    bit [31:0] v;
    int n = 0;
    sq_base[0] = 64'h0000_0001_0000_0000;
    sq_size[0] = asqs;
    sq_tail[0] = 0;
    sq_atail[0] = 0;
    sq_ahead[0] = 0;
    sq_qd[0]   = 0;
    hw32(32'h24, {4'd0, 12'(acqs - 1), 4'd0, 12'(asqs - 1)});
    hw64(32'h28, sq_base[0]);
    hw64(32'h30, 64'h0000_0001_0001_0000);
    hw32(32'h14, 32'h0046_0001);              // IOCQES 4, IOSQES 6, EN
    do begin
      hr32(32'h1C, v);
      if (++n > 100) begin fail("CSTS.RDY never set"); break; end
    end while (!v[0]);
  endtask

  task automatic host_disable();
    bit [31:0] v;
    int n = 0;
    hw32(32'h14, 32'h0046_0000);
    do begin
      hr32(32'h1C, v);
      if (++n > 200) begin fail("CSTS.RDY never cleared"); break; end
    end while (v[0]);
  endtask

  // Firmware creates I/O queue pair q (1..4): SQ at 0x2_0000_0000 + q MiB.
  task automatic fw_ioq(int q, int size);
    sq_base[q] = 64'h0000_0002_0000_0000 + 64'(q) * 64'h10_0000;
    sq_size[q] = size;
    sq_tail[q] = 0;
    sq_atail[q] = 0;
    sq_ahead[q] = 0;
    sq_qd[q]   = 0;
    fw_wr(r_ioq(q, 0), sq_base[q][31:0]);
    fw_wr(r_ioq(q, 1), sq_base[q][63:32]);
    fw_wr(r_ioq(q, 3), 32'h0003_0000 + 32'(q) * 32'h1000);
    fw_wr(r_ioq(q, 4), 32'h3);
    fw_wr(r_ioq(q, 5), {1'b1, 6'd0, 1'b1, 5'd0, 3'(q), 4'd0, 12'(size - 1)});
    fw_wr(r_ioq(q, 2), {1'b1, 12'd0, 3'(q), 4'd0, 12'(size - 1)});
  endtask

  // ---------------------------------------------------------------------------
  // Firmware: pop commands, check them, free slots
  // ---------------------------------------------------------------------------
  int popped_q[$];

  // Pop one command if one waits; returns 0 if none.
  task automatic fw_take(output bit got);
    bit [31:0] c, dw0;
    int q, s;
    fw_rd(R_CMD, c);
    got = c[31];
    if (!got) return;
    q = int'(c[18:16]);
    s = int'(c[3:0]);
    popped_q.push_back(q);
    if (q >= NQ || expect_q[q].size() == 0) begin
      fail($sformatf("command from queue %0d, which has none outstanding", q));
    end else begin
      dw0 = expect_q[q].pop_front();
      for (int i = 0; i < 16; i++) begin
        bit [31:0] w;
        for (int k = 0; k < 4; k++) w[8*k +: 8] = mem.get(CMDBUF + 32'(64 * s + 4 * i + k));
        if (w !== sqe_dw(dw0, i)) begin
          fail($sformatf("queue %0d slot %0d DW %0d: %h, expected %h (CID %h)", q, s, i, w,
                         sqe_dw(dw0, i), dw0[31:16]));
          break;
        end
      end
    end
    n_chk++;
    fw_wr(R_FREE, 32'(s));
  endtask

  // Pop until nothing is outstanding (then 30 empty polls more, to catch
  // extra commands) or, with commands outstanding, 2000 empty polls.
  task automatic fw_drain(int limit = 100000);
    bit got;
    int idle_n = 0, n = 0;
    while (idle_n < ((outstanding() > 0) ? 2000 : 30) && n < limit) begin
      fw_take(got);
      idle_n = got ? 0 : idle_n + 1;
      n++;
    end
  endtask

  task automatic refresh_heads();
    bit [31:0] v;
    for (int q = 0; q < NQ; q++) begin
      fw_rd(r_sqptr(q), v);
      sq_qd[q] = int'(v[11:0]);
    end
  endtask

  function automatic int outstanding();
    int n = 0;
    for (int q = 0; q < NQ; q++) n += expect_q[q].size();
    return n;
  endfunction

  task automatic expect_reg(bit [11:0] a, bit [31:0] mask, bit [31:0] want, string what);
    bit [31:0] v;
    fw_rd(a, v);
    if ((v & mask) !== want) fail($sformatf("%s: %h, expected %h under %h", what, v, want, mask));
  endtask

  // ---------------------------------------------------------------------------
  // Functional coverage, sampled from the controller's state
  // ---------------------------------------------------------------------------
  int cv_q, cv_slot, cv_wrap, cv_ev, cv_depth;

  // Every fetch: queue, command buffer slot, whether the head wraps.
  covergroup cg_fetch;
    cp_q:    coverpoint cv_q    { bins q0 = {0}; bins q1 = {1}; bins q2 = {2}; bins q3 = {3}; bins q4 = {4}; }
    cp_slot: coverpoint cv_slot { bins s0 = {0}; bins s1 = {1}; bins s2 = {2}; bins s3 = {3};
                                  bins s4 = {4}; bins s5 = {5}; bins s6 = {6}; bins s7 = {7};
                                  bins s8 = {8}; bins s9 = {9}; bins s10 = {10}; bins s11 = {11};
                                  bins s12 = {12}; bins s13 = {13}; bins s14 = {14}; bins s15 = {15}; }
    cp_wrap: coverpoint cv_wrap { bins no = {0}; bins yes = {1}; }
    x_q_wrap: cross cp_q, cp_wrap;
  endgroup

  // Controller events and corner states.
  covergroup cg_ctl;
    cp_ev: coverpoint cv_ev { bins enable = {0}; bins reset_idle = {1}; bins reset_busy = {2};
                              bins shutdown = {3}; bins shutdown_busy = {4};
                              bins db_sq_off = {5}; bins db_sq_big = {6}; bins db_cq_off = {7};
                              bins db_cq_big = {8}; bins fetch_err = {9}; bins no_slot = {10};
                              bins free_in_reset = {11}; }
  endgroup

  // Commands waiting for firmware when one more arrives.
  covergroup cg_depth;
    cp_d: coverpoint cv_depth { bins one = {1}; bins few = {[2:8]}; bins many = {[9:15]}; bins full = {16}; }
  endgroup

  cg_fetch cov_fetch = new();
  cg_ctl   cov_ctl   = new();
  cg_depth cov_depth = new();

  function void ev(int k);
    cv_ev = k;
    cov_ctl.sample();
  endfunction

  bit rst_waited, shut_waited, no_slot_seen;
  always @(posedge clk) if (rst_n) begin
    if (u_nv.cf_push) begin
      cv_q     = int'(u_nv.f_q);
      cv_slot  = int'(u_nv.f_slot);
      cv_wrap  = int'(u_nv.sq_head[u_nv.f_q] == u_nv.sq_size[u_nv.f_q]);
      cv_depth = int'(u_nv.cf_count) + 1;
      cov_fetch.sample();
      cov_depth.sample();
    end
    if (u_nv.c_st == 2'd2 && u_nv.f_busy) rst_waited = 1'b1;
    if (u_nv.shst == 2'b01 && u_nv.f_busy) shut_waited = 1'b1;
    if (u_nv.ev_enable) ev(0);
    if (u_nv.ev_reset) begin ev(rst_waited ? 2 : 1); rst_waited = 1'b0; end
    if (u_nv.ev_shut) ev(3);
    if (u_nv.shst == 2'b01 && !u_nv.f_busy && shut_waited) begin ev(4); shut_waited = 1'b0; end
    if (u_nv.db_w && !u_nv.db_ok)
      ev(u_nv.db_cq ? (u_nv.cq_en[u_nv.db_q] ? 8 : 7) : (u_nv.sq_en[u_nv.db_q] ? 6 : 5));
    if (u_nv.ev_fetch_err) ev(9);
    if (u_nv.c_st == 2'd1 && u_nv.any && !u_nv.have_slot && !no_slot_seen) begin
      ev(10);
      no_slot_seen = 1'b1;
    end
    if (u_nv.have_slot) no_slot_seen = 1'b0;
    if (u_nv.free_wr && u_nv.c_st == 2'd2) ev(11);
  end

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  task automatic t_regs();
    bit [31:0] v;
    bit [63:0] q;
    hr64(32'h00, q);
    if (q[15:0] != 16'd1023 || !q[16] || q[31:24] != 8'd1 || !q[37] || q[35:32] != 0 || q[51:48] != 0)
      fail($sformatf("CAP %h", q));
    hr32(32'h08, v);  if (v != 32'h0001_0400) fail($sformatf("VS %h", v));
    hw32(32'h14, 32'hFFFF_FFFE);               // every bit but EN
    hr32(32'h14, v);  if (v != 32'h00FF_FFF0) fail($sformatf("CC write mask: %h", v));
    hw32(32'h14, 32'h0);
    hw32(32'h24, 32'hFFFF_FFFF);
    hr32(32'h24, v);  if (v != 32'h0FFF_0FFF) fail($sformatf("AQA write mask: %h", v));
    hw64(32'h28, 64'hFFFF_FFFF_FFFF_FFFF);
    hr64(32'h28, q);  if (q != 64'hFFFF_FFFF_FFFF_F000) fail($sformatf("ASQ: %h", q));
    hw64(32'h30, 64'h1234_5678_9ABC_DFFF);
    hr64(32'h30, q);  if (q != 64'h1234_5678_9ABC_D000) fail($sformatf("ACQ: %h", q));
    hw32(32'h1C, 32'hFFFF_FFFF);                // CSTS is read-only
    hr32(32'h1C, v);  if (v != 32'h0) fail($sformatf("CSTS after a write: %h", v));
    hw32(32'h0C, 32'hFFFF_FFFF); hw32(32'h20, 32'h4E56_4D65);
    hr32(32'h0C, v);  if (v != 0) fail("INTMS reads 0");
    hr32(32'h20, v);  if (v != 0) fail("NSSR reads 0");
    hr32(32'h1000, v); if (v != 0) fail("doorbells read 0");
    hr32(32'h800, v); if (v != 0) fail("reserved space reads 0");
    // Firmware's mirrors
    expect_reg(R_ASQL, 32'hFFFF_FFFF, 32'hFFFF_F000, "ASQ_LO mirror");
    expect_reg(R_ACQH, 32'hFFFF_FFFF, 32'h1234_5678, "ACQ_HI mirror");
    expect_reg(R_AQA, 32'hFFFF_FFFF, 32'h0FFF_0FFF, "AQA mirror");
    expect_reg(R_STATUS, 32'h001F_1F37, 32'h0010_0000, "STATUS at reset (16 free slots)");
    expect_reg(R_CMDBUF, 32'hFFFF_FFFF, CMDBUF, "CMDBUF reset value");
    // Firmware addresses that map to nothing get PSLVERR.
    apb(1'b0, 12'h02C, 32'd0, v, 1'b1);
    apb(1'b1, 12'h800, 32'd0, v, 1'b1);
  endtask

  task automatic t_enable();
    bit [31:0] v;
    fw_wr(R_EVENT, 32'h1F);
    host_enable(8);
    expect_reg(R_STATUS, 32'h7, 32'h5, "STATUS: RDY and EN after enable");
    expect_reg(R_EVENT, 32'h1, 32'h1, "EVENT.ENABLE");
    expect_reg(R_CC, 32'hFFFF_FFFF, 32'h0046_0001, "CC mirror");
    // Interrupt from an event
    fw_wr(R_EVEN, 32'h1);
    if (!irq) fail("EVENT.ENABLE with EVENT_EN does not interrupt");
    fw_wr(R_EVENT, 32'h1);
    if (irq) fail("interrupt after clearing EVENT");
    fw_wr(R_EVEN, 32'h0);
    host_disable();
    expect_reg(R_STATUS, 32'h7, 32'h0, "STATUS after CC.EN 0");
    expect_reg(R_EVENT, 32'h2, 32'h2, "EVENT.RESET");
    fw_wr(R_EVENT, 32'h1F);
    // Enable again: works from a clean state.
    host_enable(8);
    expect_reg(r_sqptr(0), 32'hFFFF_FFFF, 32'h0, "admin SQ pointers after enable");
  endtask

  // Admin commands in order, with the queue wrapping several times.
  task automatic t_fetch();
    bit got;
    int sent = 0;
    fw_wr(R_CTRL, 32'h1);                       // command interrupt
    host_enable(4);
    while (sent < 30) begin
      refresh_heads();
      if (sq_room(0) > 0) begin
        int k = $urandom_range(sq_room(0), 1);
        repeat (k) begin put_sqe(0); sent++; end
        ring_sq(0);
      end
      repeat ($urandom_range(40, 5)) @(negedge clk);
      if (irq) fw_take(got);
    end
    fw_drain();
    if (outstanding() != 0) fail($sformatf("%0d admin commands never fetched", outstanding()));
    // The same through the four I/O queues, 3 entries each, so their heads
    // wrap too.
    for (int q = 1; q < NQ; q++) fw_ioq(q, 3);
    sent = 0;
    while (sent < 32) begin
      refresh_heads();
      for (int q = 1; q < NQ; q++) begin
        if (sq_room(q) > 0) begin
          put_sqe(q);
          ring_sq(q);
          sent++;
        end
      end
      repeat ($urandom_range(40, 5)) @(negedge clk);
      if (irq) fw_take(got);
    end
    fw_drain();
    if (outstanding() != 0) fail($sformatf("%0d I/O commands never fetched", outstanding()));
    fw_wr(R_CTRL, 32'h0);
  endtask

  // Round robin: with every queue backlogged, one command per queue in turn.
  task automatic t_rr();
    bit got;
    int first;
    host_enable(64);
    for (int q = 1; q < NQ; q++) fw_ioq(q, 64);
    // Use up all 16 slots without freeing them, so nothing more is fetched.
    repeat (16) put_sqe(0);
    ring_sq(0);
    begin
      bit [31:0] v;
      int n = 0;
      do begin
        fw_rd(R_STATUS, v);
        n++;
      end while (v[20:16] != 0 && n < 2000);
      if (v[20:16] != 0) fail("16 admin commands not fetched");
    end
    // 16 commands wait: the command interrupt follows CTRL.IEN_CMD.
    if (irq) fail("interrupt with CTRL.IEN_CMD clear");
    fw_wr(R_CTRL, 32'h1);
    if (!irq) fail("no interrupt with commands waiting and CTRL.IEN_CMD set");
    fw_wr(R_CTRL, 32'h0);
    // Six commands in every queue, then free the slots one at a time.
    for (int q = 0; q < NQ; q++) begin
      repeat (6) put_sqe(q);
      ring_sq(q);
    end
    repeat (200) @(negedge clk);
    popped_q.delete();
    fw_drain();
    // The first 16 pops are queue 0's; then the order must cycle.
    first = 16;
    for (int i = first + 1; i < popped_q.size() && i < first + 30; i++) begin
      if (popped_q[i] != (popped_q[i - 1] + 1) % NQ) begin
        fail($sformatf("fetch %0d from queue %0d after queue %0d: not round robin", i - first,
                       popped_q[i], popped_q[i - 1]));
        break;
      end
    end
    if (outstanding() != 0) fail($sformatf("%0d commands never fetched", outstanding()));
  endtask

  // Doorbells that must be ignored and reported.
  task automatic t_doorbell();
    bit [31:0] v, f0;
    fw_rd(R_FETCH, f0);
    fw_wr(R_EVENT, 32'h1F);
    host_enable(8);
    hw32(32'h1000, 32'd8);                     // SQ0 tail = size
    hw32(32'h1008, 32'd1);                     // SQ1: not created
    hw32(32'h100C, 32'd1);                     // CQ1: not created
    hw32(32'h1004, 32'd20);                    // CQ0 head beyond 16 entries
    repeat (100) @(negedge clk);
    fw_rd(R_DBERR, v);
    if (v[2:0] != 3'd0 || !v[3] || v[31:16] != 16'd20) fail($sformatf("DB_ERR %h", v));
    expect_reg(R_EVENT, 32'h8, 32'h8, "EVENT.DB_ERR");
    expect_reg(r_sqptr(0), 32'h0FFF_0FFF, 32'h0, "SQ0 untouched by a bad doorbell");
    expect_reg(R_FETCH, 32'hFFFF_FFFF, f0, "nothing fetched");
    // A good CQ head doorbell is taken.
    hw32(32'h1004, 32'd5);
    repeat (50) @(negedge clk);
    expect_reg(12'h220, 32'h0000_0FFF, 32'd5, "CQ0 head from its doorbell");
    fw_wr(R_EVENT, 32'h1F);
  endtask

  // A fetch that fails stops the controller until a reset.
  task automatic t_ferr();
    bit [31:0] v;
    fw_wr(R_EVENT, 32'h1F);
    host_enable(8);
    host.inj_ur = 100;
    put_sqe(0); put_sqe(0);
    ring_sq(0);
    repeat (400) @(negedge clk);
    host.inj_ur = 0;
    hr32(32'h1C, v);
    if (!v[1]) fail("CSTS.CFS not set after a failed fetch");
    expect_reg(R_EVENT, 32'h10, 32'h10, "EVENT.FETCH_ERR");
    expect_reg(R_STATUS, 32'h001F_1F00, 32'h0010_0000, "no command waiting, all slots free");
    host_disable();
    hr32(32'h1C, v);
    if (v[1]) fail("CSTS.CFS still set after the reset");
    expect_q[0].delete();
    fw_wr(R_EVENT, 32'h1F);
  endtask

  // Shutdown right behind a doorbell, with the host slow to answer, so a
  // fetch is in flight: SHST reads "complete" only once it is done, and
  // nothing is fetched after that.
  task automatic t_shutdown();
    bit [31:0] v, f0;
    int n = 0;
    host_enable(8);
    host.lat_min = 300;
    host.lat_max = 300;
    repeat (7) put_sqe(0);
    ring_sq(0);
    hw32(32'h14, 32'h0046_4001);               // SHN = 01
    do begin
      hr32(32'h1C, v);
      if (++n > 100) begin fail("SHST never reached complete"); break; end
    end while (v[3:2] != 2'b10);
    fw_rd(R_FETCH, f0);
    repeat (600) @(negedge clk);
    host.lat_min = 4;
    host.lat_max = 60;
    expect_reg(R_FETCH, 32'hFFFF_FFFF, f0, "fetches after SHST complete");
    expect_reg(R_EVENT, 32'h4, 32'h4, "EVENT.SHUTDOWN");
    fw_drain(200);
    expect_q[0].delete();
    host_disable();
    hr32(32'h1C, v);
    if (v[3:2] != 2'b00) fail("SHST not cleared by the reset");
    fw_wr(R_EVENT, 32'h1F);
  endtask

  // Controller reset with commands waiting for firmware and a fetch in
  // flight: everything is cleared, and after the next enable no command from
  // before the reset shows up.
  task automatic t_reset();
    bit [31:0] v;
    bit        got;
    int        n = 0;
    host_enable(16);
    for (int q = 1; q < NQ; q++) fw_ioq(q, 16);
    for (int q = 0; q < NQ; q++) begin
      repeat (5) put_sqe(q);
      ring_sq(q);
    end
    do begin
      fw_rd(R_STATUS, v);
      if (++n > 3000) begin fail("16 commands never fetched"); break; end
    end while (v[20:16] != 0);
    // Two slots back: two more fetches start; reset right behind them. The
    // host is slow to answer, so the reset waits for the fetch in flight,
    // and firmware takes a command and frees its slot while it waits.
    host.lat_min = 300;
    host.lat_max = 300;
    fw_take(got);
    fw_take(got);
    n = 0;
    while (!u_nv.f_busy && n < 300) begin @(negedge clk); n++; end
    if (!u_nv.f_busy) fail("no fetch after two slots were freed");
    fork
      host_disable();
      begin
        n = 0;
        while (u_nv.c_st != 2'd2 && n < 2000) begin @(negedge clk); n++; end
        if (u_nv.c_st != 2'd2) fail("controller never waiting in reset");
        else fw_take(got);
        if (u_nv.c_st != 2'd2) fail("reset did not wait for the fetch in flight");
      end
    join
    host.lat_min = 4;
    host.lat_max = 60;
    expect_reg(R_STATUS, 32'h001F_1F07, 32'h0010_0000, "STATUS after the reset: no command, 16 free slots");
    expect_reg(R_CMD, 32'h8000_0000, 32'h0, "CMD after the reset");
    for (int q = 0; q < NQ; q++) begin
      expect_reg(r_sqptr(q), 32'h0FFF_0FFF, 32'h0, $sformatf("SQ%0d pointers after the reset", q));
      expect_reg(12'h220 + 12'(4 * q), 32'h8FFF_0FFF, 32'h8000_0000,
                 $sformatf("CQ%0d pointers and phase after the reset", q));
    end
    for (int q = 1; q < NQ; q++) begin
      expect_reg(r_ioq(q, 2), 32'h8000_0000, 32'h0, $sformatf("SQ%0d enable after the reset", q));
      expect_reg(r_ioq(q, 5), 32'h8000_0000, 32'h0, $sformatf("CQ%0d enable after the reset", q));
    end
    for (int q = 0; q < NQ; q++) expect_q[q].delete();
    // Enable again: only the new commands arrive.
    host_enable(8);
    fw_ioq(1, 8);
    repeat (3) put_sqe(1);
    ring_sq(1);
    repeat (2) put_sqe(0);
    ring_sq(0);
    fw_drain();
    if (outstanding() != 0) fail($sformatf("%0d commands never fetched after the reset", outstanding()));
    fw_wr(R_EVENT, 32'h1F);
  endtask

  // Throughput and latency with nothing else in the way: the host answers
  // after 2 clocks and takes every beat, the memory never stalls. Numbers are
  // clk_sys clocks, counted from the clock the doorbell write reaches the
  // controller to the clock a command enters the command FIFO.
  task automatic t_perf();
    longint t0, t1;
    int     n;
    host.rx_gap_pct = 0;
    host.tx_ready_pct = 100;
    host.lat_min = 2;
    host.lat_max = 2;
    mem.set_speed(100, 0, 0);
    host_enable(64);
    // One command.
    put_sqe(0);
    ring_sq(0);
    @(negedge clk);
    while (!u_nv.db_w) @(negedge clk);
    t0 = $time;
    while (!u_nv.cf_push) @(negedge clk);
    t1 = $time;
    fw_drain();
    $display("[NVME] perf: doorbell to command in the FIFO: %0d clocks", (t1 - t0) / CLK);
    // 63 commands behind one doorbell (the queue full), taken by the firmware
    // model as they come.
    repeat (63) put_sqe(0);
    ring_sq(0);
    @(negedge clk);
    while (!u_nv.db_w) @(negedge clk);
    t0 = $time;
    n = 0;
    fork
      begin
        while (n < 63) begin
          @(negedge clk);
          if (u_nv.cf_push) n++;
        end
        t1 = $time;
      end
      fw_drain();
    join
    $display("[NVME] perf: 63 commands from one doorbell in %0d clocks: %0.1f clocks per command, %0.2f bytes of commands per clock",
             (t1 - t0) / CLK, real'((t1 - t0) / CLK) / 63.0, 64.0 * 63.0 / real'((t1 - t0) / CLK));
    if (outstanding() != 0) fail($sformatf("%0d commands never fetched", outstanding()));
    t_perf23();
    host.rx_gap_pct = 10;
    host.tx_ready_pct = 85;
    host.lat_min = 4;
    host.lat_max = 60;
  endtask

  // ===========================================================================
  // Step 2-3: data by PRP, completion queue entries, MSI-X per queue
  // ===========================================================================
  localparam bit [11:0] R_XP1L = 12'h050, R_XP1H = 12'h054, R_XP2L = 12'h058, R_XP2H = 12'h05C,
                        R_XLA = 12'h060, R_XLEN = 12'h064, R_XCTL = 12'h068, R_XST = 12'h06C,
                        R_XCYC = 12'h070, R_QDW0 = 12'h080, R_QINFO = 12'h084, R_QCTL = 12'h088,
                        R_QST = 12'h08C, R_QCNT = 12'h090;
  localparam bit [63:0] HDATA = 64'h0000_0004_0000_0000;   // host data pages, 12 KiB apart
  localparam bit [63:0] HLIST = 64'h0000_0005_0000_0000;   // host PRP list pages, 8 KiB apart
  localparam bit [31:0] SBUF  = 32'h1100_0000;             // SRAM data buffers, 128 KiB each
  localparam bit [14:0] ST_OK = 15'h0, ST_OPC = 15'h4001, ST_FIELD = 15'h4002, ST_XFER = 15'h0004,
                        ST_PRP = 15'h4013;                  // {DNR, M, CRD, SCT, SC}

  // A data layout in host memory: pages (never adjacent: every page is 12 KiB
  // from the next one handed out) and the PRP entries that describe them.
  class prp_c;
    bit [63:0] prp1, prp2;
    bit [63:0] pg[$];       // data pages, in data order
    bit [63:0] lp[$];       // list pages
    int        off, len;
    int        kind;        // 0 one page, 1 two pages, 2 list, 3 list over two list pages
    function bit [63:0] addr(int i);
      int first = 4096 - off;
      int j = i - first;
      int k = j % 4096;
      if (i < first) return pg[0] + 64'(off + i);
      return pg[1 + j / 4096] + 64'(k);
    endfunction
  endclass

  bit [63:0] free_pages[$], free_lists[$];
  int        n_pages_made, n_lists_made;

  function automatic bit [63:0] get_page();
    if (free_pages.size() > 0) return free_pages.pop_front();
    n_pages_made++;
    return HDATA + 64'(n_pages_made) * 64'h3000;
  endfunction

  function automatic bit [63:0] get_list();
    if (free_lists.size() > 0) return free_lists.pop_front();
    n_lists_made++;
    return HLIST + 64'(n_lists_made) * 64'h2000;
  endfunction

  function automatic void put_qw(bit [63:0] a, bit [63:0] v);
    for (int k = 0; k < 8; k++) host.hmem[a + 64'(k)] = v[8*k +: 8];
  endfunction

  // len bytes starting at offset off in the first page; lofs is the list's
  // offset in its page (8-byte aligned), so a list may run over the end of
  // its page: the page's last entry then points to the next list page.
  function automatic prp_c make_prp(int len, int off, int lofs);
    prp_c x = new();
    int   np = (off + len + 4095) / 4096;
    x.off = off;
    x.len = len;
    for (int i = 0; i < np; i++) x.pg.push_back(get_page());
    x.prp1 = x.pg[0] + 64'(off);
    x.prp2 = {32'hDEAD_0000, $urandom} & ~64'h7;   // ignored when one page holds the data
    x.kind = 0;
    if (np == 2) begin
      x.prp2 = x.pg[1];
      x.kind = 1;
    end else if (np > 2) begin
      bit [63:0] lpg  = get_list();
      int        slot = lofs / 8;
      x.lp.push_back(lpg);
      x.prp2 = lpg + 64'(lofs);
      x.kind = 2;
      for (int i = 1; i < np; i++) begin
        if (slot == 511 && i < np - 1) begin
          bit [63:0] nxt = get_list();
          put_qw(lpg + 64'h0FF8, nxt);
          lpg  = nxt;
          slot = 0;
          x.lp.push_back(nxt);
          x.kind = 3;
        end
        put_qw(lpg + 64'(8 * slot), x.pg[i]);
        slot++;
      end
    end
    return x;
  endfunction

  function automatic void drop_prp(prp_c x);
    foreach (x.pg[i]) free_pages.push_back(x.pg[i]);
    foreach (x.lp[i]) free_lists.push_back(x.lp[i]);
  endfunction

  // What the host expects of a command.
  class rec_c;
    int        sq, pos, seq;
    bit [7:0]  opc;
    bit [15:0] cid;
    bit [14:0] st;
    prp_c      x;
  endclass
  rec_c recs [bit [15:0]];
  bit [3:0] xf_cause [bit [15:0]];   // firmware's transfer result per CID, for messages

  function automatic bit [7:0] rpat(bit [15:0] cid, int i);
    return 8'(cid) ^ 8'(cid >> 8) ^ 8'(i) ^ 8'(i >> 8) ^ 8'(i >> 16) ^ 8'h96;
  endfunction

  // ---------------------------------------------------------------------------
  // Host: completion queues
  // ---------------------------------------------------------------------------
  int        hcq_head [NQ], hcq_size [NQ];
  bit        hcq_phase[NQ];
  bit [63:0] hcq_base [NQ];
  int        n_cqe [NQ], n_msi [NQ];
  int        n_io_ok, n_io_err, n_rd_bytes, n_wr_bytes;

  function automatic void cq_init(int q, bit [63:0] base, int size);
    hcq_base[q]  = base;
    hcq_size[q]  = size;
    hcq_head[q]  = 0;
    hcq_phase[q] = 1'b1;
    for (int i = 0; i < 16 * size; i++) host.hmem[base + 64'(i)] = 8'h00;
  endfunction

  function automatic int qdist(int a, int b, int size);
    return (b - a + size) % size;
  endfunction

  // Take the next entry of CQ q if its phase says it is new; check it against
  // the command it completes; free the command's pages. No doorbell.
  task automatic host_cq_take(int q, output bit got);
    bit [63:0] a;
    bit [31:0] d0, d2, d3;
    rec_c      r;
    a  = hcq_base[q] + 64'(16 * hcq_head[q]);
    d3 = host.hget_dw(a + 64'd12);
    got = (d3[16] == hcq_phase[q]);
    if (!got) return;
    d0 = host.hget_dw(a);
    d2 = host.hget_dw(a + 64'd8);
    n_cqe[q]++;
    if (!recs.exists(d3[15:0])) begin
      fail($sformatf("CQ%0d entry %0d: CID %h of no outstanding command", q, hcq_head[q], d3[15:0]));
    end else begin
      r = recs[d3[15:0]];
      if (int'(d2[31:16]) != r.sq) fail($sformatf("CID %h: SQID %0d, expected %0d", r.cid, d2[31:16], r.sq));
      if (q != r.sq) fail($sformatf("CID %h on CQ%0d, expected CQ%0d", r.cid, q, r.sq));
      if (d3[31:17] != r.st)
        fail($sformatf("CID %h: status %h, expected %h (opcode %h, %0d bytes, transfer cause %0d)", r.cid,
                       d3[31:17], r.st, r.opc, (r.x != null) ? r.x.len : 0,
                       xf_cause.exists(r.cid) ? int'(xf_cause[r.cid]) : -1));
      if (d0 != {16'hC0DE, r.cid}) fail($sformatf("CID %h: DW0 %h", r.cid, d0));
      // The SQ head: past this command and not past the tail, and never moving
      // back. Counted along all entries submitted, since the tail may have
      // wrapped past this command's slot by now.
      begin
        int h  = int'(d2[15:0]);
        int nh = sq_ahead[r.sq] + qdist(sq_ahead[r.sq] % sq_size[r.sq], h, sq_size[r.sq]);
        if (h >= sq_size[r.sq] || nh < r.seq + 1 || nh > sq_atail[r.sq])
          fail($sformatf("CID %h: SQ head %0d (entry %0d of SQ%0d, size %0d; %0d submitted, head known %0d)",
                         r.cid, h, r.seq, r.sq, sq_size[r.sq], sq_atail[r.sq], sq_ahead[r.sq]));
        else
          sq_ahead[r.sq] = nh;
      end
      if (r.st == ST_OK && (r.opc == 8'h02 || r.opc == 8'h06)) begin
        for (int i = 0; i < r.x.len; i++) begin
          if (host.hget(r.x.addr(i)) !== rpat(r.cid, i)) begin
            fail($sformatf("CID %h read data byte %0d at %h: %h, expected %h", r.cid, i, r.x.addr(i),
                           host.hget(r.x.addr(i)), rpat(r.cid, i)));
            break;
          end
        end
      end
      if (r.st == ST_OK) n_io_ok++;
      else               n_io_err++;
      sq_qd[r.sq] = int'(d2[15:0]);                // the host learns the SQ head here
      if (r.x != null) drop_prp(r.x);
      recs.delete(r.cid);
    end
    hcq_head[q] = (hcq_head[q] + 1) % hcq_size[q];
    if (hcq_head[q] == 0) hcq_phase[q] = !hcq_phase[q];
  endtask

  // Doorbells only when the value moved, and not while the host's send queue
  // is long: a host that floods the link delays the device's reads.
  int rung_sq [NQ], rung_cq [NQ];

  task automatic ring_cq(int q);
    while (host.sendq.size() > 8) @(negedge clk);
    hw32(32'h1004 + 8 * q, 32'(hcq_head[q]));
    rung_cq[q] = hcq_head[q];
  endtask

  task automatic ring_sq_new(int q);
    if (rung_sq[q] == sq_tail[q]) return;
    while (host.sendq.size() > 8) @(negedge clk);
    ring_sq(q);
    rung_sq[q] = sq_tail[q];
  endtask

  // Submit an I/O command (Read 0x02, Write 0x01, Flush 0x00, others to test
  // the opcode check) or an admin Identify (0x06) with len bytes at offset off.
  task automatic sub_io(int q, bit [7:0] opc, int len, int off, int lofs, bit [14:0] st = ST_OK,
                        bit [63:0] p2x = 64'd0);
    rec_c      r = new();
    bit [31:0] dw [16];
    bit [63:0] a;
    r.sq  = q;
    r.pos = sq_tail[q];
    r.seq = sq_atail[q];
    sq_atail[q]++;
    r.opc = opc;
    r.cid = next_cid[15:0];
    r.st  = st;
    next_cid++;
    r.x = (len > 0) ? make_prp(len, off, lofs) : null;
    foreach (dw[i]) dw[i] = 32'd0;
    dw[0]  = {r.cid, 8'h00, opc};
    dw[1]  = 32'd1;
    if (r.x != null) begin
      dw[6] = r.x.prp1[31:0]; dw[7] = r.x.prp1[63:32];
      dw[8] = r.x.prp2[31:0] ^ p2x[31:0]; dw[9] = r.x.prp2[63:32] ^ p2x[63:32];
    end
    dw[10] = 32'(r.cid) * 32'd8;
    dw[12] = (len > 0) ? 32'(len / 512 - 1) : 32'd0;
    a = sq_base[q] + 64'(64 * sq_tail[q]);
    for (int i = 0; i < 16; i++)
      for (int k = 0; k < 4; k++) host.hmem[a + 64'(4 * i + k)] = dw[i][8*k +: 8];
    recs[r.cid] = r;
    sq_tail[q] = (sq_tail[q] + 1) % sq_size[q];
    n_sub++;
  endtask

  // ---------------------------------------------------------------------------
  // Firmware: data transfers and completion entries
  // ---------------------------------------------------------------------------
  int n_xfer, n_post;
  int cv_kind, cv_dir, cv_lenc, cv_cause, cv_cqev;

  task automatic fw_xfer(bit d2h, bit [63:0] prp1, bit [63:0] prp2, bit [31:0] la, int len,
                         output bit [3:0] cause);
    bit [31:0] v;
    int n = 0;
    fw_wr(R_XP1L, prp1[31:0]); fw_wr(R_XP1H, prp1[63:32]);
    fw_wr(R_XP2L, prp2[31:0]); fw_wr(R_XP2H, prp2[63:32]);
    fw_wr(R_XLA, la);
    fw_wr(R_XLEN, 32'(len));
    fw_wr(R_XCTL, {30'd0, d2h, 1'b1});
    do begin
      fw_rd(R_XST, v);
      if (++n > 400000) begin fail("data transfer never ended"); break; end
    end while (!(v[1] || v[2]));
    cause = v[11:8];
    if (v[1] && cause != 4'd0) fail($sformatf("XF_STATUS %h: DONE with cause %0d", v, cause));
    fw_wr(R_XST, 32'h6);
    n_xfer++;
  endtask

  // Post a completion entry, waiting while 4 already wait (a post then would
  // be dropped) unless nowait.
  task automatic fw_post(int cq, bit [15:0] cid, int sq, bit [14:0] st, bit [31:0] dw0, bit nowait = 1'b0);
    bit [31:0] v;
    int n = 0;
    if (!nowait) begin
      do begin
        fw_rd(R_QST, v);
        if (++n > 200000) begin fail("CQE FIFO never had room"); break; end
      end while (v[4]);
    end
    fw_wr(R_QDW0, dw0);
    fw_wr(R_QINFO, {13'd0, 3'(sq), cid});
    fw_wr(R_QCTL, {st, 14'd0, 3'(cq)});
    n_post++;
  endtask

  // Pop one command and handle it: read the entry, return the slot, move its
  // data by PRP (checking a Write's data in SRAM), post its completion on
  // the completion queue with its submission queue's number.
  task automatic fw_take_io(output bit got);
    bit [31:0] c, dw [16];
    bit [3:0]  cause;
    bit [14:0] st;
    bit [31:0] la;
    int        q, s, len;
    bit [7:0]  opc;
    fw_rd(R_CMD, c);
    got = c[31];
    if (!got) return;
    q = int'(c[18:16]);
    s = int'(c[3:0]);
    for (int i = 0; i < 16; i++)
      for (int k = 0; k < 4; k++) dw[i][8*k +: 8] = mem.get(CMDBUF + 32'(64 * s + 4 * i + k));
    fw_wr(R_FREE, 32'(s));
    n_chk++;
    opc = dw[0][7:0];
    la  = SBUF + 32'(s) * 32'h2_0000;
    len = (int'(dw[12][15:0]) + 1) * 512;
    if (q == 0 && opc == 8'h06) len = 4096;
    st = ST_OK;
    if ((q == 0 && opc != 8'h06) || (q != 0 && !(opc inside {8'h00, 8'h01, 8'h02}))) begin
      st = ST_OPC;
    end else if (opc != 8'h00) begin
      bit d2h = (opc != 8'h01);
      if (d2h) for (int i = 0; i < len; i++) mem.mem[la + 32'(i)] = rpat(dw[0][31:16], i);
      fw_xfer(d2h, {dw[7], dw[6]}, {dw[9], dw[8]}, la, len, cause);
      xf_cause[dw[0][31:16]] = cause;
      case (cause)
        4'd0:    st = ST_OK;
        4'd8:    st = ST_FIELD;
        4'd9:    st = ST_PRP;
        default: st = ST_XFER;
      endcase
      if (cause == 4'd0 && !d2h && recs.exists(dw[0][31:16])) begin
        prp_c x = recs[dw[0][31:16]].x;
        for (int i = 0; i < len; i++) begin
          if (mem.get(la + 32'(i)) !== host.hget(x.addr(i))) begin
            fail($sformatf("CID %h write data byte %0d in SRAM: %h, host %h", dw[0][31:16], i,
                           mem.get(la + 32'(i)), host.hget(x.addr(i))));
            break;
          end
        end
      end
      if (recs.exists(dw[0][31:16]) && recs[dw[0][31:16]].x != null) begin
        prp_c x = recs[dw[0][31:16]].x;
        cv_kind = x.kind; cv_dir = int'(d2h); cv_lenc = (len <= 4096) ? 0 : (len <= 32768) ? 1 : 2;
        cov_xfer.sample();
        if (d2h) n_rd_bytes += len;
        else     n_wr_bytes += len;
      end
    end
    fw_post(q, dw[0][31:16], q, st, {16'hC0DE, dw[0][31:16]});
  endtask

  // ---------------------------------------------------------------------------
  // Coverage of step 2-3
  // ---------------------------------------------------------------------------
  covergroup cg_xfer;
    cp_kind: coverpoint cv_kind { bins one = {0}; bins two = {1}; bins list = {2}; bins chained = {3}; }
    cp_dir:  coverpoint cv_dir  { bins h2d = {0}; bins d2h = {1}; }
    cp_len:  coverpoint cv_lenc { bins page = {0}; bins mid = {1}; bins big = {2}; }
    x_kind_dir: cross cp_kind, cp_dir;
  endgroup

  // Transfer causes and completion events, seen in the controller.
  covergroup cg_cq;
    cp_ev: coverpoint cv_cqev { bins len_bad = {0}; bins prp_bad = {1}; bins bm_err = {2}; bins aborted = {3};
                                bins cq_wait = {4}; bins wrap = {5}; bins drop_off = {6}; bins drop_full = {7};
                                bins werr = {8}; bins msix_masked = {9}; bins chain_ptr = {10};
                                bins full_batch = {11}; }
  endgroup

  covergroup cg_cqe;
    cp_q:  coverpoint cv_q    { bins q0 = {0}; bins q1 = {1}; bins q2 = {2}; bins q3 = {3}; bins q4 = {4}; }
    cp_ph: coverpoint cv_wrap { bins ph0 = {0}; bins ph1 = {1}; }
    x_q_ph: cross cp_q, cp_ph;
  endgroup

  cg_xfer cov_xfer = new();
  cg_cq   cov_cq   = new();
  cg_cqe  cov_cqe  = new();

  function void cqev(int k);
    cv_cqev = k;
    cov_cq.sample();
  endfunction

  // Pointer rule: an SQ head only moves by one (wrapping at the size), or to
  // 0 when its queue is enabled or the controller resets.
  logic [11:0] sqh_prev [NQ];
  logic [1:0]  cst_prev;
  always @(posedge clk) if (rst_n) begin
    for (int q = 0; q < NQ; q++) begin
      if (u_nv.sq_head[q] != sqh_prev[q] &&
          u_nv.sq_head[q] != ((sqh_prev[q] == u_nv.sq_size[q]) ? 12'd0 : sqh_prev[q] + 12'd1) &&
          !(u_nv.sq_head[q] == 12'd0 && (cst_prev != 2'd1 || u_nv.c_st != 2'd1 ||
                                          (q > 0 && !u_nv.sq_en_q[q]))))
        fail($sformatf("SQ%0d head %0d -> %0d (size %0d)", q, sqh_prev[q], u_nv.sq_head[q], u_nv.sq_size[q] + 1));
      sqh_prev[q] = u_nv.sq_head[q];
    end
    if (u_nv.c_st != cst_prev && dbg_cst) $display("[NVME] debug %0t: controller state %0d -> %0d", $time, cst_prev, u_nv.c_st);
    cst_prev = u_nv.c_st;
  end
  bit dbg_cst = $test$plusargs("dbg");

  bit cq_wait_seen;
  always @(posedge clk) if (rst_n) begin
    if (u_nv.p_fin) begin
      if (u_nv.p_cause == 4'd8)                           cqev(0);
      if (u_nv.p_cause == 4'd9)                           cqev(1);
      if (u_nv.p_cause != 4'd0 && u_nv.p_cause < 4'd8)    cqev(2);
      if (u_nv.p_cause == 4'd10)                          cqev(3);
    end
    if (u_nv.c_wait && !cq_wait_seen) cqev(4);
    cq_wait_seen = u_nv.c_wait;
    if (u_nv.c_adv) begin
      cv_q    = int'(u_nv.c_cq);
      cv_wrap = int'(u_nv.c_phase);
      cov_cqe.sample();
      if (u_nv.c_tail == u_nv.c_size) cqev(5);
    end
    if (u_nv.u_cqe.pop && !u_nv.c_en)                   cqev(6);
    if (u_nv.c_post && u_nv.c_full)                    cqev(7);
    if (u_nv.c_werr)                                    cqev(8);
    if (u_nv.u_prp.st == 3'd4 && u_nv.u_prp.x_chain && u_nv.u_prp.x_i == u_nv.u_prp.x_k - 4'd1) cqev(10);
    if (u_nv.u_prp.st == 3'd1 && u_nv.u_prp.x_fetch && u_nv.u_prp.x_k == 4'd8 && u_nv.p_ready) cqev(11);
  end

  // ---------------------------------------------------------------------------
  // Tests of step 2-3
  // ---------------------------------------------------------------------------
  function automatic int msi_count(int v);
    int n = 0;
    foreach (host.msis[i]) if (host.msis[i].addr == MSI + 64'(16 * v)) n++;
    return n;
  endfunction

  // Controller up with an admin pair of asz entries and I/O pairs 1..nio of
  // size entries; completion queues zeroed in host memory.
  task automatic io_setup(int nio, int size, int asz = 16);
    host_enable(asz, asz);
    cq_init(0, 64'h0000_0001_0001_0000, asz);
    for (int q = 1; q <= nio; q++) begin
      fw_ioq(q, size);
      cq_init(q, 64'h0000_0003_0003_0000 + 64'(q) * 64'h1000, size);
    end
  endtask

  // One command from submission to completion, then its MSI-X message.
  task automatic run_one(int q, bit [7:0] opc, int len, int off, int lofs, bit [14:0] st = ST_OK,
                         bit [63:0] p2x = 64'd0);
    bit got;
    int n = 0;
    int m0 = msi_count(q);
    sub_io(q, opc, len, off, lofs, st, p2x);
    ring_sq(q);
    do begin
      fw_take_io(got);
      if (++n > 3000) begin fail("command never fetched"); return; end
    end while (!got);
    n = 0;
    do begin
      @(negedge clk);
      host_cq_take(q, got);
      if (++n > 200000) begin fail($sformatf("no completion on CQ%0d", q)); return; end
    end while (!got);
    ring_cq(q);
    n = 0;
    while (msi_count(q) == m0 && n < 3000) begin @(negedge clk); n++; end
    if (msi_count(q) != m0 + 1) fail($sformatf("CQ%0d: %0d MSI-X messages for one entry", q, msi_count(q) - m0));
  endtask

  // Every PRP layout, both directions, on the admin and two I/O queues.
  task automatic t_data();
    // {queue, opcode (0: Write then Read), bytes, offset, list offset, status, PRP2 xor}
    int        tq[$], tlen[$], toff[$], tlo[$];
    bit [7:0]  top[$];
    bit [14:0] tst[$];
    bit [63:0] tx[$];
    io_setup(2, 16);
    tq.push_back(0); top.push_back(8'h06); tlen.push_back(4096); toff.push_back(32'h100); tlo.push_back(0);
    tst.push_back(ST_OK); tx.push_back(0);                                   // Identify: two pages
    for (int d = 0; d < 2; d++) begin
      bit [7:0] opc = (d == 0) ? 8'h01 : 8'h02;
      int       qq[10] = '{1, 1, 1, 1, 2, 2, 1, 1, 2, 2};
      int       ll[10] = '{512, 1024, 1536, 8192, 12288, 65536, 131072, 130560, 20480, 40960};
      int       oo[10] = '{0, 32'hC00, 32'hE00, 0, 32'h200, 0, 0, 32'h200, 0, 32'h400};
      int       lo[10] = '{0, 0, 0, 0, 0, 32'h100, 0, 32'h800, 32'hFF0, 32'hFC0};
      // one page, to its end, over a page end, two pages, list of 3, list of
      // 15 (batches 8 and 7), 128 KiB (31), 128 KiB - 512 from an offset,
      // a list over two list pages, a full batch that ends in the pointer
      for (int k = 0; k < 10; k++) begin
        tq.push_back(qq[k]); top.push_back(opc); tlen.push_back(ll[k]); toff.push_back(oo[k]);
        tlo.push_back(lo[k]); tst.push_back(ST_OK); tx.push_back(0);
      end
    end
    tq.push_back(1); top.push_back(8'h00); tlen.push_back(0); toff.push_back(0); tlo.push_back(0);
    tst.push_back(ST_OK); tx.push_back(0);                                   // Flush: no data
    tq.push_back(1); top.push_back(8'h7F); tlen.push_back(0); toff.push_back(0); tlo.push_back(0);
    tst.push_back(ST_OPC); tx.push_back(0);                                  // unknown opcode
    tq.push_back(2); top.push_back(8'h01); tlen.push_back(1536); toff.push_back(32'hE00); tlo.push_back(0);
    tst.push_back(ST_PRP); tx.push_back(64'h200);                            // PRP2 with an offset
    tq.push_back(2); top.push_back(8'h02); tlen.push_back(12288); toff.push_back(0); tlo.push_back(0);
    tst.push_back(ST_PRP); tx.push_back(64'h4);                              // list pointer not 8-byte aligned
    foreach (tq[k]) run_one(tq[k], top[k], tlen[k], toff[k], tlo[k], tst[k], tx[k]);
    if (recs.size() != 0) fail($sformatf("%0d commands never completed", recs.size()));
  endtask

  // A record for an entry firmware posts without a command.
  function automatic void post_rec(int q, bit [15:0] cid);
    rec_c r = new();
    r.sq = q; r.pos = sq_size[q] - 1; r.seq = sq_atail[q] - 1; r.opc = 8'h00; r.cid = cid; r.st = ST_OK;
    r.x = null;
    recs[cid] = r;
  endfunction

  // Completion queues on their own: wrap and phase on every queue, a full
  // queue, the MSI-X message after its entry, a masked vector, dropped
  // entries, a failed entry write.
  task automatic t_cqe();
    bit        got;
    bit [31:0] v;
    bit [15:0] cid = 16'hE000;
    int        n, m0;
    io_setup(4, 4, 4);
    // Every queue: 6 entries, consumed one by one, so the phase wraps.
    for (int q = 0; q < NQ; q++) begin
      for (int k = 0; k < 6; k++) begin
        post_rec(q, cid);
        fw_post(q, cid, q, ST_OK, {16'hC0DE, cid});
        cid++;
        n = 0;
        do begin @(negedge clk); host_cq_take(q, got); n++; end while (!got && n < 3000);
        if (!got) fail($sformatf("CQ%0d: entry %0d never written", q, k));
        ring_cq(q);
      end
    end
    // CQ1 full: 3 entries fill it; the 4th waits until the host frees one.
    for (int k = 0; k < 4; k++) begin post_rec(1, cid); fw_post(1, cid, 1, ST_OK, {16'hC0DE, cid}); cid++; end
    repeat (200) @(negedge clk);
    fw_rd(R_QST, v);
    if (!v[5] || v[2:0] != 3'd1) fail($sformatf("CQE_STATUS %h with CQ1 full, expected one waiting", v));
    host_cq_take(1, got);
    ring_cq(1);
    n = 0;
    do begin fw_rd(R_QST, v); n++; end while (v[2:0] != 3'd0 && n < 1000);
    if (v[2:0] != 3'd0) fail("entry still waiting after the host freed CQ1");
    for (int k = 0; k < 3; k++) begin host_cq_take(1, got); if (!got) fail("CQ1 entry missing"); end
    ring_cq(1);
    // The message follows its entry: when it arrives, the entry is there.
    m0 = msi_count(2);
    post_rec(2, cid);
    fw_post(2, cid, 2, ST_OK, {16'hC0DE, cid});
    cid++;
    n = 0;
    while (msi_count(2) == m0 && n < 3000) begin @(negedge clk); n++; end
    host_cq_take(2, got);
    if (!got) fail("CQ2: MSI-X message before its entry");
    ring_cq(2);
    // Vector 3 masked: the message waits in the PBA until the unmask.
    hw32(32'h2000 + 16 * 3 + 12, 32'h1);
    m0 = msi_count(3);
    post_rec(3, cid);
    fw_post(3, cid, 3, ST_OK, {16'hC0DE, cid});
    cid++;
    repeat (400) @(negedge clk);
    host_cq_take(3, got);
    if (!got) fail("CQ3 entry missing while its vector is masked");
    if (msi_count(3) != m0 || !st_msix_pend[3]) fail("masked vector 3: message sent or not pending");
    else cqev(9);
    hw32(32'h2000 + 16 * 3 + 12, 32'h0);
    n = 0;
    while (msi_count(3) == m0 && n < 3000) begin @(negedge clk); n++; end
    if (msi_count(3) != m0 + 1) fail("vector 3 not sent after the unmask");
    ring_cq(3);
    // Dropped: to a completion queue that does not exist, and a fifth entry
    // while four wait.
    fw_wr(R_EVENT, 32'h3F);
    fw_post(5, cid, 1, ST_OK, 32'd0, 1'b1);
    cid++;
    repeat (50) @(negedge clk);
    fw_rd(R_QST, v);
    if (!v[8]) fail("post to CQ5 not dropped");
    expect_reg(R_EVENT, 32'h20, 32'h20, "EVENT.CQE_ERR after a drop");
    fw_wr(R_QST, 32'h300);
    fw_wr(R_EVENT, 32'h3F);
    for (int k = 0; k < 3; k++) begin post_rec(1, cid); fw_post(1, cid, 1, ST_OK, {16'hC0DE, cid}); cid++; end
    repeat (200) @(negedge clk);                      // CQ1 full again: these 3 fill it
    for (int k = 0; k < 4; k++) begin post_rec(1, cid); fw_post(1, cid, 1, ST_OK, {16'hC0DE, cid}, 1'b1); cid++; end
    fw_post(1, cid, 1, ST_OK, {16'hC0DE, cid}, 1'b1);   // the fifth: dropped
    cid++;
    repeat (20) @(negedge clk);
    fw_rd(R_QST, v);
    if (!v[8] || !v[4]) fail($sformatf("CQE_STATUS %h: no drop with 4 waiting", v));
    fw_wr(R_QST, 32'h300);
    n = 0;
    while (recs.size() > 0 && n < 50) begin
      host_cq_take(1, got);
      if (got) ring_cq(1);
      repeat (40) @(negedge clk);
      n++;
    end
    if (recs.size() != 0) fail($sformatf("%0d posted entries never seen", recs.size()));
    // A failed entry write: Bus Master Enable clear. CSTS.CFS follows.
    cfgwr(10'd1, 32'h0000_0002, 4'h1);
    fw_post(1, cid, 1, ST_OK, 32'd0);
    cid++;
    repeat (300) @(negedge clk);
    fw_rd(R_QST, v);
    if (!v[9]) fail("entry write with Bus Master Enable clear did not fail");
    hr32(32'h1C, v);
    if (!v[1]) fail("CSTS.CFS not set by a failed entry write");
    cfgwr(10'd1, 32'h0000_0006, 4'h1);
    fw_wr(R_QST, 32'h300);
    fw_wr(R_EVENT, 32'h3F);
  endtask

  // Transfer errors, directly through XF_* (no commands).
  task automatic t_xerr();
    bit [3:0] c;
    prp_c     x;
    io_setup(1, 8);
    fw_xfer(1'b0, HDATA, 64'd0, SBUF, 0, c);
    if (c != 4'd8) fail($sformatf("length 0: cause %0d", c));
    fw_xfer(1'b0, HDATA, 64'd0, SBUF, 131076, c);
    if (c != 4'd8) fail($sformatf("length 128 KiB + 4: cause %0d", c));
    x = make_prp(512, 0, 0);
    fw_xfer(1'b0, x.prp1 + 64'd2, x.prp2, SBUF, 512, c);
    if (c != 4'd9) fail($sformatf("PRP1 not DW aligned: cause %0d", c));
    drop_prp(x);
    x = make_prp(4096, 32'h800, 0);
    fw_xfer(1'b1, x.prp1, x.prp2 + 64'h10, SBUF, 4096, c);
    if (c != 4'd9) fail($sformatf("PRP2 page with an offset: cause %0d", c));
    drop_prp(x);
    x = make_prp(16384, 0, 32'h40);
    put_qw(x.lp[0] + 64'h48, x.pg[2] + 64'h200);                  // second list entry
    fw_xfer(1'b0, x.prp1, x.prp2, SBUF, 16384, c);
    if (c != 4'd9) fail($sformatf("list entry with an offset: cause %0d", c));
    drop_prp(x);
    x = make_prp(20480, 0, 32'hFF0);
    put_qw(x.lp[0] + 64'hFF8, x.lp[1] + 64'h4);                   // chain pointer
    fw_xfer(1'b1, x.prp1, x.prp2, SBUF, 20480, c);
    if (c != 4'd9) fail($sformatf("chain pointer not 8-byte aligned: cause %0d", c));
    drop_prp(x);
    // The host answers the data read with UR.
    x = make_prp(2048, 0, 0);
    host.inj_ur = 100;
    fw_xfer(1'b0, x.prp1, x.prp2, SBUF, 2048, c);
    host.inj_ur = 0;
    if (c == 4'd0 || c >= 4'd8) fail($sformatf("UR on the data read: cause %0d", c));
    drop_prp(x);
    // A controller reset during a long transfer: it ends between pages with
    // cause 10, and the reset waits for it.
    x = make_prp(131072, 0, 0);
    host.lat_min = 400;
    host.lat_max = 400;
    fork
      fw_xfer(1'b0, x.prp1, x.prp2, SBUF, 131072, c);
      begin
        repeat (300) @(negedge clk);
        host_disable();
      end
    join
    host.lat_min = 4;
    host.lat_max = 60;
    if (c != 4'd10) fail($sformatf("transfer during a controller reset: cause %0d", c));
    drop_prp(x);
    // A controller reset while a transfer and a completion entry wait for the
    // bus master, which a fetch holds (the host slow to answer): both give up
    // without a transfer.
    io_setup(1, 8);
    x = make_prp(4096, 0, 0);
    host.lat_min = 600;
    host.lat_max = 600;
    put_sqe(1);
    ring_sq(1);
    while (!u_nv.f_busy) @(negedge clk);
    fork
      fw_xfer(1'b1, x.prp1, x.prp2, SBUF, 4096, c);
      begin
        fw_post(1, 16'hFFFF, 1, ST_OK, 32'd0, 1'b1);
        while (!(u_nv.p_valid && u_nv.c_valid)) @(negedge clk);
        hw32(32'h14, 32'h0046_0000);
      end
    join
    host.lat_min = 4;
    host.lat_max = 60;
    if (c != 4'd10) fail($sformatf("transfer waiting during a controller reset: cause %0d", c));
    host_disable();
    expect_reg(R_QST, 32'h7, 32'h0, "no completion entry left after the reset");
    expect_q[1].delete();
    drop_prp(x);
    fw_wr(R_EVENT, 32'h3F);
  endtask

  // Throughput and latency of step 2-3, called from t_perf (fast host, memory
  // that never stalls): PRP transfers of 4 KiB and 128 KiB each way (XF_CYCLES),
  // and a completion entry from the CQE_CTRL write to the entry in host memory
  // and to its MSI-X message.
  task automatic t_perf23();
    prp_c      x;
    bit [3:0]  c;
    bit [31:0] cyc;
    int        lens[2] = '{4096, 131072};
    longint    t0, t1, t2;
    int        m0;
    fw_ioq(1, 8);
    cq_init(1, 64'h0000_0003_0003_1000, 8);
    foreach (lens[k]) begin
      for (int d = 0; d < 2; d++) begin
        x = make_prp(lens[k], 0, 0);
        fw_xfer(1'(d), x.prp1, x.prp2, SBUF, lens[k], c);
        fw_rd(R_XCYC, cyc);
        if (c != 4'd0) fail($sformatf("perf transfer: cause %0d", c));
        $display("[NVME] perf: PRP transfer of %0d bytes, %s: %0d clocks, %0.2f bytes per clock", lens[k],
                 (d == 1) ? "SRAM to host" : "host to SRAM", cyc, real'(lens[k]) / real'(cyc));
        drop_prp(x);
      end
    end
    post_rec(1, 16'hBEEF);
    m0 = msi_count(1);
    fork
      fw_post(1, 16'hBEEF, 1, ST_OK, {16'hC0DE, 16'hBEEF});
      begin
        while (!u_nv.c_post) @(negedge clk);
        t0 = $time;
        while (!u_nv.c_adv) @(negedge clk);
        t1 = $time;
        while (msi_count(1) == m0) @(negedge clk);
        t2 = $time;
      end
    join
    begin
      bit got;
      host_cq_take(1, got);
      if (!got) fail("perf: completion entry not in host memory");
    end
    $display("[NVME] perf: completion entry: %0d clocks from the post to the entry written, %0d to its MSI-X message at the host",
             (t1 - t0) / CLK, (t2 - t0) / CLK);
  endtask

  // Random I/O: four I/O queues and the admin queue, Reads, Writes, Flushes,
  // a few bad commands, random layouts; firmware handles each command; the
  // host consumes completions and rings CQ head doorbells late at times; now
  // and then a controller reset (firmware held off first) and new queues.
  bit fw_run, fw_hold, fw_idle;
  bit reset_done [int];
  int n_io_resets;

  task automatic fw_loop();
    bit got;
    fw_idle = 1'b1;
    while (fw_run) begin
      if (fw_hold) begin
        fw_idle = 1'b1;
        @(negedge clk);
        continue;
      end
      fw_idle = 1'b0;
      fw_take_io(got);
      fw_idle = 1'b1;
      if (!got) repeat ($urandom_range(20, 1)) @(negedge clk);
    end
  endtask

  task automatic t_io(int ncmd);
    bit got;
    int sz, issued = 0, n = 0;
    sz = $urandom_range(16, 2);
    io_setup(4, sz, 8);
    for (int q = 0; q < NQ; q++) begin sq_qd[q] = 0; rung_sq[q] = 0; rung_cq[q] = 0; end
    fw_run = 1'b1;
    fw_hold = 1'b0;
    fork
      fw_loop();
      begin
        while (issued < ncmd || recs.size() > 0) begin
          int q = $urandom_range(NQ - 1);
          if (issued < ncmd && sq_room(q) > 0 && recs.size() < 24) begin
            int r = $urandom_range(99);
            int len = 512 * (($urandom_range(9) == 0) ? $urandom_range(256, 1) : $urandom_range(32, 1));
            int off = 4 * $urandom_range(1023);
            int lofs = 8 * (($urandom_range(2) == 0) ? $urandom_range(511, 500) : $urandom_range(511));
            if (q == 0)       sub_io(0, 8'h06, 4096, off, lofs);
            else if (r < 44)  sub_io(q, 8'h02, len, off, lofs);
            else if (r < 88)  sub_io(q, 8'h01, len, off, lofs);
            else if (r < 93)  sub_io(q, 8'h00, 0, 0, 0);
            else if (r < 96)  sub_io(q, 8'h55, 0, 0, 0, ST_OPC);
            else              sub_io(q, 8'h01, 2048 + len, 32'hE00, lofs, ST_PRP, 64'h4);
            issued++;
            if ($urandom_range(2) == 0) ring_sq_new(q);
          end else begin
            for (int k = 0; k < NQ; k++) ring_sq_new(k);
          end
          // Completions: take what is there; the head doorbell now or later.
          for (int k = 0; k < NQ; k++) begin
            int taken = 0;
            do begin host_cq_take(k, got); if (got) taken++; end while (got);
            if (taken > 0 && $urandom_range(3) != 0) ring_cq(k);
            if (taken == 0 && rung_cq[k] != hcq_head[k] && $urandom_range(7) == 0) ring_cq(k);
          end
          repeat ($urandom_range(30, 1)) @(negedge clk);
          if (++n > 200000) begin fail($sformatf("random I/O stuck: %0d outstanding", recs.size())); break; end
          // A controller reset now and then, with firmware held off.
          if (issued < ncmd && issued > 0 && issued % 97 == 0 && !reset_done[issued]) begin
            reset_done[issued] = 1'b1;
            fw_hold = 1'b1;
            while (!fw_idle) @(negedge clk);
            host_disable();
            foreach (recs[c]) if (recs[c].x != null) drop_prp(recs[c].x);
            recs.delete();
            n_io_resets++;
            sz = $urandom_range(16, 2);
            io_setup(4, sz, 8);
            for (int k = 0; k < NQ; k++) begin sq_qd[k] = 0; rung_sq[k] = 0; rung_cq[k] = 0; end
            fw_hold = 1'b0;
          end
        end
        fw_run = 1'b0;
      end
    join
  endtask

  // Random: commands into all queues, random firmware pace, and controller
  // resets now and then.
  int n_resets, n_shut;
  task automatic t_random(int ncmd);
    bit got;
    bit [31:0] f0;
    int sizes[NQ];
    for (int q = 0; q < NQ; q++) sizes[q] = $urandom_range(40, 2);
    host_enable(sizes[0]);
    for (int q = 1; q < NQ; q++) fw_ioq(q, sizes[q]);
    while (n_sub < ncmd) begin
      int q = $urandom_range(NQ - 1);
      refresh_heads();
      if (sq_room(q) > 0) begin
        repeat ($urandom_range(sq_room(q), 1)) put_sqe(q);
        ring_sq(q);
      end
      repeat ($urandom_range(6)) begin
        if ($urandom_range(3) != 0) fw_take(got);
      end
      // A controller reset with commands in flight, half the time after a
      // shutdown: what was not fetched is lost, as for a host that resets
      // its controller.
      if ($urandom_range(999) == 0) begin
        fw_drain(40);
        if ($urandom_range(1) == 1) begin
          bit [31:0] v;
          int w = 0;
          hw32(32'h14, 32'h0046_4001);
          do begin
            hr32(32'h1C, v);
            if (++w > 100) begin fail("SHST never reached complete"); break; end
          end while (v[3:2] != 2'b10);
          // Shutdown complete: nothing is fetched any more.
          fw_rd(R_FETCH, f0);
          repeat (200) @(negedge clk);
          expect_reg(R_FETCH, 32'hFFFF_FFFF, f0, "fetches after SHST complete");
          n_shut++;
        end
        // Firmware may still be taking commands while the reset runs.
        fork
          host_disable();
          repeat ($urandom_range(3)) fw_take(got);
        join
        for (int k = 1; k < NQ; k++) begin
          expect_reg(r_ioq(k, 2), 32'h8000_0000, 32'h0, "SQ enable after a controller reset");
          expect_reg(r_ioq(k, 5), 32'h8000_0000, 32'h0, "CQ enable after a controller reset");
        end
        for (int k = 0; k < NQ; k++) expect_q[k].delete();
        n_resets++;
        for (int k = 0; k < NQ; k++) sizes[k] = $urandom_range(40, 2);
        host_enable(sizes[0]);
        for (int k = 1; k < NQ; k++) fw_ioq(k, sizes[k]);
      end
    end
    fw_drain();
    if (outstanding() != 0) fail($sformatf("%0d commands never fetched", outstanding()));
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test;
  int    ncmd;
  initial begin
    if (!$value$plusargs("test=%s", test)) test = "all";
    if (!$value$plusargs("n=%d", ncmd)) ncmd = 2000;
    apbd = new(aif);
    host = new(tif);
    host.clk_period = CLK;
    mem = new(mif);
    mem.clk_period = CLK;
    mem.narrow_ok = 1'b1;
    host.run();
    mem.run();
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);
    enumerate();
    begin
      string seq[$];
      if (test == "all") begin
        // the directed tests, then random; each leaves the controller off
        seq.push_back("regs");  seq.push_back("enable"); seq.push_back("fetch"); seq.push_back("rr");
        seq.push_back("doorbell"); seq.push_back("ferr"); seq.push_back("shutdown"); seq.push_back("reset");
        seq.push_back("data");  seq.push_back("cqe");    seq.push_back("xerr");  seq.push_back("random");
      end else begin
        seq.push_back(test);
      end
      foreach (seq[k]) begin
        case (seq[k])
          "regs":     t_regs();
          "enable":   t_enable();
          "fetch":    t_fetch();
          "rr":       t_rr();
          "doorbell": t_doorbell();
          "ferr":     t_ferr();
          "shutdown": t_shutdown();
          "reset":    t_reset();
          "perf":     t_perf();
          "data":     t_data();
          "cqe":      t_cqe();
          "xerr":     t_xerr();
          "io":       t_io(ncmd);
          "random":   t_random(ncmd);
          default:    fail($sformatf("no test %s", seq[k]));
        endcase
        if (test == "all" && k + 1 < seq.size()) host_disable();
      end
    end
    repeat (100) @(negedge clk);
    errors += host.errors + mem.errors;
    $display("[NVME] test %s: %0d commands submitted, %0d fetched and checked, %0d controller resets (%0d after a shutdown), %0d APB accesses",
             test, n_sub, n_chk, n_resets, n_shut, n_apb);
    $display("[NVME] host sent %0d TLPs, device MRd %0d (%0d bytes)", host.n_sent, host.n_dev_mrd,
             host.dev_rd_bytes);
    if (n_xfer > 0 || n_post > 0)
      $display("[NVME] data and completions: %0d transfers (%0d bytes to the host, %0d from it), %0d entries posted; completions seen: %0d good, %0d with an error status; %0d MSI-X messages; %0d controller resets in random I/O",
               n_xfer, n_rd_bytes, n_wr_bytes, n_post, n_io_ok, n_io_err, host.msis.size(), n_io_resets);
    if (errors == 0) $display("[NVME] PASS");
    else             $display("[NVME] FAIL: %0d errors", errors);
    if (errors != 0) $fatal(1, "tb_nvme failed");
    $finish;
  end

  initial begin
    #(64'd4_000_000_000);
    $display("[NVME] FAIL: timeout");
    $fatal(1, "tb_nvme timeout");
  end

endmodule
