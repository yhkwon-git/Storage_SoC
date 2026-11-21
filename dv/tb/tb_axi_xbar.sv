// tb_axi_xbar
//
// axi_xbar with four master models, five memory slave models and an
// axi4_checker on each of the nine ports.
//
//   +test=random    (default) every master sends +n= bursts (default 2000):
//                   reads and writes to every slave it can reach, 8% to
//                   unmapped addresses or slaves it has no path to, random IDs,
//                   1 to 16 beats, random gaps, READY and latencies drawn per seed
//   +test=directed  decode errors, W order with four masters on one slave,
//                   same-ID slave switch, outstanding limit, parallel paths,
//                   round-robin share, throughput
// A watchdog fails the run if no transaction finishes for 20000 clocks.
// Seed: +verilator+seed+N. Prints [XBAR] lines and ends with PASS or $fatal.

`timescale 1ns/1ps

module tb_axi_xbar;
  import axi_tb_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  axi4_if mif [NM] (.clk(clk), .rst_n(rst_n));
  axi4_if sif [NS] (.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------------------
  // DUT
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

  axi_xbar dut (.*);

  for (genvar g = 0; g < NM; g++) begin : g_mport
    assign s_awid[g]    = mif[g].awid[1:0];
    assign s_awaddr[g]  = mif[g].awaddr;
    assign s_awlen[g]   = mif[g].awlen;
    assign s_awsize[g]  = mif[g].awsize;
    assign s_awburst[g] = mif[g].awburst;
    assign s_awprot[g]  = mif[g].awprot;
    assign s_awcache[g] = mif[g].awcache;
    assign s_awqos[g]   = mif[g].awqos;
    assign s_awvalid[g] = mif[g].awvalid;
    assign mif[g].awready = s_awready[g];

    assign s_wdata[g]  = mif[g].wdata;
    assign s_wstrb[g]  = mif[g].wstrb;
    assign s_wlast[g]  = mif[g].wlast;
    assign s_wvalid[g] = mif[g].wvalid;
    assign mif[g].wready = s_wready[g];

    assign mif[g].bid    = {2'b00, s_bid[g]};
    assign mif[g].bresp  = s_bresp[g];
    assign mif[g].bvalid = s_bvalid[g];
    assign s_bready[g]   = mif[g].bready;

    assign s_arid[g]    = mif[g].arid[1:0];
    assign s_araddr[g]  = mif[g].araddr;
    assign s_arlen[g]   = mif[g].arlen;
    assign s_arsize[g]  = mif[g].arsize;
    assign s_arburst[g] = mif[g].arburst;
    assign s_arprot[g]  = mif[g].arprot;
    assign s_arcache[g] = mif[g].arcache;
    assign s_arqos[g]   = mif[g].arqos;
    assign s_arvalid[g] = mif[g].arvalid;
    assign mif[g].arready = s_arready[g];

    assign mif[g].rid    = {2'b00, s_rid[g]};
    assign mif[g].rdata  = s_rdata[g];
    assign mif[g].rresp  = s_rresp[g];
    assign mif[g].rlast  = s_rlast[g];
    assign mif[g].rvalid = s_rvalid[g];
    assign s_rready[g]   = mif[g].rready;

    axi4_checker #(.KIND("M"), .IDX(g)) u_chk (.a(mif[g]));
  end

  for (genvar g = 0; g < NS; g++) begin : g_sport
    assign sif[g].awid    = m_awid[g];
    assign sif[g].awaddr  = m_awaddr[g];
    assign sif[g].awlen   = m_awlen[g];
    assign sif[g].awsize  = m_awsize[g];
    assign sif[g].awburst = m_awburst[g];
    assign sif[g].awprot  = m_awprot[g];
    assign sif[g].awcache = m_awcache[g];
    assign sif[g].awqos   = m_awqos[g];
    assign sif[g].awvalid = m_awvalid[g];
    assign m_awready[g]   = sif[g].awready;

    assign sif[g].wdata  = m_wdata[g];
    assign sif[g].wstrb  = m_wstrb[g];
    assign sif[g].wlast  = m_wlast[g];
    assign sif[g].wvalid = m_wvalid[g];
    assign m_wready[g]   = sif[g].wready;

    assign m_bid[g]      = sif[g].bid;
    assign m_bresp[g]    = sif[g].bresp;
    assign m_bvalid[g]   = sif[g].bvalid;
    assign sif[g].bready = m_bready[g];

    assign sif[g].arid    = m_arid[g];
    assign sif[g].araddr  = m_araddr[g];
    assign sif[g].arlen   = m_arlen[g];
    assign sif[g].arsize  = m_arsize[g];
    assign sif[g].arburst = m_arburst[g];
    assign sif[g].arprot  = m_arprot[g];
    assign sif[g].arcache = m_arcache[g];
    assign sif[g].arqos   = m_arqos[g];
    assign sif[g].arvalid = m_arvalid[g];
    assign m_arready[g]   = sif[g].arready;

    assign m_rid[g]      = sif[g].rid;
    assign m_rdata[g]    = sif[g].rdata;
    assign m_rresp[g]    = sif[g].rresp;
    assign m_rlast[g]    = sif[g].rlast;
    assign m_rvalid[g]   = sif[g].rvalid;
    assign sif[g].rready = m_rready[g];

    axi4_checker #(.KIND("S"), .IDX(g)) u_chk (.a(sif[g]));
  end

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------
  axi_master mst [NM];
  axi_slave  slv [NS];

  for (genvar g = 0; g < NM; g++) begin : g_mmodel
    initial mst[g] = new(mif[g], g);
  end
  for (genvar g = 0; g < NS; g++) begin : g_smodel
    initial slv[g] = new(sif[g], g);
  end

  // ---------------------------------------------------------------------------
  // Functional coverage at the master ports: path (master x target, the 16
  // that exist, DECERR included), burst length, direction.
  // ---------------------------------------------------------------------------
  int cov_path;
  int cov_len;
  bit cov_wr;

  covergroup cg_xbar;
    cp_path: coverpoint cov_path {
      bins m0_rom   = {0};  bins m0_sram  = {1};  bins m0_err   = {5};
      bins m1_rom   = {8};  bins m1_sram  = {9};  bins m1_apb   = {10};
      bins m1_nand0 = {11}; bins m1_nand1 = {12}; bins m1_err   = {13};
      bins m2_sram  = {17}; bins m2_nand0 = {19}; bins m2_nand1 = {20};
      bins m2_err   = {21};
      bins m3_sram  = {25}; bins m3_apb   = {26}; bins m3_err   = {29};
    }
    cp_len: coverpoint cov_len {
      bins one = {0}; bins two_4 = {[1:3]}; bins five_8 = {[4:7]}; bins nine_16 = {[8:15]};
    }
    cp_dir: coverpoint cov_wr;
    x_dir_path: cross cp_dir, cp_path;
    x_dir_len:  cross cp_dir, cp_len;
  endgroup

  cg_xbar cg = new;

  longint aw_id_stall_cyc [NM];
  longint ar_id_stall_cyc [NM];

  always @(posedge clk) begin
    if (rst_n) begin
      for (int m = 0; m < NM; m++) begin
        if (s_awvalid[m] && s_awready[m]) begin
          cov_path = m * 8 + decode(m, s_awaddr[m]);
          cov_len  = int'(s_awlen[m]);
          cov_wr   = 1'b1;
          cg.sample();
        end
        if (s_arvalid[m] && s_arready[m]) begin
          cov_path = m * 8 + decode(m, s_araddr[m]);
          cov_len  = int'(s_arlen[m]);
          cov_wr   = 1'b0;
          cg.sample();
        end
        if (stat_aw_id_stall[m]) aw_id_stall_cyc[m]++;
        if (stat_ar_id_stall[m]) ar_id_stall_cyc[m]++;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Progress watchdog: a hang (for example lost W beats) ends the run with a
  // diagnosis instead of waiting for the global timeout.
  // ---------------------------------------------------------------------------
  int     done_sum;
  int     done_seen      = -1;
  longint last_progress  = 0;
  bit     any_pending;

  always @(posedge clk) begin
    if (rst_n) begin
      done_sum    = 0;
      any_pending = 1'b0;
      for (int m = 0; m < NM; m++) begin
        done_sum += mst[m].n_done;
        if (mst[m].pending() != 0) any_pending = 1'b1;
      end
      if (done_sum != done_seen) begin
        done_seen     = done_sum;
        last_progress = $time;
      end else if (any_pending && ($time - last_progress > 64'd200_000)) begin
        $display("[XBAR] ERROR at %0t: no transaction finished for 20000 clocks", $time);
        for (int m = 0; m < NM; m++) $display("[XBAR]   M%0d pending %0d", m, mst[m].pending());
        $fatal(1, "[XBAR] FAIL: no progress");
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  int tb_errors = 0;

  function automatic void tb_err(string s);
    tb_errors++;
    $display("[XBAR] ERROR at %0t: %s", $time, s);
  endfunction

  function automatic axi_txn mk(int m, bit wr, int s, int id, int len, logic [31:0] a);
    axi_txn t;
    t       = new();
    t.write = wr;
    t.id    = 4'(id);
    t.len   = len;
    t.addr  = a;
    t.tgt   = s;
    if (decode(m, a) != s) begin
      $fatal(1, "[XBAR] testbench: %h from M%0d decodes to %s, not %s",
             a, m, tgt_name(decode(m, a)), tgt_name(s));
    end
    if (wr) begin
      for (int b = 0; b <= len; b++) begin
        t.data.push_back({$urandom(), $urandom()});
        t.strb.push_back(($urandom_range(9) == 0) ? 8'($urandom()) : 8'hFF);
      end
    end
    return t;
  endfunction

  // A burst address in master m's region of slave s that no in-flight burst
  // of m conflicts with. Returns 0 if none was found in 20 tries.
  function automatic bit pick_addr(int m, int s, int len, bit wr, output logic [31:0] a);
    logic [31:0] base;
    int          words;
    base  = region_base(m, s);
    words = int'(region_size(s) / 8);
    a     = base;
    for (int tries = 0; tries < 20; tries++) begin
      a = base + 32'($urandom_range(words - len - 1) * 8);
      if ((a & 32'hFFF) + 32'((len + 1) * 8) > 32'h1000) continue;
      if (mst[m].words_free(a, len, wr)) return 1'b1;
    end
    return 1'b0;
  endfunction

  function automatic logic [31:0] err_addr(int m);
    int forb[$];
    for (int s = 0; s < NS; s++) if (!CONN[m][s]) forb.push_back(s);
    if (forb.size() != 0 && $urandom_range(1) == 1) begin
      return SLV_BASE[forb[$urandom_range(forb.size() - 1)]] + 32'($urandom_range(15) * 8);
    end
    return UNMAPPED[$urandom_range(6)];
  endfunction

  task automatic set_slaves(int rdy, int lat_lo, int lat_hi, int gap, bit reorder);
    for (int s = 0; s < NS; s++) begin
      slv[s].awready_pct = rdy;  slv[s].wready_pct = rdy;  slv[s].arready_pct = rdy;
      slv[s].b_lat_min   = lat_lo; slv[s].b_lat_max = lat_hi;
      slv[s].r_lat_min   = lat_lo; slv[s].r_lat_max = lat_hi;
      slv[s].r_gap_pct   = gap;  slv[s].reorder = reorder;
    end
  endtask

  task automatic set_masters(int gap, int rdy);
    for (int m = 0; m < NM; m++) begin
      mst[m].aw_gap_pct = gap; mst[m].w_gap_pct = gap; mst[m].ar_gap_pct = gap;
      mst[m].bready_pct = rdy; mst[m].rready_pct = rdy;
    end
  endtask

  task automatic wait_all(int limit_clk);
    bit     busy;
    longint t0;
    t0 = $time;
    forever begin
      @(negedge clk);
      busy = 1'b0;
      for (int m = 0; m < NM; m++) if (mst[m].pending() != 0) busy = 1'b1;
      for (int s = 0; s < NS; s++) if (!slv[s].idle()) busy = 1'b1;
      if (!busy) break;
      if ($time - t0 > longint'(limit_clk) * 10) begin
        tb_err("timeout waiting for outstanding transactions");
        for (int m = 0; m < NM; m++) $display("[XBAR]   M%0d pending %0d", m, mst[m].pending());
        break;
      end
    end
    repeat (4) @(negedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Random test
  // ---------------------------------------------------------------------------
  task automatic gen_random(int m, int n);
    axi_txn      t;
    bit          wr;
    int          len, s, id, r;
    int          reach[$];
    logic [31:0] a;
    for (int i = 0; i < NS; i++) if (CONN[m][i]) reach.push_back(i);
    for (int i = 0; i < n; i++) begin
      while (mst[m].pending() >= 8) @(negedge clk);
      wr  = ($urandom_range(1) == 1);
      r   = $urandom_range(99);
      len = (r < 30) ? 0 : (r < 60) ? $urandom_range(3, 1) : (r < 80) ? $urandom_range(7, 4)
                                    : $urandom_range(15, 8);
      id  = $urandom_range(3);
      if ($urandom_range(99) < 8) begin
        t = mk(m, wr, T_ERR, id, len, err_addr(m));
      end else begin
        s = reach[$urandom_range(reach.size() - 1)];
        if (!pick_addr(m, s, len, wr, a)) begin
          @(negedge clk);
          i--;
          continue;
        end
        t = mk(m, wr, s, id, len, a);
      end
      mst[m].send(t);
      if ($urandom_range(3) == 0) @(negedge clk);
    end
  endtask

  task automatic test_random(int n);
    int rdy, lat_hi, gap;
    rdy    = $urandom_range(100, 40);
    lat_hi = $urandom_range(10, 0);
    gap    = $urandom_range(40, 0);
    set_slaves(rdy, 0, lat_hi, gap, 1'b1);
    for (int s = 0; s < NS; s++) begin
      slv[s].awready_pct = $urandom_range(100, 40);
      slv[s].reorder     = ($urandom_range(3) != 0);
    end
    set_masters($urandom_range(40, 0), $urandom_range(100, 50));
    $display("[XBAR] random: %0d bursts per master; slave READY %0d%%, latency 0-%0d clocks, R gaps %0d%%",
             n, rdy, lat_hi, gap);
    fork
      gen_random(0, n);
      gen_random(1, n);
      gen_random(2, n);
      gen_random(3, n);
    join
    wait_all(n * 400);
    for (int m = 0; m < NM; m++) begin
      $display("[XBAR] M%0d: %0d bursts (%0d writes, %0d reads), %0d DECERR, mean %.1f clocks from accept to last response, same-ID stall %0d AW + %0d AR clocks",
               m, mst[m].n_done, mst[m].n_wr_done, mst[m].n_rd_done, mst[m].n_decerr,
               real'(mst[m].lat_sum) / 10.0 / real'(mst[m].n_done),
               aw_id_stall_cyc[m], ar_id_stall_cyc[m]);
    end
    for (int s = 0; s < NS; s++) begin
      $display("[XBAR] S%0d %s: %0d AW, %0d AR, %0d W beats", s, tgt_name(s),
               slv[s].n_aw, slv[s].n_ar, slv[s].n_w);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Directed tests
  // ---------------------------------------------------------------------------
  task automatic quiet();
    set_slaves(100, 0, 0, 0, 1'b0);
    set_masters(0, 100);
    for (int s = 0; s < NS; s++) slv[s].clear_stats();
  endtask

  task automatic test_decode();
    int n, n_prev, seen;
    quiet();
    n = 0;
    n_prev = 0;
    for (int m = 0; m < NM; m++) n_prev += mst[m].n_decerr;
    for (int m = 0; m < NM; m++) begin
      for (int u = 0; u < 7; u++) begin
        mst[m].send(mk(m, 1'b1, T_ERR, u % 4, 3, UNMAPPED[u]));
        mst[m].send(mk(m, 1'b0, T_ERR, (u + 1) % 4, 1, UNMAPPED[u]));
        n += 2;
      end
      for (int s = 0; s < NS; s++) begin
        if (!CONN[m][s]) begin
          mst[m].send(mk(m, 1'b1, T_ERR, 0, 0, SLV_BASE[s]));
          mst[m].send(mk(m, 1'b0, T_ERR, 1, 2, SLV_BASE[s]));
          n += 2;
        end
      end
    end
    wait_all(20000);
    seen = -n_prev;
    for (int m = 0; m < NM; m++) seen += mst[m].n_decerr;
    for (int s = 0; s < NS; s++) begin
      if (slv[s].n_aw != 0 || slv[s].n_ar != 0) tb_err($sformatf("%s saw a decode-error burst", tgt_name(s)));
    end
    if (seen != n) tb_err($sformatf("decode: %0d DECERR responses for %0d bursts", seen, n));
    $display("[XBAR] decode: %0d bursts to unmapped addresses or to slaves without a path, %0d answered DECERR with the right beat count, 0 reached a slave",
             n, seen);
  endtask

  task automatic test_same_id();
    axi_txn t1, t2, t3, w1, w2;
    logic [31:0] a;
    longint stall0;
    quiet();
    slv[1].r_lat_min = 40; slv[1].r_lat_max = 40;
    slv[1].b_lat_min = 40; slv[1].b_lat_max = 40;
    stall0 = ar_id_stall_cyc[1];
    // ID 0 to SRAM (slow), then ID 1 to NAND0, then ID 0 to NAND0.
    void'(pick_addr(1, 1, 7, 1'b0, a)); t1 = mk(1, 1'b0, 1, 0, 7, a);
    void'(pick_addr(1, 3, 0, 1'b0, a)); t3 = mk(1, 1'b0, 3, 1, 0, a);
    void'(pick_addr(1, 3, 0, 1'b0, a)); t2 = mk(1, 1'b0, 3, 0, 0, a + 32'h100);
    mst[1].send(t1); mst[1].send(t3); mst[1].send(t2);
    wait_all(2000);
    if (t3.t_acc - t1.t_acc > 20) tb_err("same-ID: a different ID was held");
    if (t2.t_acc < t1.t_done) tb_err("same-ID: ID 0 switched slaves before its earlier read finished");
    $display("[XBAR] same-ID switch, reads: ID 1 to NAND0 accepted %0d clock(s) after ID 0 to SRAM; ID 0 to NAND0 waited %0d clocks and was accepted %0d clock(s) after the SRAM read's last beat (AR stall counter %0d)",
             (t3.t_acc - t1.t_acc) / 10, (t2.t_acc - t2.t_req) / 10, (t2.t_acc - t1.t_done) / 10,
             ar_id_stall_cyc[1] - stall0);
    // Same for writes.
    void'(pick_addr(1, 1, 3, 1'b1, a)); w1 = mk(1, 1'b1, 1, 2, 3, a);
    void'(pick_addr(1, 4, 0, 1'b1, a)); w2 = mk(1, 1'b1, 4, 2, 0, a);
    mst[1].send(w1); mst[1].send(w2);
    wait_all(2000);
    if (w2.t_acc < w1.t_done) tb_err("same-ID: write ID 2 switched slaves before its earlier write finished");
    $display("[XBAR] same-ID switch, writes: ID 2 to NAND1 accepted %0d clock(s) after the SRAM write's B",
             (w2.t_acc - w1.t_done) / 10);
  endtask

  // All four masters write SRAM at once while the slave holds WREADY low half
  // the time, so W bursts from different masters queue at one slave; then
  // every burst is read back.
  task automatic test_w_order();
    logic [31:0] addrs[$];
    int          lens[$];
    int          owner[$];
    int          len;
    logic [31:0] a;
    int          n_ok;
    quiet();
    slv[1].wready_pct = 50;
    for (int i = 0; i < 8; i++) begin
      for (int m = 0; m < NM; m++) begin
        len = $urandom_range(15);
        if (pick_addr(m, 1, len, 1'b1, a)) begin
          mst[m].send(mk(m, 1'b1, 1, i % 4, len, a));
          addrs.push_back(a); lens.push_back(len); owner.push_back(m);
        end
      end
    end
    wait_all(20000);
    n_ok = slv[1].n_aw;
    for (int i = 0; i < addrs.size(); i++) begin
      mst[owner[i]].send(mk(owner[i], 1'b0, 1, i % 4, lens[i], addrs[i]));
    end
    wait_all(20000);
    $display("[XBAR] W order: %0d bursts from four masters to SRAM with WREADY at 50%%, %0d accepted, all read back by their masters",
             addrs.size(), n_ok);
  endtask

  task automatic test_outstanding();
    logic [31:0] a;
    quiet();
    slv[1].r_lat_min = 30; slv[1].r_lat_max = 30;
    slv[1].b_lat_min = 30; slv[1].b_lat_max = 30;
    for (int i = 0; i < 8; i++) begin
      void'(pick_addr(1, 1, 0, 1'b0, a));
      mst[1].send(mk(1, 1'b0, 1, i % 4, 0, a));
    end
    wait_all(3000);
    for (int i = 0; i < 8; i++) begin
      void'(pick_addr(1, 1, 0, 1'b1, a));
      mst[1].send(mk(1, 1'b1, 1, i % 4, 0, a));
    end
    wait_all(3000);
    if (slv[1].max_out_rd[1] != 4 || slv[1].max_out_wr[1] != 4) begin
      tb_err($sformatf("outstanding: SRAM saw %0d reads and %0d writes from M1 at once, limit 4",
                       slv[1].max_out_rd[1], slv[1].max_out_wr[1]));
    end
    $display("[XBAR] outstanding: 8 reads and 8 writes offered at once to a slow SRAM; at most %0d reads and %0d writes from M1 were outstanding",
             slv[1].max_out_rd[1], slv[1].max_out_wr[1]);
  endtask

  task automatic test_parallel();
    axi_txn r1, r2, w1, w2;
    logic [31:0] a;
    quiet();
    @(negedge clk);
    void'(pick_addr(1, 2, 0, 1'b0, a)); r1 = mk(1, 1'b0, 2, 0, 0, a);
    void'(pick_addr(2, 1, 0, 1'b0, a)); r2 = mk(2, 1'b0, 1, 0, 0, a);
    void'(pick_addr(1, 3, 3, 1'b1, a)); w1 = mk(1, 1'b1, 3, 1, 3, a);
    void'(pick_addr(2, 4, 3, 1'b1, a)); w2 = mk(2, 1'b1, 4, 1, 3, a);
    mst[1].send(r1); mst[2].send(r2); mst[1].send(w1); mst[2].send(w2);
    wait_all(2000);
    if (r1.t_acc != r2.t_acc || w1.t_acc != w2.t_acc) tb_err("parallel: different slaves were not served together");
    $display("[XBAR] parallel: M1 to APB and M2 to SRAM reads accepted in the same clock (%0s); M1 to NAND0 and M2 to NAND1 writes too (%0s)",
             (r1.t_acc == r2.t_acc) ? "yes" : "no", (w1.t_acc == w2.t_acc) ? "yes" : "no");
  endtask

  task automatic test_fairness();
    int          cnt[NM];
    int          lo, hi;
    logic [31:0] a;
    quiet();
    for (int i = 0; i < 100; i++) begin
      for (int m = 0; m < NM; m++) begin
        void'(pick_addr(m, 1, 0, 1'b0, a));
        mst[m].send(mk(m, 1'b0, 1, i % 4, 0, a));
      end
    end
    wait_all(5000);
    for (int m = 0; m < NM; m++) cnt[m] = 0;
    for (int i = 0; i < 200; i++) cnt[slv[1].ar_order[i]]++;
    lo = cnt[0]; hi = cnt[0];
    for (int m = 1; m < NM; m++) begin
      if (cnt[m] < lo) lo = cnt[m];
      if (cnt[m] > hi) hi = cnt[m];
    end
    if (hi - lo > 2) tb_err("fairness: shares differ by more than 2 grants");
    $display("[XBAR] round-robin: four masters reading SRAM at once; of the first 200 AR grants M0 %0d, M1 %0d, M2 %0d, M3 %0d",
             cnt[0], cnt[1], cnt[2], cnt[3]);
  endtask

  task automatic test_throughput();
    real wr_rate, rd_rate;
    quiet();
    for (int i = 0; i < 64; i++) begin
      mst[2].send(mk(2, 1'b1, 1, i % 4, 15, region_base(2, 1) + 32'(i * 128)));
    end
    wait_all(5000);
    wr_rate = real'(slv[1].n_w) / (real'(slv[1].last_w - slv[1].first_w) / 10.0 + 1.0);
    for (int i = 0; i < 64; i++) begin
      mst[2].send(mk(2, 1'b0, 1, i % 4, 15, region_base(2, 1) + 32'(i * 128)));
    end
    wait_all(5000);
    rd_rate = real'(slv[1].n_r) / (real'(slv[1].last_r - slv[1].first_r) / 10.0 + 1.0);
    $display("[XBAR] throughput: M2 to SRAM, 64 bursts of 16 beats, no back-pressure: write %.3f, read %.3f data beats per clock",
             wr_rate, rd_rate);
    if (wr_rate < 0.95 || rd_rate < 0.95) tb_err("throughput below 0.95 beats per clock");
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test = "random";
  int    n    = 2000;
  int    errs;

  initial begin
    void'($value$plusargs("test=%s", test));
    void'($value$plusargs("n=%d", n));
    repeat (2) @(negedge clk);
    for (int m = 0; m < NM; m++) mst[m].run();
    for (int s = 0; s < NS; s++) slv[s].run();
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(negedge clk);

    if (test == "directed") begin
      test_decode();
      test_w_order();
      test_same_id();
      test_outstanding();
      test_parallel();
      test_fairness();
      test_throughput();
    end else begin
      test_random(n);
    end

    errs = tb_errors;
    for (int m = 0; m < NM; m++) errs += mst[m].errors;
    for (int s = 0; s < NS; s++) errs += slv[s].errors;
    $display("[XBAR] %s: errors %0d", test, errs);
    if (errs != 0) $fatal(1, "[XBAR] FAIL");
    $display("[XBAR] PASS");
    $finish;
  end

  initial begin
    #(64'd2_000_000_000);
    $fatal(1, "[XBAR] FAIL: global timeout");
  end

endmodule
