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
  axi4_if axi (.clk(clk), .rst_n(rst_n));
  axi4_checker #(.KIND("M"), .IDX(3)) u_chk (.a(axi));

  // ---------------------------------------------------------------------------
  // DUT: transaction layer and NVMe controller
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

  logic        psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
  logic [11:0] paddr = '0;
  logic [31:0] pwdata = '0;
  wire  [31:0] prdata;
  wire         pready, pslverr;

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
    .msix_req (1'b0), .msix_vec (3'd0),
    .st_mse (), .st_bme (), .st_msix_en (), .st_msix_fmask (), .st_mps256 (), .st_mrrs (),
    .st_id (), .st_msix_pend (),
    .ev_ur (), .ev_malformed (), .ev_poisoned (), .ev_unexp_cpl (), .ev_cpl_timeout (),
    .ev_cpl_err (), .ev_axi_err (), .ev_discard (), .ev_msix_drop (), .rx_tlp (), .tx_tlp (),
    .idle ()
  );

  nvme_ctrl u_nv (
    .clk (clk), .rst_n (rst_n),
    .psel (psel), .penable (penable), .paddr (paddr), .pwrite (pwrite), .pwdata (pwdata),
    .pstrb (4'hF), .prdata (prdata), .pready (pready), .pslverr (pslverr),
    .reg_we (rp_we), .reg_dw (rp_dw), .reg_be (rp_be), .reg_wdata (rp_wdata),
    .reg_rd0 (rp_rd0), .reg_rd1 (rp_rd1),
    .bm_valid (nv_valid), .bm_ready (nv_ready), .bm_d2h (nv_d2h), .bm_haddr (nv_haddr),
    .bm_laddr (nv_laddr), .bm_len (nv_len), .bm_done (nv_done), .bm_cause (nv_cause),
    .irq (irq), .idle (nv_idle)
  );

  assign axi.awid    = {2'b00, awid};
  assign axi.arid    = {2'b00, arid};
  assign axi.awprot  = 3'd0;
  assign axi.arprot  = 3'd0;
  assign axi.awcache = 4'd0;
  assign axi.arcache = 4'd0;
  assign axi.awqos   = 4'd0;
  assign axi.arqos   = 4'd0;

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
    int w = 0;
    @(negedge clk);
    psel = 1'b1; penable = 1'b0; pwrite = wr; paddr = a; pwdata = d;
    @(negedge clk);
    penable = 1'b1;
    while (pready !== 1'b1) begin
      @(negedge clk);
      if (++w > 100) $fatal(1, "[NVME] APB hang at %h", a);
    end
    rd = prdata;
    if (pslverr !== exp_err) fail($sformatf("PSLVERR %b at %h, expected %b", pslverr, a, exp_err));
    @(negedge clk);
    psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
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
    if (u_nv.c_st == u_nv.C_RESET && u_nv.f_busy) rst_waited = 1'b1;
    if (u_nv.shst == 2'b01 && u_nv.f_busy) shut_waited = 1'b1;
    if (u_nv.ev_enable) ev(0);
    if (u_nv.ev_reset) begin ev(rst_waited ? 2 : 1); rst_waited = 1'b0; end
    if (u_nv.ev_shut) ev(3);
    if (u_nv.shst == 2'b01 && !u_nv.f_busy && shut_waited) begin ev(4); shut_waited = 1'b0; end
    if (u_nv.db_w && !u_nv.db_ok)
      ev(u_nv.db_cq ? (u_nv.cq_en[u_nv.db_q] ? 8 : 7) : (u_nv.sq_en[u_nv.db_q] ? 6 : 5));
    if (u_nv.ev_fetch_err) ev(9);
    if (u_nv.c_st == u_nv.C_ON && u_nv.any && !u_nv.have_slot && !no_slot_seen) begin
      ev(10);
      no_slot_seen = 1'b1;
    end
    if (u_nv.have_slot) no_slot_seen = 1'b0;
    if (u_nv.free_wr && u_nv.c_st == u_nv.C_RESET) ev(11);
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

  // Shutdown right behind a doorbell, so a fetch is in flight: SHST reads
  // "complete" only once it is done, and nothing is fetched after that.
  task automatic t_shutdown();
    bit [31:0] v, f0;
    int n = 0;
    host_enable(8);
    repeat (7) put_sqe(0);
    ring_sq(0);
    hw32(32'h14, 32'h0046_4001);               // SHN = 01
    do begin
      hr32(32'h1C, v);
      if (++n > 100) begin fail("SHST never reached complete"); break; end
    end while (v[3:2] != 2'b10);
    fw_rd(R_FETCH, f0);
    repeat (300) @(negedge clk);
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
    // Two slots back: two more fetches start; reset right behind them.
    fw_take(got);
    fw_take(got);
    n = 0;
    while (!u_nv.f_busy && n < 300) begin @(negedge clk); n++; end
    if (!u_nv.f_busy) fail("no fetch after two slots were freed");
    host_disable();
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
    host.rx_gap_pct = 10;
    host.tx_ready_pct = 85;
    host.lat_min = 4;
    host.lat_max = 60;
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
    host = new(tif);
    host.clk_period = CLK;
    mem = new(axi);
    mem.clk_period = CLK;
    mem.narrow_ok = 1'b1;
    host.run();
    mem.run();
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);
    enumerate();
    case (test)
      "regs":     t_regs();
      "enable":   t_enable();
      "fetch":    t_fetch();
      "rr":       t_rr();
      "doorbell": t_doorbell();
      "ferr":     t_ferr();
      "shutdown": t_shutdown();
      "reset":    t_reset();
      "perf":     t_perf();
      "random":   t_random(ncmd);
      default: begin
        t_regs();
        t_enable();   host_disable();
        t_fetch();    host_disable();
        t_rr();       host_disable();
        t_doorbell(); host_disable();
        t_ferr();
        t_shutdown();
        t_reset();    host_disable();
        t_random(ncmd);
      end
    endcase
    repeat (100) @(negedge clk);
    errors += host.errors + mem.errors;
    $display("[NVME] test %s: %0d commands submitted, %0d fetched and checked, %0d controller resets (%0d after a shutdown), %0d APB accesses",
             test, n_sub, n_chk, n_resets, n_shut, n_apb);
    $display("[NVME] host sent %0d TLPs, device MRd %0d (%0d bytes)", host.n_sent, host.n_dev_mrd,
             host.dev_rd_bytes);
    if (errors == 0) $display("[NVME] PASS");
    else             $display("[NVME] FAIL: %0d errors", errors);
    if (errors != 0) $fatal(1, "tb_nvme failed");
    $finish;
  end

  initial begin
    #(64'd500_000_000);
    $display("[NVME] FAIL: timeout");
    $fatal(1, "tb_nvme timeout");
  end

endmodule
