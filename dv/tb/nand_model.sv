`timescale 1ns/1ps
// Device timing is a set of real-valued delays.
/* verilator lint_off ZERODLY */

// -----------------------------------------------------------------------------
// nand_model
//
// An ONFI-style asynchronous NAND target for the testbenches (step 3-1,
// docs/15_nand_channel.md). Step 3-2 adds busy times that vary and bit
// errors; here busy times are fixed knobs.
//
// Array: BLOCKS blocks of PAGES pages of PBYTES bytes (4096 main + 224 spare),
// erased to FFh. A program ANDs the page register into the page, as flash
// can only clear bits; an erase sets a whole block back to FFh.
//
// Commands (latched at WE# rising with CE# low; CLE for a command byte, ALE
// for an address byte, neither for data):
//   FFh                reset; also stops a busy operation
//   90h, 1 address     read ID: address 00h gives ID00, 20h gives "ONFI"
//   00h, 5 address, 30h  read the page into the page register (busy tR)
//   05h, 2 address, E0h  change the column of data output
//   80h, 5 address, data, 10h  program (busy tPROG); refused with WP# low
//   60h, 3 address, D0h  erase the block (busy tBERS); refused with WP# low
//   70h                status: bit 7 WP# high (not protected), bit 6 and
//                      bit 5 ready, bit 0 the last program or erase failed
// R/B# goes low tWB_DEV after the confirm byte and high when the operation
// ends. During busy only 70h and FFh are taken; any other cycle is an error.
// Data out: RE# falling starts a byte, valid tREA later (an inverted byte
// before that, so a read sampled early fails), held until tRHOH after RE#
// rises; the column moves on at RE# rising.
//
// Every interface rule the controller has to keep is checked, in ns, against
// the variables below, which the testbench sets for the timing it expects:
// WE# and RE# low and high widths and cycle times; CLE, ALE, DQ and CE#
// setup to WE# rising; CLE, ALE and DQ hold after it; tWHR from the last WE#
// rising to the next RE# falling; tADL from the last address cycle to the
// first data cycle; tRR from R/B# rising to RE# falling; WE# and RE# never
// low together; CLE and ALE never high together; no cycle with CE# high; DQ
// never driven by both sides. Each violation counts in errors.
//
// Knobs: fail_prog and fail_erase make the next so many programs or erases
// fail (status bit 0, the array unchanged); stuck_busy keeps R/B# low until a
// reset.
// -----------------------------------------------------------------------------

module nand_model #(
  parameter string NAME   = "NAND",
  parameter int    BLOCKS = 64,
  parameter int    PAGES  = 64,
  parameter int    PBYTES = 4320
) (
  input  wire        ce_n,
  input  wire        cle,
  input  wire        ale,
  input  wire        we_n,
  input  wire        re_n,
  input  wire        wp_n,
  input  wire  [7:0] dq_c,       // the controller's DQ
  input  wire        dq_c_oe,
  output logic [7:0] dq_d,       // the device's DQ
  output logic       dq_d_oe,
  output logic       rb_n
);

  // ---------------------------------------------------------------------------
  // Timing the device requires (ns)
  // ---------------------------------------------------------------------------
  realtime tWP = 15.0, tWH = 10.0, tWC = 30.0, tRP = 15.0, tREH = 10.0, tRC = 30.0;
  realtime tCLS = 10.0, tALS = 10.0, tDS = 10.0, tCS = 15.0;
  realtime tCLH = 5.0, tALH = 5.0, tDH = 5.0;
  realtime tWHR = 80.0, tADL = 70.0, tRR = 20.0;

  // What the device does (ns)
  realtime tREA = 16.0, tRHOH = 4.0, tCLR = 2.0, tWB_DEV = 100.0;   // tWB at its usual limit
  realtime tR = 5000.0, tPROG = 20000.0, tBERS = 50000.0, tRST = 2000.0, tPROT = 500.0;

  // Knobs and results
  int  fail_prog, fail_erase;
  bit  stuck_busy;
  bit  quiet;                        // no error messages (negative tests)
  int  errors, checks;
  int  n_cmd, n_reset, n_id, n_read, n_prog, n_erase, n_status, n_rdcol, n_din, n_dout;
  realtime last_busy;                // length of the last busy period

  bit [7:0] ID00 [4] = '{8'h00, 8'h4E, 8'h53, 8'h31};
  bit [7:0] ID20 [4] = '{8'h4F, 8'h4E, 8'h46, 8'h49};   // "ONFI"

  function automatic void err(string s);
    errors++;
    if (!quiet && errors <= 20) $display("[NANDM] %s ERROR at %0t: %s", NAME, $time, s);
  endfunction

  // ---------------------------------------------------------------------------
  // Array and page register
  // ---------------------------------------------------------------------------
  typedef bit [7:0] page_t [];
  page_t    arr [int];
  bit [7:0] preg [PBYTES];

  function automatic bit [7:0] page_byte(int row, int col);
    if (!arr.exists(row)) return 8'hFF;
    return arr[row][col];
  endfunction

  // ---------------------------------------------------------------------------
  // Bus state
  // ---------------------------------------------------------------------------
  localparam int O_NONE = 0, O_PAGE = 1, O_ID = 2, O_STATUS = 3;

  bit [7:0] cur;                     // command being assembled
  int       acnt;                    // address bytes taken for it
  bit [7:0] adr [5];
  int       col;                     // column of data in or out
  int       out_mode, id_sel, id_ptr;
  bit       busy, fail_last, page_ok;
  bit       rd_since_we;             // an RE# fall since the last WE# rise
  bit       data_started;
  int       gen;                     // the busy operation in progress

  realtime t_we_fall = -1.0e9, t_we_rise = -1.0e9, t_re_fall = -1.0e9, t_re_rise = -1.0e9;
  realtime t_cle = -1.0e9, t_ale = -1.0e9, t_dq = -1.0e9, t_ce_fall = -1.0e9;
  realtime t_rb_rise = -1.0e9, t_last_addr = -1.0e9, t_busy0 = 0.0;
  bit      held_cle, held_ale, held_dq;   // the last WE# rise latched them

  initial begin
    rb_n = 1'b1;
    dq_d = 8'h00;
    dq_d_oe = 1'b0;
    cur = 8'h00;
    out_mode = O_NONE;
  end

  function automatic int row_of();
    return int'({adr[4], adr[3], adr[2]});
  endfunction

  function automatic int col_of();
    return int'({adr[1], adr[0]});
  endfunction

  function automatic bit [7:0] status();
    return {wp_n, !busy, !busy, 4'd0, fail_last};
  endfunction

  // ---------------------------------------------------------------------------
  // Busy operations
  // ---------------------------------------------------------------------------
  localparam int B_RESET = 0, B_READ = 1, B_PROG = 2, B_ERASE = 3, B_PROT = 4;

  task automatic run_busy(int kind, realtime t, int row);
    int g;
    gen++;
    g = gen;
    busy = 1'b1;
    #(tWB_DEV);
    if (g != gen) return;
    rb_n = 1'b0;
    t_busy0 = $realtime;
    #(t - tWB_DEV);
    while (stuck_busy && kind != B_RESET && g == gen) #(100.0);
    if (g != gen) return;
    case (kind)
      B_READ: begin
        for (int i = 0; i < PBYTES; i++) preg[i] = page_byte(row, i);
        page_ok = 1'b1;
      end
      B_PROG: begin
        if (fail_prog > 0) begin
          fail_prog--;
          fail_last = 1'b1;
        end else begin
          if (!arr.exists(row)) begin
            arr[row] = new[PBYTES];
            for (int i = 0; i < PBYTES; i++) arr[row][i] = 8'hFF;
          end
          for (int i = 0; i < PBYTES; i++) arr[row][i] = arr[row][i] & preg[i];
          fail_last = 1'b0;
        end
      end
      B_ERASE: begin
        if (fail_erase > 0) begin
          fail_erase--;
          fail_last = 1'b1;
        end else begin
          for (int p = 0; p < PAGES; p++) arr.delete((row / PAGES) * PAGES + p);
          fail_last = 1'b0;
        end
      end
      B_PROT:  fail_last = 1'b1;
      default: fail_last = 1'b0;    // B_RESET
    endcase
    busy = 1'b0;
    rb_n = 1'b1;
    t_rb_rise = $realtime;
    last_busy = $realtime - t_busy0;
  endtask

  // ---------------------------------------------------------------------------
  // Signal history for the timing checks
  // ---------------------------------------------------------------------------
  always @(cle) begin
    if (held_cle && we_n && ($realtime - t_we_rise) < tCLH) err($sformatf("CLE changed %0.1f ns after WE# rising (tCLH %0.1f)", $realtime - t_we_rise, tCLH));
    t_cle = $realtime;
  end
  always @(ale) begin
    if (held_ale && we_n && ($realtime - t_we_rise) < tALH) err($sformatf("ALE changed %0.1f ns after WE# rising (tALH %0.1f)", $realtime - t_we_rise, tALH));
    t_ale = $realtime;
  end
  always @(dq_c or dq_c_oe) begin
    if (held_dq && we_n && ($realtime - t_we_rise) < tDH) err($sformatf("DQ changed %0.1f ns after WE# rising (tDH %0.1f)", $realtime - t_we_rise, tDH));
    t_dq = $realtime;
  end
  always @(negedge ce_n) t_ce_fall = $realtime;

  // Checks start once the bus has been idle (CE#, WE#, RE# high): before the
  // controller's reset its outputs mean nothing.
  bit armed;
  always @(posedge ce_n or posedge we_n or posedge re_n) if (ce_n && we_n && re_n) armed = 1'b1;

  always @(we_n or re_n or cle or ale) begin
    if (armed && !we_n && !re_n) err("WE# and RE# low together");
    if (armed && cle && ale) err("CLE and ALE high together");
  end
  always @(dq_c_oe or dq_d_oe) if (armed && dq_c_oe && dq_d_oe) err("DQ driven by the controller and the device");
  always @(negedge we_n) if (armed && ce_n) err("WE# cycle with CE# high");
  always @(negedge re_n) if (armed && ce_n) err("RE# cycle with CE# high");

  // ---------------------------------------------------------------------------
  // Write cycles
  // ---------------------------------------------------------------------------
  always @(negedge we_n) begin
    if (!ce_n) begin
      checks++;
      if (($realtime - t_we_rise) < tWH) err($sformatf("WE# high %0.1f ns (tWH %0.1f)", $realtime - t_we_rise, tWH));
      if (($realtime - t_we_fall) < tWC) err($sformatf("WE# cycle %0.1f ns (tWC %0.1f)", $realtime - t_we_fall, tWC));
    end
    t_we_fall = $realtime;
  end

  always @(posedge we_n) begin
    if (!ce_n) begin
      automatic bit [7:0] b = dq_c;
      checks++;
      if (($realtime - t_we_fall) < tWP) err($sformatf("WE# low %0.1f ns (tWP %0.1f)", $realtime - t_we_fall, tWP));
      if (($realtime - t_ce_fall) < tCS) err($sformatf("CE# setup %0.1f ns (tCS %0.1f)", $realtime - t_ce_fall, tCS));
      if (cle && ($realtime - t_cle) < tCLS) err($sformatf("CLE setup %0.1f ns (tCLS %0.1f)", $realtime - t_cle, tCLS));
      if (ale && ($realtime - t_ale) < tALS) err($sformatf("ALE setup %0.1f ns (tALS %0.1f)", $realtime - t_ale, tALS));
      if (($realtime - t_dq) < tDS) err($sformatf("DQ setup %0.1f ns (tDS %0.1f)", $realtime - t_dq, tDS));
      if (!dq_c_oe) err("WE# rising with DQ not driven");
      held_cle = 1'b1;
      held_ale = 1'b1;
      held_dq  = 1'b1;
      if (cle && !ale)       command(b);
      else if (ale && !cle)  address(b);
      else if (!cle && !ale) data_in(b);
      rd_since_we = 1'b0;
    end
    t_we_rise = $realtime;
  end

  task automatic command(bit [7:0] b);
    n_cmd++;
    if (busy && b != 8'h70 && b != 8'hFF) begin
      err($sformatf("command %h while busy", b));
      return;
    end
    case (b)
      8'hFF: begin
        n_reset++;
        cur = 8'h00;
        acnt = 0;
        out_mode = O_NONE;
        page_ok = 1'b0;
        fork run_busy(B_RESET, tRST, 0); join_none
      end
      8'h70: begin
        n_status++;
        out_mode = O_STATUS;
      end
      8'h90, 8'h00, 8'h05, 8'h60: begin
        cur = b;
        acnt = 0;
        out_mode = O_NONE;
      end
      8'h80: begin
        cur = b;
        acnt = 0;
        out_mode = O_NONE;
        data_started = 1'b0;
        for (int i = 0; i < PBYTES; i++) preg[i] = 8'hFF;
        page_ok = 1'b0;
      end
      8'h30: begin
        if (cur != 8'h00 || acnt != 5) begin err("30h without 00h and 5 address bytes"); return; end
        n_read++;
        col = col_of();
        out_mode = O_PAGE;
        cur = 8'h00;
        acnt = 0;
        fork run_busy(B_READ, tR, row_of()); join_none
      end
      8'hE0: begin
        if (cur != 8'h05 || acnt != 2) begin err("E0h without 05h and 2 address bytes"); return; end
        if (!page_ok) err("change read column with no page read");
        n_rdcol++;
        col = col_of();
        out_mode = O_PAGE;
        cur = 8'h00;
      end
      8'h10: begin
        if (cur != 8'h80 || acnt != 5) begin err("10h without 80h and 5 address bytes"); return; end
        n_prog++;
        cur = 8'h00;
        acnt = 0;
        if (!wp_n) begin fork run_busy(B_PROT, tPROT, 0); join_none end
        else begin fork run_busy(B_PROG, tPROG, row_of()); join_none end
      end
      8'hD0: begin
        if (cur != 8'h60 || acnt != 3) begin err("D0h without 60h and 3 address bytes"); return; end
        n_erase++;
        cur = 8'h00;
        acnt = 0;
        if (!wp_n) begin fork run_busy(B_PROT, tPROT, 0); join_none end
        else begin fork run_busy(B_ERASE, tBERS, row_of()); join_none end
      end
      default: err($sformatf("unknown command %h", b));
    endcase
  endtask

  task automatic address(bit [7:0] b);
    if (busy) begin err("address cycle while busy"); return; end
    case (cur)
      8'h90: begin
        if (acnt != 0) begin err("second address byte for read ID"); return; end
        if (b != 8'h00 && b != 8'h20) err($sformatf("read ID address %h", b));
        n_id++;
        id_sel = (b == 8'h20) ? 1 : 0;
        id_ptr = 0;
        out_mode = O_ID;
        acnt = 1;
      end
      8'h00, 8'h80: begin
        if (acnt >= 5) begin err("more than 5 address bytes"); return; end
        adr[acnt] = b;
        acnt++;
        if (cur == 8'h80 && acnt == 5) begin
          col = col_of();
          t_last_addr = $realtime;
        end
      end
      8'h05: begin
        if (acnt >= 2) begin err("more than 2 column bytes"); return; end
        adr[acnt] = b;
        acnt++;
      end
      8'h60: begin
        if (acnt >= 3) begin err("more than 3 row bytes"); return; end
        adr[acnt + 2] = b;
        acnt++;
      end
      default: err($sformatf("address byte %h with no command", b));
    endcase
    // The column is complete after the second address byte.
    if ((cur == 8'h00 || cur == 8'h80 || cur == 8'h05) && acnt == 2 && col_of() >= PBYTES)
      err($sformatf("column %0d beyond the page", col_of()));
  endtask

  task automatic data_in(bit [7:0] b);
    if (cur != 8'h80 || acnt != 5) begin err("data cycle outside a program"); return; end
    if (!data_started) begin
      data_started = 1'b1;
      if (($realtime - t_last_addr) < tADL) err($sformatf("tADL %0.1f ns (%0.1f)", $realtime - t_last_addr, tADL));
    end
    if (col >= PBYTES) begin err("program data beyond the page"); return; end
    preg[col] = b;
    col++;
    n_din++;
  endtask

  // ---------------------------------------------------------------------------
  // Read cycles
  // ---------------------------------------------------------------------------
  int rgen;

  always @(negedge re_n) begin
    if (!ce_n) begin
      automatic bit [7:0] b;
      automatic int       g;
      checks++;
      if (($realtime - t_re_rise) < tREH) err($sformatf("RE# high %0.1f ns (tREH %0.1f)", $realtime - t_re_rise, tREH));
      if (($realtime - t_re_fall) < tRC) err($sformatf("RE# cycle %0.1f ns (tRC %0.1f)", $realtime - t_re_fall, tRC));
      if (($realtime - t_rb_rise) < tRR) err($sformatf("tRR %0.1f ns (%0.1f)", $realtime - t_rb_rise, tRR));
      if (!rd_since_we && ($realtime - t_we_rise) < tWHR) err($sformatf("tWHR %0.1f ns (%0.1f)", $realtime - t_we_rise, tWHR));
      rd_since_we = 1'b1;
      if (busy && out_mode != O_STATUS) err("data read while busy");
      case (out_mode)
        O_PAGE: begin
          if (col >= PBYTES) begin err("read beyond the page"); b = 8'hFF; end
          else b = preg[col];
        end
        O_ID:     b = (id_sel == 1) ? ID20[id_ptr % 4] : ID00[id_ptr % 4];
        O_STATUS: b = status();
        default: begin err("RE# with nothing to read"); b = 8'hFF; end
      endcase
      rgen++;
      g = rgen;
      fork
        begin
          #(tCLR);
          if (g == rgen) begin dq_d = ~b; dq_d_oe = 1'b1; end
          #(tREA - tCLR);
          if (g == rgen && !re_n) dq_d = (out_mode == O_STATUS) ? status() : b;
        end
      join_none
      n_dout++;
    end
    t_re_fall = $realtime;
  end

  always @(posedge re_n) begin
    if (!ce_n) begin
      automatic int g;
      checks++;
      if (($realtime - t_re_fall) < tRP) err($sformatf("RE# low %0.1f ns (tRP %0.1f)", $realtime - t_re_fall, tRP));
      if (out_mode == O_PAGE) col++;
      if (out_mode == O_ID) id_ptr++;
      g = rgen;
      fork
        begin
          #(tRHOH);
          if (g == rgen && re_n) dq_d_oe = 1'b0;
        end
      join_none
    end
    t_re_rise = $realtime;
  end

  // Hold checks apply only to what the last WE# rising latched; once its hold
  // window has passed, changes are free.
  always @(posedge we_n) begin
    #(tDH + tCLH + tALH + 1.0);
    if (we_n) begin
      held_cle = 1'b0;
      held_ale = 1'b0;
      held_dq  = 1'b0;
    end
  end

endmodule : nand_model
