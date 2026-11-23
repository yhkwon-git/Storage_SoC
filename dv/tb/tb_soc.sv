// tb_soc
//
// soc_top running a firmware image from the boot ROM.
//
//   +rom=<file>      ROM image, 64-bit words (fw/images/<test>.hex)
//   +test=<name>     name used in the messages; "host" also checks what the
//                    host test's firmware wrote to host memory
//   +bg              the host sends random memory writes and reads through
//                    BAR2 into its quarter of SRAM (0x1000_C000) while the
//                    firmware runs; read data is checked against every byte
//                    the host wrote. M2 is the DMA since step 1-6; the dma
//                    firmware test keeps its buffers in M2's quarter
//                    (0x1000_8000)
//   +max_cycles=<n>  give up after n clocks (default 2,000,000)
//   +apb_check       after the firmware ends, the host checks the APB bridge
//                    with DW, QW and burst reads through BAR2 (apb_check below)
//
// Since step 2-1, M3 is the transaction layer: the host model (tlp_tb_pkg) on
// the host_rx_* and host_tx_* pins, on pclk_in, enumerates the device once
// PD_HOST is up (BARs, Memory Space and Bus Master Enable, Max_Payload_Size
// 256, MSI-X table and enable). When the firmware holds the link or powers
// PD_HOST down, the host's next TLP simply waits for READY.
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
  import tlp_tb_pkg::*;

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
  // Host link: packed TLPs on pclk_in (the PHY PLL's gated clock is pclk_in
  // while it runs)
  // ---------------------------------------------------------------------------
  tlp_if hif (.clk(pclk_in), .rst_n(por_n));

  logic        host_rx_valid, host_rx_ready, host_rx_sop, host_rx_eop, host_rx_ehalf;
  logic [63:0] host_rx_data, host_tx_data;
  logic        host_tx_valid, host_tx_ready, host_tx_sop, host_tx_eop, host_tx_ehalf;

  assign host_rx_valid = hif.rx_valid;
  assign host_rx_data  = hif.rx_data;
  assign host_rx_sop   = hif.rx_sop;
  assign host_rx_eop   = hif.rx_eop;
  assign host_rx_ehalf = hif.rx_ehalf;
  assign hif.rx_ready  = host_rx_ready;
  assign hif.tx_valid  = host_tx_valid;
  assign hif.tx_data   = host_tx_data;
  assign hif.tx_sop    = host_tx_sop;
  assign hif.tx_eop    = host_tx_eop;
  assign hif.tx_ehalf  = host_tx_ehalf;
  assign host_tx_ready = hif.tx_ready;

  logic        console_valid, exit_valid, cpu_double_fault;
  logic [7:0]  console_char;
  logic [31:0] exit_code;

  soc_top dut (.*);

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
  // Host model and enumeration
  // ---------------------------------------------------------------------------
  localparam bit [63:0] BAR0 = 64'h0000_0008_0000_0000;   // 64-bit: 4DW headers
  localparam bit [63:0] BAR2 = 64'h0000_0000_C000_0000;   // below 4 GiB: 3DW
  localparam bit [63:0] MSI  = 64'h0000_0000_FEE0_0000;

  tlp_host host;
  int      host_errors = 0;
  bit      enumerated  = 1'b0;

  function automatic void herr(string s);
    host_errors++;
    if (host_errors <= 10) $display("[SOC] ERROR host: %s", s);
  endfunction

  function automatic byteq_t le_bytes(bit [63:0] v, int n);
    byteq_t b;
    for (int i = 0; i < n; i++) b.push_back(v[8*i +: 8]);
    return b;
  endfunction

  task automatic cfgwr(bit [9:0] r, bit [31:0] d, bit [3:0] be = 4'hF);
    bit [2:0] st;
    host.cfg_wr(r, d, be, st);
    if (st != SC) herr($sformatf("CfgWr reg %0d status %0d", r, st));
  endtask

  task automatic enumerate();
    bit [31:0] d;
    bit [2:0]  st;
    host.cfg_rd(10'd0, d, st);
    if (st != SC || d != 32'h0001_0000) herr($sformatf("IDs %h", d));
    cfgwr(10'd4, BAR0[31:0]); cfgwr(10'd5, BAR0[63:32]);
    cfgwr(10'd6, BAR2[31:0]); cfgwr(10'd7, BAR2[63:32]);
    // Max_Payload_Size 256, Max_Read_Request_Size 512, relaxed ordering and
    // no snoop as at reset.
    cfgwr(10'd18, 32'h0000_2830, 4'h3);
    host.dev_mps  = 256;
    host.dev_mrrs = 512;
    cfgwr(10'd1, 32'h0000_0006, 4'h1);
    for (int v = 0; v < 8; v++) begin
      host.mem_wr(BAR0 + 64'h2000 + 64'(16 * v), le_bytes(MSI + 64'(16 * v), 8));
      host.mem_wr(BAR0 + 64'h2008 + 64'(16 * v), le_bytes({32'd0, 32'h1000 + 32'(v)}, 8));
    end
    host.cfg_rd(10'd32, d, st);
    cfgwr(10'd32, {1'b1, 1'b0, d[29:0]}, 4'h8);
    enumerated = 1'b1;
  endtask

  // ---------------------------------------------------------------------------
  // Background traffic: the host writes and reads its quarter of SRAM through
  // BAR2 (BAR2 offset 0x4000 is SRAM 0x1000_C000). A read is checked against
  // the bytes the host wrote; no write touches the bytes of a read in flight.
  // ---------------------------------------------------------------------------
  localparam int BG_OFF = 32'h4000;
  localparam int BG_LEN = 32'h4000;

  bit [7:0] shadow [int];
  bit       stop_bg = 1'b0;
  int       bg_ops = 0, bg_bytes = 0;

  task automatic gen_bg();
    host_req rq[$];
    int      ro[$], rn[$];
    int      off, n;
    bit      clash;
    while (!stop_bg) begin
      while (host.sendq.size() > 4 && !stop_bg) @(negedge clk);
      if (stop_bg) break;
      if ($urandom_range(1) == 1) begin
        off = BG_OFF + $urandom_range(BG_LEN - 256, 0);
        n   = $urandom_range(256 - (off % 4), 1);
        if ((off % 4096) + n > 4096) n = 4096 - (off % 4096);
        clash = 1'b0;
        foreach (rq[j]) if (!rq[j].done && off < ro[j] + rn[j] && ro[j] < off + n) clash = 1'b1;
        if (clash) begin
          @(negedge clk);
          continue;
        end
        begin
          byteq_t b;
          for (int i = 0; i < n; i++) b.push_back(8'($urandom));
          host.mem_wr(BAR2 + 64'(off), b);
          foreach (b[i]) shadow[off + i] = b[i];
        end
      end else begin
        host_req r;
        off = BG_OFF + $urandom_range(BG_LEN - 512, 0);
        n   = $urandom_range(512, 1);
        if ((off % 4096) + n > 4096) n = 4096 - (off % 4096);
        while (host.outq.size() >= 8 && !stop_bg) @(negedge clk);
        host.mem_rd_nb(BAR2 + 64'(off), n, r);
        rq.push_back(r); ro.push_back(off); rn.push_back(n);
        begin
          byteq_t e;
          bit     known [$];
          for (int i = 0; i < n; i++) begin
            known.push_back(shadow.exists(off + i));
            e.push_back(shadow.exists(off + i) ? shadow[off + i] : 8'h00);
          end
          fork
            begin
              host_req rr = r;
              byteq_t  ee = e;
              bit      kk [$] = known;
              int      o2 = off;
              while (!rr.done) @(negedge clk);
              if (rr.status != SC) herr($sformatf("background read +%h status %0d", o2, rr.status));
              else for (int i = 0; i < ee.size(); i++)
                if (kk[i] && rr.bytes[i] !== ee[i]) begin
                  herr($sformatf("background read +%h byte %0d: %h, wrote %h", o2, i, rr.bytes[i], ee[i]));
                  break;
                end
            end
          join_none
        end
      end
      bg_ops++;
      bg_bytes += n;
      while (rq.size() > 0 && rq[0].done) begin
        void'(rq.pop_front()); void'(ro.pop_front()); void'(rn.pop_front());
      end
      if ($urandom_range(3) == 0) @(negedge clk);
    end
    while (host.outq.size() != 0) @(negedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // APB through BAR2 (+apb_check, after the firmware ends). The testbench
  // points the BAR2 window at the APB slots it needs (forcing BAR2_WIN's value
  // inside the transaction layer); DW accesses become 32-bit AXI beats, QW and
  // longer ones 64-bit beats that the bridge splits into two words.
  // ---------------------------------------------------------------------------
  int apb_errors = 0;

  task automatic apb_expect(bit ok, string what);
    if (!ok) begin
      apb_errors++;
      $display("[SOC] ERROR apb check: %s", what);
    end
  endtask

  function automatic bit [63:0] qw(byteq_t b, int at);
    bit [63:0] v;
    for (int i = 0; i < 8; i++) v[8*i +: 8] = (at + i < b.size()) ? b[at + i] : 8'h00;
    return v;
  endfunction

  task automatic apb_check();
    byteq_t   b;
    bit [2:0] st;
    // Window on slots 0 to 7: SYS, PMU, INTC, TIMER, DMA, HOST, 6, 7.
    force dut.u_pwr.u_host_if.u_tl.bar2_win = 17'h0_8000;   // 0x4000_0000
    // ID (0x000) and VERSION (0x004) in one QW read.
    host.mem_rd(BAR2, 8, b, st);
    apb_expect(st == SC && qw(b, 0) == {32'h0002_0002, 32'h5353_4F43}, "QW read of ID and VERSION");
    // SCRATCH through a DW write, read back.
    host.mem_wr(BAR2 + 64'h8, le_bytes(64'h1234_5678, 4));
    host.mem_rd(BAR2 + 64'h8, 4, b, st);
    apb_expect(st == SC && qw(b, 0) == 64'h1234_5678, "DW write and read of SCRATCH");
    // SCRATCH and the undefined 0x00C in one QW read: PSLVERR inside the beat,
    // so a Completer Abort.
    host.mem_rd(BAR2 + 64'h8, 8, b, st);
    apb_expect(st == CA, "QW read beside an undefined word gets CA");
    // PMU AON_SCRATCH (0x1018) through the APB crossing into clk_aon.
    host.mem_wr(BAR2 + 64'h1018, le_bytes(64'hCAFE_0001, 4));
    host.mem_rd(BAR2 + 64'h1018, 4, b, st);
    apb_expect(st == SC && qw(b, 0) == 64'hCAFE_0001, "DW write and read of AON_SCRATCH");
    // A 16-byte read is a 2-beat burst over the timer; MTIMECMP still holds
    // its reset value.
    host.mem_rd(BAR2 + 64'h3000, 16, b, st);
    apb_expect(st == SC && qw(b, 8) == '1 && qw(b, 0) != 0, "2-beat burst over the timer");
    // Slot 6 has no peripheral: CA.
    host.mem_rd(BAR2 + 64'h6000, 4, b, st);
    apb_expect(st == CA, "read of empty slot 6 gets CA");
    // Window on slots 8 to 15: NVME, then empty slots.
    force dut.u_pwr.u_host_if.u_tl.bar2_win = 17'h0_8001;   // 0x4000_8000
    // NVME STATUS: controller off, no command, 16 free slots.
    host.mem_rd(BAR2 + 64'h4, 4, b, st);
    apb_expect(st == SC && qw(b, 0) == 64'h0010_0000, "NVME STATUS through slot 8");
    // CMDBUF holds its reset value.
    host.mem_rd(BAR2 + 64'h14, 4, b, st);
    apb_expect(st == SC && qw(b, 0) == 64'h1000_BC00, "NVME CMDBUF through slot 8");
    host.mem_rd(BAR2 + 64'h7000, 4, b, st);
    apb_expect(st == CA, "read of empty slot 15 gets CA");
    release dut.u_pwr.u_host_if.u_tl.bar2_win;
    $display("[SOC] apb check through BAR2: QW read, DW write and read, CA beside an undefined word, AON register, 2-beat burst, empty slots, NVME slot: %0d errors",
             apb_errors);
  endtask

  // ---------------------------------------------------------------------------
  // What the host test's firmware wrote into host memory (fw/tests/host.c)
  // ---------------------------------------------------------------------------
  function automatic bit [7:0] pat(bit [63:0] a);
    return a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h3C;
  endfunction

  task automatic host_check();
    int bad = 0, nmsi = 0;
    for (int i = 0; i < 8192; i++) begin
      bit [63:0] a = 64'h0000_0002_0000_0000 + 64'(i);
      if (!host.hmem.exists(a) || host.hmem[a] !== (pat(64'(i)) ^ 8'hA5)) bad++;
    end
    for (int i = 0; i < 1000; i++) begin
      bit [63:0] a = 64'h0000_0000_3000_200C + 64'(i);
      if (!host.hmem.exists(a) || host.hmem[a] !== pat(64'h3000_0004 + 64'(i))) bad++;
    end
    foreach (host.msis[i]) if (host.msis[i].addr == MSI + 64'h20 && host.msis[i].data == 32'h1002) nmsi++;
    if (bad != 0) herr($sformatf("%0d bytes of host memory wrong after the SoC-to-host transfers", bad));
    if (nmsi != 1) herr($sformatf("%0d MSI-X messages for vector 2, expected 1", nmsi));
    $display("[SOC] host memory: 9192 bytes from the SoC checked, %0d wrong; MSI-X vector 2 messages %0d; device MRd %0d, MWr %0d, completions from the host %0d",
             bad, nmsi, host.n_dev_mrd, host.n_dev_mwr, host.n_cpl_sent);
  endtask

  // ---------------------------------------------------------------------------
  // NVMe host (+test=nvme, fw/tests/nvme.c): enables the controller with an
  // 8-entry admin queue pair, creates I/O queue pair 1 (16 entries) with two
  // admin commands, submits 12 Read commands on it in two batches, then shuts
  // the controller down. Completion queue entries come with step 2-3, so the
  // host follows the controller's state inside the design instead: SQ1 enabled
  // by the firmware, the SQ1 head at 12.
  // ---------------------------------------------------------------------------
  localparam bit [63:0] ASQ   = 64'h0000_0001_4000_0000;
  localparam bit [63:0] ACQ   = 64'h0000_0001_4001_0000;
  localparam bit [63:0] IOCQ1 = 64'h0000_0001_4002_0000;
  localparam bit [63:0] IOSQ1 = 64'h0000_0001_4003_0000;
  localparam int        NV_IO = 12;
  int nv_cycles_admin, nv_cycles_io;

  task automatic nv_wr(int off, bit [31:0] v);
    host.mem_wr(BAR0 + 64'(off), le_bytes({32'd0, v}, 4));
  endtask

  task automatic nv_rd(int off, output bit [31:0] v);
    byteq_t b;
    bit [2:0] st;
    host.mem_rd(BAR0 + 64'(off), 4, b, st);
    if (st != SC) herr($sformatf("NVMe register read +%h status %0d", off, st));
    v = {b[3], b[2], b[1], b[0]};
  endtask

  function automatic void nv_sqe(bit [63:0] a, bit [7:0] opc, bit [15:0] cid, bit [31:0] nsid,
                                 bit [63:0] prp1, bit [31:0] cdw10, bit [31:0] cdw11,
                                 bit [31:0] cdw12);
    bit [31:0] dw [16];
    foreach (dw[i]) dw[i] = 32'd0;
    dw[0] = {cid, 8'h00, opc};
    dw[1] = nsid;
    dw[6] = prp1[31:0];
    dw[7] = prp1[63:32];
    dw[10] = cdw10;
    dw[11] = cdw11;
    dw[12] = cdw12;
    for (int i = 0; i < 16; i++)
      for (int k = 0; k < 4; k++) host.hmem[a + 64'(4 * i + k)] = dw[i][8*k +: 8];
  endfunction

  task automatic nvme_host();
    bit [31:0] v;
    int n = 0;
    longint t0;
    nv_wr(32'h24, 32'h0007_0007);                        // AQA: 8 entries each
    host.mem_wr(BAR0 + 64'h28, le_bytes(ASQ, 8));
    host.mem_wr(BAR0 + 64'h30, le_bytes(ACQ, 8));
    nv_wr(32'h14, 32'h0046_0001);                        // IOCQES 4, IOSQES 6, EN
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.RDY never set"); return; end
    end while (!v[0]);
    // Create I/O CQ 1: 16 entries, vector 1, interrupts on, contiguous.
    // Create I/O SQ 1: 16 entries on CQ 1, contiguous.
    nv_sqe(ASQ,       8'h05, 16'h0001, 32'd0, IOCQ1, {16'd15, 16'd1}, {16'd1, 14'd0, 2'b11}, 32'd0);
    nv_sqe(ASQ + 64,  8'h01, 16'h0002, 32'd0, IOSQ1, {16'd15, 16'd1}, {16'd1, 15'd0, 1'b1}, 32'd0);
    t0 = $time;
    nv_wr(32'h1000, 32'd2);
    n = 0;
    while (dut.u_pwr.u_host_if.u_nvme.sq_en[1] !== 1'b1) begin
      @(negedge clk);
      if (++n > 400000) begin herr("I/O SQ 1 never created"); return; end
    end
    nv_cycles_admin = int'(($time - t0) / 20);
    // 12 Reads: CID 0x100 + i, NSID 1, PRP1 0x1_5000_0000 + 4 KiB x i,
    // SLBA 8 x i, NLB 7; doorbell after the fifth and after the last.
    t0 = $time;
    for (int i = 0; i < NV_IO; i++) begin
      nv_sqe(IOSQ1 + 64'(64 * i), 8'h02, 16'(16'h0100 + i), 32'd1,
             64'h0000_0001_5000_0000 + 64'(4096 * i), 32'(8 * i), 32'd0, 32'd7);
      if (i == 4 || i == NV_IO - 1) nv_wr(32'h1008, 32'(i + 1));
    end
    n = 0;
    while (dut.u_pwr.u_host_if.u_nvme.sq_head[1] != 12'(NV_IO)) begin
      @(negedge clk);
      if (++n > 400000) begin herr("I/O commands never all fetched"); return; end
    end
    nv_cycles_io = int'(($time - t0) / 20);
    // Shutdown: SHN normal, until SHST reads complete.
    nv_wr(32'h14, 32'h0046_4001);
    n = 0;
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.SHST never complete"); return; end
    end while (v[3:2] != 2'b10);
    if (v[1]) herr("CSTS.CFS set");
    $display("[SOC] nvme host: admin queue up, 2 admin commands to I/O SQ 1 in %0d clk_sys cycles, %0d I/O commands fetched in %0d, shutdown complete",
             nv_cycles_admin, NV_IO, nv_cycles_io);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  bit    bg;
  int    errs;
  string mode;

  initial begin
    void'($value$plusargs("test=%s", test));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    bg = $test$plusargs("bg");
    host = new(hif);
    host.clk_period = 16;
    host.lat_min = 10;
    host.lat_max = 40;
    // The host starts once power-on reset is released: before the first clk_aon
    // edge the asynchronous resets have not acted yet in simulation, and
    // PD_HOST's isolation is not in place.
    #2000;
    por_n = 1'b1;
    host.run();
    wait (rst_n === 1'b1);
    @(negedge clk);
    fork
      begin
        enumerate();
        fork
          if (bg) gen_bg();
          if (test == "nvme") nvme_host();
        join
      end
    join_none

    wait (fw_done);
    stop_bg = 1'b1;
    // Let posted writes and the last completions reach the host.
    repeat (200) @(negedge clk);
    if (test != "reset") while (!host.idle()) @(negedge clk);
    if (test == "host") host_check();
    if ($test$plusargs("apb_check")) apb_check();

    errs = host.errors + host_errors + apb_errors;
    mode = "";
    if (bg) mode = " with background traffic";
    $display("[SOC] %s%s: exit code %0d after %0d cycles; host requests %0d (%0d bytes), errors %0d",
             test, mode, fw_code, exit_cycle, bg_ops, bg_bytes, errs);
    if (fw_code != 0 || errs != 0) $fatal(1, "[SOC] %s: FAIL", test);
    $display("[SOC] %s: PASS", test);
    $finish;
  end

endmodule
