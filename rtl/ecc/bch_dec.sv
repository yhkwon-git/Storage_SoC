`default_nettype none

// -----------------------------------------------------------------------------
// bch_dec
//
// BCH decoder of the NAND channels (step 3-3). Codeword bytes stream in, a
// byte a clock at most; the syndromes are ready the clock after the last
// byte. A codeword whose syndromes are all 0 is done at once. Any other goes
// through Berlekamp-Massey (bch_bm, 145 clocks) and the Chien search
// (bch_chien, 529 clocks), whose error bits in the 516 message bytes are kept
// (at most 8 bytes). The codeword is correctable when the locator's degree,
// the number of errors Berlekamp-Massey counted and the roots the search
// found agree and are at most t; then its corrections come out in byte order,
// and the result last.
//
// One codeword is decoded at a time, while the next one's bytes stream in;
// READY is low from the clock after a codeword's last byte until its
// syndromes are taken, and the next codeword's first byte must wait for it.
// -----------------------------------------------------------------------------

module bch_dec
  import bch_pkg::*;
(
  input  wire        clk,
  input  wire        rst_n,
  // received bytes
  input  wire        en,           // din is a codeword byte
  input  wire        first,        // ... the first of a codeword
  input  wire        lastb,        // ... its last
  input  wire  [7:0] din,
  output logic       ready,        // a first byte may come
  // corrections of a correctable codeword, in byte order
  output logic       cor_valid,
  output logic [9:0] cor_idx,      // message byte, 0 .. K_BYTES - 1
  output logic [7:0] cor_mask,     // bits to flip, bit 7 first
  input  wire        cor_ready,
  // then its result, one clock
  output logic       res_valid,
  output logic       res_unc,      // past correcting; no corrections came out
  output logic [3:0] res_bits      // bits corrected
);

  logic [12:0] s [T];
  bch_syn u_syn (.clk (clk), .rst_n (rst_n), .en (en), .first (first), .din (din), .s (s));

  logic pend;                      // a codeword's syndromes wait to be taken
  assign ready = !pend;

  wire s_zero = (s[0] | s[1] | s[2] | s[3] | s[4] | s[5] | s[6] | s[7]) == 13'd0;

  // ---------------------------------------------------------------------------
  // Berlekamp-Massey, then the Chien search
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {D_IDLE, D_BM, D_CHIEN, D_DRAIN, D_RES} dst_t;
  dst_t st;

  logic        bm_start, bm_busy, bm_done;
  logic [12:0] sig [T+1];
  logic [4:0]  dd;
  bch_bm u_bm (.clk (clk), .rst_n (rst_n), .start (bm_start), .s_in (s), .busy (bm_busy),
               .done (bm_done), .sig (sig), .dd (dd));

  logic       ch_start, ch_busy, ch_last;
  logic [9:0] ch_idx;
  logic [7:0] ch_mask;
  bch_chien u_ch (.clk (clk), .rst_n (rst_n), .start (ch_start), .sig (sig), .busy (ch_busy),
                  .idx (ch_idx), .mask (ch_mask), .last (ch_last));

  assign bm_start = (st == D_IDLE) && pend && !s_zero;
  assign ch_start = (st == D_BM) && bm_done;

  // Degree of the locator
  logic [4:0] deg;
  always_comb begin
    deg = 5'd0;
    for (int n = 1; n <= T; n++) if (sig[n] != 13'd0) deg = 5'(n);
  end

  // The message bytes in error, at most T of them
  logic [9:0] b_idx [T];
  logic [7:0] b_mask [T];
  logic [3:0] b_n, b_rd;
  logic [4:0] roots;
  logic       ovf, unc;

  function automatic logic [3:0] pop8(logic [7:0] x);
    logic [3:0] c;
    c = 4'd0;
    for (int n = 0; n < 8; n++) c = c + {3'd0, x[n]};
    return c;
  endfunction

  // The verdict, from the clock after the search's last byte: the roots of
  // that byte are counted by then.
  wire unc_now = (dd > 5'(T)) || (deg != dd) || (roots != dd) || ovf;

  assign cor_valid = (st == D_DRAIN) && !unc_now && (b_rd != b_n);
  assign cor_idx   = b_idx[b_rd[2:0]];
  assign cor_mask  = b_mask[b_rd[2:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend      <= 1'b0;
      st        <= D_IDLE;
      b_n       <= '0;
      b_rd      <= '0;
      roots     <= '0;
      ovf       <= 1'b0;
      unc       <= 1'b0;
      res_valid <= 1'b0;
      res_unc   <= 1'b0;
      res_bits  <= '0;
      for (int n = 0; n < T; n++) begin
        b_idx[n]  <= '0;
        b_mask[n] <= '0;
      end
    end else begin
      res_valid <= 1'b0;
      if (en && lastb) pend <= 1'b1;

      case (st)
        D_IDLE: begin
          if (pend && s_zero) begin
            pend      <= 1'b0;
            res_valid <= 1'b1;
            res_unc   <= 1'b0;
            res_bits  <= '0;
          end else if (bm_start) begin
            pend  <= 1'b0;
            st    <= D_BM;
            b_n   <= '0;
            b_rd  <= '0;
            roots <= '0;
            ovf   <= 1'b0;
          end
        end

        D_BM: if (bm_done) st <= D_CHIEN;

        D_CHIEN: begin
          if (ch_busy && ch_mask != 8'd0) begin
            roots <= roots + {1'b0, pop8(ch_mask)};
            if (ch_idx < 10'(K_BYTES)) begin
              if (b_n == 4'(T)) begin
                ovf <= 1'b1;
              end else begin
                b_idx[b_n[2:0]]  <= ch_idx;
                b_mask[b_n[2:0]] <= ch_mask;
                b_n              <= b_n + 4'd1;
              end
            end
          end
          if (ch_last) st <= D_DRAIN;
        end

        D_DRAIN: begin
          if (unc_now || b_rd == b_n) begin
            unc <= unc_now;
            st  <= D_RES;
          end else if (cor_ready) begin
            b_rd <= b_rd + 4'd1;
          end
        end

        default: begin   // D_RES
          res_valid <= 1'b1;
          res_unc   <= unc;
          res_bits  <= unc ? 4'd0 : roots[3:0];
          unc       <= 1'b0;
          st        <= D_IDLE;
        end
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{bm_busy, roots[4]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : bch_dec

`default_nettype wire
