// tb_tl
//
// Testbench of the transaction layer, tl_core (docs/10_transaction_layer.md,
// section 6). The host model (tlp_tb_pkg) sits on the packed TLP streams, the
// DMA testbench's memory model (dma_tb_pkg::mem_slave) on AXI port M3, and the
// testbench drives the HOST register signals as firmware would.
//
//   +test=<name>  enum, target, errors, msix, bm, bm_err, random, or all
//                 (default: all, in that order)
//   +n=<ops>      operations of the random test (default 3000)
//
// Memory map of the test:
//   AXI 0x1000_8000-0x1000_FFFF  BAR2 window (32 KiB), checked against a
//                                byte shadow of everything the host wrote
//   AXI 0x1000_0000-0x1000_7FFF  local side of bus-master transfers
//   host 0x0000_0001_2000_0000   and 0x3000_0000: bus-master sources
//   host 0x0000_0000_5000_0000   and 0x0000_0002_5000_0000: destinations
//   host 0xFEE0_0000             MSI-X messages
//   AXI 0x1001_0000-0x1001_7FFF  local side of the NVMe port's transfers
//   host 0x0000_0004_0000_0000   and 0x0000_0004_4000_0000: the NVMe port's
//                                sources and destinations
//   BAR0 0x0000-0x1FFF           a register model on the register port
//   BAR0 at 0x0000_0008_0000_0000 (4DW headers), BAR2 at 0xC000_0000 (3DW)
//
// The random test also drives the NVMe controller's bus-master port (nv_*)
// with its own transfers, so that it competes with the HOST-register requests
// for the bus master.
//
// axi4_checker watches M3. A test passes when the host model, the memory
// model and every check here report no error.

`timescale 1ns/1ps

module tb_tl;
  import tlp_tb_pkg::*;

  localparam longint CLK = 20;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK / 2) clk = ~clk;

  tlp_if  tif (.clk(clk), .rst_n(rst_n));
  axi4_if axi (.clk(clk), .rst_n(rst_n));
  axi4_checker #(.KIND("M"), .IDX(3)) u_chk (.a(axi));

  // HOST register signals
  logic [31:15] bar2_win = 17'h0_2001;   // 0x1000_8000
  logic [7:0]   cto_ticks = 8'd64;
  logic         bm_start = 1'b0, bm_d2h = 1'b0;
  logic [63:2]  bm_haddr = '0;
  logic [31:2]  bm_laddr = '0;
  logic [17:0]  bm_len = '0;
  logic         bm_done, bm_busy;
  logic [2:0]   bm_cause;
  logic         msix_req = 1'b0;
  logic [2:0]   msix_vec = 3'd0;
  logic         st_mse, st_bme, st_msix_en, st_msix_fmask, st_mps256;
  logic [2:0]   st_mrrs;
  logic [15:0]  st_id;
  logic [7:0]   st_msix_pend;
  logic ev_ur, ev_poisoned, ev_unexp_cpl, ev_cpl_timeout, ev_cpl_err, ev_axi_err;
  logic [1:0] ev_malformed;
  logic ev_discard, ev_msix_drop, rx_tlp, tx_tlp, idle;
  logic [1:0] awid, arid;

  // Register port: a model of 2048 DWs (BAR0 0x0000-0x1FFF)
  logic        rp_we;
  logic [10:0] rp_dw;
  logic [3:0]  rp_be;
  logic [31:0] rp_wdata;
  logic [31:0] rp_mem [2048];
  int          rp_writes;
  initial for (int i = 0; i < 2048; i++) rp_mem[i] = 32'(i) * 32'h0101_0003 ^ 32'hA5C3_0000;
  always @(posedge clk) if (rp_we) begin
    for (int k = 0; k < 4; k++) if (rp_be[k]) rp_mem[rp_dw][8*k +: 8] <= rp_wdata[8*k +: 8];
    rp_writes++;
  end
  wire [31:0] rp_rd0 = rp_mem[rp_dw];
  wire [31:0] rp_rd1 = rp_mem[11'(rp_dw + 11'd1)];

  // NVMe bus-master port, driven by the random test
  logic        nv_valid = 1'b0, nv_d2h = 1'b0;
  logic        nv_ready, nv_done;
  logic [63:2] nv_haddr = '0;
  logic [31:2] nv_laddr = '0;
  logic [17:0] nv_len = '0;
  logic [2:0]  nv_cause;

  tl_core dut (
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
    .bar2_win (bar2_win), .cto_ticks (cto_ticks),
    .bm_start (bm_start), .bm_d2h (bm_d2h), .bm_haddr (bm_haddr), .bm_laddr (bm_laddr),
    .bm_len (bm_len), .bm_done (bm_done), .bm_cause (bm_cause), .bm_busy (bm_busy),
    .msix_req (msix_req), .msix_vec (msix_vec),
    .st_mse (st_mse), .st_bme (st_bme), .st_msix_en (st_msix_en), .st_msix_fmask (st_msix_fmask),
    .st_mps256 (st_mps256), .st_mrrs (st_mrrs), .st_id (st_id), .st_msix_pend (st_msix_pend),
    .ev_ur (ev_ur), .ev_malformed (ev_malformed), .ev_poisoned (ev_poisoned),
    .ev_unexp_cpl (ev_unexp_cpl), .ev_cpl_timeout (ev_cpl_timeout), .ev_cpl_err (ev_cpl_err),
    .ev_axi_err (ev_axi_err), .ev_discard (ev_discard), .ev_msix_drop (ev_msix_drop),
    .rx_tlp (rx_tlp), .tx_tlp (tx_tlp), .idle (idle)
  );

  assign axi.awid    = {2'b00, awid};
  assign axi.arid    = {2'b00, arid};
  assign axi.awprot  = 3'd0;
  assign axi.arprot  = 3'd0;
  assign axi.awcache = 4'd0;
  assign axi.arcache = 4'd0;
  assign axi.awqos   = 4'd0;
  assign axi.arqos   = 4'd0;

  tlp_host               host;
  dma_tb_pkg::mem_slave  mem;

  // Event counters
  int c_ur, c_mal, c_poi, c_unexp, c_to, c_cerr, c_axi, c_disc, c_mxdrop, c_rx, c_tx;
  always @(posedge clk) begin
    c_ur     += ev_ur;
    c_mal    += int'(ev_malformed);
    c_poi    += ev_poisoned;
    c_unexp  += ev_unexp_cpl;
    c_to     += ev_cpl_timeout;
    c_cerr   += ev_cpl_err;
    c_axi    += ev_axi_err;
    c_disc   += ev_discard;
    c_mxdrop += ev_msix_drop;
    c_rx     += rx_tlp;
    c_tx     += tx_tlp;
  end


  int errors;
  function void fail(string s);
    errors++;
    if (errors <= 30) $display("[TL] ERROR at %0t: %s", $time, s);
  endfunction

  // Placement of the BARs and the windows
  localparam bit [63:0] BAR0 = 64'h0000_0008_0000_0000;
  localparam bit [63:0] BAR2 = 64'h0000_0000_C000_0000;
  localparam bit [31:0] W2   = 32'h1000_8000;
  localparam bit [63:0] MSI  = 64'h0000_0000_FEE0_0000;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic clocks(int n);
    repeat (n) @(negedge clk);
  endtask

  task automatic cfgrd(bit [9:0] r, output bit [31:0] d);
    bit [2:0] st;
    host.cfg_rd(r, d, st);
    if (st != SC) fail($sformatf("CfgRd reg %0d status %0d", r, st));
  endtask

  task automatic cfgwr(bit [9:0] r, bit [31:0] d, bit [3:0] be = 4'hF);
    bit [2:0] st;
    host.cfg_wr(r, d, be, st);
    if (st != SC) fail($sformatf("CfgWr reg %0d status %0d", r, st));
  endtask

  task automatic expect_cfg(bit [9:0] r, bit [31:0] mask, bit [31:0] want, string what);
    bit [31:0] d;
    cfgrd(r, d);
    if ((d & mask) != want) fail($sformatf("%s: reg %0d reads %h, expected %h under %h", what, r, d, want, mask));
  endtask

  // Byte shadow of the BAR2 window; unwritten bytes hold the memory model's
  // initial value.
  bit [7:0] shadow [bit [31:0]];
  function bit [7:0] w2_exp(bit [31:0] a);
    return shadow.exists(a) ? shadow[a] : dma_tb_pkg::init_byte(a);
  endfunction

  // Host write into the BAR2 window, shadow updated at once (posted writes
  // reach memory in order, and no read of these bytes is outstanding).
  function void w2_write(int off, byteq_t b, bit ep = 1'b0);
    host.mem_wr(BAR2 + 64'(off), b, ep);
    if (!ep) foreach (b[i]) shadow[W2 + 32'(off + i)] = b[i];
  endfunction

  function automatic byteq_t rnd_bytes(int n);
    byteq_t b;
    for (int i = 0; i < n; i++) b.push_back(8'($urandom));
    return b;
  endfunction

  // The low n bytes of v, little-endian.
  function automatic byteq_t le_bytes(bit [63:0] v, int n);
    byteq_t b;
    for (int i = 0; i < n; i++) b.push_back(v[8*i +: 8]);
    return b;
  endfunction

  function automatic dwq_t dws(int n, bit [31:0] v);
    dwq_t q;
    for (int i = 0; i < n; i++) q.push_back(v + 32'(i));
    return q;
  endfunction

  function automatic bit same(byteq_t a, byteq_t b);
    if (a.size() != b.size()) return 1'b0;
    foreach (a[i]) if (a[i] !== b[i]) return 1'b0;
    return 1'b1;
  endfunction

  function automatic dma_tb_pkg::range_t rng(bit [31:0] lo, bit [31:0] hi);
    dma_tb_pkg::range_t r;
    r.lo = lo; r.hi = hi; r.resp = dma_tb_pkg::SLVERR;
    return r;
  endfunction

  // MSI-X table entry v: address MSI + 16v, data 0x1000 + v, unmasked; two
  // QW writes, as software accesses the table.
  function void msix_entry(int v);
    host.mem_wr(BAR0 + 64'h2000 + 64'(16 * v), le_bytes(MSI + 64'(16 * v), 8));
    host.mem_wr(BAR0 + 64'h2008 + 64'(16 * v), le_bytes({32'd0, 32'h1000 + 32'(v)}, 8));
  endfunction

  task automatic w2_check_read(int off, int n, string what);
    byteq_t   b;
    bit [2:0] st;
    host.mem_rd(BAR2 + 64'(off), n, b, st);
    if (st != SC) fail($sformatf("%s: read at +%h status %0d", what, off, st));
    else if (b.size() != n) fail($sformatf("%s: read at +%h gave %0d bytes of %0d", what, off, b.size(), n));
    else foreach (b[i])
      if (b[i] !== w2_exp(W2 + 32'(off + i))) begin
        fail($sformatf("%s: byte +%h is %h, expected %h", what, off + i, b[i], w2_exp(W2 + 32'(off + i))));
        break;
      end
  endtask

  task automatic wait_idle(int limit = 200000);
    int n = 0;
    while (!(host.idle() && idle && mem.idle() && !bm_busy) && n < limit) begin
      @(negedge clk);
      n++;
    end
    clocks(4);
    if (n >= limit) fail("no return to idle");
  endtask

  // Bus-master request as firmware would start it, waiting for done.
  task automatic bm_xfer(bit d2h, bit [63:0] ha, bit [31:0] la, int len, output bit [2:0] cause,
                         output int cyc);
    longint t0;
    @(negedge clk);
    bm_d2h   = d2h;
    bm_haddr = ha[63:2];
    bm_laddr = la[31:2];
    bm_len   = 18'(len);
    bm_start = 1'b1;
    t0 = $time;
    @(negedge clk);
    bm_start = 1'b0;
    while (!bm_done) @(posedge clk);
    cause = bm_cause;
    cyc = int'(($time - t0) / CLK);
    @(negedge clk);
  endtask

  // A transfer on the NVMe controller's port: VALID until READY, then done.
  int nv_xfers, nv_contend;
  task automatic nv_xfer(bit d2h, bit [63:0] ha, bit [31:0] la, int len, output bit [2:0] cause);
    @(negedge clk);
    nv_d2h   = d2h;
    nv_haddr = ha[63:2];
    nv_laddr = la[31:2];
    nv_len   = 18'(len);
    nv_valid = 1'b1;
    // READY is combinational and settles before the next edge.
    #1;
    while (!nv_ready) begin @(negedge clk); #1; end
    @(posedge clk);
    #1;
    nv_valid = 1'b0;
    while (!nv_done) @(posedge clk);
    cause = nv_cause;
    nv_xfers++;
    @(negedge clk);
  endtask

  // Clocks in which both requesters wait for the bus master, and the
  // arbiter's rule: with both waiting when the bus master takes a request,
  // the one not served last goes first. A done on the NVMe port must belong
  // to an NVMe transfer: the controller takes any done while its fetch
  // waits as that fetch's.
  int  nv_alt;
  bit  tb_last_nv, nv_out;
  always @(posedge clk) if (rst_n) begin
    bit g_nv, g_csr;
    g_nv  = nv_valid && nv_ready;
    g_csr = dut.grant_csr;
    if (nv_valid && !nv_ready && bm_busy) nv_contend++;
    if (g_nv && g_csr) fail("bus master granted to both requesters");
    if (nv_done && !nv_out) fail("done on the NVMe port with no NVMe transfer in flight");
    if (nv_done) nv_out = 1'b0;
    if (g_nv)    nv_out = 1'b1;
    if (dut.csr_pend && nv_valid && dut.bm_req_ready) begin
      if (tb_last_nv ? !g_csr : !g_nv) fail("bus-master requesters not served alternately");
      nv_alt++;
    end
    if (g_nv)  tb_last_nv = 1'b1;
    if (g_csr) tb_last_nv = 1'b0;
  end

  function void cmp_h2d(bit [63:0] ha, bit [31:0] la, int len, string what);
    for (int i = 0; i < 4 * len; i++) begin
      if (mem.get(la + 32'(i)) !== host.hget(ha + 64'(i))) begin
        fail($sformatf("%s: local byte %h is %h, host %h", what, la + 32'(i), mem.get(la + 32'(i)),
                       host.hget(ha + 64'(i))));
        break;
      end
    end
  endfunction

  function void cmp_d2h(bit [63:0] ha, bit [31:0] la, int len, string what);
    for (int i = 0; i < 4 * len; i++) begin
      if (!host.hmem.exists(ha + 64'(i)) || host.hmem[ha + 64'(i)] !== mem.get(la + 32'(i))) begin
        fail($sformatf("%s: host byte %h is %h, local %h", what, ha + 64'(i), host.hget(ha + 64'(i)),
                       mem.get(la + 32'(i))));
        break;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  int  cv_kind, cv_len, cv_lane, cv_x4k, cv_split;
  covergroup cg_bm;
    cp_dir:  coverpoint cv_kind { bins h2d = {0}; bins d2h = {1}; }
    cp_len:  coverpoint cv_len  { bins one = {1}; bins few = {[2:31]}; bins mps = {[32:64]};
                                  bins mid = {[65:255]}; bins big = {[256:2048]}; }
    cp_lane: coverpoint cv_lane { bins same = {0}; bins differ = {1}; }
    cp_x4k:  coverpoint cv_x4k  { bins in_page = {0}; bins host = {1}; bins local_ = {2}; bins both = {3}; }
    x_dir_len:  cross cp_dir, cp_len;
    x_dir_lane: cross cp_dir, cp_lane;
    x_dir_x4k:  cross cp_dir, cp_x4k;
  endgroup

  int cv_sz, cv_off;
  // Inbound writes and reads, by size and by byte offset in the 8-byte beat.
  // Writes carry at most Max_Payload_Size (256 bytes), so they have no "big"
  // bin.
  covergroup cg_wr;
    cp_sz:  coverpoint cv_sz  { bins b1 = {1}; bins b2_3 = {[2:3]}; bins dw1 = {4}; bins b5_8 = {[5:8]};
                                bins upto128 = {[9:128]}; bins upto256 = {[129:256]}; }
    cp_off: coverpoint cv_off { bins o0 = {0}; bins o1 = {1}; bins o2 = {2}; bins o3 = {3};
                                bins o4 = {4}; bins o5 = {5}; bins o6 = {6}; bins o7 = {7}; }
    x_sz_off: cross cp_sz, cp_off;
  endgroup

  covergroup cg_rd;
    cp_sz:  coverpoint cv_sz  { bins b1 = {1}; bins b2_3 = {[2:3]}; bins dw1 = {4}; bins b5_8 = {[5:8]};
                                bins upto128 = {[9:128]}; bins upto256 = {[129:256]};
                                bins big = {[257:4096]}; }
    cp_off: coverpoint cv_off { bins o0 = {0}; bins o1 = {1}; bins o2 = {2}; bins o3 = {3};
                                bins o4 = {4}; bins o5 = {5}; bins o6 = {6}; bins o7 = {7}; }
    x_sz_off: cross cp_sz, cp_off;
  endgroup

  covergroup cg_split;
    cp_cpls: coverpoint cv_split { bins one = {1}; bins two = {2}; bins few = {[3:8]};
                                   bins many = {[9:64]}; }
  endgroup

  cg_bm    cov_bm    = new();
  cg_wr    cov_wr    = new();
  cg_rd    cov_rd    = new();
  cg_split cov_split = new();

  function void sample_bm(bit d2h, bit [63:0] ha, bit [31:0] la, int len);
    int eh, el;
    eh = int'(ha[11:2]) + len - 1;
    el = int'(la[11:2]) + len - 1;
    cv_kind = int'(d2h);
    cv_len  = len;
    cv_lane = (ha[2] != la[2]) ? 1 : 0;
    cv_x4k  = (eh > 1023 ? 1 : 0) + (el > 1023 ? 2 : 0);
    cov_bm.sample();
  endfunction

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  // Enumeration: IDs, BAR sizing and placement, capabilities, MSI-X table.
  task automatic t_enum(bit mps256 = 1'b1, bit [2:0] mrrs = 3'd2);
    bit [31:0] d;
    bit [7:0]  p;
    expect_cfg(10'd0, 32'hFFFF_FFFF, 32'h0001_0000, "IDs");
    expect_cfg(10'd2, 32'hFFFF_FFFF, 32'h0108_0201, "class code");
    expect_cfg(10'd3, 32'h00FF_0000, 32'h0000_0000, "header type 0");
    // BAR sizing
    cfgwr(10'd4, 32'hFFFF_FFFF); cfgwr(10'd5, 32'hFFFF_FFFF);
    cfgwr(10'd6, 32'hFFFF_FFFF); cfgwr(10'd7, 32'hFFFF_FFFF);
    cfgwr(10'd8, 32'hFFFF_FFFF);
    expect_cfg(10'd4, 32'hFFFF_FFFF, 32'hFFFF_C004, "BAR0 size 16 KiB, 64-bit");
    expect_cfg(10'd5, 32'hFFFF_FFFF, 32'hFFFF_FFFF, "BAR1");
    expect_cfg(10'd6, 32'hFFFF_FFFF, 32'hFFFF_800C, "BAR2 size 32 KiB, 64-bit prefetchable");
    expect_cfg(10'd8, 32'hFFFF_FFFF, 32'h0000_0000, "BAR4 not implemented");
    cfgwr(10'd4, BAR0[31:0]); cfgwr(10'd5, BAR0[63:32]);
    cfgwr(10'd6, BAR2[31:0]); cfgwr(10'd7, BAR2[63:32]);
    expect_cfg(10'd4, 32'hFFFF_FFF0, BAR0[31:0], "BAR0 placed");
    expect_cfg(10'd5, 32'hFFFF_FFFF, BAR0[63:32], "BAR1 placed");
    // Read-only registers ignore writes.
    cfgwr(10'd0, 32'h1234_5678);
    expect_cfg(10'd0, 32'hFFFF_FFFF, 32'h0001_0000, "IDs after a write");
    // Capability list
    cfgrd(10'd13, d);
    p = d[7:0];
    if (p != 8'h40) fail("capabilities pointer");
    cfgrd(10'(int'(p) / 4), d);
    if (d[7:0] != 8'h10 || d[19:16] != 4'd2) fail("PCI Express capability");
    p = d[15:8];
    cfgrd(10'(int'(p) / 4), d);
    if (d[7:0] != 8'h11 || d[26:16] != 11'd7 || d[15:8] != 8'h00) fail("MSI-X capability");
    expect_cfg(10'(int'(p) / 4 + 1), 32'hFFFF_FFFF, 32'h0000_2000, "MSI-X table offset");
    expect_cfg(10'(int'(p) / 4 + 2), 32'hFFFF_FFFF, 32'h0000_3000, "MSI-X PBA offset");
    expect_cfg(10'd17, 32'h0000_0007, 32'h0000_0001, "Max_Payload_Size Supported 256");
    // Device Control: MPS and MRRS
    cfgwr(10'd18, {16'h0000, 1'b0, mrrs, 1'b1, 3'b000, 3'(mps256), 1'b1, 4'h0}, 4'h3);
    if (st_mps256 != mps256 || st_mrrs != mrrs) fail("Device Control settings");
    host.dev_mps  = mps256 ? 256 : 128;
    host.dev_mrrs = 128 << mrrs;
    // Memory Space and Bus Master Enable
    cfgwr(10'd1, 32'h0000_0006, 4'h1);
    if (!st_mse || !st_bme || st_id != 16'h0100) fail("command register or captured ID");
    // MSI-X table: vector v to MSI + 16v, data 0x1000 + v, unmasked.
    for (int v = 0; v < 8; v++) msix_entry(v);
    cfgrd(10'(int'(p) / 4), d);
    cfgwr(10'(int'(p) / 4), {1'b1, 1'b0, d[29:0]}, 4'h8);
    if (!st_msix_en || st_msix_fmask) fail("MSI-X enable");
    wait_idle();
  endtask

  // Inbound writes and reads of many sizes and alignments.
  task automatic t_target();
    byteq_t   b;
    host_req  rq[$];
    host_req  r;
    int       off, n;
    int sizes[18] = '{1, 2, 3, 4, 5, 7, 8, 9, 12, 60, 64, 120, 124, 127, 128, 129, 132, 252};
    int longs[6]  = '{200, 512, 1000, 2048, 4000, 4096};
    // Sizes around every boundary of the datapath, at all eight offsets.
    for (int s = 0; s < 8; s++) begin
      for (int k = 0; k < 18; k++) begin
        n   = sizes[k];
        off = 256 * k + s;
        cv_sz = n; cv_off = s; cov_wr.sample();
        w2_write(off, rnd_bytes(n));
        cov_rd.sample();
        w2_check_read(off, n, "write then read");
      end
    end
    // Long reads: up to 4 KiB, split into 128-byte completions.
    for (int k = 0; k < 6; k++) begin
      off = (k == 5) ? 4096 : 4096 * (k % 2) + 4 * k + 1;
      if (longs[k] + (off % 4096) > 4096) off = 4096 * (k % 2);
      cv_sz = longs[k]; cv_off = off % 8; cov_rd.sample();
      w2_check_read(off, longs[k], "long read");
    end
    // Several reads outstanding at once, then each checked.
    for (int i = 0; i < 12; i++) begin
      host.mem_rd_nb(BAR2 + 64'(1024 * i + 8), 300, r);
      rq.push_back(r);
    end
    for (int i = 0; i < rq.size(); i++) begin
      r = rq[i];
      while (!r.done) @(negedge clk);
      for (int j = 0; j < r.bytes.size(); j++)
        if (r.bytes[j] !== w2_exp(W2 + 32'(1024 * i + 8 + j))) begin
          fail($sformatf("outstanding read %0d byte %0d", i, j));
          break;
        end
    end
    // A read right behind a write to the same bytes returns the new data.
    for (int i = 0; i < 20; i++) begin
      off = 8192 + 64 * i + (i % 4);
      w2_write(off, rnd_bytes(16 + i));
      w2_check_read(off, 16 + i, "read after write");
    end
    // Zero-length read: one completion, Byte Count 1.
    begin
      dwq_t none;
      host_req zr = new();
      bit [7:0] tag;
      host.get_tag(tag);
      zr.tag = tag; zr.nbytes = 1; zr.exp_la = 7'h10;   // Lower Address bits 1:0 are 0
      host.outq[tag] = zr;
      host.send(enc_mem(1'b0, BAR2 + 64'h10, 1, 4'h0, 4'h0, host.rc_id, tag, none));
      while (!zr.done) @(negedge clk);
      if (zr.status != SC || zr.ncpl != 1) fail("zero-length read");
    end
    // BAR0 0x0000-0x1FFF: the register port, one DW per clock; writes and
    // reads of up to 2 DWs. A longer write is dropped with UR, a longer read
    // gets CA.
    w2_write(0, rnd_bytes(4));   // keep the BAR2 shadow in use
    b = rnd_bytes(16);
    host.mem_wr(BAR0 + 64'h104, b[0:7]);
    host.mem_wr(BAR0 + 64'h10C, b[8:15]);
    host.mem_wr(BAR0 + 64'h201, le_bytes(64'h00C0_FFEE, 3));
    host.mem_wr(BAR0 + 64'h1FFC, le_bytes(64'h1357_9BDF, 4));
    host.mem_wr(BAR0 + 64'h300, rnd_bytes(12));
    begin
      byteq_t   rb;
      bit [2:0] st;
      bit [31:0] d80, dc0;
      int       w0 = rp_writes, ur0 = c_ur;
      d80 = rp_mem[11'h80];
      dc0 = rp_mem[11'hC0];
      wait_idle();
      if (rp_writes - w0 != 6) fail($sformatf("%0d register-port writes, expected 6", rp_writes - w0));
      if (c_ur - ur0 != 1) fail("a 3-DW write to BAR0 is dropped with UR");
      if (rp_mem[11'hC0] !== dc0) fail("a 3-DW write to BAR0 reached the register port");
      for (int i = 0; i < 16; i++) if (rp_mem[11'h41 + 11'(i / 4)][8*(i%4) +: 8] !== b[i]) begin
        fail($sformatf("BAR0 write: byte %0d", i));
        break;
      end
      if (rp_mem[11'h80][31:8] !== 24'hC0_FFEE || rp_mem[11'h80][7:0] !== d80[7:0])
        fail($sformatf("BAR0 partial write: %h", rp_mem[11'h80]));
      host.mem_rd(BAR0 + 64'h108, 8, rb, st);
      if (st != SC || !same(rb, b[4:11])) fail("BAR0 read of 2 DWs");
      host.mem_rd(BAR0 + 64'h10A, 2, rb, st);
      if (st != SC || !same(rb, b[6:7])) fail("BAR0 read of 2 bytes");
      host.mem_rd(BAR0 + 64'h1FFC, 4, rb, st);
      if (st != SC || !same(rb, le_bytes(64'h1357_9BDF, 4))) fail("BAR0 read of the last DW");
      host.mem_rd(BAR0 + 64'h104, 12, rb, st);
      if (st != CA) fail($sformatf("BAR0 read of 3 DWs: status %0d, expected CA", st));
    end
    wait_idle();
  endtask

  // Requests the endpoint refuses, malformed and poisoned TLPs, AXI errors.
  task automatic t_errors();
    byteq_t   b;
    bit [2:0] st;
    bit [31:0] d;
    dwq_t     none, q;
    int       ur0, mal0, n0;
    host_req  r;
    bit [7:0] tag;

    // Memory read outside the BARs: UR completion; write: dropped.
    ur0 = c_ur;
    host.mem_rd(64'h0000_0000_D000_0000, 8, b, st);
    if (st != UR) fail("read outside the BARs gets UR");
    host.mem_wr(64'h0000_0000_D000_0000, rnd_bytes(8));
    wait_idle();
    if (c_ur != ur0 + 2) fail($sformatf("UR count %0d, expected %0d", c_ur - ur0, 2));
    expect_cfg(10'd18, 32'h0008_0000, 32'h0008_0000, "Unsupported Request Detected");
    cfgwr(10'd18, 32'h000F_0000, 4'hC);    // clear the Device Status bits
    expect_cfg(10'd18, 32'h000F_0000, 32'h0000_0000, "Device Status cleared");

    // Memory Space Enable clear: UR.
    cfgwr(10'd1, 32'h0000_0004, 4'h1);
    host.mem_rd(BAR2 + 64'h40, 4, b, st);
    if (st != UR) fail("read with Memory Space Enable clear gets UR");
    cfgwr(10'd1, 32'h0000_0006, 4'h1);

    // I/O read, type 1 configuration read, configuration read of function 1,
    // locked read: UR completions.
    for (int k = 0; k < 4; k++) begin
      r = new();
      host.get_tag(tag);
      r.tag = tag; r.cfg = 1'b1; r.nbytes = 4;
      host.outq[tag] = r;
      case (k)
        0: begin q = enc_cfg(1'b0, host.rc_id, tag, 16'h0100, 10'd0, 4'hF, 32'd0); q[0][28:24] = 5'b00010; end
        1: q = enc_cfg(1'b0, host.rc_id, tag, 16'h0100, 10'd0, 4'hF, 32'd0, 1'b1);
        2: q = enc_cfg(1'b0, host.rc_id, tag, 16'h0101, 10'd0, 4'hF, 32'd0);
        default: begin q = enc_cfg(1'b0, host.rc_id, tag, 16'h0100, 10'd0, 4'hF, 32'd0); q[0][28:24] = 5'b00001; end
      endcase
      host.send(q);
      while (!r.done) @(negedge clk);
      if (r.status != UR) fail($sformatf("unsupported request %0d gets UR, got %0d", k, r.status));
    end

    // A message is dropped without an error.
    ur0 = c_ur; mal0 = c_mal;
    q.delete();
    q.push_back(mk_dw0(3'b001, 5'b10100, 0)); q.push_back({host.rc_id, 8'd0, 8'h7F});
    q.push_back(32'd0); q.push_back(32'd0);
    host.send(q);
    wait_idle();
    if (c_ur != ur0 || c_mal != mal0) fail("a message counted as an error");

    // Malformed TLPs: removed whole, counted, and the next request works.
    mal0 = c_mal;
    n0   = 0;
    // MWr longer than the largest payload accepted (64 DWs)
    q = enc_mem(1'b1, BAR2 + 64'h100, 65, 4'hF, 4'hF, host.rc_id, 8'd0, dws(65, 32'hBAD0_0000));
    host.send(q); n0++;
    // MRd across 4 KiB
    q = enc_mem(1'b0, BAR2 + 64'hFF8, 4, 4'hF, 4'hF, host.rc_id, 8'd0, none);
    host.send(q); n0++;
    // MWr with an empty First BE and Length 2
    q = enc_mem(1'b1, BAR2 + 64'h100, 2, 4'h0, 4'hF, host.rc_id, 8'd0, dws(2, 32'hBAD1));
    host.send(q); n0++;
    // Length says 2 DWs, 3 sent
    q = enc_mem(1'b1, BAR2 + 64'h100, 2, 4'hF, 4'hF, host.rc_id, 8'd0, dws(2, 32'hBAD1));
    q.push_back(32'hBAD3);
    host.send(q); n0++;
    // TD = 1
    q = enc_mem(1'b1, BAR2 + 64'h100, 1, 4'hF, 4'h0, host.rc_id, 8'd0, dws(1, 32'hBAD4));
    q[0][15] = 1'b1;
    q.push_back(32'h0);
    host.send(q); n0++;
    // First beat without sop
    host.send(enc_mem(1'b1, BAR2 + 64'h100, 2, 4'hF, 4'hF, host.rc_id, 8'd0, dws(2, 32'hBAD5)), 1'b1); n0++;
    // sop again on the second beat: ends this TLP and the one it starts
    host.send(enc_mem(1'b1, BAR2 + 64'h100, 4, 4'hF, 4'hF, host.rc_id, 8'd0, dws(4, 32'hBAD7)), 1'b0, 1'b1); n0++;
    // Configuration read of two DWs
    q = enc_cfg(1'b0, host.rc_id, 8'd0, 16'h0100, 10'd0, 4'hF, 32'd0);
    q[0][9:0] = 10'd2;
    host.send(q); n0++;
    wait_idle();
    if (c_mal - mal0 < n0) fail($sformatf("%0d malformed TLPs counted, %0d sent", c_mal - mal0, n0));
    expect_cfg(10'd18, 32'h0004_0000, 32'h0004_0000, "Fatal Error Detected");
    w2_check_read(32'h100, 16, "memory after malformed writes");

    // Poisoned MWr: dropped; poisoned configuration write: UR, no effect.
    n0 = c_poi;
    host.mem_wr(BAR2 + 64'h200, rnd_bytes(12), 1'b1);
    wait_idle();
    if (c_poi != n0 + 1) fail("poisoned write counted");
    w2_check_read(32'h200, 12, "memory after a poisoned write");
    expect_cfg(10'd1, 32'h8000_0000, 32'h8000_0000, "Detected Parity Error");
    host.cfg_wr(10'd15, 32'h0000_00AA, 4'h1, st, 1'b1);
    if (st != UR) fail("poisoned configuration write gets UR");
    expect_cfg(10'd15, 32'h0000_00FF, 32'h0000_0000, "poisoned write had no effect");

    // Discarded by the link layer: no effect, no error.
    n0 = c_disc; mal0 = c_mal;
    host.send(enc_mem(1'b1, BAR2 + 64'h300, 2, 4'hF, 4'hF, host.rc_id, 8'd0, dws(2, 32'hBAD8)), 1'b0, 1'b0, 1'b1);
    wait_idle();
    if (c_disc != n0 + 1 || c_mal != mal0) fail("discarded TLP");
    w2_check_read(32'h300, 8, "memory after a discarded write");

    // AXI read error inside a long read: data up to the bad burst, then one
    // CA completion with the remaining Byte Count.
    mem.rd_err.push_back(rng(W2 + 32'h1180, W2 + 32'h1188));
    r = null;
    host.mem_rd_nb(BAR2 + 64'h1000, 600, r);
    while (!r.done) @(negedge clk);
    if (r.status != CA || r.got != 384) fail($sformatf("read with an AXI error: status %0d after %0d bytes", r.status, r.got));
    expect_cfg(10'd1, 32'h0800_0000, 32'h0800_0000, "Signaled Target Abort");
    mem.rd_err.delete();
    // AXI write error: the write is lost and reported.
    n0 = c_axi;
    mem.wr_err.push_back(rng(W2 + 32'h1400, W2 + 32'h1408));
    host.mem_wr(BAR2 + 64'h1400, rnd_bytes(8));
    wait_idle();
    mem.wr_err.delete();
    if (c_axi != n0 + 1) fail("AXI write error reported");

    // MSI-X structure read wider than 8 bytes: CA.
    host.mem_rd(BAR0 + 64'h2000, 16, b, st);
    if (st != CA) fail("16-byte read of the MSI-X table gets CA");
    // Clear the status bits the test set.
    cfgwr(10'd1, 32'hF900_0000, 4'hC);
    cfgwr(10'd18, 32'h000F_0000, 4'hC);
    expect_cfg(10'd1, 32'hF900_0000, 32'h0000_0000, "Status cleared");
    wait_idle();
  endtask

  // MSI-X: delivery, vector mask and PBA, function mask, disabled.
  task automatic t_msix();
    byteq_t   b;
    bit [2:0] st;
    bit [31:0] d;
    int        n0;
    host.msis.delete();
    for (int v = 0; v < 8; v++) begin
      @(negedge clk); msix_vec = 3'(v); msix_req = 1'b1;
      @(negedge clk); msix_req = 1'b0;
    end
    wait_idle();
    if (host.msis.size() != 8) fail($sformatf("%0d MSI-X messages, expected 8", host.msis.size()));
    foreach (host.msis[i])
      if (host.msis[i].addr != MSI + 64'(16 * i) || host.msis[i].data != 32'h1000 + 32'(i))
        fail($sformatf("MSI-X message %0d: %h %h", i, host.msis[i].addr, host.msis[i].data));
    // Vector 3 masked: pending in the PBA, sent when unmasked.
    host.msis.delete();
    host.mem_wr(BAR0 + 64'h2000 + 64'h3C, le_bytes(64'h1, 4));
    wait_idle();
    @(negedge clk); msix_vec = 3'd3; msix_req = 1'b1;
    @(negedge clk); msix_req = 1'b0;
    wait_idle();
    host.mem_rd(BAR0 + 64'h3000, 8, b, st);
    if (st != SC || b[0] != 8'h08 || host.msis.size() != 0)
      fail($sformatf("masked vector pending in the PBA: status %0d, PBA %h, %0d messages", st, b[0], host.msis.size()));
    host.mem_wr(BAR0 + 64'h2000 + 64'h3C, le_bytes(64'h0, 4));
    wait_idle();
    if (host.msis.size() != 1 || host.msis[0].data != 32'h1003) fail("pending vector sent on unmask");
    host.mem_rd(BAR0 + 64'h3000, 4, b, st);
    if (b[0] != 8'h00) fail("PBA bit cleared after sending");
    // Function mask
    host.msis.delete();
    cfgrd(10'd32, d);
    cfgwr(10'd32, {1'b1, 1'b1, d[29:0]}, 4'h8);
    @(negedge clk); msix_vec = 3'd5; msix_req = 1'b1;
    @(negedge clk); msix_req = 1'b0;
    wait_idle();
    if (host.msis.size() != 0 || st_msix_pend != 8'h20) fail("function mask holds the vector pending");
    cfgwr(10'd32, {1'b1, 1'b0, d[29:0]}, 4'h8);
    wait_idle();
    if (host.msis.size() != 1 || host.msis[0].data != 32'h1005) fail("sent on function unmask");
    // A table entry written and read as one QW.
    host.mem_wr(BAR0 + 64'h2000 + 64'h70, le_bytes(64'h0000_0000_FEE0_0040, 8));
    host.mem_rd(BAR0 + 64'h2000 + 64'h70, 8, b, st);
    if (st != SC || !same(b, le_bytes(64'h0000_0000_FEE0_0040, 8))) fail("QW access to the table");
    host.mem_wr(BAR0 + 64'h2000 + 64'h70, le_bytes(MSI + 64'h70, 4));
    // Disabled: dropped.
    n0 = c_mxdrop;
    host.msis.delete();
    cfgwr(10'd32, {1'b0, 1'b0, d[29:0]}, 4'h8);
    @(negedge clk); msix_vec = 3'd1; msix_req = 1'b1;
    @(negedge clk); msix_req = 1'b0;
    wait_idle();
    if (host.msis.size() != 0 || c_mxdrop != n0 + 1) fail("request while MSI-X is disabled");
    cfgwr(10'd32, {1'b1, 1'b0, d[29:0]}, 4'h8);
    wait_idle();
  endtask

  // Bus master: lengths, alignments, 4 KiB crossings, both directions.
  int bm_bytes_h2d, bm_cyc_h2d, bm_bytes_d2h, bm_cyc_d2h;
  task automatic t_bm();
    bit [2:0] cause;
    int       cyc;
    int       lens[14] = '{1, 2, 3, 15, 16, 31, 32, 33, 64, 65, 255, 256, 1024, 2048};
    for (int k = 0; k < 14; k++) begin
      for (int a = 0; a < 4; a++) begin
        bit [63:0] hs, hd;
        bit [31:0] l;
        hs = ((a % 2 == 1) ? 64'h0000_0001_2000_0000 : 64'h0000_0000_3000_0000) + 64'(4096 * k + 4 * a + ((a == 3) ? 3072 : 0));
        hd = ((a % 2 == 1) ? 64'h0000_0002_5000_0000 : 64'h0000_0000_5000_0000) + 64'(4096 * k + 8 * a);
        l  = 32'h1000_0000 + 32'(4 * (a == 2 ? 1 : 0)) + ((a == 3) ? 32'h0000_0F00 : 32'h0);
        sample_bm(1'b0, hs, l, lens[k]);
        bm_xfer(1'b0, hs, l, lens[k], cause, cyc);
        if (cause != 0) fail($sformatf("H2D of %0d DWs ended with cause %0d", lens[k], cause));
        cmp_h2d(hs, l, lens[k], $sformatf("H2D %0d DWs case %0d", lens[k], a));
        if (lens[k] == 2048 && a == 0) begin bm_bytes_h2d = 8192; bm_cyc_h2d = cyc; end
        sample_bm(1'b1, hd, l, lens[k]);
        bm_xfer(1'b1, hd, l, lens[k], cause, cyc);
        wait_idle();
        if (cause != 0) fail($sformatf("D2H of %0d DWs ended with cause %0d", lens[k], cause));
        cmp_d2h(hd, l, lens[k], $sformatf("D2H %0d DWs case %0d", lens[k], a));
        if (lens[k] == 2048 && a == 0) begin bm_bytes_d2h = 8192; bm_cyc_d2h = cyc; end
      end
    end
    wait_idle();
    // Both requesters at once: the NVMe port asks one clock after a START,
    // when the START is waiting too, so the arbiter picks between them. In
    // odd rounds an NVMe transfer runs alone first, so the HOST-register
    // request must win; in even rounds the NVMe request must.
    for (int k = 0; k < 8; k++) begin
      bit [2:0] c1, c2;
      bit [63:0] h1, h2;
      bit [31:0] l1, l2;
      int alt0;
      h1 = 64'h0000_0000_3008_0000 + 64'(4096 * k);
      h2 = 64'h0000_0004_0000_0000 + 64'(4096 * k);
      l1 = 32'h1000_4000 + 32'(256 * k);
      l2 = 32'h1001_0000 + 32'(256 * k);
      if (k % 2 == 1) begin
        nv_xfer(1'b0, h2 + 64'h800, l2 + 32'h80, 4, c2);
        if (c2 != 0) fail($sformatf("NVMe-port transfer alone %0d: cause %0d", k, c2));
        cmp_h2d(h2 + 64'h800, l2 + 32'h80, 4, $sformatf("NVMe-port transfer alone %0d", k));
      end
      alt0 = nv_alt;
      fork
        bm_xfer(1'b0, h1, l1, 16 + k, c1, cyc);
        begin @(negedge clk); nv_xfer(1'b0, h2, l2, 16 + k, c2); end
      join
      if (c1 != 0 || c2 != 0) fail($sformatf("requests at once %0d: causes %0d and %0d", k, c1, c2));
      cmp_h2d(h1, l1, 16 + k, $sformatf("requests at once %0d, HOST registers", k));
      cmp_h2d(h2, l2, 16 + k, $sformatf("requests at once %0d, NVMe port", k));
      if (nv_alt != alt0 + 1) fail($sformatf("requests at once %0d: both did not wait", k));
    end
    wait_idle();
  endtask

  // Bus-master errors: each cause once, then a good request.
  task automatic t_bm_err();
    bit [2:0] cause;
    int       cyc, n0;
    bit [63:0] hs = 64'h0000_0000_3100_0000;
    // Bus Master Enable clear
    cfgwr(10'd1, 32'h0000_0002, 4'h1);
    bm_xfer(1'b0, hs, 32'h1000_0000, 64, cause, cyc);
    if (cause != 3'd1) fail($sformatf("BME clear: cause %0d", cause));
    cfgwr(10'd1, 32'h0000_0006, 4'h1);
    // Completion faults injected by the host, one kind at a time.
    for (int k = 0; k < 4; k++) begin
      host.inj_ur = (k == 0) ? 100 : 0;
      host.inj_ca = (k == 1) ? 100 : 0;
      host.inj_ep = (k == 2) ? 100 : 0;
      host.inj_bc = (k == 3) ? 100 : 0;
      bm_xfer(1'b0, hs, 32'h1000_0000, 300, cause, cyc);
      if (cause != ((k == 0) ? 3'd3 : (k == 1) ? 3'd4 : 3'd6)) fail($sformatf("fault %0d: cause %0d", k, cause));
      host.inj_ur = 0; host.inj_ca = 0; host.inj_ep = 0; host.inj_bc = 0;
      wait_idle();
    end
    // Completion timeout, then the late completions are dropped as
    // unexpected and the tags come back after the quarantine.
    n0 = c_unexp;
    cto_ticks = 8'd4;
    host.lat_min = 600; host.lat_max = 700;
    bm_xfer(1'b0, hs, 32'h1000_0000, 64, cause, cyc);
    if (cause != 3'd5) fail($sformatf("timeout: cause %0d", cause));
    host.lat_min = 4; host.lat_max = 60;
    wait_idle();
    clocks(600);
    if (c_unexp == n0) fail("late completions counted as unexpected");
    cto_ticks = 8'd64;
    // Unexpected completions alongside a good request: no error for it.
    n0 = c_unexp;
    host.inj_unexp = 100;
    bm_xfer(1'b0, hs, 32'h1000_0000, 300, cause, cyc);
    host.inj_unexp = 0;
    wait_idle();
    if (cause != 0 || c_unexp == n0) fail("unexpected completions with a good request");
    cmp_h2d(hs, 32'h1000_0000, 300, "H2D next to unexpected completions");
    // Local AXI errors
    mem.wr_err.push_back(rng(32'h1000_0100, 32'h1000_0108));
    bm_xfer(1'b0, hs, 32'h1000_0000, 300, cause, cyc);
    if (cause != 3'd2) fail($sformatf("local write error: cause %0d", cause));
    mem.wr_err.delete();
    mem.rd_err.push_back(rng(32'h1000_0200, 32'h1000_0208));
    n0 = host.n_dev_mwr;
    bm_xfer(1'b1, 64'h0000_0000_5100_0000, 32'h1000_0000, 512, cause, cyc);
    if (cause != 3'd2) fail($sformatf("local read error: cause %0d", cause));
    mem.rd_err.delete();
    wait_idle();
    if (host.n_dev_mwr - n0 >= 512 / 64) fail("MWr sent for a chunk with a read error");
    // And a good one after all of it.
    bm_xfer(1'b0, hs, 32'h1000_0000, 1000, cause, cyc);
    if (cause != 0) fail("good request after the errors");
    cmp_h2d(hs, 32'h1000_0000, 1000, "H2D after the errors");
    cfgwr(10'd1, 32'hF900_0000, 4'hC);
    cfgwr(10'd18, 32'h000F_0000, 4'hC);
    wait_idle();
  endtask

  // Everything at once: inbound traffic, bus-master requests, MSI-X.
  int rnd_ops, rnd_bm, rnd_msix_sent;
  task automatic t_random(int nops);
    bit done_tgt, done_bm, done_nv;
    int msix_exp;
    host.msis.delete();
    msix_exp = 0;
    done_tgt = 1'b0;
    done_bm  = 1'b0;
    mem.set_speed(60, 10, 20);
    host.rx_gap_pct = 20; host.tx_ready_pct = 70;
    fork
      // Inbound traffic into the BAR2 window; reads never overlap a later write.
      begin
        host_req  rq[$];
        int       ro[$], rn[$];
        int       off, n, maxw;
        bit       clash;
        maxw = host.dev_mps;
        for (int i = 0; i < nops; i++) begin
          // A host does not queue unbounded traffic ahead of its completions.
          while (host.sendq.size() > 4) @(negedge clk);
          if ($urandom_range(99) < 50) begin
            // At most Max_Payload_Size bytes in whole DWs, inside 4 KiB.
            off = $urandom_range(32767 - maxw, 0);
            n   = $urandom_range(maxw - (off % 4), 1);
            if ($urandom_range(3) == 0) n = $urandom_range(8, 1);
            if ((off % 4096) + n > 4096) off = off - (off % 4096) + 4096 - n;
            // wait while a read of these bytes is outstanding
            do begin
              clash = 1'b0;
              foreach (rq[j]) if (!rq[j].done && off < ro[j] + rn[j] && ro[j] < off + n) clash = 1'b1;
              if (clash) @(negedge clk);
            end while (clash);
            cv_sz = n; cv_off = off % 8; cov_wr.sample();
            w2_write(off, rnd_bytes(n));
          end else begin
            host_req r;
            n   = ($urandom_range(3) == 0) ? $urandom_range(4096, 1) : $urandom_range(260, 1);
            off = $urandom_range(32767 - n, 0);
            if ((off % 4096) + n > 4096) off = off - (off % 4096) + 4096 - n;
            cv_sz = n; cv_off = off % 8; cov_rd.sample();
            host.mem_rd_nb(BAR2 + 64'(off), n, r);
            // expected data now: no later write touches these bytes until done
            begin
              byteq_t e;
              for (int j = 0; j < n; j++) e.push_back(w2_exp(W2 + 32'(off + j)));
              rq.push_back(r); ro.push_back(off); rn.push_back(n);
              fork
                begin
                  host_req rr = r;
                  byteq_t  ee = e;
                  int      o2 = off;
                  while (!rr.done) @(negedge clk);
                  cv_split = rr.ncpl; cov_split.sample();
                  if (rr.status != SC) fail($sformatf("random read +%h status %0d", o2, rr.status));
                  else if (rr.bytes != ee) fail($sformatf("random read +%h, %0d bytes: data", o2, ee.size()));
                end
              join_none
            end
            while (host.outq.size() >= 16) @(negedge clk);
          end
          // forget finished reads
          while (rq.size() > 0 && rq[0].done) begin
            void'(rq.pop_front()); void'(ro.pop_front()); void'(rn.pop_front());
          end
          rnd_ops++;
          if ($urandom_range(9) == 0) clocks($urandom_range(20, 1));
        end
        done_tgt = 1'b1;
      end
      // Bus-master requests, checked one by one
      begin
        bit [2:0] cause;
        int       cyc, len;
        bit [63:0] ha;
        bit [31:0] la;
        for (int i = 0; i < nops / 30 + 4; i++) begin
          bit d2h = 1'($urandom_range(1));
          len = ($urandom_range(3) == 0) ? $urandom_range(2048, 1) : $urandom_range(300, 1);
          ha  = (($urandom_range(1) == 1) ? 64'h0000_0001_2000_0000 : 64'h0000_0000_3000_0000) + 64'(4 * $urandom_range(8191, 0));
          if (d2h) ha = ha + 64'h2000_0000;
          la  = 32'h1000_0000 + 32'(4 * $urandom_range(8191 - len, 0));
          sample_bm(d2h, ha, la, len);
          bm_xfer(d2h, ha, la, len, cause, cyc);
          if (cause != 0) fail($sformatf("random bus-master request %0d: cause %0d", i, cause));
          else if (d2h) begin
            // D2H data is written posted; wait for the host to see it all.
            int w = 0;
            // The last MWr was handed to the packer; let it reach the host.
            while (w < 40) begin @(negedge clk); w++; end
            while (tif.tx_valid) @(negedge clk);
            cmp_d2h(ha, la, len, $sformatf("random D2H %0d", i));
          end else begin
            cmp_h2d(ha, la, len, $sformatf("random H2D %0d", i));
          end
          if ($urandom_range(3) == 0) begin
            @(negedge clk); msix_vec = 3'($urandom_range(7)); msix_req = 1'b1;
            @(negedge clk); msix_req = 1'b0;
            msix_exp++;
          end
          rnd_bm++;
        end
        done_bm = 1'b1;
      end
      // NVMe-port requests, in their own address ranges, checked one by one
      begin
        bit [2:0] cause;
        int       len;
        bit [63:0] ha;
        bit [31:0] la;
        while (!done_bm) begin
          bit d2h = 1'($urandom_range(1));
          len = ($urandom_range(3) == 0) ? $urandom_range(1024, 1) : $urandom_range(64, 1);
          ha  = 64'h0000_0004_0000_0000 + 64'(4 * $urandom_range(65535, 0));
          if (d2h) ha = ha + 64'h4000_0000;
          la  = 32'h1001_0000 + 32'(4 * $urandom_range(8191 - len, 0));
          nv_xfer(d2h, ha, la, len, cause);
          if (cause != 0) fail($sformatf("NVMe-port request: cause %0d", cause));
          else if (d2h) begin
            int w = 0;
            while (w < 40) begin @(negedge clk); w++; end
            while (tif.tx_valid) @(negedge clk);
            cmp_d2h(ha, la, len, "NVMe-port D2H");
          end else begin
            cmp_h2d(ha, la, len, "NVMe-port H2D");
          end
          if ($urandom_range(3) == 0) clocks($urandom_range(30, 1));
        end
        done_nv = 1'b1;
      end
    join
    wait_idle();
    if (host.msis.size() != msix_exp) fail($sformatf("%0d MSI-X messages, expected %0d", host.msis.size(), msix_exp));
    rnd_msix_sent = host.msis.size();
    // Whole BAR2 window against the shadow.
    for (int i = 0; i < 32768; i++) begin
      if (mem.get(W2 + 32'(i)) !== w2_exp(W2 + 32'(i))) begin
        fail($sformatf("window byte +%h is %h, expected %h", i, mem.get(W2 + 32'(i)), w2_exp(W2 + 32'(i))));
        break;
      end
    end
    mem.set_speed(70, 6, 20);
    host.rx_gap_pct = 10; host.tx_ready_pct = 85;
  endtask

  // ---------------------------------------------------------------------------
  // Throughput and latency with nothing else in the way: the host sends
  // without idle clocks, takes every TX beat, answers reads after 2 clocks in
  // completions of up to 256 bytes, and the memory model is always ready with
  // no latency. Numbers are clk_sys clocks; 8 bytes per clock is the width of
  // both the TLP streams and AXI.
  // ---------------------------------------------------------------------------
  task automatic t_perf();
    longint   t0;
    int       c;
    host_req  rq[$];
    host_req  r;
    bit [2:0] cause;
    host.rx_gap_pct = 0;   host.tx_ready_pct = 100;
    host.lat_min = 2;      host.lat_max = 2;
    host.cpl_mps = 256;    host.merge_pct = 100;
    mem.set_speed(100, 0, 0);
    mem.b_lat_min = 0; mem.r_lat_min = 0;
    wait_idle();
    // Inbound writes: 128 MWr of 256 bytes into BAR2.
    t0 = $time;
    for (int i = 0; i < 128; i++) w2_write(256 * i, rnd_bytes(256));
    wait_idle();
    c = int'(($time - t0) / CLK) - 4;
    $display("[TL] perf inbound MWr: 32768 bytes in 128 TLPs of 256 bytes: %0d clocks, %0.2f B/clk", c, 32768.0 / c);
    // One DW read and one 4 KiB read, alone: time to the last completion.
    t0 = $time;
    host.mem_rd_nb(BAR2 + 64'h40, 4, r);
    while (!r.done) @(negedge clk);
    $display("[TL] perf inbound MRd of 1 DW: %0d clocks from the request's first beat to the completion's last",
             int'(($time - t0) / CLK));
    t0 = $time;
    host.mem_rd_nb(BAR2 + 64'h1000, 4096, r);
    while (!r.done) @(negedge clk);
    $display("[TL] perf inbound MRd of 4096 bytes: %0d clocks to the last completion (%0d completions)",
             int'(($time - t0) / CLK), r.ncpl);
    // Inbound reads, 8 of 4 KiB outstanding.
    wait_idle();
    t0 = $time;
    for (int i = 0; i < 8; i++) begin
      host.mem_rd_nb(BAR2 + 64'(4096 * i), 4096, r);
      rq.push_back(r);
    end
    foreach (rq[i]) while (!rq[i].done) @(negedge clk);
    c = int'(($time - t0) / CLK);
    $display("[TL] perf inbound MRd: 8 reads of 4096 bytes outstanding: %0d clocks, %0.2f B/clk", c, 32768.0 / c);
    // Bus master, 64 KiB each way.
    wait_idle();
    bm_xfer(1'b0, 64'h0000_0000_3000_0000, 32'h1000_0000, 16384, cause, c);
    if (cause != 0) fail("perf H2D");
    $display("[TL] perf bus master host to SoC, 65536 bytes, MRRS %0d: %0d clocks, %0.2f B/clk",
             host.dev_mrrs, c, 65536.0 / c);
    bm_xfer(1'b1, 64'h0000_0000_5000_0000, 32'h1000_0000, 16384, cause, c);
    if (cause != 0) fail("perf D2H");
    wait_idle();
    $display("[TL] perf bus master SoC to host, 65536 bytes, MPS %0d: %0d clocks, %0.2f B/clk",
             host.dev_mps, c, 65536.0 / c);
    cmp_d2h(64'h0000_0000_5000_0000, 32'h1000_0000, 16384, "perf D2H");
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test;
  int    nops;
  initial begin
    if (!$value$plusargs("test=%s", test)) test = "all";
    if (!$value$plusargs("n=%d", nops)) nops = 3000;
    host = new(tif);
    host.clk_period = CLK;
    mem = new(axi);
    mem.clk_period = CLK;
    mem.narrow_ok  = 1'b1;
    host.run();
    mem.run();
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    case (test)
      "enum":    t_enum();
      "target":  begin t_enum(); t_target(); end
      "errors":  begin t_enum(); t_errors(); end
      "msix":    begin t_enum(); t_msix(); end
      "bm":      begin t_enum(); t_bm(); end
      "bm_err":  begin t_enum(); t_bm_err(); end
      "random":  begin t_enum(1'($urandom_range(1)), 3'($urandom_range(5))); t_random(nops); end
      "perf":    begin t_enum(1'b1, 3'd2); t_perf(); end
      default: begin
        t_enum(); t_target(); t_errors(); t_msix(); t_bm(); t_bm_err();
        t_random(nops);
      end
    endcase
    wait_idle();

    errors += host.errors + mem.errors;
    $display("[TL] test %s: host sent %0d TLPs and received %0d; device MRd %0d (%0d bytes), MWr %0d, MSI-X %0d",
             test, host.n_sent, host.n_recv, host.n_dev_mrd, host.dev_rd_bytes, host.n_dev_mwr, host.n_msi);
    $display("[TL] completions sent by the host %0d (%0d split), faults injected %0d, unexpected %0d; most host reads outstanding %0d",
             host.n_cpl_sent, host.n_split, host.n_faults, host.n_unexp_inj, host.max_out);
    $display("[TL] events: UR %0d, malformed %0d, poisoned %0d, unexpected %0d, timeout %0d, completion error %0d, AXI %0d, discarded %0d",
             c_ur, c_mal, c_poi, c_unexp, c_to, c_cerr, c_axi, c_disc);
    if (bm_cyc_h2d > 0)
      $display("[TL] bus master 8 KiB: host to SoC %0d clocks (%0.2f B/clk), SoC to host %0d clocks (%0.2f B/clk)",
               bm_cyc_h2d, real'(bm_bytes_h2d) / bm_cyc_h2d, bm_cyc_d2h, real'(bm_bytes_d2h) / bm_cyc_d2h);
    if (rnd_ops > 0)
      $display("[TL] random: %0d inbound operations, %0d bus-master requests, %0d NVMe-port requests (%0d clocks both waiting, %0d grants with both waiting), %0d MSI-X",
               rnd_ops, rnd_bm, nv_xfers, nv_contend, nv_alt, rnd_msix_sent);
    if (errors == 0) $display("[TL] PASS");
    else             $display("[TL] FAIL: %0d errors", errors);
    if (errors != 0) $fatal(1, "tb_tl failed");
    $finish;
  end

  initial begin
    #(64'd400_000_000);
    $display("[TL] FAIL: timeout");
    $fatal(1, "tb_tl timeout");
  end

endmodule
