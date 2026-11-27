`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tb_bch
//
// Block testbench of the BCH codec (step 3-3) against the Python reference
// model, flow/bch/bch.py. Each vector is a message, its parity, the codeword
// as received with 0 to t + 3 bit errors, and what the model's hardware form
// decodes it to (corrected or past correcting, the bits corrected, the
// message after correction).
//   bch_enc  the parity of every message; before every seventh, part of
//            another message is fed and abandoned, as a program cut short
//            leaves it
//   bch_dec  every received codeword fed in, with gaps or back to back, its
//            corrections taken with back-pressure; the result and the message
//            after the corrections must be the model's, and a codeword past
//            correcting must get no corrections
//
//   +vec=<file>  the vectors (default bch_vec.hex)
//   +nv=<n>      how many (default 100)
//   +gap=<pct>   percent of clocks with no byte offered (default 30; 0: back to back)
//   +bp=<pct>    percent of clocks with COR_READY low (default 30)
// -----------------------------------------------------------------------------

module tb_bch;
  import bch_pkg::*;

  localparam int VB   = 3 + K_BYTES + P_BYTES + N_BYTES + K_BYTES;
  localparam int MAXV = 2000;
  localparam int O_MSG = 3, O_PAR = 3 + K_BYTES, O_RX = 3 + K_BYTES + P_BYTES, O_OUT = 3 + K_BYTES + P_BYTES + N_BYTES;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  int errors;
  function automatic void fail(string s);
    errors++;
    if (errors <= 20) $display("[BCH] ERROR at %0t: %s", $time, s);
  endfunction

  bit [7:0] vec [MAXV * VB];
  int       nv, gap, bp;
  longint   cyc;
  always @(posedge clk) cyc++;

  // ---------------------------------------------------------------------------
  // DUTs
  // ---------------------------------------------------------------------------
  logic       e_en, e_first, e_shift;
  logic [7:0] e_din, e_par;
  bch_enc u_enc (.clk (clk), .rst_n (rst_n), .en (e_en), .first (e_first), .din (e_din),
                 .shift (e_shift), .parity (e_par));

  logic       d_en, d_first, d_last, d_ready, cor_valid, cor_ready, res_valid, res_unc;
  logic [7:0] d_din, cor_mask;
  logic [9:0] cor_idx;
  logic [3:0] res_bits;
  bch_dec u_dec (.clk (clk), .rst_n (rst_n), .en (d_en), .first (d_first), .lastb (d_last), .din (d_din),
                 .ready (d_ready), .cor_valid (cor_valid), .cor_idx (cor_idx), .cor_mask (cor_mask),
                 .cor_ready (cor_ready), .res_valid (res_valid), .res_unc (res_unc), .res_bits (res_bits));

  // ---------------------------------------------------------------------------
  // Encoder: every message, then its 13 parity bytes
  // ---------------------------------------------------------------------------
  int enc_ok, enc_cut;
  task automatic run_enc();
    for (int v = 0; v < nv; v++) begin
      if (v % 7 == 3) begin
        int n = $urandom_range(K_BYTES - 1, 1);
        for (int i = 0; i < n; i++) begin
          @(negedge clk);
          e_en    = 1'b1;
          e_first = (i == 0);
          e_din   = 8'($urandom);
        end
        enc_cut++;
      end
      for (int i = 0; i < K_BYTES; i++) begin
        @(negedge clk);
        e_en    = 1'b1;
        e_first = (i == 0);
        e_din   = vec[v * VB + O_MSG + i];
      end
      @(negedge clk);
      e_en = 1'b0;
      begin
        bit ok = 1'b1;
        for (int i = 0; i < P_BYTES; i++) begin
          if (e_par !== vec[v * VB + O_PAR + i]) begin
            if (ok) fail($sformatf("vector %0d: parity byte %0d %h, expected %h", v, i, e_par, vec[v * VB + O_PAR + i]));
            ok = 1'b0;
          end
          e_shift = 1'b1;
          @(negedge clk);
          e_shift = 1'b0;
        end
        if (ok) enc_ok++;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Decoder: the received codewords as one stream, a first byte only when
  // READY; the collector takes corrections and results in codeword order.
  // ---------------------------------------------------------------------------
  longint t_last [MAXV];
  task automatic feed();
    int v = 0, i = 0;
    while (v < nv) begin
      @(negedge clk);
      d_en = 1'b0;
      if (gap > 0 && $urandom_range(99) < gap) continue;
      if (i == 0 && !d_ready) continue;
      d_en    = 1'b1;
      d_first = (i == 0);
      d_last  = (i == N_BYTES - 1);
      d_din   = vec[v * VB + O_RX + i];
      if (i == N_BYTES - 1) t_last[v] = cyc;
      i++;
      if (i == N_BYTES) begin
        i = 0;
        v++;
      end
    end
    @(negedge clk);
    d_en = 1'b0;
  endtask

  int n_clean, n_fixed, n_unc, n_bits, n_cor, lat_max, lat_min = 1 << 30;
  longint lat_sum;
  task automatic collect();
    for (int v = 0; v < nv; v++) begin
      bit [7:0] got [K_BYTES];
      int       ncor = 0;
      int       b = v * VB;
      for (int i = 0; i < K_BYTES; i++) got[i] = vec[b + O_RX + i];
      forever begin
        @(negedge clk);
        if (t_last[v] > 0 && cyc - t_last[v] > 4000) begin
          fail($sformatf("vector %0d: no result 4000 clocks after its last byte", v));
          $fatal(1, "tb_bch: decoder hung");
        end
        cor_ready = (bp == 0) || ($urandom_range(99) >= bp);
        if (cor_valid && cor_ready) begin
          if (cor_idx >= 10'(K_BYTES) || cor_mask == 8'd0) fail($sformatf("vector %0d: correction at byte %0d mask %h", v, cor_idx, cor_mask));
          else got[cor_idx] ^= cor_mask;
          ncor++;
        end
        if (res_valid) break;
      end
      begin
        int lat = int'(cyc - t_last[v]);
        bit eu  = vec[b + 1][0];
        int ef  = int'(vec[b + 2]);
        string    rs, es;
        rs = res_unc ? "past correcting" : "corrected";
        es = eu ? "past correcting" : "corrected";
        if (res_unc != eu || (!eu && int'(res_bits) != ef))
          fail($sformatf("vector %0d (%0d errors): result %s with %0d bits, expected %s with %0d", v, vec[b],
                         rs, res_bits, es, ef));
        if (res_unc && ncor != 0) fail($sformatf("vector %0d: %0d corrections for a codeword past correcting", v, ncor));
        for (int i = 0; i < K_BYTES; i++)
          if (got[i] !== vec[b + O_OUT + i]) begin
            fail($sformatf("vector %0d: message byte %0d %h after correction, expected %h", v, i, got[i], vec[b + O_OUT + i]));
            break;
          end
        if (res_unc) n_unc++;
        else if (res_bits == 4'd0) n_clean++;
        else n_fixed++;
        n_bits += int'(res_bits);
        n_cor  += ncor;
        if (lat > lat_max) lat_max = lat;
        if (lat < lat_min) lat_min = lat;
        lat_sum += longint'(lat);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string  vf;
  longint t0;
  initial begin
    if (!$value$plusargs("vec=%s", vf)) vf = "bch_vec.hex";
    if (!$value$plusargs("nv=%d", nv)) nv = 100;
    if (!$value$plusargs("gap=%d", gap)) gap = 30;
    if (!$value$plusargs("bp=%d", bp)) bp = 30;
    if (nv > MAXV) nv = MAXV;
    $readmemh(vf, vec, 0, nv * VB - 1);
    e_en = 1'b0; e_first = 1'b0; e_shift = 1'b0; e_din = '0;
    d_en = 1'b0; d_first = 1'b0; d_last = 1'b0; d_din = '0; cor_ready = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    t0 = cyc;
    fork
      run_enc();
      feed();
      collect();
    join
    if (enc_ok != nv) fail($sformatf("encoder: %0d of %0d parities right", enc_ok, nv));
    $display("[BCH] %0d vectors, gap %0d%%, back-pressure %0d%%: encoder %0d of %0d parities right (%0d after an abandoned codeword); decoder %0d clean, %0d corrected (%0d bits in %0d corrections), %0d past correcting",
             nv, gap, bp, enc_ok, nv, enc_cut, n_clean, n_fixed, n_bits, n_cor, n_unc);
    $display("[BCH] decoder: %0d to %0d clocks from a codeword's last byte to its result, %0.1f on average; %0d clocks in all, %0.2f bytes a clock",
             lat_min, lat_max, real'(lat_sum) / real'(nv), cyc - t0, real'(nv * N_BYTES) / real'(cyc - t0));
    if (errors == 0) $display("[BCH] PASS");
    else             $display("[BCH] FAIL: %0d errors", errors);
    if (errors != 0) $fatal(1, "tb_bch failed");
    $finish;
  end

  initial begin
    #(64'd2_000_000_000);
    $display("[BCH] FAIL: timeout");
    $fatal(1, "tb_bch timeout");
  end

endmodule : tb_bch
