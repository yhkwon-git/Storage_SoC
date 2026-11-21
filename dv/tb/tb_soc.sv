// tb_soc
//
// soc_top running a firmware image from the boot ROM.
//
//   +rom=<file>      ROM image, 64-bit words (fw/images/<test>.hex)
//   +test=<name>     name used in the messages
//   +bg              M3 runs random reads and writes in its quarter of SRAM
//                    (0x1000_C000) while the firmware runs, checked by the
//                    master model. M2 is the DMA since step 1-6; the dma
//                    firmware test keeps its buffers in M2's quarter
//                    (0x1000_8000)
//   +max_cycles=<n>  give up after n clocks (default 2,000,000)
//   +apb_check       after the firmware ends, M3 checks the APB bridge with
//                    64-bit accesses (apb_check below)
//
// Console characters are printed line by line as [FW] lines. A write to the
// SYS EXIT register ends the run: code 0 is a pass. An axi4_checker watches
// each of the nine crossbar ports.
//
// Clocks (step 1-7): clk_sys 50 MHz, clk_aon 1 MHz, clk_nand 50 MHz, pclk_in
// 62.5 MHz. por_n rises after 2 us; the PMU then releases the core reset, and
// cycles count from that release, which also restarts after a chip reset. The
// PD_HOST power switch acknowledges 3 clk_aon cycles after a change of
// host_pwr_en.

`timescale 1ns/1ps

module tb_soc;
  import axi_tb_pkg::*;

  logic clk_sys  = 1'b0;
  logic clk_aon  = 1'b0;
  logic clk_nand = 1'b0;
  logic pclk_in  = 1'b0;
  logic por_n    = 1'b0;
  always #10  clk_sys = ~clk_sys;  // 50 MHz
  always #500 clk_aon = ~clk_aon;  // 1 MHz
  always #8   pclk_in = ~pclk_in;  // 62.5 MHz
  initial begin
    #3;
    forever #10 clk_nand = ~clk_nand;
  end

  wire  clk   = clk_sys;
  wire  rst_n = dut.rst_sys_n;

  // PD_HOST power switch.
  logic host_pwr_en;
  logic host_pwr_ack = 1'b0;
  logic host_wake    = 1'b0;
  int   sw_cnt       = 0;
  always @(posedge clk_aon) begin
    if (host_pwr_ack != host_pwr_en) begin
      sw_cnt++;
      if (sw_cnt >= 3) begin
        host_pwr_ack <= host_pwr_en;
        sw_cnt = 0;
      end
    end else begin
      sw_cnt = 0;
    end
  end

  // ---------------------------------------------------------------------------
  // External master port M3
  // ---------------------------------------------------------------------------
  axi4_if eif (.clk(clk), .rst_n(rst_n));

  logic [1:0]  ext_awid,  ext_arid,  ext_bid,   ext_rid;
  logic [31:0] ext_awaddr, ext_araddr;
  logic [7:0]  ext_awlen, ext_arlen;
  logic [2:0]  ext_awsize, ext_arsize, ext_awprot, ext_arprot;
  logic [1:0]  ext_awburst, ext_arburst, ext_bresp, ext_rresp;
  logic [3:0]  ext_awcache, ext_arcache, ext_awqos, ext_arqos;
  logic        ext_awvalid, ext_awready, ext_arvalid, ext_arready;
  logic [63:0] ext_wdata, ext_rdata;
  logic [7:0]  ext_wstrb;
  logic        ext_wlast, ext_wvalid, ext_wready, ext_bvalid, ext_bready;
  logic        ext_rlast, ext_rvalid, ext_rready;

  logic        console_valid, exit_valid, cpu_double_fault;
  logic [7:0]  console_char;
  logic [31:0] exit_code;

  soc_top dut (.*);

  assign ext_awid    = eif.awid[1:0];
  assign ext_awaddr  = eif.awaddr;
  assign ext_awlen   = eif.awlen;
  assign ext_awsize  = eif.awsize;
  assign ext_awburst = eif.awburst;
  assign ext_awprot  = eif.awprot;
  assign ext_awcache = eif.awcache;
  assign ext_awqos   = eif.awqos;
  assign ext_awvalid = eif.awvalid;
  assign eif.awready = ext_awready;
  assign ext_wdata   = eif.wdata;
  assign ext_wstrb   = eif.wstrb;
  assign ext_wlast   = eif.wlast;
  assign ext_wvalid  = eif.wvalid;
  assign eif.wready  = ext_wready;
  assign eif.bid     = {2'b00, ext_bid};
  assign eif.bresp   = ext_bresp;
  assign eif.bvalid  = ext_bvalid;
  assign ext_bready  = eif.bready;
  assign ext_arid    = eif.arid[1:0];
  assign ext_araddr  = eif.araddr;
  assign ext_arlen   = eif.arlen;
  assign ext_arsize  = eif.arsize;
  assign ext_arburst = eif.arburst;
  assign ext_arprot  = eif.arprot;
  assign ext_arcache = eif.arcache;
  assign ext_arqos   = eif.arqos;
  assign ext_arvalid = eif.arvalid;
  assign eif.arready = ext_arready;
  assign eif.rid     = {2'b00, ext_rid};
  assign eif.rdata   = ext_rdata;
  assign eif.rresp   = ext_rresp;
  assign eif.rlast   = ext_rlast;
  assign eif.rvalid  = ext_rvalid;
  assign ext_rready  = eif.rready;

  // ---------------------------------------------------------------------------
  // Protocol checkers on the nine crossbar ports, through monitor interfaces
  // ---------------------------------------------------------------------------
  axi4_if mon_m [4] (.clk(clk), .rst_n(rst_n));
  axi4_if mon_s [5] (.clk(clk), .rst_n(rst_n));

  for (genvar g = 0; g < 4; g++) begin : g_mon_m
    assign mon_m[g].awid    = {2'b00, dut.s_awid[g]};
    assign mon_m[g].awaddr  = dut.s_awaddr[g];
    assign mon_m[g].awlen   = dut.s_awlen[g];
    assign mon_m[g].awsize  = dut.s_awsize[g];
    assign mon_m[g].awburst = dut.s_awburst[g];
    assign mon_m[g].awprot  = dut.s_awprot[g];
    assign mon_m[g].awcache = dut.s_awcache[g];
    assign mon_m[g].awqos   = dut.s_awqos[g];
    assign mon_m[g].awvalid = dut.s_awvalid[g];
    assign mon_m[g].awready = dut.s_awready[g];
    assign mon_m[g].wdata   = dut.s_wdata[g];
    assign mon_m[g].wstrb   = dut.s_wstrb[g];
    assign mon_m[g].wlast   = dut.s_wlast[g];
    assign mon_m[g].wvalid  = dut.s_wvalid[g];
    assign mon_m[g].wready  = dut.s_wready[g];
    assign mon_m[g].bid     = {2'b00, dut.s_bid[g]};
    assign mon_m[g].bresp   = dut.s_bresp[g];
    assign mon_m[g].bvalid  = dut.s_bvalid[g];
    assign mon_m[g].bready  = dut.s_bready[g];
    assign mon_m[g].arid    = {2'b00, dut.s_arid[g]};
    assign mon_m[g].araddr  = dut.s_araddr[g];
    assign mon_m[g].arlen   = dut.s_arlen[g];
    assign mon_m[g].arsize  = dut.s_arsize[g];
    assign mon_m[g].arburst = dut.s_arburst[g];
    assign mon_m[g].arprot  = dut.s_arprot[g];
    assign mon_m[g].arcache = dut.s_arcache[g];
    assign mon_m[g].arqos   = dut.s_arqos[g];
    assign mon_m[g].arvalid = dut.s_arvalid[g];
    assign mon_m[g].arready = dut.s_arready[g];
    assign mon_m[g].rid     = {2'b00, dut.s_rid[g]};
    assign mon_m[g].rdata   = dut.s_rdata[g];
    assign mon_m[g].rresp   = dut.s_rresp[g];
    assign mon_m[g].rlast   = dut.s_rlast[g];
    assign mon_m[g].rvalid  = dut.s_rvalid[g];
    assign mon_m[g].rready  = dut.s_rready[g];
    axi4_checker #(.KIND("M"), .IDX(g)) u_chk (.a(mon_m[g]));
  end

  for (genvar g = 0; g < 5; g++) begin : g_mon_s
    assign mon_s[g].awid    = dut.m_awid[g];
    assign mon_s[g].awaddr  = dut.m_awaddr[g];
    assign mon_s[g].awlen   = dut.m_awlen[g];
    assign mon_s[g].awsize  = dut.m_awsize[g];
    assign mon_s[g].awburst = dut.m_awburst[g];
    assign mon_s[g].awprot  = dut.m_awprot[g];
    assign mon_s[g].awcache = dut.m_awcache[g];
    assign mon_s[g].awqos   = dut.m_awqos[g];
    assign mon_s[g].awvalid = dut.m_awvalid[g];
    assign mon_s[g].awready = dut.m_awready[g];
    assign mon_s[g].wdata   = dut.m_wdata[g];
    assign mon_s[g].wstrb   = dut.m_wstrb[g];
    assign mon_s[g].wlast   = dut.m_wlast[g];
    assign mon_s[g].wvalid  = dut.m_wvalid[g];
    assign mon_s[g].wready  = dut.m_wready[g];
    assign mon_s[g].bid     = dut.m_bid[g];
    assign mon_s[g].bresp   = dut.m_bresp[g];
    assign mon_s[g].bvalid  = dut.m_bvalid[g];
    assign mon_s[g].bready  = dut.m_bready[g];
    assign mon_s[g].arid    = dut.m_arid[g];
    assign mon_s[g].araddr  = dut.m_araddr[g];
    assign mon_s[g].arlen   = dut.m_arlen[g];
    assign mon_s[g].arsize  = dut.m_arsize[g];
    assign mon_s[g].arburst = dut.m_arburst[g];
    assign mon_s[g].arprot  = dut.m_arprot[g];
    assign mon_s[g].arcache = dut.m_arcache[g];
    assign mon_s[g].arqos   = dut.m_arqos[g];
    assign mon_s[g].arvalid = dut.m_arvalid[g];
    assign mon_s[g].arready = dut.m_arready[g];
    assign mon_s[g].rid     = dut.m_rid[g];
    assign mon_s[g].rdata   = dut.m_rdata[g];
    assign mon_s[g].rresp   = dut.m_rresp[g];
    assign mon_s[g].rlast   = dut.m_rlast[g];
    assign mon_s[g].rvalid  = dut.m_rvalid[g];
    assign mon_s[g].rready  = dut.m_rready[g];
    axi4_checker #(.KIND("S"), .IDX(g)) u_chk (.a(mon_s[g]));
  end

  // ---------------------------------------------------------------------------
  // Console, exit, cycle count
  // ---------------------------------------------------------------------------
  string  line = "";
  string  test = "fw";
  bit     fw_done = 1'b0;
  int     fw_code;
  longint cycles = 0;
  longint exit_cycle = 0;
  longint max_cycles = 2_000_000;

  always @(posedge clk) begin
    if (rst_n) begin
      cycles++;
      if (console_valid) begin
        if (console_char == 8'h0A) begin
          $display("[FW] %s", line);
          line = "";
        end else begin
          line = {line, string'(console_char)};
        end
      end
      if (exit_valid && !fw_done) begin
        fw_done    = 1'b1;
        fw_code    = int'(exit_code);
        exit_cycle = cycles;
      end
      if (cpu_double_fault) $fatal(1, "[SOC] %s: double fault in the core", test);
      if (cycles > max_cycles) $fatal(1, "[SOC] %s: no exit after %0d cycles", test, max_cycles);
    end
  end

  // ---------------------------------------------------------------------------
  // Background traffic on M3
  // ---------------------------------------------------------------------------
  axi_master mst;
  bit        stop_bg = 1'b0;

  initial begin
    mst = new(eif, 3);
    // SRAM starts with unknown contents; only written words are predictable.
    mst.learn_unknown = 1'b1;
  end

  task automatic gen_bg();
    axi_txn      t;
    bit          wr;
    int          len, words;
    logic [31:0] base, a;
    base  = region_base(3, 1);
    words = int'(region_size(1) / 8);
    while (!stop_bg) begin
      while (mst.pending() >= 6 && !stop_bg) @(negedge clk);
      if (stop_bg) break;
      wr  = ($urandom_range(1) == 1);
      len = $urandom_range(15);
      a   = base + 32'($urandom_range(words - len - 1) * 8);
      if ((a & 32'hFFF) + 32'((len + 1) * 8) > 32'h1000 || !mst.words_free(a, len, wr)) begin
        @(negedge clk);
        continue;
      end
      t       = new();
      t.write = wr;
      t.id    = 4'($urandom_range(3));
      t.addr  = a;
      t.len   = len;
      t.tgt   = 1;
      if (wr) begin
        for (int b = 0; b <= len; b++) begin
          t.data.push_back({$urandom(), $urandom()});
          t.strb.push_back(8'hFF);
        end
      end
      mst.send(t);
      if ($urandom_range(1) == 1) @(negedge clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // APB through 64-bit accesses from M3 (+apb_check, after the firmware ends):
  // the CPU only makes 32-bit accesses, so this covers the bridge's two-word
  // beats, strobe-selected words, PSLVERR inside a beat, an empty slot and a
  // burst.
  // ---------------------------------------------------------------------------
  int apb_errors = 0;

  function automatic axi_txn mk_apb(bit wr, logic [31:0] a, int len, int resp);
    axi_txn t;
    t          = new();
    t.write    = wr;
    t.id       = 4'd0;
    t.addr     = a;
    t.len      = len;
    t.tgt      = 2;
    t.exp_resp = resp;
    t.no_check = 1'b1;
    return t;
  endfunction

  task automatic apb_send(axi_txn t);
    mst.send(t);
    while (mst.pending() != 0) @(negedge clk);
  endtask

  task automatic apb_expect(bit ok, string what);
    if (!ok) begin
      apb_errors++;
      $display("[SOC] ERROR apb check: %s", what);
    end
  endtask

  task automatic apb_check();
    axi_txn t;
    // ID (0x000) and VERSION (0x004) in one 64-bit read; reset values from
    // rtl/csr/rdl/soc_apb.rdl.
    t = mk_apb(1'b0, 32'h4000_0000, 0, 0);
    apb_send(t);
    apb_expect(t.rdata[0] == {32'h0001_0007, 32'h5353_4F43}, "64-bit read of ID and VERSION");
    // SCRATCH written through the lower word only (WSTRB 0x0F).
    t = mk_apb(1'b1, 32'h4000_0008, 0, 0);
    t.data.push_back({32'hDEAD_BEEF, 32'h1234_5678});
    t.strb.push_back(8'h0F);
    apb_send(t);
    // Reading both words: 0x00C is undefined, so the beat is SLVERR, and the
    // lower word still carries SCRATCH.
    t = mk_apb(1'b0, 32'h4000_0008, 0, 2);
    apb_send(t);
    apb_expect(t.rdata[0] == {32'h0, 32'h1234_5678}, "SCRATCH beside an undefined word");
    // Slot 6 (NAND0 registers, phase 3) has no peripheral yet.
    t = mk_apb(1'b1, 32'h4000_6000, 0, 2);
    t.data.push_back(64'h1);
    t.strb.push_back(8'hFF);
    apb_send(t);
    // Two-beat burst over the timer: MTIMECMP still holds its reset value.
    t = mk_apb(1'b0, 32'h4000_3000, 1, 0);
    apb_send(t);
    apb_expect(t.rdata.size() == 2 && t.rdata[1] == '1 && t.rdata[0] != 0,
               "two-beat timer read");
    $display("[SOC] apb check: 64-bit read, strobed write, SLVERR beside a valid word, empty slot, 2-beat burst: %0d errors",
             apb_errors + mst.errors);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  bit    bg;
  int    errs;
  int    bg_m3;
  string mode;

  initial begin
    void'($value$plusargs("test=%s", test));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    bg = $test$plusargs("bg");
    #1;
    mst.run();
    #2000;
    por_n = 1'b1;
    wait (rst_n === 1'b1);
    @(negedge clk);
    if (bg) begin
      fork
        gen_bg();
      join_none
    end

    wait (fw_done);
    stop_bg = 1'b1;
    while (mst.pending() != 0) @(negedge clk);
    repeat (4) @(negedge clk);
    bg_m3 = mst.n_done;
    if ($test$plusargs("apb_check")) apb_check();

    errs = mst.errors + apb_errors;
    mode = "";
    if (bg) mode = " with background traffic";
    $display("[SOC] %s%s: exit code %0d after %0d cycles; background bursts %0d (M3), errors %0d",
             test, mode, fw_code, exit_cycle, bg_m3, errs);
    if (fw_code != 0 || errs != 0) $fatal(1, "[SOC] %s: FAIL", test);
    $display("[SOC] %s: PASS", test);
    $finish;
  end

endmodule
