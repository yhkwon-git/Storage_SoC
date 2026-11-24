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
  axi4_if mon_s [6] (.clk(clk), .rst_n(rst_n));

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

  for (genvar g = 0; g < 6; g++) begin : g_mon_s
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
    apb_expect(st == SC && qw(b, 0) == {32'h0002_0005, 32'h5353_4F43}, "QW read of ID and VERSION");
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
  // 8-entry admin queue pair, creates I/O queue pair 1 (16 entries, vector 1)
  // with two admin commands, runs 7 I/O commands on it against the
  // firmware's 16-block namespace, then shuts the controller down. Every
  // command is completed: the host takes the entries by phase and checks CID,
  // SQID, status and the data it read back.
  // ---------------------------------------------------------------------------
  localparam bit [63:0] ASQ   = 64'h0000_0001_4000_0000;
  localparam bit [63:0] ACQ   = 64'h0000_0001_4001_0000;
  localparam bit [63:0] IOCQ1 = 64'h0000_0001_4002_0000;
  localparam bit [63:0] IOSQ1 = 64'h0000_0001_4003_0000;
  localparam bit [63:0] NVPG  = 64'h0000_0001_5000_0000;   // data pages, 8 KiB apart
  localparam bit [63:0] NVLP  = 64'h0000_0001_6000_0000;   // PRP list pages
  int nv_cycles_admin, nv_cycles_io, nv_msi0, nv_msi1;

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

  function automatic void nv_qw(bit [63:0] a, bit [63:0] v);
    for (int k = 0; k < 8; k++) host.hmem[a + 64'(k)] = v[8*k +: 8];
  endfunction

  function automatic void nv_sqe(bit [63:0] a, bit [7:0] opc, bit [15:0] cid, bit [31:0] nsid,
                                 bit [63:0] prp1, bit [63:0] prp2, bit [31:0] cdw10, bit [31:0] cdw11,
                                 bit [31:0] cdw12);
    bit [31:0] dw [16];
    foreach (dw[i]) dw[i] = 32'd0;
    dw[0] = {cid, 8'h00, opc};
    dw[1] = nsid;
    dw[6] = prp1[31:0];
    dw[7] = prp1[63:32];
    dw[8] = prp2[31:0];
    dw[9] = prp2[63:32];
    dw[10] = cdw10;
    dw[11] = cdw11;
    dw[12] = cdw12;
    for (int i = 0; i < 16; i++)
      for (int k = 0; k < 4; k++) host.hmem[a + 64'(4 * i + k)] = dw[i][8*k +: 8];
  endfunction

  // The firmware's check pattern for byte b of its namespace.
  function automatic bit [7:0] nv_wpat(int b);
    return 8'(b) ^ 8'(b >> 8) ^ 8'hA5;
  endfunction

  // Data of an I/O command: page pg[i] holds bytes from offset off on.
  function automatic bit [63:0] nv_addr(bit [63:0] pg[$], int off, int i);
    int first = 4096 - off;
    int j = i - first;
    if (i < first) return pg[0] + 64'(off + i);
    return pg[1 + j / 4096] + 64'(j % 4096);
  endfunction

  // Wait for the next entry of a completion queue (by phase) and check it.
  int nv_head [2];
  bit nv_ph [2];
  task automatic nv_cqe(int q, bit [63:0] base, int size, bit [15:0] cid, int sqid, bit [14:0] st);
    bit [31:0] d0, d2, d3;
    int n = 0;
    bit [63:0] a;
    a = base + 64'(16 * nv_head[q]);
    do begin
      @(negedge clk);
      d3 = host.hget_dw(a + 64'd12);
      if (++n > 400000) begin herr($sformatf("no completion for CID %h", cid)); return; end
    end while (d3[16] != nv_ph[q]);
    d0 = host.hget_dw(a);
    d2 = host.hget_dw(a + 64'd8);
    if (d3[15:0] != cid || int'(d2[31:16]) != sqid || d3[31:17] != st || d0 != {16'hC0DE, cid})
      herr($sformatf("completion %h %h %h for CID %h: CID %h SQID %0d status %h, expected status %h",
                     d0, d2, d3, cid, d3[15:0], d2[31:16], d3[31:17], st));
    nv_head[q] = (nv_head[q] + 1) % size;
    if (nv_head[q] == 0) nv_ph[q] = !nv_ph[q];
  endtask

  function automatic int nv_msi(int v);
    int n = 0;
    foreach (host.msis[i]) if (host.msis[i].addr == MSI + 64'(16 * v)) n++;
    return n;
  endfunction

  task automatic nvme_host();
    bit [31:0] v;
    int        n = 0;
    longint    t0;
    bit [63:0] pw[$], pr[$], p1[$], pw2[$];
    for (int i = 0; i < 16 * 8; i++)  host.hmem[ACQ + 64'(i)] = 8'h00;
    for (int i = 0; i < 16 * 16; i++) host.hmem[IOCQ1 + 64'(i)] = 8'h00;
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
    nv_sqe(ASQ,      8'h05, 16'h0001, 32'd0, IOCQ1, 64'd0, {16'd15, 16'd1}, {16'd1, 14'd0, 2'b11}, 32'd0);
    nv_sqe(ASQ + 64, 8'h01, 16'h0002, 32'd0, IOSQ1, 64'd0, {16'd15, 16'd1}, {16'd1, 15'd0, 1'b1}, 32'd0);
    t0 = $time;
    nv_wr(32'h1000, 32'd2);
    nv_head[0] = 0; nv_ph[0] = 1'b1; nv_head[1] = 0; nv_ph[1] = 1'b1;
    nv_cqe(0, ACQ, 8, 16'h0001, 0, 15'h0);
    nv_cqe(0, ACQ, 8, 16'h0002, 0, 15'h0);
    nv_wr(32'h1004, 32'(nv_head[0]));
    nv_cycles_admin = int'(($time - t0) / 20);
    // Data pages: the Write's 8 KiB from offset 0x200 (three pages, its PRP
    // list in the last slot of a list page, so the list chains); the first
    // Read's 4 KiB from offset 0x600 (two pages); one block in one page; the
    // second Write's 1 KiB over a page end.
    for (int i = 0; i < 3; i++) pw.push_back(NVPG + 64'(i) * 64'h2000);
    for (int i = 0; i < 2; i++) pr.push_back(NVPG + 64'h10_0000 + 64'(i) * 64'h2000);
    p1.push_back(NVPG + 64'h20_0000);
    for (int i = 0; i < 2; i++) pw2.push_back(NVPG + 64'h30_0000 + 64'(i) * 64'h2000);
    for (int i = 0; i < 8192; i++) host.hmem[nv_addr(pw, 32'h200, i)] = nv_wpat(i);
    for (int i = 0; i < 1024; i++) host.hmem[nv_addr(pw2, 32'hE00, i)] = nv_wpat(1024 + i);
    nv_qw(NVLP + 64'h0FF8, NVLP + 64'h2000);              // the list's only slot points on
    nv_qw(NVLP + 64'h2000, pw[1]);
    nv_qw(NVLP + 64'h2008, pw[2]);
    nv_sqe(IOSQ1 + 64'd0,   8'h01, 16'h0100, 32'd1, pw[0] + 64'h200, NVLP + 64'h0FF8, 32'd0, 32'd0, 32'd15);
    nv_sqe(IOSQ1 + 64'd64,  8'h02, 16'h0101, 32'd1, pr[0] + 64'h600, pr[1], 32'd4, 32'd0, 32'd7);
    nv_sqe(IOSQ1 + 64'd128, 8'h02, 16'h0102, 32'd1, p1[0], 64'd0, 32'd0, 32'd0, 32'd0);
    nv_sqe(IOSQ1 + 64'd192, 8'h01, 16'h0103, 32'd1, pw2[0] + 64'hE00, pw2[1], 32'd2, 32'd0, 32'd1);
    nv_sqe(IOSQ1 + 64'd256, 8'h00, 16'h0104, 32'd1, 64'd0, 64'd0, 32'd0, 32'd0, 32'd0);
    nv_sqe(IOSQ1 + 64'd320, 8'h7F, 16'h0105, 32'd1, 64'd0, 64'd0, 32'd0, 32'd0, 32'd0);
    nv_sqe(IOSQ1 + 64'd384, 8'h01, 16'h0106, 32'd1, p1[0], 64'd0, 32'd15, 32'd0, 32'd1);
    nv_msi0 = nv_msi(0);
    t0 = $time;
    nv_wr(32'h1008, 32'd3);
    nv_wr(32'h1008, 32'd7);
    nv_cqe(1, IOCQ1, 16, 16'h0100, 1, 15'h0000);
    nv_cqe(1, IOCQ1, 16, 16'h0101, 1, 15'h0000);
    nv_cqe(1, IOCQ1, 16, 16'h0102, 1, 15'h0000);
    nv_cqe(1, IOCQ1, 16, 16'h0103, 1, 15'h0000);
    nv_cqe(1, IOCQ1, 16, 16'h0104, 1, 15'h0000);
    nv_cqe(1, IOCQ1, 16, 16'h0105, 1, 15'h4001);   // Invalid Command Opcode
    nv_cqe(1, IOCQ1, 16, 16'h0106, 1, 15'h4080);   // LBA Out of Range
    nv_cycles_io = int'(($time - t0) / 20);
    nv_wr(32'h100C, 32'(nv_head[1]));
    // Read back: LBA 4-11 and LBA 0, as the first Write left them.
    begin
      int bad = 0;
      for (int i = 0; i < 4096; i++) if (host.hget(nv_addr(pr, 32'h600, i)) !== nv_wpat(2048 + i)) bad++;
      for (int i = 0; i < 512; i++)  if (host.hget(p1[0] + 64'(i)) !== nv_wpat(i)) bad++;
      if (bad != 0) herr($sformatf("%0d bytes read back wrong", bad));
    end
    repeat (100) @(negedge clk);
    nv_msi1 = nv_msi(1);
    if (nv_msi(0) < 1 || nv_msi1 < 1 || nv_msi1 > 7)
      herr($sformatf("MSI-X messages: vector 0 %0d, vector 1 %0d", nv_msi(0), nv_msi1));
    // Shutdown: SHN normal, until SHST reads complete.
    nv_wr(32'h14, 32'h0046_4001);
    n = 0;
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.SHST never complete"); return; end
    end while (v[3:2] != 2'b10);
    if (v[1]) herr("CSTS.CFS set");
    $display("[SOC] nvme host: 2 admin commands completed in %0d clk_sys cycles, 7 I/O commands (13,824 bytes moved) in %0d; read-back checked; MSI-X vector 0 %0d, vector 1 %0d; shutdown complete",
             nv_cycles_admin, nv_cycles_io, nv_msi(0), nv_msi1);
  endtask


  // ---------------------------------------------------------------------------
  // NVMe host for fw/app/nvme_app.c (+test=nvme_app, step 2-4): bring-up as a
  // host driver does it (Identify controller, namespace and active list, Set
  // and Get Features Number of Queues, four I/O queue pairs), then
  // workloads: the namespace written, reads at queue depth 1 for latency,
  // reads at queue depths 1, 4 and 16 over the four queues for IOPS, error
  // commands, queue deletion, shutdown. Every completion and every byte read
  // is checked. Times are clk_sys clocks, from the doorbell write to the
  // entry seen in host memory.
  // ---------------------------------------------------------------------------
  localparam bit [63:0] AQ_S  = 64'h0000_0001_7000_0000;
  localparam bit [63:0] AQ_C  = 64'h0000_0001_7001_0000;
  localparam bit [63:0] IQ_S  = 64'h0000_0001_7100_0000;   // + q x 64 KiB
  localparam bit [63:0] IQ_C  = 64'h0000_0001_7200_0000;
  localparam bit [63:0] HBUF  = 64'h0000_0001_7400_0000;   // one 8 KiB-spaced page per command tag
  localparam int        QS    = 16;
  int        na_tail [5], na_head [5];
  bit        na_ph [5];
  bit [15:0] na_cid;
  int        na_errs;

  function automatic bit [7:0] na_pat(int b);
    return 8'(b) ^ 8'(b >> 8) ^ 8'h5A;
  endfunction

  function automatic bit [63:0] na_sq(int q); return (q == 0) ? AQ_S : IQ_S + 64'(q) * 64'h1_0000; endfunction
  function automatic bit [63:0] na_cq(int q); return (q == 0) ? AQ_C : IQ_C + 64'(q) * 64'h1_0000; endfunction
  function automatic bit [63:0] na_buf(bit [15:0] cid); return HBUF + 64'(cid % 64) * 64'h2000; endfunction

  // Put a command into SQ q (not rung).
  function automatic bit [15:0] na_put(int q, bit [7:0] opc, bit [31:0] nsid, bit [63:0] prp1,
                                       bit [31:0] c10, bit [31:0] c11, bit [31:0] c12);
    bit [15:0] cid = na_cid;
    na_cid++;
    nv_sqe(na_sq(q) + 64'(64 * na_tail[q]), opc, cid, nsid, prp1, 64'd0, c10, c11, c12);
    na_tail[q] = (na_tail[q] + 1) % QS;
    return cid;
  endfunction

  // The next entry of CQ q, if there: CID, status, DW0.
  task automatic na_take(int q, output bit got, output bit [15:0] cid, output bit [14:0] st,
                         output bit [31:0] dw0);
    bit [63:0] a = na_cq(q) + 64'(16 * na_head[q]);
    bit [31:0] d2, d3;
    d3  = host.hget_dw(a + 64'd12);
    got = (d3[16] == na_ph[q]);
    if (!got) return;
    dw0 = host.hget_dw(a);
    d2  = host.hget_dw(a + 64'd8);
    cid = d3[15:0];
    st  = d3[31:17];
    if (int'(d2[31:16]) != q) herr($sformatf("CQ%0d entry for CID %h with SQID %0d", q, cid, d2[31:16]));
    na_head[q] = (na_head[q] + 1) % QS;
    if (na_head[q] == 0) na_ph[q] = !na_ph[q];
  endtask

  // An admin command, waited for: returns its status and DW0.
  task automatic na_admin(bit [7:0] opc, bit [31:0] nsid, bit [63:0] prp1, bit [31:0] c10, bit [31:0] c11,
                          bit [14:0] want, output bit [31:0] dw0);
    bit        got;
    bit [15:0] cid, c;
    bit [14:0] st;
    int        n = 0;
    cid = na_put(0, opc, nsid, prp1, c10, c11, 32'd0);
    nv_wr(32'h1000, 32'(na_tail[0]));
    do begin
      @(negedge clk);
      na_take(0, got, c, st, dw0);
      if (++n > 400000) begin herr($sformatf("admin opcode %h never completed", opc)); return; end
    end while (!got);
    nv_wr(32'h1004, 32'(na_head[0]));
    if (c != cid || st != want) begin
      herr($sformatf("admin opcode %h: CID %h status %h, expected CID %h status %h", opc, c, st, cid, want));
      na_errs++;
    end
  endtask

  // n I/O commands of len bytes (opcode opc), at most qd outstanding, spread
  // round robin over SQ1..nq. Reads are checked against the namespace's
  // pattern. Returns the clocks from the first doorbell to the last entry,
  // and the sum and the largest of the per-command latencies.
  typedef struct { longint t0; int lba; int len; bit [7:0] opc; int q; } na_rec_t;
  task automatic na_run(int nq, int qd, int n, int len, bit [7:0] opc, output longint total,
                        output longint lat_sum, output longint lat_max);
    na_rec_t   out [bit [15:0]];
    int        oq [5] = '{0, 0, 0, 0, 0};             // outstanding per queue: below its 15 entries
    int        issued = 0, k = 0;
    longint    t_first = 0, t_last = 0;
    lat_sum = 0;
    lat_max = 0;
    while (issued < n || out.size() > 0) begin
      if (issued < n && out.size() < qd && oq[1 + issued % nq] < QS - 2) begin
        int        q   = 1 + issued % nq;
        int        nb  = len / 512;
        int        lba = (nb == 8) ? 8 * (issued % 3) : (issued * 7) % 24;
        bit [15:0] cid = na_cid;
        na_rec_t   r;
        if (opc == 8'h01)
          for (int i = 0; i < len; i++) host.hmem[na_buf(cid) + 64'(i)] = na_pat(512 * lba + i);
        void'(na_put(q, opc, 32'd1, na_buf(cid), 32'(lba), 32'd0, 32'(nb - 1)));
        nv_wr(32'h1000 + 8 * q, 32'(na_tail[q]));
        r.t0 = $time; r.lba = lba; r.len = len; r.opc = opc; r.q = q;
        if (issued == 0) t_first = $time;
        out[cid] = r;
        oq[q]++;
        issued++;
      end
      @(negedge clk);
      for (int q = 1; q <= nq; q++) begin
        bit        got;
        bit [15:0] cid;
        bit [14:0] st;
        bit [31:0] dw0;
        int        took = 0;
        do begin
          na_take(q, got, cid, st, dw0);
          if (got) begin
            took++;
            if (!out.exists(cid)) begin
              herr($sformatf("CQ%0d: CID %h of no outstanding command", q, cid));
            end else begin
              longint lat = ($time - out[cid].t0) / 20;
              if (st != 15'h0) herr($sformatf("CID %h: status %h", cid, st));
              if (out[cid].q != q) herr($sformatf("CID %h on CQ%0d, submitted to SQ%0d", cid, q, out[cid].q));
              if (out[cid].opc == 8'h02)
                for (int i = 0; i < out[cid].len; i++)
                  if (host.hget(na_buf(cid) + 64'(i)) !== na_pat(512 * out[cid].lba + i)) begin
                    herr($sformatf("CID %h: read byte %0d wrong", cid, i));
                    break;
                  end
              lat_sum += lat;
              if (lat > lat_max) lat_max = lat;
              oq[out[cid].q]--;
              out.delete(cid);
              t_last = $time;
            end
          end
        end while (got);
        if (took > 0) nv_wr(32'h1004 + 8 * q, 32'(na_head[q]));
      end
      if (++k > 2000000) begin herr("I/O workload stuck"); break; end
    end
    total = (t_last - t_first) / 20;
  endtask

  task automatic nvme_app_host();
    bit [31:0] v, dw0;
    int        n = 0;
    longint    tot, ls, lm;
    longint    lat4, lat4max, lat512, iops [4], lat4o, iopso [5];
    for (int q = 0; q < 5; q++) begin
      na_tail[q] = 0; na_head[q] = 0; na_ph[q] = 1'b1;
      for (int i = 0; i < 16 * QS; i++) host.hmem[na_cq(q) + 64'(i)] = 8'h00;
    end
    na_cid = 16'h0010;
    nv_wr(32'h24, {4'd0, 12'(QS - 1), 4'd0, 12'(QS - 1)});
    host.mem_wr(BAR0 + 64'h28, le_bytes(AQ_S, 8));
    host.mem_wr(BAR0 + 64'h30, le_bytes(AQ_C, 8));
    nv_wr(32'h14, 32'h0046_0001);
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.RDY never set"); return; end
    end while (!v[0]);
    // Identify controller, namespace 1, active namespace list; an unknown CNS.
    na_admin(8'h06, 32'd0, HBUF, 32'h1, 32'd0, 15'h0, dw0);
    if (host.hget(HBUF + 64'd77) != 8'd5 || host.hget(HBUF + 64'd512) != 8'h66 ||
        host.hget(HBUF + 64'd513) != 8'h44 || host.hget_dw(HBUF + 64'd516) != 32'd1 ||
        host.hget_dw(HBUF + 64'd80) != 32'h0001_0400)
      herr("Identify Controller: MDTS, SQES, CQES, NN or VER");
    na_admin(8'h06, 32'd1, HBUF, 32'h0, 32'd0, 15'h0, dw0);
    if (host.hget_dw(HBUF) != 32'd24 || host.hget_dw(HBUF + 64'd128) != 32'h0009_0000)
      herr("Identify Namespace: NSZE or LBAF0");
    na_admin(8'h06, 32'd0, HBUF, 32'h2, 32'd0, 15'h0, dw0);
    if (host.hget_dw(HBUF) != 32'd1) herr("Identify active namespace list");
    na_admin(8'h06, 32'd0, HBUF, 32'h10, 32'd0, 15'h4002, dw0);       // Invalid Field
    na_admin(8'h06, 32'd2, HBUF, 32'h0, 32'd0, 15'h400B, dw0);        // Invalid Namespace
    // Number of Queues: 8 asked, 4 granted.
    na_admin(8'h09, 32'd0, 64'd0, 32'h7, 32'h0007_0007, 15'h0, dw0);
    if (dw0 != 32'h0003_0003) herr($sformatf("Set Features Number of Queues: DW0 %h", dw0));
    na_admin(8'h0A, 32'd0, 64'd0, 32'h7, 32'd0, 15'h0, dw0);
    if (dw0 != 32'h0003_0003) herr($sformatf("Get Features Number of Queues: DW0 %h", dw0));
    na_admin(8'h0A, 32'd0, 64'd0, 32'h6, 32'd0, 15'h4002, dw0);       // not a feature here
    // Four I/O queue pairs, vectors 1 to 4; and the queue errors.
    for (int q = 1; q <= 4; q++)
      na_admin(8'h05, 32'd0, na_cq(q), {16'(QS - 1), 16'(q)}, {16'(q), 14'd0, 2'b11}, 15'h0, dw0);
    for (int q = 1; q <= 4; q++)
      na_admin(8'h01, 32'd0, na_sq(q), {16'(QS - 1), 16'(q)}, {16'(q), 15'd0, 1'b1}, 15'h0, dw0);
    na_admin(8'h05, 32'd0, na_cq(1), {16'(QS - 1), 16'd5}, 32'h3, 15'h4101, dw0);   // Invalid Queue Identifier
    na_admin(8'h04, 32'd0, 64'd0, 32'd1, 32'd0, 15'h410C, dw0);                      // Invalid Queue Deletion
    // Workloads
    na_run(1, 1, 3, 4096, 8'h01, tot, ls, lm);              // the namespace written, 3 x 4 KiB
    na_run(1, 1, 32, 4096, 8'h02, tot, ls, lm);
    lat4 = ls / 32; lat4max = lm;
    iops[0] = 64'd32 * 64'd50_000_000 / tot;
    na_run(1, 1, 32, 512, 8'h02, tot, ls, lm);
    lat512 = ls / 32;
    na_run(4, 4, 48, 4096, 8'h02, tot, ls, lm);
    iops[1] = 64'd48 * 64'd50_000_000 / tot;
    na_run(4, 16, 64, 4096, 8'h02, tot, ls, lm);
    iops[2] = 64'd64 * 64'd50_000_000 / tot;
    na_run(4, 16, 64, 512, 8'h02, tot, ls, lm);
    iops[3] = 64'd64 * 64'd50_000_000 / tot;
    // The same throughput runs with the firmware's transfer overlap on
    // (vendor-specific feature 0xC0).
    na_admin(8'h09, 32'd0, 64'd0, 32'hC0, 32'd1, 15'h0, dw0);
    na_admin(8'h0A, 32'd0, 64'd0, 32'hC0, 32'd0, 15'h0, dw0);
    if (dw0 != 32'd1) herr($sformatf("Get Features 0xC0: DW0 %h", dw0));
    na_run(1, 1, 32, 4096, 8'h02, tot, ls, lm);
    lat4o = ls / 32;
    iopso[0] = 64'd32 * 64'd50_000_000 / tot;
    na_run(4, 4, 48, 4096, 8'h02, tot, ls, lm);
    iopso[1] = 64'd48 * 64'd50_000_000 / tot;
    na_run(4, 16, 64, 4096, 8'h02, tot, ls, lm);
    iopso[2] = 64'd64 * 64'd50_000_000 / tot;
    na_run(4, 16, 64, 512, 8'h02, tot, ls, lm);
    iopso[3] = 64'd64 * 64'd50_000_000 / tot;
    na_run(4, 16, 48, 4096, 8'h01, tot, ls, lm);          // writes overlapped, then read back below
    iopso[4] = 64'd48 * 64'd50_000_000 / tot;
    na_run(4, 16, 24, 4096, 8'h02, tot, ls, lm);
    // A Flush, then errors on an I/O queue: past the end, another namespace,
    // an unknown opcode.
    begin
      bit got; bit [15:0] c; bit [14:0] st; bit [15:0] cid [4];
      bit [14:0] want [4] = '{15'h0, 15'h4080, 15'h400B, 15'h4001};
      cid[0] = na_put(1, 8'h00, 32'd1, 64'd0, 32'd0, 32'd0, 32'd0);
      cid[1] = na_put(1, 8'h02, 32'd1, na_buf(16'd0), 32'd23, 32'd0, 32'd1);
      cid[2] = na_put(1, 8'h02, 32'd2, na_buf(16'd0), 32'd0, 32'd0, 32'd0);
      cid[3] = na_put(1, 8'h99, 32'd1, na_buf(16'd0), 32'd0, 32'd0, 32'd0);
      nv_wr(32'h1008, 32'(na_tail[1]));
      for (int k = 0; k < 4; k++) begin
        n = 0;
        do begin @(negedge clk); na_take(1, got, c, st, dw0); n++; end while (!got && n < 400000);
        if (c != cid[k] || st != want[k]) herr($sformatf("I/O error command %0d: CID %h status %h", k, c, st));
      end
      nv_wr(32'h100C, 32'(na_head[1]));
    end
    // Delete the queues: submission queues first.
    for (int q = 1; q <= 4; q++) na_admin(8'h00, 32'd0, 64'd0, 32'(q), 32'd0, 15'h0, dw0);
    for (int q = 1; q <= 4; q++) na_admin(8'h04, 32'd0, 64'd0, 32'(q), 32'd0, 15'h0, dw0);
    // A controller reset, then the admin queue again: the firmware keeps
    // serving.
    nv_wr(32'h14, 32'h0046_0000);
    n = 0;
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.RDY never cleared"); return; end
    end while (v[0]);
    na_tail[0] = 0; na_head[0] = 0; na_ph[0] = 1'b1;
    for (int i = 0; i < 16 * QS; i++) host.hmem[AQ_C + 64'(i)] = 8'h00;
    nv_wr(32'h14, 32'h0046_0001);
    n = 0;
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.RDY never set again"); return; end
    end while (!v[0]);
    na_admin(8'h06, 32'd0, HBUF, 32'h1, 32'd0, 15'h0, dw0);
    if (host.hget(HBUF + 64'd77) != 8'd5) herr("Identify Controller after the reset");
    na_admin(8'h0A, 32'd0, 64'd0, 32'hC0, 32'd0, 15'h0, dw0);        // back to its default
    if (dw0 != 32'd0) herr($sformatf("Get Features 0xC0 after the reset: DW0 %h", dw0));
    nv_wr(32'h14, 32'h0046_4001);
    n = 0;
    do begin
      nv_rd(32'h1C, v);
      if (++n > 1000) begin herr("CSTS.SHST never complete"); return; end
    end while (v[3:2] != 2'b10);
    $display("[SOC] nvme_app host: QD1 read latency 4 KiB %0d clocks (worst %0d), 512 B %0d clocks; IOPS at 50 MHz, 4 KiB reads: QD1 %0d, QD4 %0d, QD16 %0d; 512 B reads QD16 %0d",
             lat4, lat4max, lat512, iops[0], iops[1], iops[2], iops[3]);
    $display("[SOC] nvme_app host, transfer overlap on: QD1 read latency 4 KiB %0d clocks; IOPS 4 KiB reads: QD1 %0d, QD4 %0d, QD16 %0d; 512 B reads QD16 %0d; 4 KiB writes QD16 %0d; MSI-X messages %0d",
             lat4o, iopso[0], iopso[1], iopso[2], iopso[3], iopso[4], host.msis.size());
  endtask

  // ---------------------------------------------------------------------------
  // NVMe host driver model against nvme_app (+test=nvme_rand, step 2-5,
  // docs/14_nvme_host_verification.md, dv/tb/nvme_host_pkg.sv). Epochs of
  // random I/O over random queue layouts. All but the last end in a
  // controller reset at a chosen moment: with many, some or a few commands
  // outstanding, with a data transfer, an entry write or a fetch in flight,
  // with commands waiting for firmware, or after the queues are deleted. The
  // last epoch deletes its queues and shuts the controller down.
  //   +nvme_n=<n>       I/O commands in all (default 1200)
  //   +nvme_epochs=<n>  epochs (default 6)
  // ---------------------------------------------------------------------------
  nvme_host_pkg::nvme_host nh;
  int nr_live [$], nr_cqs [$];

  wire        nv_cc_en   = dut.u_pwr.u_host_if.u_nvme.cc[0];
  wire        nv_f_busy  = dut.u_pwr.u_host_if.u_nvme.f_busy;
  wire        nv_p_busy  = dut.u_pwr.u_host_if.u_nvme.p_busy;
  wire        nv_c_act   = dut.u_pwr.u_host_if.u_nvme.c_active;
  wire        nv_c_wait  = dut.u_pwr.u_host_if.u_nvme.c_wait;
  wire [2:0]  nv_c_cq    = dut.u_pwr.u_host_if.u_nvme.c_cq;
  wire [4:0]  nv_cf_cnt  = dut.u_pwr.u_host_if.u_nvme.cf_count;
  wire [31:0] nv_stale   = {dut.u_pwr.u_host_if.u_nvme.n_stale_xf, dut.u_pwr.u_host_if.u_nvme.n_stale_cqe};

  // Coverage: the host's events, the controller at each reset, and the
  // controller waiting for room in a completion queue.
  int nc_a, nc_b, nc_c, nr_out, nr_busy, nr_wait, nq_cq;
  covergroup cg_nh_io;
    cp_kind: coverpoint nc_a { bins read = {0}; bins write = {1}; bins flush = {2}; bins bad_opcode = {3};
                               bins bad_lba = {4}; bins bad_nsid = {5}; bins bad_prp = {6}; }
    cp_sq:   coverpoint nc_b { bins sq1 = {1}; bins sq2 = {2}; bins sq3 = {3}; bins sq4 = {4}; }
  endgroup
  covergroup cg_nh_rw;
    cp: coverpoint nc_c { bins read_sq1 = {1}; bins read_sq2 = {2}; bins read_sq3 = {3}; bins read_sq4 = {4};
                          bins write_sq1 = {9}; bins write_sq2 = {10}; bins write_sq3 = {11}; bins write_sq4 = {12}; }
  endgroup
  covergroup cg_nh_form;
    cp_form: coverpoint nc_a { bins prp1_only = {0}; bins prp1_prp2 = {1}; bins prp_list = {2}; }
    cp_size: coverpoint nc_b { bins blk1 = {0}; bins blk2_7 = {1}; bins blk8 = {2}; bins blk9_24 = {3}; }
  endgroup
  covergroup cg_nh_sqwrap; cp: coverpoint nc_a { bins sq1 = {1}; bins sq2 = {2}; bins sq3 = {3}; bins sq4 = {4}; } endgroup
  covergroup cg_nh_cqwrap; cp: coverpoint nc_a { bins cq0 = {0}; bins cq1 = {1}; bins cq2 = {2}; bins cq3 = {3}; bins cq4 = {4}; } endgroup
  covergroup cg_nh_sqfull; cp: coverpoint nc_a { bins sq1 = {1}; bins sq2 = {2}; bins sq3 = {3}; bins sq4 = {4}; } endgroup
  covergroup cg_nh_cqhold; cp: coverpoint nc_a { bins cq1 = {1}; bins cq2 = {2}; bins cq3 = {3}; bins cq4 = {4}; } endgroup
  covergroup cg_nh_cqwait; cp: coverpoint nq_cq { bins cq1 = {1}; bins cq2 = {2}; bins cq3 = {3}; bins cq4 = {4}; } endgroup
  covergroup cg_nh_qd; cp: coverpoint nc_a { bins qd1 = {0}; bins qd2_4 = {1}; bins qd5_15 = {2}; bins qd16 = {3}; } endgroup
  covergroup cg_nh_admin;
    cp: coverpoint nc_a { bins identify = {0}; bins create_cq = {1}; bins create_sq = {2}; bins delete_sq = {3};
                          bins delete_cq = {4}; bins get_features = {5}; bins set_features = {6};
                          bins err_qid = {7}; bins err_cq_invalid = {8}; bins err_qsize = {9}; bins err_vector = {10};
                          bins err_qdel = {11}; bins err_field = {12}; }
  endgroup
  covergroup cg_nh_reset;
    cp_out:  coverpoint nr_out  { bins none = {0}; bins out1_3 = {1}; bins out4_15 = {2}; bins out16 = {3}; }
    cp_busy: coverpoint nr_busy { bins idle = {0}; bins fetch = {1}; bins transfer = {2}; bins entry = {3}; }
    cp_wait: coverpoint nr_wait { bins none = {0}; bins waiting = {1}; }
  endgroup
  covergroup cg_nh_map; cp: coverpoint nc_a { bins cq_per_sq = {0}; bins shared_cq = {1}; bins shared_vector = {2}; } endgroup
  covergroup cg_nh_mode;
    cp: coverpoint nc_c { bins read = {0}; bins write = {1}; bins read_overlap = {2}; bins write_overlap = {3}; }
  endgroup
  cg_nh_io     cov_io     = new();
  cg_nh_rw     cov_rw     = new();
  cg_nh_form   cov_form   = new();
  cg_nh_sqwrap cov_sqwrap = new();
  cg_nh_cqwrap cov_cqwrap = new();
  cg_nh_sqfull cov_sqfull = new();
  cg_nh_cqhold cov_cqhold = new();
  cg_nh_cqwait cov_cqwait = new();
  cg_nh_qd     cov_qd     = new();
  cg_nh_admin  cov_admin  = new();
  cg_nh_reset  cov_reset  = new();
  cg_nh_map    cov_map    = new();
  cg_nh_mode   cov_mode   = new();

  nvme_host_pkg::nh_cov_t nce;
  bit nr_cc_q, nr_wait_q;
  int nr_o;
  always @(negedge clk) begin
    if (nh != null) begin
      while (nh.cov.size() > 0) begin
        nce = nh.cov.pop_front();
        nc_a = nce.a;
        nc_b = nce.b;
        case (nce.kind)
          0: begin
            cov_io.sample();
            if (nce.a <= 1) begin nc_c = 8 * nce.a + nce.b; cov_rw.sample(); end
          end
          1: cov_form.sample();
          2: cov_sqwrap.sample();
          3: cov_cqwrap.sample();
          4: cov_sqfull.sample();
          5: cov_cqhold.sample();
          6: cov_qd.sample();
          7: cov_admin.sample();
          9: cov_map.sample();
          10: if (nce.b <= 1) begin nc_c = 2 * nce.a + nce.b; cov_mode.sample(); end
          default: ;
        endcase
      end
      // The controller's state as the host clears CC.EN.
      if (nr_cc_q && !nv_cc_en) begin
        nr_o    = nh.out.size();
        nr_out  = (nr_o == 0) ? 0 : (nr_o < 4) ? 1 : (nr_o < 16) ? 2 : 3;
        nr_busy = nv_p_busy ? 2 : nv_c_act ? 3 : nv_f_busy ? 1 : 0;
        nr_wait = (nv_cf_cnt != 5'd0) ? 1 : 0;
        cov_reset.sample();
      end
      if (nv_c_wait && !nr_wait_q) begin nq_cq = int'(nv_c_cq); cov_cqwait.sample(); end
    end
    nr_cc_q   = nv_cc_en;
    nr_wait_q = nv_c_wait;
  end

  function automatic int nr_kind();
    int r = $urandom_range(99);
    if (r < 44) return nvme_host_pkg::K_READ;
    if (r < 84) return nvme_host_pkg::K_WRITE;
    if (r < 89) return nvme_host_pkg::K_FLUSH;
    if (r < 92) return nvme_host_pkg::K_BAD_OPC;
    if (r < 95) return nvme_host_pkg::K_BAD_LBA;
    if (r < 97) return nvme_host_pkg::K_BAD_NS;
    return nvme_host_pkg::K_BAD_PRP;
  endfunction

  // One step of the workload: a command if fewer than qd are outstanding,
  // doorbells now and then, completions, a completion queue's head held back
  // now and then so that it fills.
  task automatic nr_step(int qd, inout int issued);
    if (nh.out.size() < qd && nr_live.size() > 0) begin
      // A command whose blocks are busy is tried again on other blocks: a
      // write needs all of its blocks free of outstanding commands.
      int q = nr_live[$urandom_range(nr_live.size() - 1)];
      int k = nr_kind();
      bit ok = 1'b0;
      for (int t = 0; t < 6 && !ok; t++) begin
        int nb  = ($urandom_range(9) < 7) ? $urandom_range(8, 1) : ($urandom_range(2) == 0) ? 1 : $urandom_range(24, 9);
        int lba = $urandom_range(nvme_host_pkg::NSB - nb);
        int off = ($urandom_range(1) == 0) ? 0 : 4 * $urandom_range(1023);
        ok = nh.io(q, k, lba, nb, off);
        if (nh.sq_room(q) == 0) break;
      end
      if (ok) issued++;
    end
    if ($urandom_range(3) == 0) nh.ring_all();
    nh.poll();
    if (nr_cqs.size() > 0) begin
      if ($urandom_range(149) == 0) begin
        int c = nr_cqs[$urandom_range(nr_cqs.size() - 1)];
        if (!nh.cq_hold[c]) begin nh.cq_hold[c] = 1'b1; nh.n_cq_hold++; nh.ev(5, c); end
      end else if ($urandom_range(59) == 0) begin
        nh.release_cqs();
      end
    end
    repeat ($urandom_range(6, 1)) @(negedge clk);
  endtask

  // Enable, identify, and set up this epoch's I/O queues: layout 0 one CQ
  // per SQ, 1 one CQ for all SQs, 2 one vector for all CQs. Epoch 0 uses
  // all four pairs with four entries each and checks the queue errors
  // before creating the fourth.
  task automatic nr_setup(int e);
    bit [31:0] dw0;
    int        layout, nio, sqs, cqs;
    nh.enable((e == 0) ? 4 : $urandom_range(16, 2));
    nh.admin(0, 8'h06, 32'd0, HBUF, 32'h1, 32'd0, nvme_host_pkg::ST_OK, dw0);
    if (host.hget(HBUF + 64'd77) != 8'd5) nh.err("Identify Controller: MDTS");
    layout = (e == 0) ? 0 : $urandom_range(2);
    nio    = (e == 0 || e == 1) ? 4 : $urandom_range(4, 2);
    nr_live.delete();
    nr_cqs.delete();
    for (int q = 1; q <= nio; q++) begin
      sqs = (e == 0) ? 4 : (e == 1) ? 32 : $urandom_range(32, 2);
      cqs = (e == 0) ? 4 : (e == 1) ? 64 : $urandom_range(64, 2);
      if (e == 0 && q == 4) begin
        // Queue errors: no CQ 4 yet, CQ 1 exists, size 1, vector 9, CQ 1 in
        // use, an unknown CNS, no SQ 4 to delete, and SQ 5.
        nh.admin(0, 8'h01, 32'd0, nh.sq_addr(4), {16'd3, 16'd4}, {16'd4, 15'd0, 1'b1}, nvme_host_pkg::ST_CQ_INV, dw0);
        nh.admin(0, 8'h05, 32'd0, nh.cq_addr(1), {16'd3, 16'd1}, {16'd1, 14'd0, 2'b11}, nvme_host_pkg::ST_QID, dw0);
        nh.admin(0, 8'h05, 32'd0, nh.cq_addr(4), {16'd0, 16'd4}, {16'd4, 14'd0, 2'b11}, nvme_host_pkg::ST_QSIZE, dw0);
        nh.admin(0, 8'h05, 32'd0, nh.cq_addr(4), {16'd3, 16'd4}, {16'd9, 14'd0, 2'b11}, nvme_host_pkg::ST_IV, dw0);
        nh.admin(0, 8'h04, 32'd0, 64'd0, 32'd1, 32'd0, nvme_host_pkg::ST_QDEL, dw0);
        nh.admin(0, 8'h06, 32'd0, HBUF, 32'h10, 32'd0, nvme_host_pkg::ST_FIELD, dw0);
        nh.admin(0, 8'h00, 32'd0, 64'd0, 32'd4, 32'd0, nvme_host_pkg::ST_QID, dw0);
        nh.admin(0, 8'h01, 32'd0, nh.sq_addr(1), {16'd3, 16'd5}, {16'd1, 15'd0, 1'b1}, nvme_host_pkg::ST_QID, dw0);
      end
      case (layout)
        0: begin nh.create_cq(q, cqs, q); nh.create_sq(q, sqs, q); nr_cqs.push_back(q); end
        1: begin
          if (q == 1) begin nh.create_cq(1, cqs, 1); nr_cqs.push_back(1); end
          nh.create_sq(q, sqs, 1);
        end
        default: begin nh.create_cq(q, cqs, 1); nh.create_sq(q, sqs, q); nr_cqs.push_back(q); end
      endcase
      nr_live.push_back(q);
    end
    nh.ev(9, layout);
    nh.admin(0, 8'h0A, 32'd0, 64'd0, 32'h7, 32'd0, nvme_host_pkg::ST_OK, dw0);
    if (dw0 != 32'h0003_0003) nh.err($sformatf("Get Features Number of Queues: DW0 %h", dw0));
    nh.set_overlap(1'($urandom_range(1)));
  endtask

  // Epoch 0, after the namespace is written: large transfers one at a time
  // (PRP lists), then for each queue pair in turn its CQ head held back while
  // Flush commands go to its SQ, until the controller waits for room in that
  // CQ; with four entries per queue both wrap on the way.
  task automatic nr_directed();
    int n, sent;
    int big_lba [4] = '{0, 4, 0, 10};
    int big_nb [4]  = '{24, 16, 24, 9};
    int big_off [4] = '{0, 2048, 3584, 1024};
    for (int i = 0; i < 4; i++) begin
      n = 0;
      while (!nh.io(i + 1, (i % 2 == 0) ? nvme_host_pkg::K_WRITE : nvme_host_pkg::K_READ,
                    big_lba[i], big_nb[i], big_off[i])) begin
        nh.ring_all(); nh.poll(); @(negedge clk);
        if (++n > 100000) begin nh.err("large transfer could not be issued"); break; end
      end
      nh.drain();
      n = 0;
      while (!nh.io(i + 1, nvme_host_pkg::K_READ, big_lba[i], big_nb[i], big_off[i])) begin
        nh.ring_all(); nh.poll(); @(negedge clk);
        if (++n > 100000) begin nh.err("large read could not be issued"); break; end
      end
      nh.drain();
    end
    foreach (nr_cqs[k]) begin
      int c = nr_cqs[k];
      bit waited = 1'b0;
      nh.cq_hold[c] = 1'b1;
      nh.n_cq_hold++;
      nh.ev(5, c);
      sent = 0;
      n = 0;
      while (!waited || sent < 8) begin
        if (nh.io(c, nvme_host_pkg::K_FLUSH, 0, 1, 0)) sent++;
        nh.ring_all();
        nh.poll();
        if (nv_c_wait && nv_c_cq == 3'(c)) waited = 1'b1;
        if (waited) nh.cq_hold[c] = 1'b0;
        repeat (4) @(negedge clk);
        if (++n > 100000) begin nh.err($sformatf("CQ%0d never filled", c)); break; end
      end
      nh.drain();
    end
  endtask

  task automatic nr_delete_all();
    foreach (nr_live[i]) nh.delete_sq(nr_live[i]);
    foreach (nr_cqs[i]) nh.delete_cq(nr_cqs[i]);
    nr_live.delete();
    nr_cqs.delete();
  endtask

  // How each epoch but the last ends: outstanding commands between lo and
  // hi, and what the controller is doing (0 anything, 1 a fetch, 2 a data
  // transfer, 3 an entry write, 4 commands waiting for firmware, 5 queues
  // deleted first).
  int nr_plan_lo [5]   = '{4, 16, 1, 0, 1};
  int nr_plan_hi [5]   = '{15, 999, 3, 0, 999};
  int nr_plan_busy [5] = '{3, 2, 1, 5, 4};

  task automatic nvme_rand_host();
    int ncmd = 1200, nep = 6, issued, per, n, p;
    longint t0;
    void'($value$plusargs("nvme_n=%d", ncmd));
    void'($value$plusargs("nvme_epochs=%d", nep));
    nh = new(host, BAR0, MSI);
    per = ncmd / nep;
    for (int e = 0; e < nep; e++) begin
      nr_setup(e);
      if (e == 0) begin
        // The whole namespace written, so that every block is known.
        for (int b = 0; b < nvme_host_pkg::NSB; b += 8) begin
          n = 0;
          while (!nh.io(1, nvme_host_pkg::K_WRITE, b, 8, 0)) begin
            nh.ring_all(); nh.poll(); @(negedge clk);
            if (++n > 100000) begin nh.err("namespace fill stuck"); break; end
          end
        end
        nh.drain();
        nr_directed();
      end
      issued = 0;
      n = 0;
      while (issued < per) begin
        int qd = (e == 1) ? 40 : (e == 0) ? 12 : $urandom_range(32, 1);
        nr_step(qd, issued);
        if (++n > 400000) begin nh.err($sformatf("epoch %0d: workload stuck", e)); break; end
      end
      if (e == nep - 1) begin
        // Last epoch: complete everything, delete the queues, shut down.
        nh.drain();
        nr_delete_all();
        nh.shutdown();
      end else begin
        p = e % 5;
        if (nr_plan_busy[p] == 5) begin
          nh.drain();
          nr_delete_all();
        end else begin
          // Reach the planned state, then reset.
          int qd = (nr_plan_hi[p] > 100) ? 40 : nr_plan_hi[p];
          if (nr_plan_busy[p] == 4) foreach (nr_cqs[i]) nh.cq_hold[nr_cqs[i]] = 1'b1;
          n = 0;
          forever begin
            bit busy_ok;
            case (nr_plan_busy[p])
              1: busy_ok = nv_f_busy;
              2: busy_ok = nv_p_busy;
              3: busy_ok = nv_c_act;
              4: busy_ok = (nv_cf_cnt != 5'd0);
              default: busy_ok = 1'b1;
            endcase
            if (nh.out.size() >= nr_plan_lo[p] && nh.out.size() <= nr_plan_hi[p] && busy_ok) break;
            if (++n > 200000) begin
              $display("[SOC] nvme_rand: epoch %0d reset without the planned state (%0d outstanding)", e, nh.out.size());
              break;
            end
            if (nh.out.size() < nr_plan_lo[p]) nr_step(qd, issued);
            else begin
              if (nr_plan_busy[p] != 4) nh.poll();
              nh.ring_all();
              @(negedge clk);
            end
          end
        end
        nh.reset_ctrl();
      end
    end
    host_errors += nh.errors;
    $display("[SOC] nvme_rand host: %0d commands (%0d Read, %0d Write, %0d Flush, %0d admin), %0d completed (%0d with an error status, as expected), %0d abandoned by %0d controller resets",
             nh.n_sub, nh.n_reads, nh.n_writes, nh.n_flush, nh.n_admin, nh.n_done, nh.n_st_err, nh.n_abandon, nh.n_resets);
    $display("[SOC] nvme_rand host: %0d bytes read and compared, %0d written; %0d SQ-full waits, %0d CQ holds; MSI-X messages %0d, lost at resets %0d; abandoned buffers checked %0d; stale starts refused %0d, stale posts discarded %0d; errors %0d",
             nh.rd_bytes, nh.wr_bytes, nh.n_sq_full, nh.n_cq_hold, host.msis.size(), nh.n_msi_lost, nh.n_quar_checked,
             nv_stale[31:16], nv_stale[15:0], nh.errors);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  bit    bg;
  int    errs;
  string mode;

  initial begin
    void'($value$plusargs("test=%s", test));
    if (!$value$plusargs("max_cycles=%d", max_cycles) && test == "nvme_rand") max_cycles = 80_000_000;
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
          if (test == "nvme_app") nvme_app_host();
          if (test == "nvme_rand") nvme_rand_host();
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
