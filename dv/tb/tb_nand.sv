`timescale 1ns/1ps
// Clock periods and the model's timing are real-valued delays.
/* verilator lint_off ZERODLY */

// -----------------------------------------------------------------------------
// tb_nand
//
// Block testbench of one NAND channel (step 3-1, docs/15_nand_channel.md):
// nand_ctrl with nand_model on its pins; the testbench is the firmware on APB
// and a bus master on the page buffer. nand_checker is bound into the
// sequencer, axi4_checker watches the page-buffer port. The tests from busy
// on check the model's device behavior (step 3-2, docs/16_nand_model.md).
//
//   +test=<name>    regs, reset, id, rw, erase, fail, wp, timeout, timing,
//                   queue, arb, softreset, busy, wear, abort, rules, biterr,
//                   random, or all (default: the directed tests, then random)
//   +n=<n>          commands in the random test (default 400)
//   +nand_ps=<ps>   clk_nand period in ps (default 20000); clk_sys is 20 ns
//   +profile=<0|1>  the model's busy-time profile in the random test
//   +rber_ppm=<n>   its bit error rate there, in errors per million bits
//
// Every read is compared with an expected copy of the array kept here (a
// program ANDs, an erase sets FFh), with the bits the model logs as flipped
// by that read flipped; every completion with the tag and code it must have.
// The model's interface and rule checks and the assertions count as errors.
// -----------------------------------------------------------------------------

module tb_nand;
  import nand_pkg::*;

  localparam realtime CLK    = 20.0;
  localparam int      PBYTES = 4320;
  localparam int      PAGES  = 64;

  realtime nclk = 20.0;
  logic    clk = 1'b0, clk_nand = 1'b0;
  logic    rst_n = 1'b0, rst_nand_n = 1'b0;
  int      errors;

  initial forever #(CLK / 2.0) clk = ~clk;
  initial begin
    int ps;
    if ($value$plusargs("nand_ps=%d", ps)) nclk = real'(ps) / 1000.0;
    #(3.3);                                // not in phase with clk_sys
    forever #(nclk / 2.0) clk_nand = ~clk_nand;
  end

  function automatic void fail(string s);
    errors++;
    if (errors <= 30) $display("[NAND] ERROR at %0t: %s", $time, s);
  endfunction

  // ---------------------------------------------------------------------------
  // DUT, model and bus
  // ---------------------------------------------------------------------------
  apb_if  aif (.pclk(clk), .presetn(rst_n));
  axi4_if bif (.clk(clk), .rst_n(rst_n));
  axi4_checker #(.KIND("S"), .IDX(3)) u_achk (.a(bif));

  logic       ce_n, cle, ale, we_n, re_n, wp_n, dq_oe, rb_n, dq_d_oe;
  logic [7:0] dq_o, dq_d, dq_i;
  logic       irq_done, irq_err;

  // DQ as the controller sees it: the device's byte while it drives,
  // otherwise a floating-bus pattern.
  assign dq_i = dq_d_oe ? dq_d : (dq_oe ? dq_o : 8'hA5);

  nand_ctrl #(.IDW(4)) u_nc (
    .clk (clk), .rst_n (rst_n), .clk_nand (clk_nand), .rst_nand_n (rst_nand_n),
    .psel (aif.psel), .penable (aif.penable), .paddr (aif.paddr[11:0]), .pwrite (aif.pwrite),
    .pwdata (aif.pwdata), .pstrb (aif.pstrb), .prdata (aif.prdata), .pready (aif.pready),
    .pslverr (aif.pslverr),
    .s_awid (bif.awid), .s_awaddr (bif.awaddr), .s_awlen (bif.awlen), .s_awvalid (bif.awvalid),
    .s_awready (bif.awready), .s_wdata (bif.wdata), .s_wstrb (bif.wstrb), .s_wlast (bif.wlast),
    .s_wvalid (bif.wvalid), .s_wready (bif.wready), .s_bid (bif.bid), .s_bresp (bif.bresp),
    .s_bvalid (bif.bvalid), .s_bready (bif.bready),
    .s_arid (bif.arid), .s_araddr (bif.araddr), .s_arlen (bif.arlen), .s_arvalid (bif.arvalid),
    .s_arready (bif.arready), .s_rid (bif.rid), .s_rdata (bif.rdata), .s_rresp (bif.rresp),
    .s_rlast (bif.rlast), .s_rvalid (bif.rvalid), .s_rready (bif.rready),
    .ce_n (ce_n), .cle (cle), .ale (ale), .we_n (we_n), .re_n (re_n), .wp_n (wp_n),
    .dq_o (dq_o), .dq_oe (dq_oe), .dq_i (dq_i), .rb_n (rb_n),
    .irq_done (irq_done), .irq_err (irq_err)
  );

  nand_model #(.NAME("NAND0"), .BLOCKS(64), .PAGES(PAGES), .PBYTES(PBYTES)) u_m (
    .ce_n (ce_n), .cle (cle), .ale (ale), .we_n (we_n), .re_n (re_n), .wp_n (wp_n),
    .dq_c (dq_o), .dq_c_oe (dq_oe), .dq_d (dq_d), .dq_d_oe (dq_d_oe), .rb_n (rb_n)
  );

  // ---------------------------------------------------------------------------
  // APB (firmware role)
  // ---------------------------------------------------------------------------
  localparam bit [11:0] R_CTRL = 12'h000, R_STATUS = 12'h004, R_EVENT = 12'h008, R_T0 = 12'h010,
                        R_T1 = 12'h014, R_TOUT = 12'h018, R_ROW = 12'h020, R_COL = 12'h024,
                        R_LEN = 12'h028, R_BUF = 12'h02C, R_GO = 12'h030, R_CPL = 12'h034,
                        R_CYC = 12'h038, R_BUSY = 12'h03C, R_COUNT = 12'h040;

  class apb_drv;
    virtual apb_if v;
    int            n, errs;
    function new(virtual apb_if vi);
      v = vi;
      v.psel = 1'b0; v.penable = 1'b0; v.pwrite = 1'b0; v.paddr = '0; v.pwdata = '0;
      v.pstrb = 4'hF; v.pprot = 3'd0;
    endfunction
    task xfer(bit wr, bit [11:0] a, bit [31:0] d, output bit [31:0] rd);
      int w = 0;
      @(negedge v.pclk);
      v.psel = 1'b1; v.penable = 1'b0; v.pwrite = wr; v.paddr = {4'd0, a}; v.pwdata = d;
      @(negedge v.pclk);
      v.penable = 1'b1;
      while (v.pready !== 1'b1) begin
        @(negedge v.pclk);
        if (++w > 100) $fatal(1, "[NAND] APB hang at %h", a);
      end
      rd = v.prdata;
      if (v.pslverr) begin
        errs++;
        $display("[NAND] ERROR at %0t: PSLVERR at %h", $time, a);
      end
      @(negedge v.pclk);
      v.psel = 1'b0; v.penable = 1'b0; v.pwrite = 1'b0;
      n++;
    endtask
  endclass

  // Firmware operations on the channel registers
  class fw_c;
    apb_drv a;
    int     errs;
    function new(apb_drv aa);
      a = aa;
    endfunction
    function void bad(string s);
      errs++;
      $display("[NAND] ERROR at %0t: %s", $time, s);
    endfunction
    task wr(bit [11:0] r, bit [31:0] d);
      bit [31:0] x;
      a.xfer(1'b1, r, d, x);
    endtask
    task rd(bit [11:0] r, output bit [31:0] d);
      a.xfer(1'b0, r, 32'd0, d);
    endtask
    task submit(bit [2:0] op, int row, int col, int len, int off, bit [7:0] tag);
      wr(R_ROW, 32'(row));
      wr(R_COL, 32'(col));
      wr(R_LEN, 32'(len));
      wr(R_BUF, 32'(off));
      wr(R_GO, {16'd0, tag, 5'd0, op});
    endtask
    // The next completion: polls CPL (a read takes it) until one is there.
    task take(output bit [31:0] c, input int limit = 400000);
      int n = 0;
      do begin
        rd(R_CPL, c);
        if (!c[31] && ++n > limit) begin bad("no completion"); return; end
      end while (!c[31]);
    endtask
    task expect_cpl(bit [7:0] tag, bit [1:0] code, output bit [7:0] st);
      bit [31:0] c;
      take(c);
      st = c[23:16];
      if (c[7:0] != tag || c[9:8] != code)
        bad($sformatf("completion tag %h code %0d, expected tag %h code %0d", c[7:0], c[9:8], tag, code));
    endtask
    task run(bit [2:0] op, int row, int col, int len, int off, bit [1:0] code, output bit [7:0] st);
      submit(op, row, col, len, off, 8'(op * 16 + 1));
      expect_cpl(8'(op * 16 + 1), code, st);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Page buffer (bus-master role)
  // ---------------------------------------------------------------------------
  class pb_c;
    virtual axi4_if v;
    int             errs;
    int             rgap;              // percent of clocks with RREADY low
    function new(virtual axi4_if vi);
      v = vi;
      v.awvalid = 1'b0; v.wvalid = 1'b0; v.bready = 1'b0; v.arvalid = 1'b0; v.rready = 1'b0;
      v.awid = '0; v.arid = '0; v.awsize = 3'd3; v.arsize = 3'd3; v.awburst = 2'b01; v.arburst = 2'b01;
      v.awprot = '0; v.arprot = '0; v.awcache = '0; v.arcache = '0; v.awqos = '0; v.arqos = '0;
      v.wlast = 1'b0; v.wstrb = '0; v.wdata = '0; v.awaddr = '0; v.araddr = '0; v.awlen = '0; v.arlen = '0;
    endfunction
    // Bytes d at byte offset off: bursts of up to 16 words, none across 4 KiB.
    task wr(int off, ref bit [7:0] d [], input int at = 0, input int n = -1);
      int i = 0, cnt;
      cnt = (n < 0) ? d.size() - at : n;
      while (i < cnt) begin
        int a = off + i, w0 = a / 8, nb, wend;
        wend = (off + cnt + 7) / 8;
        nb = wend - w0;
        if (nb > 16) nb = 16;
        if ((w0 % 512) + nb > 512) nb = 512 - (w0 % 512);
        // A handshake: VALID set at a falling edge, READY high there, taken at
        // the rising edge after it.
        @(negedge v.clk);
        v.awaddr = 32'(w0 * 8); v.awlen = 8'(nb - 1); v.awvalid = 1'b1;
        while (!v.awready) @(negedge v.clk);
        @(negedge v.clk);
        v.awvalid = 1'b0;
        for (int b = 0; b < nb; b++) begin
          bit [63:0] wd = '0;
          bit [7:0]  st = '0;
          for (int k = 0; k < 8; k++) begin
            int ba = (w0 + b) * 8 + k;
            if (ba >= off + i && ba < off + cnt) begin
              wd[8*k +: 8] = d[at + ba - off];
              st[k] = 1'b1;
            end
          end
          v.wdata = wd; v.wstrb = st; v.wlast = (b == nb - 1); v.wvalid = 1'b1;
          while (!v.wready) @(negedge v.clk);
          @(negedge v.clk);
        end
        v.wvalid = 1'b0; v.wlast = 1'b0;
        v.bready = 1'b1;
        while (!v.bvalid) @(negedge v.clk);
        if (v.bresp != 2'b00) begin errs++; $display("[NAND] ERROR: page buffer write BRESP %0d", v.bresp); end
        @(negedge v.clk);
        v.bready = 1'b0;
        i = (w0 + nb) * 8 - off;
      end
    endtask
    task rd(int off, int cnt, ref bit [7:0] d []);
      int i = 0;
      d = new[cnt];
      while (i < cnt) begin
        int a = off + i, w0 = a / 8, nb, wend, got = 0;
        wend = (off + cnt + 7) / 8;
        nb = wend - w0;
        if (nb > 16) nb = 16;
        if ((w0 % 512) + nb > 512) nb = 512 - (w0 % 512);
        @(negedge v.clk);
        v.araddr = 32'(w0 * 8); v.arlen = 8'(nb - 1); v.arvalid = 1'b1;
        while (!v.arready) @(negedge v.clk);
        @(negedge v.clk);
        v.arvalid = 1'b0;
        while (got < nb) begin
          // A beat moves at the rising edge after a falling edge that sees
          // RVALID and RREADY high.
          v.rready = (rgap == 0) || ($urandom_range(99) >= rgap);
          if (v.rvalid && v.rready) begin
            for (int k = 0; k < 8; k++) begin
              int ba = (w0 + got) * 8 + k;
              if (ba >= off && ba < off + cnt) d[ba - off] = v.rdata[8*k +: 8];
            end
            if (v.rlast != (got == nb - 1)) begin errs++; $display("[NAND] ERROR: RLAST"); end
            got++;
          end
          @(negedge v.clk);
        end
        v.rready = 1'b0;
        i = (w0 + nb) * 8 - off;
      end
    endtask
  endclass

  apb_drv apbd;
  fw_c    fw;
  pb_c    pb;

  // ---------------------------------------------------------------------------
  // Expected array, data patterns
  // ---------------------------------------------------------------------------
  typedef bit [7:0] page_t [];
  page_t exp_pg [int];

  // Factory bad blocks, as the testbench made them: 00h in the first spare
  // byte of the first and last page.
  bit tb_bad [int];
  function automatic void mark_bad(int blk);
    tb_bad[blk] = 1'b1;
    u_m.set_bad(blk);
  endfunction

  function automatic bit [7:0] exp_cell(int row, int col);
    if (tb_bad.exists(row / PAGES) && col == 4096 && (row % PAGES == 0 || row % PAGES == PAGES - 1)) return 8'h00;
    return exp_pg.exists(row) ? exp_pg[row][col] : 8'hFF;
  endfunction
  function automatic void exp_prog(int row, int col, input bit [7:0] d [], input int at, input int n);
    if (!exp_pg.exists(row)) begin
      exp_pg[row] = new[PBYTES];
      foreach (exp_pg[row][i]) exp_pg[row][i] = 8'hFF;
    end
    for (int i = 0; i < n; i++) exp_pg[row][col + i] &= d[at + i];
  endfunction
  function automatic void exp_erase(int row);
    for (int p = 0; p < PAGES; p++) exp_pg.delete((row / PAGES) * PAGES + p);
  endfunction

  // The model's array itself, after a program or an erase: the address
  // cycles must have reached the page meant.
  task automatic check_array(int row, int col, int len, string what);
    for (int i = col; i < col + len; i++) begin
      bit [7:0] m = u_m.arr.exists(row) ? u_m.arr[row][i] : 8'hFF;
      if (m !== exp_cell(row, i)) begin
        fail($sformatf("%s: model array row %0d column %0d: %h, expected %h", what, row, i, m, exp_cell(row, i)));
        break;
      end
    end
  endtask

  // Check bytes read from the buffer against the expected page, with the bits
  // the model's last read of the row flipped.
  task automatic check_read(int row, int col, int len, int off, string what);
    bit [7:0] d [];
    bit [7:0] fm [int];
    int       q [$];
    if (u_m.flip_log.exists(row)) q = u_m.flip_log[row];
    foreach (q[k]) fm[q[k] / 8] = (fm.exists(q[k] / 8) ? fm[q[k] / 8] : 8'h00) ^ (8'h01 << (q[k] % 8));
    pb.rd(off, len, d);
    for (int i = 0; i < len; i++) begin
      bit [7:0] e = exp_cell(row, col + i) ^ (fm.exists(col + i) ? fm[col + i] : 8'h00);
      if (d[i] !== e) begin
        fail($sformatf("%s: row %0d column %0d: %h, expected %h", what, row, col + i, d[i], e));
        break;
      end
    end
  endtask

  // Program len bytes of random data at row/col from buffer offset off.
  task automatic do_prog(int row, int col, int len, int off, bit [1:0] code = CODE_OK);
    bit [7:0] d [];
    bit [7:0] st;
    d = new[len];
    foreach (d[i]) d[i] = 8'($urandom);
    pb.wr(off, d);
    fw.run(OP_PROG, row, col, len, off, code, st);
    if (code == CODE_OK) exp_prog(row, col, d, 0, len);
    check_array(row, col, len, "program");
    cov_op(OP_PROG, code, col, len, off);
  endtask

  // A read into the buffer, with guard bytes before and after it that must
  // not change.
  task automatic do_read(int row, int col, int len, int off, string what);
    bit [7:0] st, g [], r [];
    g = new[8];
    foreach (g[i]) g[i] = 8'hC3 ^ 8'(i * 37 + off);
    if (off >= 8) pb.wr(off - 8, g);
    if (off + len + 8 <= 8192) pb.wr(off + len, g);
    fw.run(OP_READ, row, col, len, off, CODE_OK, st);
    check_read(row, col, len, off, what);
    if (off >= 8) begin
      pb.rd(off - 8, 8, r);
      foreach (g[i]) if (r[i] != g[i]) begin fail($sformatf("%s: guard byte before the data changed", what)); break; end
    end
    if (off + len + 8 <= 8192) begin
      pb.rd(off + len, 8, r);
      foreach (g[i]) if (r[i] != g[i]) begin fail($sformatf("%s: guard byte after the data changed", what)); break; end
    end
    cov_op(OP_READ, CODE_OK, col, len, off);
  endtask

  task automatic do_erase(int row, bit [1:0] code = CODE_OK);
    bit [7:0] st;
    fw.run(OP_ERASE, row, 0, 0, 0, code, st);
    if (code == CODE_OK) begin
      exp_erase(row);
      for (int p = 0; p < PAGES; p++)
        if (u_m.arr.exists((row / PAGES) * PAGES + p)) fail($sformatf("erase: page %0d of the block still programmed", p));
    end
    cov_op(OP_ERASE, code, 0, 0, 0);
  endtask

  // Timing: TIMING0/TIMING1 and the model's requirements together.
  int cur_twb = 12;
  task automatic set_timing(int twp, int twh, int trp, int treh, int twb, int twhr, int tadl, int trr);
    cur_twb = twb;
    fw.wr(R_T0, {16'd0, 4'(treh), 4'(trp), 4'(twh), 4'(twp)});
    fw.wr(R_T1, {2'd0, 6'(trr), 2'd0, 6'(tadl), 2'd0, 6'(twhr), 2'd0, 6'(twb)});
  endtask

  // Fast device requirements (a fast ONFI-style mode) or slow ones (mode 0).
  task automatic model_fast();
    u_m.tWP = 15; u_m.tWH = 10; u_m.tWC = 30; u_m.tRP = 15; u_m.tREH = 10; u_m.tRC = 30;
    u_m.tCLS = 10; u_m.tALS = 10; u_m.tDS = 10; u_m.tCS = 15; u_m.tCLH = 5; u_m.tALH = 5; u_m.tDH = 5;
    u_m.tWHR = 80; u_m.tADL = 70; u_m.tRR = 20; u_m.tREA = 16;
  endtask
  task automatic model_slow();
    u_m.tWP = 50; u_m.tWH = 30; u_m.tWC = 100; u_m.tRP = 50; u_m.tREH = 30; u_m.tRC = 100;
    u_m.tCLS = 50; u_m.tALS = 50; u_m.tDS = 40; u_m.tCS = 70; u_m.tCLH = 20; u_m.tALH = 20; u_m.tDH = 20;
    u_m.tWHR = 120; u_m.tADL = 200; u_m.tRR = 40; u_m.tREA = 40;
  endtask

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  int cv_op, cv_code, cv_len, cv_col, cv_off, cv_q, cv_t, cv_ev;

  covergroup cg_op;
    cp_op:   coverpoint cv_op   { bins reset = {0}; bins id = {1}; bins read = {2}; bins prog = {3};
                                  bins erase = {4}; bins status = {5}; bins rdcol = {6}; }
    cp_code: coverpoint cv_code { bins ok = {0}; bins fail = {1}; bins timeout = {2}; bins prot = {3}; }
  endgroup
  covergroup cg_data;
    cp_len: coverpoint cv_len { bins one = {1}; bins few = {[2:63]}; bins many = {[64:4095]};
                                bins page = {[4096:4319]}; bins full = {4320}; }
    cp_col: coverpoint cv_col { bins main = {0}; bins spare = {1}; bins across = {2}; }
    cp_off: coverpoint cv_off { bins aligned = {0}; bins unaligned = {1}; }
  endgroup
  covergroup cg_misc;
    cp_ev: coverpoint cv_ev { bins q4 = {0}; bins ovf = {1}; bins cq8 = {2}; bins irq_done = {3};
                              bins irq_err = {4}; bins soft_reset = {5}; bins fast = {6}; bins slow = {7};
                              bins mixed = {8}; bins violation = {9}; bins arb = {10}; }
  endgroup
  cg_op   cov_opg  = new();
  cg_data cov_dat  = new();
  cg_misc cov_misc = new();

  // The model's device behavior (step 3-2)
  int cv_loops, cv_pulses, cv_tr, cv_dev;
  covergroup cg_loops;
    cp_loops: coverpoint cv_loops { bins worn = {[1:9]}; bins l10 = {10}; bins l11 = {11}; bins l12 = {12};
                                    bins l13 = {13}; bins l14 = {14}; }
  endgroup
  covergroup cg_pulses;
    cp_pulses: coverpoint cv_pulses { bins p2 = {2}; bins p3 = {3}; bins p4 = {4}; bins p5 = {5}; bins p6 = {6}; }
  endgroup
  covergroup cg_tr;
    cp_tr: coverpoint cv_tr { bins t0 = {0}; bins t1 = {1}; bins t2 = {2}; bins t3 = {3}; bins t4 = {4}; }
  endgroup
  covergroup cg_dev;
    cp_dev: coverpoint cv_dev { bins wear_fail = {0}; bins worn_ops = {1}; bins abort_prog = {2};
                                bins abort_erase = {3}; bins abort_read = {4}; bins status_busy = {5};
                                bins rule_order = {6}; bins rule_nop = {7}; bins rule_bad = {8};
                                bins rule_unstable = {9}; bins err_rate = {10}; bins err_window = {11};
                                bins err_stuck = {12}; bins err_erased = {13}; bins err_rdcol = {14};
                                bins err_repeat = {15}; bins err_wear = {16}; bins marker = {17}; }
  endgroup
  cg_loops  cov_loopg  = new();
  cg_pulses cov_pulseg = new();
  cg_tr     cov_trg    = new();
  cg_dev    cov_devg   = new();
  function automatic void cov_loops(int v);  cv_loops = v;  cov_loopg.sample();  endfunction
  function automatic void cov_pulses(int v); cv_pulses = v; cov_pulseg.sample(); endfunction
  function automatic void cov_tr(int v);     cv_tr = v;     cov_trg.sample();    endfunction
  function automatic void cov_dev(int v);    cv_dev = v;    cov_devg.sample();   endfunction

  function automatic void cov_op(bit [2:0] op, bit [1:0] code, int col, int len, int off);
    cv_op = int'(op);
    cv_code = int'(code);
    cov_opg.sample();
    if (len > 0) begin
      cv_len = len;
      cv_col = (col >= 4096) ? 1 : (col + len > 4096) ? 2 : 0;
      cv_off = (off % 8 != 0) ? 1 : 0;
      cov_dat.sample();
    end
  endfunction
  function automatic void cov_ev(int e);
    cv_ev = e;
    cov_misc.sample();
  endfunction

  bit irq_done_seen, irq_err_seen;
  always @(posedge clk) begin
    if (irq_done && !irq_done_seen) begin irq_done_seen = 1'b1; cov_ev(3); end
    if (irq_err && !irq_err_seen) begin irq_err_seen = 1'b1; cov_ev(4); end
  end

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  task automatic expect_reg(bit [11:0] r, bit [31:0] mask, bit [31:0] want, string what);
    bit [31:0] v;
    fw.rd(r, v);
    if ((v & mask) != want) fail($sformatf("%s: %h, expected %h under %h", what, v, want, mask));
  endtask

  task automatic t_regs();
    expect_reg(R_CTRL, 32'h7, 32'h1, "CTRL at reset (write protect on)");
    expect_reg(R_STATUS, 32'hF703, 32'h0002, "STATUS at reset: idle, R/B# ready, queues empty");
    expect_reg(R_T0, 32'hFFFF, 32'h2323, "TIMING0 at reset");
    expect_reg(R_T1, 32'h3F3F_3F3F, 32'h020A_060C, "TIMING1 at reset");
    expect_reg(R_TOUT, 32'hFFFF, 32'h1000, "TIMEOUT at reset");
    expect_reg(R_CPL, 32'h8000_0000, 32'h0, "CPL empty at reset");
    fw.wr(R_T0, 32'hFFFF_FFFF);
    expect_reg(R_T0, 32'hFFFF_FFFF, 32'h0000_FFFF, "TIMING0 write mask");
    fw.wr(R_T1, 32'hFFFF_FFFF);
    expect_reg(R_T1, 32'hFFFF_FFFF, 32'h3F3F_3F3F, "TIMING1 write mask");
    fw.wr(R_ROW, 32'hFFFF_FFFF);
    expect_reg(R_ROW, 32'hFFFF_FFFF, 32'h00FF_FFFF, "CMD_ROW write mask");
    fw.wr(R_COL, 32'hFFFF_FFFF);
    expect_reg(R_COL, 32'hFFFF_FFFF, 32'h0000_1FFF, "CMD_COL write mask");
    fw.wr(R_EVENT, 32'h3);
    expect_reg(R_EVENT, 32'h3, 32'h0, "EVENT clear");
    // Back to the reset values.
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
    fw.wr(R_ROW, 0); fw.wr(R_COL, 0);
  endtask

  task automatic t_reset();
    bit [7:0]  st;
    bit [31:0] b;
    fw.wr(R_CTRL, 32'h0);                     // write protect off
    fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
    cov_op(OP_RESET, CODE_OK, 0, 0, 0);
    fw.rd(R_BUSY, b);
    // R/B# is low from tWB_DEV after FFh to tRST; the count starts after the
    // sequencer's tWB wait and ends two synchronizer clocks after R/B# rises.
    if (real'(b) < (u_m.tRST - 20.0 * nclk) / nclk || real'(b) > u_m.tRST / nclk + 5.0)
      fail($sformatf("BUSY_TIME %0d clocks for a %0.0f ns reset", b, u_m.tRST));
    if (u_m.n_reset != 1) fail($sformatf("model saw %0d resets", u_m.n_reset));
    fw.run(OP_STATUS, 0, 0, 0, 0, CODE_OK, st);
    cov_op(OP_STATUS, CODE_OK, 0, 0, 0);
    if (st != 8'hE0) fail($sformatf("status %h after reset, expected E0", st));
  endtask

  task automatic t_id();
    bit [7:0] st, d [];
    fw.run(OP_ID, 0, 0, 4, 0, CODE_OK, st);
    cov_op(OP_ID, CODE_OK, 0, 4, 0);
    pb.rd(0, 4, d);
    foreach (d[i]) if (d[i] != u_m.ID00[i]) fail($sformatf("ID byte %0d: %h", i, d[i]));
    fw.run(OP_ID, 0, 32, 4, 13, CODE_OK, st);
    cov_op(OP_ID, CODE_OK, 0, 4, 13);
    pb.rd(13, 4, d);
    if ({d[0], d[1], d[2], d[3]} != "ONFI") fail("ONFI signature");
  endtask

  task automatic t_rw();
    bit [7:0] st;
    do_erase(64);
    if (u_m.n_erase != 1) fail("erase not seen by the model");
    do_prog(64, 0, PBYTES, 0);                         // a whole page, spare included
    do_read(64, 0, PBYTES, 3840, "whole page");
    do_read(64, 4096, 224, 3, "spare area");
    do_read(64, 4000, 200, 1001, "across main and spare");
    do_read(64, 17, 1, 7, "one byte");
    do_read(64, 120, 4100, 2, "most of a page");
    // Change read column on the page just read.
    fw.run(OP_RDCOL, 0, 100, 50, 7936, CODE_OK, st);
    cov_op(OP_RDCOL, CODE_OK, 100, 50, 7936);
    check_read(64, 100, 50, 7936, "changed read column");
    // A partial program: only its bytes change.
    do_prog(65, 1000, 37, 5);
    do_read(65, 0, PBYTES, 0, "page after a partial program");
    // Bits only clear: a second program ANDs.
    do_prog(65, 1000, 37, 900);
    do_read(65, 990, 60, 2222, "page after a second program");
  endtask

  task automatic t_erase();
    do_prog(128, 0, 512, 0);
    do_prog(129, 2048, 512, 512);
    do_erase(130);                                     // the same block (rows 128 to 191)
    do_read(128, 0, 512, 0, "erased page");
    do_read(129, 2048, 512, 600, "erased page 2");
  endtask

  task automatic t_fail();
    bit [31:0] v;
    fw.wr(R_EVENT, 32'h3);
    fw.wr(R_CTRL, 32'h4);                              // IEN_ERR
    u_m.fail_prog = 1;
    do_prog(192, 0, 64, 0, CODE_FAIL);
    do_read(192, 0, 64, 64, "page after a failed program");
    expect_reg(R_EVENT, 32'h1, 32'h1, "EVENT.ERR after a failure");
    if (!irq_err) fail("no error interrupt");
    fw.wr(R_EVENT, 32'h1);
    if (irq_err) fail("error interrupt after EVENT cleared");
    do_prog(192, 0, 64, 0);
    u_m.fail_erase = 1;
    do_erase(192, CODE_FAIL);
    do_read(192, 0, 64, 64, "page after a failed erase");
    fw.rd(R_COUNT, v);
    if (v[31:16] != 16'd2) fail($sformatf("COUNT.ERR %0d", v[31:16]));
    fw.wr(R_EVENT, 32'h3);
    fw.wr(R_CTRL, 32'h0);
  endtask

  task automatic t_wp();
    bit [7:0] st;
    fw.wr(R_CTRL, 32'h1);
    repeat (10) @(negedge clk_nand);
    do_prog(256, 0, 128, 0, CODE_PROT);
    do_read(256, 0, 128, 128, "page after a protected program");
    do_erase(256, CODE_PROT);
    fw.run(OP_STATUS, 0, 0, 0, 0, CODE_OK, st);
    if (st[7]) fail("status bit 7 set with WP# low");
    fw.wr(R_CTRL, 32'h0);
    repeat (10) @(negedge clk_nand);
    do_prog(256, 0, 128, 0);
    do_read(256, 0, 128, 128, "page after protection was lifted");
    fw.wr(R_EVENT, 32'h3);
  endtask

  task automatic t_timeout();
    bit [7:0] st;
    fw.wr(R_TOUT, 32'd2);                              // 512 clocks
    u_m.stuck_busy = 1'b1;
    do_erase(320, CODE_TOUT);
    u_m.stuck_busy = 1'b0;
    fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
    cov_op(OP_RESET, CODE_OK, 0, 0, 0);
    fw.wr(R_TOUT, 32'h1000);
    do_erase(320);
    do_read(320, 0, 32, 0, "page after recovery");
    fw.wr(R_EVENT, 32'h3);
  endtask

  // Timing: the fastest setting against fast requirements, other settings,
  // and a fast setting against slow requirements, which the model must catch.
  longint fast_cyc;
  task automatic t_timing();
    bit [31:0] c;
    bit [7:0]  st;
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    cov_ev(6);
    do_erase(384);
    do_prog(384, 0, PBYTES, 0);
    fw.rd(R_CYC, c);
    fast_cyc = longint'(c);
    do_read(384, 0, PBYTES, 0, "fast timing");
    $display("[NAND] timing: program of %0d bytes in %0d clk_sys clocks with 1+1-clock cycles", PBYTES, fast_cyc);
    set_timing(2, 1, 2, 3, 8, 5, 4, 1);
    cov_ev(8);
    do_prog(385, 7, 999, 3);
    do_read(385, 0, 1100, 1, "mixed timing");
    model_slow();
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
    cov_ev(7);
    do_prog(386, 0, 300, 0);
    do_read(386, 0, 300, 400, "slow timing");
    // Too fast for the slow requirements: the model must object.
    begin
      int e0 = u_m.errors;
      u_m.quiet = 1'b1;
      set_timing(1, 1, 1, 1, 8, 5, 4, 1);
      fw.run(OP_STATUS, 0, 0, 0, 0, CODE_OK, st);
      u_m.quiet = 1'b0;
      if (u_m.errors == e0) fail("fast cycles not caught against slow requirements");
      else cov_ev(9);
      u_m.errors = e0;                                 // expected violations
    end
    model_fast();
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // Queues: 4 commands waiting behind a running one and a fifth dropped; then
  // 8 completions waiting, which holds back the next command; the done
  // interrupt while one waits.
  task automatic t_queue();
    bit [31:0] v, c;
    int        n;
    fw.wr(R_EVENT, 32'h3);
    fw.wr(R_CTRL, 32'h6);                              // both interrupts
    fw.submit(OP_ERASE, 448, 0, 0, 0, 8'h40);          // runs for tBERS
    for (int i = 0; i < 4; i++) fw.submit(OP_STATUS, 0, 0, 0, 0, 8'h41 + 8'(i));
    expect_reg(R_STATUS, 32'h0701, 32'h0401, "4 commands waiting behind a running one");
    cov_ev(0);
    fw.submit(OP_STATUS, 0, 0, 0, 0, 8'h4F);           // dropped
    expect_reg(R_EVENT, 32'h2, 32'h2, "EVENT.OVF");
    cov_ev(1);
    fw.wr(R_EVENT, 32'h2);
    // Once the queue is empty, 3 more: 8 completions in all, then a ninth
    // that must wait for room.
    n = 0;
    do begin fw.rd(R_STATUS, v); n++; end while (v[10:8] != 3'd0 && n < 100000);
    for (int i = 0; i < 3; i++) fw.submit(OP_STATUS, 0, 0, 0, 0, 8'h45 + 8'(i));
    n = 0;
    do begin fw.rd(R_STATUS, v); n++; end while ((v[15:12] != 4'd8 || v[0]) && n < 100000);
    if (v[15:12] != 4'd8) fail($sformatf("STATUS %h: 8 completions never waited", v));
    else cov_ev(2);
    fw.submit(OP_STATUS, 0, 0, 0, 0, 8'h48);
    repeat (200) @(negedge clk);
    expect_reg(R_STATUS, 32'hF701, 32'h8100, "a command held back by 8 waiting completions");
    if (!irq_done) fail("no done interrupt with completions waiting");
    for (int i = 0; i < 9; i++) begin
      fw.take(c);
      if (c[7:0] != 8'h40 + 8'(i)) fail($sformatf("completion %0d: tag %h", i, c[7:0]));
      cov_op((i == 0) ? OP_ERASE : OP_STATUS, CODE_OK, 0, 0, 0);
    end
    repeat (5) @(negedge clk);
    if (irq_done) fail("done interrupt with no completion waiting");
    fw.wr(R_CTRL, 32'h0);
    exp_erase(448);
  endtask

  // The page buffer's bus port while the channel streams: other bytes of the
  // buffer written and read back the whole time a page is programmed and
  // read back.
  task automatic t_arb();
    bit       done = 1'b0;
    int       rounds = 0;
    bit [7:0] d [], st;
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    do_erase(512);
    d = new[PBYTES];
    foreach (d[i]) d[i] = 8'($urandom);
    pb.wr(0, d);
    pb.rgap = 30;
    fork
      begin
        fw.run(OP_PROG, 512, 0, PBYTES, 0, CODE_OK, st);
        fw.run(OP_READ, 512, 0, PBYTES, 1, CODE_OK, st);
        done = 1'b1;
      end
      begin
        bit [7:0] w [], r [];
        while (!done) begin
          int o = 6000 + 8 * $urandom_range(200), n = $urandom_range(400, 1);
          w = new[n];
          foreach (w[i]) w[i] = 8'($urandom);
          pb.wr(o, w);
          pb.rd(o, n, r);
          foreach (w[i]) if (r[i] != w[i]) begin fail("bus-port data while streaming"); break; end
          rounds++;
        end
      end
    join
    pb.rgap = 0;
    exp_prog(512, 0, d, 0, PBYTES);
    cov_op(OP_PROG, CODE_OK, 0, PBYTES, 0);
    cov_op(OP_READ, CODE_OK, 0, PBYTES, 1);
    check_read(512, 0, PBYTES, 1, "page read while the bus port was busy");
    if (rounds < 3) fail($sformatf("only %0d bus-port rounds during streaming", rounds));
    else cov_ev(10);
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // A channel reset in the middle of a program, both clock domains, as
  // SYS.SOFT_RESET does in the SoC.
  task automatic t_softreset();
    bit [7:0] d [];
    d = new[PBYTES];
    foreach (d[i]) d[i] = 8'($urandom);
    pb.wr(0, d);
    fw.submit(OP_PROG, 576, 0, PBYTES, 0, 8'h77);
    while (we_n || cle || ale) @(negedge clk_nand);     // data cycles are running
    repeat (200) @(negedge clk_nand);
    rst_n = 1'b0;
    rst_nand_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk_nand);
    rst_nand_n = 1'b1;
    cov_ev(5);
    expect_reg(R_STATUS, 32'hF701, 32'h0, "STATUS after the channel reset");
    expect_reg(R_CTRL, 32'h7, 32'h1, "CTRL after the channel reset");
    if (ce_n !== 1'b1 || we_n !== 1'b1 || dq_oe !== 1'b0) fail("bus not idle after the channel reset");
    begin
      bit [7:0] st;
      fw.wr(R_CTRL, 32'h0);
      fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
      cov_op(OP_RESET, CODE_OK, 0, 0, 0);
    end
    // The interrupted program left the page untouched in the model.
    do_read(576, 0, 64, 0, "page after an interrupted program");
  endtask

  // Random: operations on a few blocks, random columns, lengths, buffer
  // offsets and timing, several commands queued at a time.
  int rnd_profile, rnd_ppm;
  task automatic t_random(int ncmd);
    int      issued = 0;
    int      tsets [3][8] = '{'{1, 1, 1, 1, 8, 5, 4, 1}, '{2, 1, 2, 1, 9, 6, 5, 2}, '{1, 2, 1, 2, 8, 5, 4, 1}};
    model_fast();
    fw.wr(R_CTRL, 32'h0);
    // Pages here are programmed in no order and many times over: the program
    // rules are firmware's (t_rules), not the controller's.
    u_m.rules   = 1'b0;
    u_m.profile = rnd_profile[0];
    u_m.rber    = real'(rnd_ppm) * 1.0e-6;
    while (issued < ncmd) begin
      int        t = $urandom_range(2);
      int        nq = $urandom_range(4, 1);
      int        row [4], col [4], len [4], off [4];
      bit [2:0]  op [4];
      bit [7:0]  d [4][];
      bit [31:0] c;
      set_timing(tsets[t][0], tsets[t][1], tsets[t][2], tsets[t][3], tsets[t][4], tsets[t][5],
                 tsets[t][6], tsets[t][7]);
      // Commands on distinct pages, with buffer regions that do not overlap,
      // so that their order among themselves does not matter.
      for (int i = 0; i < nq; i++) begin
        int r = $urandom_range(99);
        row[i] = 640 + 64 * $urandom_range(3) + 16 * i + $urandom_range(15);
        len[i] = ($urandom_range(3) == 0) ? $urandom_range(PBYTES, 1) : $urandom_range(512, 1);
        if (len[i] > 2048) len[i] = $urandom_range(2048, 1);
        col[i] = $urandom_range(PBYTES - len[i]);
        off[i] = 2048 * i + $urandom_range(2048 - len[i]);
        op[i]  = (r < 40) ? OP_READ : (r < 75) ? OP_PROG : (r < 82) ? OP_ERASE : (r < 92) ? OP_STATUS : OP_RDCOL;
        if (op[i] == OP_ERASE) begin
          // Erase only when no other command of this batch is in its block.
          for (int j = 0; j < i; j++) if (row[j] / PAGES == row[i] / PAGES) op[i] = OP_STATUS;
        end
        if (op[i] == OP_RDCOL && i == 0) op[i] = OP_READ;
        if (op[i] == OP_RDCOL) begin
          // A changed column reads the page register: the previous command
          // must be a read of the same page.
          if (op[i - 1] != OP_READ) op[i] = OP_STATUS;
          else row[i] = row[i - 1];
        end
        if (op[i] != OP_RDCOL && op[i] != OP_ERASE)
          for (int j = 0; j < i; j++)
            if (row[j] / PAGES == row[i] / PAGES && op[j] == OP_ERASE) op[i] = OP_STATUS;
        if (op[i] == OP_PROG) begin
          d[i] = new[len[i]];
          foreach (d[i][k]) d[i][k] = 8'($urandom);
          pb.wr(off[i], d[i]);
        end
      end
      for (int i = 0; i < nq; i++) fw.submit(op[i], row[i], col[i], len[i], off[i], 8'(issued + i));
      for (int i = 0; i < nq; i++) begin
        fw.take(c);
        if (c[7:0] != 8'(issued + i) || c[9:8] != CODE_OK)
          fail($sformatf("random: completion tag %h code %0d, expected %h", c[7:0], c[9:8], 8'(issued + i)));
        case (op[i])
          OP_PROG: begin
            exp_prog(row[i], col[i], d[i], 0, len[i]);
            check_array(row[i], col[i], len[i], "random program");
          end
          OP_ERASE: exp_erase(row[i]);
          default:  ;
        endcase
        cov_op(op[i], CODE_OK, col[i], (op[i] == OP_READ || op[i] == OP_PROG || op[i] == OP_RDCOL) ? len[i] : 0, off[i]);
      end
      for (int i = 0; i < nq; i++)
        if (op[i] == OP_READ || op[i] == OP_RDCOL) check_read(row[i], col[i], len[i], off[i], "random read");
      issued += nq;
    end
    u_m.rules   = 1'b1;
    u_m.profile = 1'b0;
    u_m.rber    = 0.0;
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // ---------------------------------------------------------------------------
  // Device behavior (step 3-2, docs/16_nand_model.md)
  // ---------------------------------------------------------------------------
  // BUSY_TIME of the last command against the model's busy time for it: the
  // count runs from the end of the sequencer's tWB wait to R/B# seen ready,
  // which comes out at the operation's time in clocks less tWB less 1.
  int busy_lo = 99, busy_hi = -99;
  task automatic check_busy(string what);
    bit [31:0] b;
    int        d;
    fw.rd(R_BUSY, b);
    d = int'(b) - (int'(u_m.last_len / nclk) - cur_twb - 1);
    if (d < busy_lo) busy_lo = d;
    if (d > busy_hi) busy_hi = d;
    if (d < -1 || d > 1) fail($sformatf("%s: BUSY_TIME %0d clocks for a %0.0f ns operation", what, b, u_m.last_len));
  endtask

  // Expected rule violations: exactly n between rules_begin and rules_end,
  // and no other error of the model.
  int rule_mark, err_mark;
  task automatic rules_begin();
    rule_mark   = u_m.rule_errs;
    err_mark    = u_m.errors;
    u_m.quiet   = 1'b1;
  endtask
  task automatic rules_end(int n, string what);
    u_m.quiet = 1'b0;
    if (u_m.rule_errs - rule_mark != n || u_m.errors - err_mark != n)
      fail($sformatf("%s: %0d rule violations and %0d model errors, expected %0d", what,
                     u_m.rule_errs - rule_mark, u_m.errors - err_mark, n));
    u_m.errors = err_mark;
  endtask

  // The flips of the last read of a row: the model's log, and as a string.
  typedef int iq_t [$];
  function automatic iq_t flips(int row);
    iq_t q;
    if (u_m.flip_log.exists(row)) q = u_m.flip_log[row];
    return q;
  endfunction
  function automatic string flips_of(int row);
    string s = "";
    iq_t   q = flips(row);
    foreach (q[k]) s = {s, $sformatf("%0d,", q[k])};
    return s;
  endfunction
  function automatic bit near(real a, real b);
    return (a - b < 0.01) && (b - a < 0.01);
  endfunction
  function automatic int nflips(int row);
    return u_m.flip_log.exists(row) ? u_m.flip_log[row].size() : 0;
  endfunction

  // Busy times drawn per operation: each program's loops, each erase's pulses
  // and each read's tR in the range its block's wear allows, the busy time
  // the formula gives, and BUSY_TIME in agreement; worn cells program faster
  // and erase slower.
  task automatic t_busy();
    int sum_l [3], np [3];
    int wears [3] = '{0, 1500, 2988};
    bit [4:0] seen_l [3];                            // loops lo to lo + 4 of each block
    bit [6:0] seen_p = '0;                           // erase pulses
    bit [4:0] seen_r = '0;                           // the five read times
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    u_m.profile = 1'b1;
    for (int b = 0; b < 3; b++) begin
      int blk = 20 + b;
      sum_l[b] = 0;
      np[b] = 0;
      seen_l[b] = '0;
      u_m.pe[blk] = wears[b];
      for (int e = 0; e < 12; e++) begin
        int w  = u_m.pe[blk];
        int lo = u_m.erase_pulses + (3 * w) / u_m.endurance;
        int hi = u_m.erase_pulses + (3 * w + 2 * u_m.endurance - 1) / u_m.endurance;
        do_erase(blk * PAGES);
        check_busy("erase");
        cov_pulses(u_m.last_pulses);
        if (u_m.last_pulses < lo || u_m.last_pulses > hi)
          fail($sformatf("erase at %0d P/E cycles: %0d pulses, expected %0d to %0d", w, u_m.last_pulses, lo, hi));
        else seen_p[u_m.last_pulses] = 1'b1;
        if (!near(u_m.last_len, u_m.tBERS_PULSE * real'(u_m.last_pulses)))
          fail($sformatf("erase of %0d pulses took %0.0f ns", u_m.last_pulses, u_m.last_len));
      end
      for (int p = 0; p < 32; p++) begin
        int lo = u_m.prog_loops - (3 * u_m.pe[blk]) / u_m.endurance;
        do_prog(blk * PAGES + p, 8 * p, 16, 8 * p);
        check_busy("program");
        cov_loops(u_m.last_loops);
        if (u_m.last_loops < lo || u_m.last_loops > lo + 4)
          fail($sformatf("program at %0d P/E cycles: %0d loops, expected %0d to %0d", u_m.pe[blk], u_m.last_loops, lo, lo + 4));
        else seen_l[b][u_m.last_loops - lo] = 1'b1;
        if (!near(u_m.last_len, u_m.tPROG_BASE + u_m.tPROG_LOOP * real'(u_m.last_loops)))
          fail($sformatf("program of %0d loops took %0.0f ns", u_m.last_loops, u_m.last_len));
        sum_l[b] += u_m.last_loops;
        np[b]++;
      end
      for (int p = 0; p < 10; p++) begin
        real k;
        do_read(blk * PAGES + p, 8 * p, 16, 640 + 32 * p, "read in t_busy");
        check_busy("read");
        k = (u_m.last_len - u_m.tR_BASE) / u_m.tR_STEP;
        if (k < -0.01 || k > 4.01 || !near(k, real'(int'(k)))) fail($sformatf("read took %0.0f ns", u_m.last_len));
        else begin
          cov_tr(int'(k));
          seen_r[int'(k)] = 1'b1;
        end
      end
      if (seen_l[b] != 5'b11111) fail($sformatf("block %0d: program loops seen %b of 5", blk, seen_l[b]));
    end
    // Every value of each distribution drawn at least once.
    if (seen_p[6:2] != 5'b11111) fail($sformatf("erase pulses seen %b of 2 to 6", seen_p[6:2]));
    if (seen_r != 5'b11111) fail($sformatf("read times seen %b of 5", seen_r));
    // Three loops fewer on average at the rated endurance.
    if (sum_l[0] - sum_l[2] < 2 * np[0] || sum_l[0] - sum_l[2] > 4 * np[0])
      fail($sformatf("program loops: %0d over 32 programs fresh, %0d at endurance", sum_l[0], sum_l[2]));
    $display("[NAND] busy: tPROG %0.0f to %0.0f ns, tBERS %0.0f to %0.0f ns, tR %0.0f to %0.0f ns; BUSY_TIME within %0d to %0d clocks of the model",
             u_m.t_min[2], u_m.t_max[2], u_m.t_min[3], u_m.t_max[3], u_m.t_min[1], u_m.t_max[1], busy_lo, busy_hi);
    $display("[NAND] busy: program loops %0.2f on average on the fresh block, %0.2f at the rated endurance",
             real'(sum_l[0]) / real'(np[0]), real'(sum_l[2]) / real'(np[2]));
    u_m.profile = 1'b0;
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // Wear: no erase fails up to the rated endurance; past 5/3 of it every one
  // does, after erase_max pulses, and the block is worn out; in between some
  // do, and the first failure ends the block. Every erase counts a cycle.
  task automatic t_wear();
    bit [31:0] c;
    int        n = 0, pe0;
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    u_m.profile = 1'b1;
    u_m.pe[23] = u_m.endurance - 12;
    for (int e = 0; e < 12; e++) do_erase(23 * PAGES);
    if (u_m.pe[23] != u_m.endurance) fail($sformatf("P/E cycles %0d after 12 erases", u_m.pe[23]));
    u_m.pe[24] = 5 * u_m.endurance / 3;
    do_erase(24 * PAGES, CODE_FAIL);
    check_busy("erase failing for wear");
    if (u_m.last_pulses != u_m.erase_max || !u_m.worn[24]) fail("an erase past 5/3 of endurance did not wear the block out");
    else cov_dev(0);
    do_prog(24 * PAGES, 0, 16, 0, CODE_FAIL);
    do_erase(24 * PAGES, CODE_FAIL);
    if (u_m.n_wear_fail != 1) fail($sformatf("%0d erases failed for wear, expected 1", u_m.n_wear_fail));
    else cov_dev(1);
    u_m.pe[25] = 4 * u_m.endurance / 3;
    pe0 = u_m.pe[25];
    do begin
      fw.submit(OP_ERASE, 25 * PAGES, 0, 0, 0, 8'h5A);
      fw.take(c);
      n++;
      if (u_m.n_wear_fail == 2) begin
        if (c[9:8] != CODE_FAIL) fail("an erase that ran out of pulses did not fail");
      end else begin
        if (c[9:8] != CODE_OK) fail($sformatf("erase at %0d cycles: code %0d", u_m.pe[25], c[9:8]));
        exp_erase(25 * PAGES);
      end
    end while (u_m.n_wear_fail == 1 && n < 40);
    if (u_m.n_wear_fail != 2) fail("no erase failed at 4/3 of endurance in 40");
    if (u_m.pe[25] != pe0 + n) fail($sformatf("P/E cycles %0d after %0d erases from %0d", u_m.pe[25], n, pe0));
    $display("[NAND] wear: the first failing erase at %0d cycles of %0d rated came after %0d erases", pe0 + n, u_m.endurance, n);
    u_m.profile = 1'b0;
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // A reset that stops a program, an erase and a read (after a busy
  // timeout): the program has cleared each of its 0 bits with the chance of
  // how far it went, the erase has set the block's 0 bits the same way and
  // the block takes no program until erased again, the read leaves no page
  // to change the column of; status while busy is not ready, and each reset
  // takes the time of what it stopped.
  task automatic fraction(int row, page_t was, page_t now, bit erase, output real fr);
    int all = 0, moved = 0;
    for (int i = 0; i < PBYTES; i++) begin
      // A program only clears bits, an erase only sets them: the bits that
      // were 1 before are 1 after either.
      if ((now[i] & was[i]) != was[i]) begin
        fail($sformatf("row %0d column %0d: %h, %h before", row, i, now[i], was[i]));
        break;
      end
      for (int k = 0; k < 8; k++)
        if (!was[i][k]) begin
          all++;
          if (now[i][k] == erase) moved++;
        end
    end
    fr = (all == 0) ? 0.0 : real'(moved) / real'(all);
  endtask

  task automatic t_abort();
    bit [7:0] st;
    page_t    d, r, old [4];
    real      fr;
    int       row;
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    u_m.profile = 1'b1;
    // Program
    row = 26 * PAGES;
    do_erase(row);
    d = new[PBYTES];
    foreach (d[i]) d[i] = 8'($urandom);
    pb.wr(0, d);
    fw.wr(R_TOUT, 32'd1);
    fw.run(OP_PROG, row, 0, PBYTES, 0, CODE_TOUT, st);
    fw.run(OP_STATUS, 0, 0, 0, 0, CODE_OK, st);
    if (st[6:5] != 2'b00) fail($sformatf("status %h while busy", st));
    else cov_dev(5);
    fw.wr(R_TOUT, 32'h1000);
    fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
    check_busy("reset stopping a program");
    if (u_m.abort_kind != 2 || !near(u_m.last_len, u_m.tRST_P)) fail("reset stopping a program");
    fw.run(OP_READ, row, 0, PBYTES, 0, CODE_OK, st);
    pb.rd(0, PBYTES, r);
    fraction(row, d, r, 1'b0, fr);
    if (fr < u_m.abort_f - 0.03 || fr > u_m.abort_f + 0.03)
      fail($sformatf("stopped program: %0.3f of its 0 bits written, %0.3f of the way through", fr, u_m.abort_f));
    else cov_dev(2);
    $display("[NAND] abort: a program stopped %0.3f of the way through had written %0.3f of its 0 bits", u_m.abort_f, fr);
    exp_pg[row] = new[PBYTES];
    foreach (r[i]) exp_pg[row][i] = r[i];
    check_array(row, 0, PBYTES, "stopped program");
    // Programmed again, a partial program finishes the page.
    pb.wr(0, d);
    fw.run(OP_PROG, row, 0, PBYTES, 0, CODE_OK, st);
    exp_prog(row, 0, d, 0, PBYTES);
    do_read(row, 0, PBYTES, 0, "page programmed again");
    // Erase
    row = 27 * PAGES;
    do_erase(row);
    for (int p = 0; p < 4; p++) begin
      do_prog(row + p, 0, PBYTES, 0);
      old[p] = new[PBYTES];
      foreach (old[p][i]) old[p][i] = exp_cell(row + p, i);
    end
    fw.wr(R_TOUT, 32'd2);
    fw.run(OP_ERASE, row, 0, 0, 0, CODE_TOUT, st);
    fw.wr(R_TOUT, 32'h1000);
    fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
    check_busy("reset stopping an erase");
    if (u_m.abort_kind != 3 || !near(u_m.last_len, u_m.tRST_E)) fail("reset stopping an erase");
    for (int p = 0; p < 4; p++) begin
      fw.run(OP_READ, row + p, 0, PBYTES, 0, CODE_OK, st);
      pb.rd(0, PBYTES, r);
      fraction(row + p, old[p], r, 1'b1, fr);
      if (fr < u_m.abort_f - 0.03 || fr > u_m.abort_f + 0.03)
        fail($sformatf("stopped erase: %0.3f of the 0 bits of page %0d set, %0.3f of the way through", fr, p, u_m.abort_f));
      exp_pg[row + p] = new[PBYTES];
      foreach (r[i]) exp_pg[row + p][i] = r[i];
    end
    $display("[NAND] abort: an erase stopped %0.3f of the way through had set %0.3f of the 0 bits of its last page", u_m.abort_f, fr);
    cov_dev(3);
    rules_begin();
    do_prog(row + 4, 0, 16, 0);
    rules_end(1, "program in a block whose erase was stopped");
    cov_dev(9);
    do_erase(row);
    rules_begin();
    do_prog(row, 0, 16, 0);
    rules_end(0, "program after the block was erased again");
    // Read
    u_m.stuck_busy = 1'b1;
    fw.wr(R_TOUT, 32'd1);
    fw.run(OP_READ, row, 0, 16, 0, CODE_TOUT, st);
    fw.wr(R_TOUT, 32'h1000);
    fw.run(OP_RESET, 0, 0, 0, 0, CODE_OK, st);
    u_m.stuck_busy = 1'b0;
    if (u_m.abort_kind != 1 || !near(u_m.last_len, u_m.tRST_R)) fail("reset stopping a read");
    else cov_dev(4);
    rules_begin();
    fw.run(OP_RDCOL, 0, 0, 16, 0, CODE_OK, st);
    u_m.quiet = 1'b0;
    if (u_m.errors == err_mark) fail("change read column after a stopped read not caught");
    u_m.errors = err_mark;
    u_m.profile = 1'b0;
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // The rules a program must keep, each caught by the model; factory bad
  // blocks.
  task automatic t_rules();
    bit [7:0] d [];
    int       row = 28 * PAGES;
    do_erase(row);
    rules_begin();
    do_prog(row + 5, 0, 16, 0);
    rules_end(0, "page 5 of an erased block");
    rules_begin();
    do_prog(row + 3, 0, 16, 0);
    rules_end(1, "page 3 after page 5");
    cov_dev(6);
    rules_begin();
    do_prog(row + 5, 100, 16, 0);
    do_prog(row + 6, 0, 16, 0);
    for (int i = 1; i < 4; i++) do_prog(row + 6, 32 * i, 16, 0);
    rules_end(0, "partial programs up to NOP");
    rules_begin();
    do_prog(row + 6, 200, 16, 0);
    rules_end(1, "a program beyond NOP");
    cov_dev(7);
    // A factory bad block: the marker in the first spare byte of its first
    // and last pages, its program and erase failing and caught.
    row = 29 * PAGES;
    mark_bad(29);
    do_read(row, 4096, 1, 0, "bad-block marker, first page");
    pb.rd(0, 1, d);
    if (d[0] != 8'h00) fail("no bad-block marker");
    else cov_dev(17);
    do_read(row + PAGES - 1, 4090, 8, 16, "bad-block marker, last page");
    do_read(row + 1, 4096, 1, 32, "no marker on the second page");
    rules_begin();
    do_erase(row, CODE_FAIL);
    do_prog(row + 2, 0, 16, 0, CODE_FAIL);
    rules_end(2, "erase and program of a factory bad block");
    cov_dev(8);
    do_read(row, 4096, 1, 0, "bad-block marker after the erase");
  endtask

  // Bit errors on reads: the data read is the array with exactly the bits
  // the model logs flipped (check_read); a rate gives the count it should,
  // reads of erased pages included; a second read flips other bits, and a
  // read with the same count again the same ones; a change of read column
  // sees the bits of the read; windows give exact counts; stuck bits read
  // their value; worn blocks give more errors.
  task automatic t_biterr();
    bit [7:0] st, d1 [], d2 [];
    int       row = 30 * PAGES, total = 0, reads = 0;
    real      mu;
    string    f1, f2;
    model_fast();
    set_timing(1, 1, 1, 1, 8, 5, 4, 1);
    do_erase(row);
    for (int p = 0; p < 12; p++) do_prog(row + p, 0, PBYTES, 0);
    u_m.rber = 1.0e-3;
    for (int p = 0; p < 16; p++) begin               // 12 programmed pages, 4 erased
      do_read(row + p, 0, PBYTES, 0, "rate errors, first read");
      f1 = flips_of(row + p);
      total += nflips(row + p);
      do_read(row + p, 0, PBYTES, 0, "rate errors, second read");
      f2 = flips_of(row + p);
      total += nflips(row + p);
      reads += 2;
      if (f1 == f2) fail($sformatf("row %0d: the same bits flipped in two reads", row + p));
      if (p >= 12 && nflips(row + p) > 0) cov_dev(13);
    end
    mu = real'(reads) * real'(PBYTES * 8) * u_m.rber;
    if (real'(total) < mu - 5.0 * $sqrt(mu) || real'(total) > mu + 5.0 * $sqrt(mu))
      fail($sformatf("%0d bits flipped in %0d reads at %e, expected %0.1f", total, reads, u_m.rber, mu));
    else cov_dev(10);
    $display("[NAND] bit errors: %0d in %0d page reads at a rate of %0.0e (expected %0.1f)", total, reads, u_m.rber, mu);
    // The same read count again gives the same bits.
    f1 = flips_of(row + 1);
    u_m.rd_cnt[row + 1] = u_m.rd_cnt[row + 1] - 1;
    do_read(row + 1, 0, PBYTES, 0, "a read repeated");
    if (flips_of(row + 1) != f1) fail("a read with the same count flipped other bits");
    else cov_dev(15);
    // Change read column: the page register's bits.
    do_read(row + 2, 0, PBYTES, 0, "before a change of column");
    pb.rd(0, PBYTES, d1);
    fw.run(OP_RDCOL, 0, 1000, 2000, 5000, CODE_OK, st);
    check_read(row + 2, 1000, 2000, 5000, "changed column with bit errors");
    pb.rd(5000, 2000, d2);
    foreach (d2[i]) if (d2[i] != d1[1000 + i]) begin fail("changed column read other bits"); break; end
    if (nflips(row + 2) > 0) cov_dev(14);
    u_m.rber = 0.0;
    // Windows: exactly 0, 1, 9 and 24 bits in four parts of the page.
    u_m.win_n = 4;
    for (int w = 0; w < 4; w++) begin
      u_m.win_start[w] = 1080 * w;
      u_m.win_len[w] = 1080;
    end
    u_m.win_cnt[0] = 0; u_m.win_cnt[1] = 1; u_m.win_cnt[2] = 9; u_m.win_cnt[3] = 24;
    for (int p = 3; p < 7; p++) begin
      int  cnt [4] = '{0, 0, 0, 0};
      iq_t q;
      do_read(row + p, 0, PBYTES, 0, "window errors");
      q = flips(row + p);
      foreach (q[k]) cnt[q[k] / (1080 * 8)]++;
      for (int w = 0; w < 4; w++)
        if (cnt[w] != u_m.win_cnt[w]) fail($sformatf("window %0d: %0d bits flipped, expected %0d", w, cnt[w], u_m.win_cnt[w]));
    end
    cov_dev(11);
    u_m.win_n = 0;
    // Stuck bits: on an erased page a bit stuck at 0 reads 0; on data, a bit
    // stuck at the value it holds is no error.
    begin
      int b0 = 8 * 777 + 3, b1 = -1, b2 = -1;
      for (int i = 0; i < PBYTES * 8 && (b1 < 0 || b2 < 0); i++) begin
        bit [7:0] v = exp_cell(row + 7, i / 8);
        if (!v[i % 8] && b1 < 0 && i > 8000) b1 = i;
        if (v[i % 8] && b2 < 0 && i > 9000) b2 = i;
      end
      u_m.add_stuck(row + 13, b0, 1'b0);
      u_m.add_stuck(row + 7, b1, 1'b1);
      u_m.add_stuck(row + 7, b2, 1'b1);
      do_read(row + 13, 0, PBYTES, 0, "stuck bit on an erased page");
      if (flips_of(row + 13) != $sformatf("%0d,", b0)) fail($sformatf("stuck bit on an erased page: flips %s", flips_of(row + 13)));
      do_read(row + 7, 0, PBYTES, 0, "stuck bits on data");
      if (flips_of(row + 7) != $sformatf("%0d,", b1)) fail($sformatf("stuck bits on data: flips %s, expected %0d", flips_of(row + 7), b1));
      else cov_dev(12);
      u_m.stuck.delete();
    end
    // Wear: at the rated endurance, ten times the rate.
    begin
      int fresh = 0, worn = 0;
      u_m.rber = 2.0e-4;
      u_m.pe[31] = u_m.endurance;
      for (int p = 0; p < 6; p++) begin
        do_read(row + 20 + p, 0, PBYTES, 0, "errors on a fresh block");
        fresh += nflips(row + 20 + p);
        do_read(31 * PAGES + p, 0, PBYTES, 0, "errors on a worn block");
        worn += nflips(31 * PAGES + p);
      end
      mu = 6.0 * real'(PBYTES * 8) * u_m.rber * (1.0 + u_m.rber_wear);
      if (real'(worn) < mu - 5.0 * $sqrt(mu) || real'(worn) > mu + 5.0 * $sqrt(mu) || worn < 4 * fresh)
        fail($sformatf("%0d bits flipped on the worn block, %0d on the fresh one; expected %0.1f on the worn one", worn, fresh, mu));
      else cov_dev(16);
      $display("[NAND] bit errors: %0d in 6 reads of a fresh block, %0d of a block at its rated endurance (expected %0.1f)", fresh, worn, mu);
      u_m.rber = 0.0;
    end
    // The generator itself: 4,000 page loads at 2e-4 straight into the model,
    // the mean and the variance of the count against the binomial's (6.912,
    // 6.911), within 4 standard errors and 10%. The loads are not counted in
    // the model's totals.
    begin
      int  f0 = u_m.n_flips, r0 = u_m.n_flip_reads, n = 4000;
      real sm = 0.0, s2 = 0.0, m, v, ex;
      u_m.rber = 2.0e-4;
      for (int i = 0; i < n; i++) begin
        int f = u_m.n_flips;
        u_m.load_page(40 * PAGES + (i % PAGES));
        sm += real'(u_m.n_flips - f);
        s2 += real'(u_m.n_flips - f) * real'(u_m.n_flips - f);
      end
      m  = sm / real'(n);
      v  = s2 / real'(n) - m * m;
      ex = real'(PBYTES * 8) * u_m.rber;
      if (m < ex - 4.0 * $sqrt(ex / real'(n)) || m > ex + 4.0 * $sqrt(ex / real'(n)) || v < 0.9 * ex || v > 1.1 * ex)
        fail($sformatf("generator: mean %0.4f and variance %0.4f of %0d page loads, expected %0.4f", m, v, n, ex));
      $display("[NAND] bit errors: %0d page loads at 2e-4 gave a mean of %0.4f and a variance of %0.4f (binomial %0.4f)", n, m, v, ex);
      u_m.n_flips      = f0;
      u_m.n_flip_reads = r0;
      u_m.page_ok      = 1'b0;
      u_m.rber         = 0.0;
    end
    set_timing(3, 2, 3, 2, 12, 6, 10, 2);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test;
  int    ncmd;
  initial begin
    if (!$value$plusargs("test=%s", test)) test = "all";
    if (!$value$plusargs("n=%d", ncmd)) ncmd = 400;
    if (!$value$plusargs("profile=%d", rnd_profile)) rnd_profile = 0;
    if (!$value$plusargs("rber_ppm=%d", rnd_ppm)) rnd_ppm = 0;
    apbd = new(aif);
    fw   = new(apbd);
    pb   = new(bif);
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk_nand);
    rst_nand_n = 1'b1;
    repeat (10) @(negedge clk);
    model_fast();
    begin
      string seq[$];
      if (test == "all") begin
        seq.push_back("regs");   seq.push_back("reset"); seq.push_back("id");      seq.push_back("rw");
        seq.push_back("erase");  seq.push_back("fail");  seq.push_back("wp");      seq.push_back("timeout");
        seq.push_back("timing"); seq.push_back("queue"); seq.push_back("arb");     seq.push_back("softreset");
        seq.push_back("busy");   seq.push_back("wear");  seq.push_back("abort");   seq.push_back("rules");
        seq.push_back("biterr"); seq.push_back("random");
      end else begin
        if (test != "regs" && test != "reset") seq.push_back("reset");
        seq.push_back(test);
      end
      foreach (seq[k]) begin
        case (seq[k])
          "regs":      t_regs();
          "reset":     t_reset();
          "id":        t_id();
          "rw":        t_rw();
          "erase":     t_erase();
          "fail":      t_fail();
          "wp":        t_wp();
          "timeout":   t_timeout();
          "timing":    t_timing();
          "queue":     t_queue();
          "arb":       t_arb();
          "softreset": t_softreset();
          "busy":      t_busy();
          "wear":      t_wear();
          "abort":     t_abort();
          "rules":     t_rules();
          "biterr":    t_biterr();
          "random":    t_random(ncmd);
          default:     fail($sformatf("no test %s", seq[k]));
        endcase
      end
    end
    repeat (100) @(negedge clk);
    errors += apbd.errs + fw.errs + pb.errs + u_m.errors;
    $display("[NAND] test %s: model saw %0d commands (%0d reset, %0d ID, %0d read, %0d program, %0d erase, %0d status, %0d change column), %0d bytes in, %0d out, %0d interface checks; %0d APB accesses",
             test, u_m.n_cmd, u_m.n_reset, u_m.n_id, u_m.n_read, u_m.n_prog, u_m.n_erase, u_m.n_status,
             u_m.n_rdcol, u_m.n_din, u_m.n_dout, u_m.checks, apbd.n);
    $display("[NAND] test %s: device: %0d busy operations, %0d bits flipped in %0d page reads, %0d resets stopping an operation, %0d erases failing for wear",
             test, u_m.n_ops, u_m.n_flips, u_m.n_flip_reads, u_m.n_abort, u_m.n_wear_fail);
    if (errors == 0) $display("[NAND] PASS");
    else             $display("[NAND] FAIL: %0d errors", errors);
    if (errors != 0) $fatal(1, "tb_nand failed");
    $finish;
  end

  // +dbg: the channel's state every 20 us.
  initial if ($test$plusargs("dbg")) forever begin
    #(20000.0);
    $display("[NAND] debug %0t: seq st %0d k %0d n %0d ce_n %b rb_n %b | d_run %b s_mode %0d s_left %0d a_pend %b w_valid %b | q %0d cq %0d | rx_empty %b cpl_empty %b",
             $time, u_nc.u_seq.st, u_nc.u_seq.k, u_nc.u_seq.n, ce_n, rb_n, u_nc.d_run, u_nc.s_mode, u_nc.s_left,
             u_nc.a_pend, u_nc.w_valid, u_nc.q_count, u_nc.cq_count, u_nc.rx_empty, u_nc.x_cpl_empty);
  end

  initial begin
    #(64'd2_000_000_000);
    $display("[NAND] FAIL: timeout");
    $fatal(1, "tb_nand timeout");
  end

endmodule : tb_nand
