`default_nettype none

// -----------------------------------------------------------------------------
// bch_bm
//
// Berlekamp-Massey for the BCH decoder (step 3-3): the error locator of a
// codeword from its syndromes, inversionless and in the binary form that
// needs t iterations (sibm in flow/bch/bch.py). Iteration k:
//   d     = sum over i of sigma_i S_(2k+1-i)                 T+1 clocks
//   sigma = gamma sigma + d x tau; then, if d != 0 and D <= k,
//           tau = x sigma (the old one), gamma = d, D = 2k+1-D,
//           else tau = x^2 tau                                T+1 clocks
// The update runs from the top coefficient down, so that every old value is
// read before it is overwritten. Two GF(2^13) multipliers; 2(T+1) clocks an
// iteration, 144 for the 8. SIG is the error locator times a constant, with
// the same roots; DD the number of errors it locates.
// -----------------------------------------------------------------------------

module bch_bm
  import bch_pkg::*;
(
  input  wire         clk,
  input  wire         rst_n,
  input  wire         start,          // s_in: the odd syndromes of a codeword
  input  wire  [12:0] s_in [T],
  output logic        busy,
  output logic        done,           // one clock; sig and dd hold until the next start
  output logic [12:0] sig [T+1],
  output logic [4:0]  dd
);

  logic [12:0] s [2*T-1];             // S_1 .. S_15 at index j - 1
  logic [12:0] tau [T+1];
  logic [12:0] gam, d;
  logic [2:0]  k;
  logic [3:0]  i;
  logic        ph;                    // 0: discrepancy, 1: update

  // S_(2k+1-i), 0 where the index falls below 1
  logic [3:0]  j1;
  logic [12:0] sj;
  always_comb begin
    j1 = (i <= {k, 1'b0}) ? ({k, 1'b0} - i) : 4'd0;   // 2k - i, the index of S_(2k+1-i)
    sj = (i <= {k, 1'b0}) ? s[j1] : 13'd0;
  end

  logic [12:0] a_p, b_p;
  assign a_p = gf_mul(sig[i], ph ? gam : sj);
  assign b_p = (i != 4'd0) ? gf_mul(d, tau[i - 4'd1]) : 13'd0;

  wire swap = (d != 13'd0) && (dd <= {2'd0, k});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      done <= 1'b0;
      k    <= '0;
      i    <= '0;
      ph   <= 1'b0;
      d    <= '0;
      gam  <= '0;
      dd   <= '0;
      for (int n = 0; n <= T; n++) begin
        sig[n] <= '0;
        tau[n] <= '0;
      end
      for (int n = 0; n < 2 * T - 1; n++) s[n] <= '0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy <= 1'b1;
        k    <= '0;
        i    <= '0;
        ph   <= 1'b0;
        d    <= '0;
        gam  <= 13'd1;
        dd   <= '0;
        for (int n = 0; n <= T; n++) begin
          sig[n] <= (n == 0) ? 13'd1 : 13'd0;
          tau[n] <= (n == 0) ? 13'd1 : 13'd0;
        end
        // Odd syndromes as given, even ones by squaring: S_2m = S_m^2.
        for (int m = 0; m < T; m++) s[2 * m] <= s_in[m];
        s[1]  <= gf_sq(s_in[0]);                       // S_2
        s[3]  <= gf_sq(gf_sq(s_in[0]));                // S_4
        s[5]  <= gf_sq(s_in[1]);                       // S_6
        s[7]  <= gf_sq(gf_sq(gf_sq(s_in[0])));         // S_8
        s[9]  <= gf_sq(s_in[2]);                       // S_10
        s[11] <= gf_sq(gf_sq(s_in[1]));                // S_12
        s[13] <= gf_sq(s_in[3]);                       // S_14
      end else if (busy) begin
        if (!ph) begin
          d <= d ^ a_p;
          if (i == 4'(T)) ph <= 1'b1;
          else            i  <= i + 4'd1;
        end else begin
          sig[i] <= a_p ^ b_p;
          tau[i] <= swap ? ((i != 4'd0) ? sig[i - 4'd1] : 13'd0)
                         : ((i > 4'd1) ? tau[i - 4'd2] : 13'd0);
          if (i == 4'd0) begin
            if (swap) begin
              gam <= d;
              dd  <= {1'b0, k, 1'b1} - dd;
            end
            d  <= '0;
            ph <= 1'b0;
            if (k == 3'(T - 1)) begin
              busy <= 1'b0;
              done <= 1'b1;
            end else begin
              k <= k + 3'd1;
            end
          end else begin
            i <= i - 4'd1;
          end
        end
      end
    end
  end

endmodule : bch_bm

`default_nettype wire
