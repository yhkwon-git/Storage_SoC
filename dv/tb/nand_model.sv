`timescale 1ns/1ps
// Device timing is a set of real-valued delays.
/* verilator lint_off ZERODLY */

// -----------------------------------------------------------------------------
// nand_model
//
// An ONFI-style asynchronous NAND target for the testbenches. Step 3-1
// (docs/15_nand_channel.md) built its bus and the interface checks; step 3-2
// (docs/16_nand_model.md) adds the behavior of the device: busy times drawn
// per operation, wear, bit errors on reads, factory bad blocks, the rules
// programs must keep, and what a reset in the middle of an operation leaves.
//
// Array: BLOCKS blocks of PAGES pages of PBYTES bytes (4096 main + 224 spare),
// erased to FFh. A program ANDs the page register into the page, as flash
// can only clear bits; an erase sets a whole block back to FFh.
//
// Commands (latched at WE# rising with CE# low; CLE for a command byte, ALE
// for an address byte, neither for data):
//   FFh                reset; also stops a busy operation (below)
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
// Interface checks (step 3-1): every rule the controller has to keep, in ns,
// against the variables below, which the testbench sets for the timing it
// expects: WE# and RE# low and high widths and cycle times; CLE, ALE, DQ and
// CE# setup to WE# rising; CLE, ALE and DQ hold after it; tWHR from the last
// WE# rising to the next RE# falling; tADL from the last address cycle to
// the first data cycle; tRR from R/B# rising to RE# falling; WE# and RE#
// never low together; CLE and ALE never high together; no cycle with CE#
// high; DQ never driven by both sides. Each violation counts in errors.
//
// Device behavior (step 3-2). "wear" below is a block's P/E cycles over
// endurance, U{0..4} a whole number drawn from 0 to 4, u a real number drawn
// from [0, 1).
//   Busy times, from the confirm command to ready. With profile 0 they are
//   the fixed tR, tPROG, tBERS and tRST of step 3-1. With profile 1 each
//   operation draws its own:
//     read     tR_BASE + tR_STEP x U{0..4}
//     program  tPROG_BASE + tPROG_LOOP x loops, where the program-and-verify
//              loops are prog_loops + U{0..4} - floor(prog_wear x wear), at
//              least 1: worn cells program faster
//     erase    tBERS_PULSE x pulses, where the erase-and-verify pulses are
//              erase_pulses + floor(erase_wear x wear + erase_spread x u);
//              more than erase_max fails after erase_max pulses
//     reset    tRST; tRST_R, tRST_P or tRST_E when it stops a read, a
//              program or an erase
//   Wear. Every erase, failed or stopped, adds a P/E cycle to its block. An
//   erase that fails for want of pulses wears the block out: its programs
//   and erases fail from then on. With the default knobs no erase fails up to
//   endurance, and past it the chance grows to certainty at 5/3 of it.
//   Bit errors, put into the page register when a read's tR ends (a change
//   of read column sees the same ones):
//     rate     each bit flips with probability rber x (1 + rber_wear x wear)
//     windows  win_cnt[i] more bits flip, all different, among the win_len[i]
//              bytes from column win_start[i] (i below win_n)
//     stuck    bits of a row that always read a set value (add_stuck)
//   flip_log[row] lists the bits of the last read of a row that differ from
//   the array, as column x 8 + bit; n_flips counts them all. Every random
//   choice comes from a splitmix64 generator keyed by seed, NAME and what is
//   drawn (the operation's number, or the row and how often it was read), so
//   the same commands give the same times and errors whatever runs beside
//   them.
//   Factory bad blocks (set_bad): the first spare byte of the first and the
//   last page of the block reads 00h; a program or an erase there fails.
//   Rules, checked while rules is 1, each a count in rule_errs and errors:
//   the pages of a block programmed in order (the same page again is a
//   partial program); at most NOP programs of a page between erases; no
//   program or erase of a factory bad block; no program in a block whose
//   erase was stopped, until it is erased again.
//   A reset that stops an operation f of the way through its busy time: a
//   program has cleared each bit it was to clear with probability f; an
//   erase has set each 0 bit of the block with probability f; a read leaves
//   no page register to change the column of.
//
// Knobs (step 3-1): fail_prog and fail_erase make the next so many programs
// or erases fail (status bit 0, the array unchanged); stuck_busy keeps R/B#
// low until a reset.
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

  localparam int MAIN  = 4096;                 // the first spare byte
  localparam int NBITS = PBYTES * 8;

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

  // Profile 1: busy times drawn per operation, wear (step 3-2)
  bit      profile;
  realtime tR_BASE = 4600.0, tR_STEP = 200.0;
  realtime tPROG_BASE = 2000.0, tPROG_LOOP = 1500.0;
  realtime tBERS_PULSE = 25000.0;
  realtime tRST_R = 2000.0, tRST_P = 4000.0, tRST_E = 10000.0;
  int      prog_loops = 10, erase_pulses = 2, erase_max = 6;
  real     prog_wear = 3.0, erase_wear = 3.0, erase_spread = 2.0;
  int      endurance = 3000;
  int      NOP = 4;

  // Bit errors (step 3-2)
  real     rber, rber_wear = 9.0;
  int      win_n;
  int      win_start [8], win_len [8], win_cnt [8];
  int      seed = 1;
  bit      rules = 1'b1;

  // Knobs (step 3-1)
  int  fail_prog, fail_erase;
  bit  stuck_busy;
  bit  quiet;                        // no error messages (negative tests)

  // Results
  int  errors, checks, rule_errs;
  int  n_cmd, n_reset, n_id, n_read, n_prog, n_erase, n_status, n_rdcol, n_din, n_dout;
  int  n_ops, n_abort, n_flips, n_flip_reads, n_wear_fail;
  realtime last_busy;                // length of the last busy period (R/B# low)
  realtime last_len;                 // and of the operation, confirm to ready
  int  last_kind, last_loops, last_pulses;
  int  abort_kind;                   // what the last stopping reset stopped
  real abort_f;                      // and how far it had gone
  int  t_n [5];                      // busy times by kind (B_*), confirm to ready
  realtime t_min [5], t_max [5], t_sum [5];

  bit [7:0] ID00 [4] = '{8'h00, 8'h4E, 8'h53, 8'h31};
  bit [7:0] ID20 [4] = '{8'h4F, 8'h4E, 8'h46, 8'h49};   // "ONFI"

  function automatic void err(string s);
    errors++;
    if (!quiet && errors <= 20) $display("[NANDM] %s ERROR at %0t: %s", NAME, $time, s);
  endfunction

  function automatic void rule(string s);
    if (!rules) return;
    rule_errs++;
    err(s);
  endfunction

  // ---------------------------------------------------------------------------
  // Random numbers: splitmix64, reseeded for every draw from what it is for
  // ---------------------------------------------------------------------------
  bit [63:0] rs;

  function automatic bit [63:0] mix64(bit [63:0] z);
    z = (z ^ (z >> 30)) * 64'hBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) * 64'h94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
  endfunction

  function automatic void rseed(bit [63:0] a, bit [63:0] b);
    bit [63:0] h = mix64(64'(seed) + 64'h9E37_79B9_7F4A_7C15);
    for (int i = 0; i < NAME.len(); i++) h = mix64(h ^ 64'(NAME[i]));
    rs = mix64(mix64(h ^ a) ^ b);
  endfunction

  function automatic bit [63:0] rnext();
    rs = rs + 64'h9E37_79B9_7F4A_7C15;
    return mix64(rs);
  endfunction

  function automatic real runi();                  // [0, 1)
    bit [63:0] x = rnext();
    return real'(x[63:11]) / 9007199254740992.0;   // 2^53
  endfunction

  function automatic int rint(int n);              // 0 to n - 1
    bit [63:0] x = rnext();
    return int'(x[31:0] % 32'(n));
  endfunction

  // ---------------------------------------------------------------------------
  // Array, page register, blocks
  // ---------------------------------------------------------------------------
  typedef bit [7:0] page_t [];
  typedef int       iq_t [$];
  page_t    arr [int];
  bit [7:0] preg [PBYTES];

  int  pe [BLOCKS];                  // P/E cycles
  bit  bad [BLOCKS];                 // factory bad
  bit  worn [BLOCKS];                // worn out (an erase ran out of pulses)
  bit  unstable [BLOCKS];            // its last erase was stopped
  int  top [BLOCKS];                 // highest page programmed since the erase, -1 none
  int  nop [int];                    // programs of a row since its block's erase
  int  rd_cnt [int];                 // page reads of a row
  iq_t stuck [int];                  // per row: bit x 2 + the value it reads
  iq_t flip_log [int];               // per row: the bits the last read flipped

  initial foreach (top[b]) top[b] = -1;

  function automatic int blk_of(int row);
    return (row / PAGES) % BLOCKS;
  endfunction

  function automatic bit [7:0] page_byte(int row, int col);
    int p = row % PAGES;
    if (bad[blk_of(row)] && col == MAIN && (p == 0 || p == PAGES - 1)) return 8'h00;
    if (!arr.exists(row)) return 8'hFF;
    return arr[row][col];
  endfunction

  function automatic void set_bad(int blk);
    bad[blk] = 1'b1;
  endfunction

  function automatic void add_stuck(int row, int bitpos, bit v);
    iq_t q;
    if (stuck.exists(row)) q = stuck[row];
    q.push_back(bitpos * 2 + int'(v));
    stuck[row] = q;
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

  // The operation in progress
  int      op_kind, op_row;
  bit      op_fail, op_wear;
  realtime op_t0, op_len;

  // Draws the busy time and the outcome of a read, a program or an erase.
  function automatic realtime plan(int kind, int row);
    int      blk = blk_of(row);
    real     w   = real'(pe[blk]) / real'(endurance);
    realtime t;
    n_ops++;
    rseed({8'd1, 56'(n_ops)}, 64'(row));
    op_fail     = 1'b0;
    op_wear     = 1'b0;
    last_loops  = 0;
    last_pulses = 0;
    case (kind)
      B_READ: t = profile ? tR_BASE + tR_STEP * real'(rint(5)) : tR;
      B_PROG: begin
        if (profile) begin
          int l = prog_loops + rint(5) - int'($floor(prog_wear * w));
          if (l < 1) l = 1;
          last_loops = l;
          t = tPROG_BASE + tPROG_LOOP * real'(l);
        end else t = tPROG;
        if (fail_prog > 0) begin
          fail_prog--;
          op_fail = 1'b1;
        end
        op_fail = op_fail || bad[blk] || worn[blk];
      end
      B_ERASE: begin
        if (profile) begin
          int n = erase_pulses + int'($floor(erase_wear * w + erase_spread * runi()));
          if (n > erase_max || worn[blk]) begin
            n       = erase_max;
            op_fail = 1'b1;
            op_wear = !worn[blk];
          end
          last_pulses = n;
          t = tBERS_PULSE * real'(n);
        end else t = tBERS;
        if (fail_erase > 0) begin
          fail_erase--;
          op_fail = 1'b1;
        end
        if (bad[blk] || worn[blk]) op_fail = 1'b1;
      end
      default: t = tPROT;                          // B_PROT
    endcase
    return t;
  endfunction

  function automatic void note_busy(int kind, realtime t);
    t_n[kind]++;
    t_sum[kind] += t;
    if (t_n[kind] == 1 || t < t_min[kind]) t_min[kind] = t;
    if (t > t_max[kind]) t_max[kind] = t;
  endfunction

  // A read's tR has ended: the page into the page register, then its errors.
  function automatic void load_page(int row);
    int  blk = blk_of(row);
    real p   = rber * (1.0 + rber_wear * real'(pe[blk]) / real'(endurance));
    iq_t lg;
    for (int i = 0; i < PBYTES; i++) preg[i] = page_byte(row, i);
    page_ok = 1'b1;
    if (!rd_cnt.exists(row)) rd_cnt[row] = 0;
    rd_cnt[row]++;
    rseed({8'd2, 24'd0, 32'(row)}, 64'(rd_cnt[row]));
    if (p > 0.0) begin
      real    lq;
      longint pos;
      if (p > 0.5) p = 0.5;
      lq  = $ln(1.0 - p);
      // Bits between errors: geometric, one draw per error.
      pos = longint'($floor($ln(1.0 - runi()) / lq));
      while (pos < longint'(NBITS)) begin
        int b = int'(pos);
        preg[b / 8][b % 8] = !preg[b / 8][b % 8];
        pos = pos + 64'sd1 + longint'($floor($ln(1.0 - runi()) / lq));
      end
    end
    for (int w = 0; w < win_n; w++) begin
      int lo = win_start[w] * 8, n = win_len[w] * 8, need = win_cnt[w];
      if (lo + n > NBITS) n = NBITS - lo;
      for (int tries = 0; need > 0 && tries < 64 * n; tries++) begin
        int       b = lo + rint(n);
        bit [7:0] s = page_byte(row, b / 8);
        if (preg[b / 8][b % 8] == s[b % 8]) begin
          preg[b / 8][b % 8] = !s[b % 8];
          need--;
        end
      end
    end
    if (stuck.exists(row)) begin
      iq_t q = stuck[row];
      foreach (q[k]) preg[q[k] / 16][(q[k] / 2) % 8] = (q[k] % 2) != 0;
    end
    for (int i = 0; i < PBYTES; i++) begin
      bit [7:0] d = preg[i] ^ page_byte(row, i);
      if (d != 8'd0) for (int k = 0; k < 8; k++) if (d[k]) lg.push_back(i * 8 + k);
    end
    flip_log[row] = lg;
    n_flips += lg.size();
    if (lg.size() > 0) n_flip_reads++;
  endfunction

  function automatic void program_page(int row);
    if (!arr.exists(row)) begin
      arr[row] = new[PBYTES];
      for (int i = 0; i < PBYTES; i++) arr[row][i] = 8'hFF;
    end
    for (int i = 0; i < PBYTES; i++) arr[row][i] = arr[row][i] & preg[i];
  endfunction

  function automatic void erase_block(int row);
    int blk = blk_of(row);
    pe[blk]++;
    if (op_wear) begin
      worn[blk] = 1'b1;
      n_wear_fail++;
    end
    if (op_fail) begin
      fail_last = 1'b1;
      return;
    end
    for (int p = 0; p < PAGES; p++) begin
      arr.delete(blk * PAGES + p);
      nop.delete(blk * PAGES + p);
    end
    top[blk]      = -1;
    unstable[blk] = 1'b0;
    fail_last     = 1'b0;
  endfunction

  // The rules of a program, at its confirm command.
  function automatic void prog_rules(int row);
    int blk = blk_of(row), pg = row % PAGES;
    if (bad[blk]) rule($sformatf("program of factory bad block %0d", blk));
    if (unstable[blk]) rule($sformatf("program in block %0d, whose erase was stopped", blk));
    if (pg < top[blk]) rule($sformatf("page %0d of block %0d programmed after page %0d", pg, blk, top[blk]));
    if (!nop.exists(row)) nop[row] = 0;
    nop[row]++;
    if (nop[row] > NOP) rule($sformatf("program %0d of row %0d since its erase (NOP %0d)", nop[row], row, NOP));
    if (pg > top[blk]) top[blk] = pg;
  endfunction

  // A reset stops the operation in progress f of the way through.
  function automatic void abort_op();
    int  blk = blk_of(op_row);
    real f   = (op_len > 0.0) ? ($realtime - op_t0) / op_len : 1.0;
    if (f > 1.0) f = 1.0;
    n_abort++;
    abort_kind = op_kind;
    abort_f    = f;
    rseed({8'd3, 56'(n_abort)}, 64'(op_row));
    case (op_kind)
      B_READ: page_ok = 1'b0;
      B_PROG: if (!op_fail) begin
        if (!arr.exists(op_row)) begin
          arr[op_row] = new[PBYTES];
          for (int i = 0; i < PBYTES; i++) arr[op_row][i] = 8'hFF;
        end
        for (int i = 0; i < PBYTES; i++) begin
          bit [7:0] c = arr[op_row][i] & ~preg[i];          // bits the program clears
          bit [7:0] v = arr[op_row][i];
          if (c != 8'd0) begin
            for (int k = 0; k < 8; k++) if (c[k] && runi() < f) v[k] = 1'b0;
            arr[op_row][i] = v;
          end
        end
      end
      B_ERASE: begin
        pe[blk]++;
        if (!op_fail) begin
          for (int p = 0; p < PAGES; p++) begin
            int r = blk * PAGES + p;
            if (arr.exists(r))
              for (int i = 0; i < PBYTES; i++) begin
                bit [7:0] v = arr[r][i];
                if (v != 8'hFF) begin
                  for (int k = 0; k < 8; k++) if (!v[k] && runi() < f) v[k] = 1'b1;
                  arr[r][i] = v;
                end
              end
          end
          unstable[blk] = 1'b1;
        end
      end
      default: ;
    endcase
  endfunction

  task automatic run_busy(int kind, int row, realtime trst = 0.0);
    int      g;
    realtime t;
    gen++;
    g = gen;
    busy = 1'b1;
    if (kind == B_RESET) begin
      t       = trst;
      op_fail = 1'b0;
      op_wear = 1'b0;
    end else t = plan(kind, row);
    op_kind = kind;
    op_row  = row;
    op_t0   = $realtime;
    op_len  = t;
    #(tWB_DEV);
    if (g != gen) return;
    rb_n = 1'b0;
    t_busy0 = $realtime;
    #(t - tWB_DEV);
    while (stuck_busy && kind != B_RESET && g == gen) #(100.0);
    if (g != gen) return;
    case (kind)
      B_READ: load_page(row);
      B_PROG: begin
        if (!op_fail) program_page(row);
        fail_last = op_fail;
      end
      B_ERASE: erase_block(row);
      B_PROT:  fail_last = 1'b1;
      default: fail_last = 1'b0;    // B_RESET
    endcase
    busy = 1'b0;
    rb_n = 1'b1;
    t_rb_rise = $realtime;
    last_busy = $realtime - t_busy0;
    last_len  = $realtime - op_t0;
    last_kind = kind;
    note_busy(kind, last_len);
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
        realtime t = tRST;
        n_reset++;
        if (busy && op_kind != B_RESET && op_kind != B_PROT) begin
          abort_op();
          if (profile) t = (op_kind == B_READ) ? tRST_R : (op_kind == B_PROG) ? tRST_P : tRST_E;
        end
        cur = 8'h00;
        acnt = 0;
        out_mode = O_NONE;
        page_ok = 1'b0;
        fork run_busy(B_RESET, 0, t); join_none
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
        if (row_of() >= BLOCKS * PAGES) err($sformatf("row %0d beyond the device", row_of()));
        col = col_of();
        out_mode = O_PAGE;
        cur = 8'h00;
        acnt = 0;
        fork run_busy(B_READ, row_of()); join_none
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
        if (row_of() >= BLOCKS * PAGES) err($sformatf("row %0d beyond the device", row_of()));
        cur = 8'h00;
        acnt = 0;
        if (!wp_n) begin fork run_busy(B_PROT, 0); join_none end
        else begin
          prog_rules(row_of());
          fork run_busy(B_PROG, row_of()); join_none
        end
      end
      8'hD0: begin
        if (cur != 8'h60 || acnt != 3) begin err("D0h without 60h and 3 address bytes"); return; end
        n_erase++;
        if (row_of() >= BLOCKS * PAGES) err($sformatf("row %0d beyond the device", row_of()));
        cur = 8'h00;
        acnt = 0;
        if (!wp_n) begin fork run_busy(B_PROT, 0); join_none end
        else begin
          if (bad[blk_of(row_of())]) rule($sformatf("erase of factory bad block %0d", blk_of(row_of())));
          fork run_busy(B_ERASE, row_of()); join_none
        end
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
